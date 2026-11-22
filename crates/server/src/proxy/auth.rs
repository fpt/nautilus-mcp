//! OAuth for remote MCP servers: the credential store, the bearer token a
//! connection sends (refreshed when it is about to expire), and the
//! interactive authorization-code + PKCE flow behind `nautilus-mcp auth`.
//!
//! The flow follows the MCP authorization spec:
//!
//! 1. probe the server without credentials; a 401 names the protected
//!    resource metadata (RFC 9728), or the well-known location is tried;
//! 2. that names the authorization server, whose metadata (RFC 8414, then
//!    OpenID discovery, then the spec's default paths) gives the endpoints;
//! 3. a client is reused, given (`--client-id`), or registered (RFC 7591);
//! 4. the browser is sent to the authorization endpoint with a PKCE S256
//!    challenge and the `resource` indicator (RFC 8707), and a loopback
//!    listener on `127.0.0.1` receives the code;
//! 5. the code is exchanged, and the credentials stored.
//!
//! Credentials are one 0600 JSON file per normalized server URL in a 0700
//! `credentials/` directory next to the config — plain files protected by
//! permissions, not the OS keychain. They are keyed by URL, so renaming a
//! server keeps them.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::config::write_private;
use super::conn::ConnError;

pub const CLIENT_NAME: &str = "nautilus-mcp";
const CALLBACK_PATH: &str = "/callback";

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Token {
    pub access_token: String,
    #[serde(default)]
    pub token_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Credentials {
    pub server_url: String,
    pub client_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub client_secret: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub redirect_uri: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scopes: Vec<String>,
    /// Kept so a refresh needs no rediscovery.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub token_endpoint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<Token>,
}

#[derive(Debug, Clone)]
pub struct Store {
    pub dir: PathBuf,
}

/// Equivalent spellings share credentials: scheme and host lowercased,
/// fragment and trailing slash dropped, query kept.
pub fn normalize(server_url: &str) -> String {
    match url::Url::parse(server_url.trim()) {
        Ok(mut u) => {
            u.set_fragment(None);
            let path = u.path().trim_end_matches('/').to_string();
            u.set_path(&path);
            // `Url` already lowercases scheme and host.
            let s = u.to_string();
            if path.is_empty() && u.query().is_none() {
                s.trim_end_matches('/').to_string()
            } else {
                s
            }
        }
        Err(_) => server_url.to_string(),
    }
}

impl Store {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn path(&self, server_url: &str) -> PathBuf {
        let digest = Sha256::digest(normalize(server_url).as_bytes());
        let hex: String = digest[..8].iter().map(|b| format!("{b:02x}")).collect();
        self.dir.join(format!("{hex}.json"))
    }

    pub fn load(&self, server_url: &str) -> Result<Option<Credentials>, String> {
        let text = match std::fs::read_to_string(self.path(server_url)) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("read credentials: {e}")),
        };
        let c: Credentials = serde_json::from_str(&text)
            .map_err(|e| format!("parse credentials for {server_url}: {e}"))?;
        // A collision or a hand-edited file: never hand out another server's token.
        if normalize(&c.server_url) != normalize(server_url) {
            return Ok(None);
        }
        Ok(Some(c))
    }

    pub fn save(&self, c: &Credentials) -> Result<(), String> {
        let mut c = c.clone();
        c.server_url = normalize(&c.server_url);
        create_private_dir(&self.dir)?;
        let mut text = serde_json::to_string_pretty(&c).map_err(|e| e.to_string())?;
        text.push('\n');
        write_private(&self.path(&c.server_url), text.as_bytes())
    }

    pub fn delete(&self, server_url: &str) -> Result<bool, String> {
        if self.load(server_url)?.is_none() {
            return Ok(false);
        }
        std::fs::remove_file(self.path(server_url))
            .map(|_| true)
            .map_err(|e| format!("delete credentials: {e}"))
    }
}

fn create_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The `Authorization` header for one server, from stored credentials.
/// Reloaded on every use, so `nautilus-mcp auth` run while the proxy is up
/// takes effect on the next request.
#[derive(Debug, Clone)]
pub struct Bearer {
    pub store: Store,
    pub server_url: String,
}

impl Bearer {
    /// `None` when the server was never authorized. `force_refresh` after a 401.
    pub fn header(
        &self,
        agent: &ureq::Agent,
        force_refresh: bool,
    ) -> Result<Option<String>, ConnError> {
        let auth_err = |m: String| ConnError::Auth {
            message: m,
            resource_metadata: None,
        };
        let Some(mut creds) = self.store.load(&self.server_url).map_err(auth_err)? else {
            return Ok(None);
        };
        let Some(token) = creds.token.clone() else {
            return Ok(None);
        };
        let expiring = token.expires_at.is_some_and(|t| t <= now() + 30);
        if !(force_refresh || expiring) {
            return Ok(Some(format!("Bearer {}", token.access_token)));
        }
        let (Some(refresh), false) = (token.refresh_token.clone(), creds.token_endpoint.is_empty())
        else {
            return if force_refresh {
                Err(auth_err(
                    "the stored token was rejected and cannot be refreshed".into(),
                ))
            } else {
                Ok(Some(format!("Bearer {}", token.access_token)))
            };
        };
        let mut form = vec![
            ("grant_type", "refresh_token".to_string()),
            ("refresh_token", refresh.clone()),
            ("client_id", creds.client_id.clone()),
            ("resource", self.server_url.clone()),
        ];
        if !creds.client_secret.is_empty() {
            form.push(("client_secret", creds.client_secret.clone()));
        }
        let fresh = token_request(agent, &creds.token_endpoint, &form)
            .map_err(|e| auth_err(format!("refreshing the token failed: {e}")))?;
        let mut fresh = fresh;
        // Servers may omit a new refresh token; the old one stays valid.
        if fresh.refresh_token.is_none() {
            fresh.refresh_token = Some(refresh);
        }
        let header = format!("Bearer {}", fresh.access_token);
        creds.token = Some(fresh);
        self.store.save(&creds).map_err(auth_err)?;
        Ok(Some(header))
    }
}

/// POST a form to a token endpoint and read the token.
fn token_request(
    agent: &ureq::Agent,
    endpoint: &str,
    form: &[(&str, String)],
) -> Result<Token, String> {
    let pairs: Vec<(&str, &str)> = form.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let resp = agent
        .post(endpoint)
        .set("Accept", "application/json")
        .send_form(&pairs);
    let body: Value = match resp {
        Ok(r) => read_json(r).map_err(|e| format!("token response: {e}"))?,
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();
            return Err(format!("HTTP {code} from {endpoint}: {}", text.trim()));
        }
        Err(e) => return Err(e.to_string()),
    };
    let access = body
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("no access_token in the response from {endpoint}"))?;
    Ok(Token {
        access_token: access.to_string(),
        token_type: body
            .get("token_type")
            .and_then(Value::as_str)
            .unwrap_or("Bearer")
            .to_string(),
        refresh_token: body
            .get("refresh_token")
            .and_then(Value::as_str)
            .map(String::from),
        expires_at: body
            .get("expires_in")
            .and_then(Value::as_u64)
            .map(|s| now() + s),
    })
}

/// `resource_metadata="…"` from a `WWW-Authenticate: Bearer …` header.
pub fn resource_metadata_from(www_authenticate: &str) -> Option<String> {
    let lower = www_authenticate.to_ascii_lowercase();
    let at = lower.find("resource_metadata=")? + "resource_metadata=".len();
    let rest = &www_authenticate[at..];
    let value = match rest.strip_prefix('"') {
        Some(q) => &q[..q.find('"')?],
        None => rest.split([',', ' ']).next()?,
    };
    (!value.is_empty()).then(|| value.to_string())
}

fn read_json(r: ureq::Response) -> Result<Value, String> {
    let text = r.into_string().map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| format!("not JSON: {e}"))
}

pub fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .build()
}

fn get_json(agent: &ureq::Agent, url: &str) -> Option<Value> {
    agent
        .get(url)
        .set("Accept", "application/json")
        .set("MCP-Protocol-Version", super::upstream::PROTOCOL_VERSION)
        .timeout(Duration::from_secs(15))
        .call()
        .ok()
        .and_then(|r| read_json(r).ok())
}

fn origin(u: &url::Url) -> String {
    u.origin().ascii_serialization()
}

/// The endpoints of an authorization server.
#[derive(Debug, Clone, PartialEq)]
pub struct Endpoints {
    pub authorization: String,
    pub token: String,
    pub registration: Option<String>,
}

/// Candidate metadata URLs for an issuer, in the order the spec asks for.
pub fn metadata_candidates(issuer: &str) -> Vec<String> {
    let Ok(u) = url::Url::parse(issuer) else {
        return vec![];
    };
    let o = origin(&u);
    let path = u.path().trim_end_matches('/');
    if path.is_empty() {
        return vec![
            format!("{o}/.well-known/oauth-authorization-server"),
            format!("{o}/.well-known/openid-configuration"),
        ];
    }
    vec![
        format!("{o}/.well-known/oauth-authorization-server{path}"),
        format!("{o}/.well-known/openid-configuration{path}"),
        format!("{o}{path}/.well-known/openid-configuration"),
    ]
}

/// Find the authorization server for `server_url` and its endpoints.
pub fn discover(
    agent: &ureq::Agent,
    server_url: &str,
    resource_metadata: Option<&str>,
) -> Result<Endpoints, String> {
    let u = url::Url::parse(server_url).map_err(|e| e.to_string())?;
    let o = origin(&u);
    let path = u.path().trim_end_matches('/');

    let mut prm_urls = Vec::new();
    if let Some(m) = resource_metadata {
        prm_urls.push(m.to_string());
    }
    if !path.is_empty() {
        prm_urls.push(format!("{o}/.well-known/oauth-protected-resource{path}"));
    }
    prm_urls.push(format!("{o}/.well-known/oauth-protected-resource"));

    let issuer = prm_urls
        .iter()
        .find_map(|m| get_json(agent, m))
        .and_then(|prm| {
            prm.get("authorization_servers")?
                .as_array()?
                .first()?
                .as_str()
                .map(String::from)
        })
        .unwrap_or_else(|| o.clone());

    for candidate in metadata_candidates(&issuer) {
        if let Some(meta) = get_json(agent, &candidate) {
            let field = |k: &str| meta.get(k).and_then(Value::as_str).map(String::from);
            if let (Some(a), Some(t)) = (field("authorization_endpoint"), field("token_endpoint")) {
                return Ok(Endpoints {
                    authorization: a,
                    token: t,
                    registration: field("registration_endpoint"),
                });
            }
        }
    }
    // The spec's fallback when no metadata is published.
    let io = url::Url::parse(&issuer).map(|i| origin(&i)).unwrap_or(o);
    Ok(Endpoints {
        authorization: format!("{io}/authorize"),
        token: format!("{io}/token"),
        registration: Some(format!("{io}/register")),
    })
}

fn random_url_safe(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).expect("system randomness");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

pub fn pkce_challenge(verifier: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

pub struct AuthOptions {
    pub client_id: String,
    pub client_secret: String,
    pub scopes: Vec<String>,
    /// 0: reuse the stored redirect port, or pick a free one.
    pub port: u16,
    pub open_browser: bool,
    pub timeout: Duration,
}

/// Run the flow and store the credentials. `resource_metadata` is what the
/// probe's 401 advertised, if anything.
pub fn authorize(
    store: &Store,
    server_url: &str,
    resource_metadata: Option<&str>,
    opts: &AuthOptions,
) -> Result<(), String> {
    let agent = agent();
    let endpoints = discover(&agent, server_url, resource_metadata)?;
    let prev = store.load(server_url)?;

    // Reuse the port of a stored registration so it stays valid.
    let mut port = opts.port;
    if port == 0 && opts.client_id.is_empty() {
        if let Some(p) = prev
            .as_ref()
            .and_then(|c| url::Url::parse(&c.redirect_uri).ok()?.port())
        {
            port = p;
        }
    }
    let listener = TcpListener::bind(("127.0.0.1", port))
        .or_else(|e| {
            if opts.port == 0 && port != 0 {
                TcpListener::bind(("127.0.0.1", 0)) // taken; register afresh
            } else {
                Err(e)
            }
        })
        .map_err(|e| format!("listen for the OAuth callback: {e}"))?;
    let bound = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect_uri = format!("http://127.0.0.1:{bound}{CALLBACK_PATH}");

    let mut client_id = opts.client_id.clone();
    let mut client_secret = opts.client_secret.clone();
    let mut scopes = opts.scopes.clone();
    if client_id.is_empty() {
        if let Some(p) = prev.as_ref().filter(|p| p.redirect_uri == redirect_uri) {
            client_id = p.client_id.clone();
            client_secret = p.client_secret.clone();
            if scopes.is_empty() {
                scopes = p.scopes.clone();
            }
        }
    }
    if client_id.is_empty() {
        eprintln!("Registering {CLIENT_NAME} with the authorization server...");
        let endpoint = endpoints
            .registration
            .clone()
            .ok_or("the authorization server offers no dynamic registration; pass --client-id")?;
        let (id, secret) = register(&agent, &endpoint, &redirect_uri, &scopes).map_err(|e| {
            format!(
                "dynamic client registration failed (pass --client-id if the server needs a \
                 pre-registered client): {e}"
            )
        })?;
        client_id = id;
        client_secret = secret;
    }

    let verifier = random_url_safe(32);
    let state = random_url_safe(16);
    let mut auth_url = url::Url::parse(&endpoints.authorization).map_err(|e| e.to_string())?;
    {
        let mut q = auth_url.query_pairs_mut();
        q.append_pair("response_type", "code")
            .append_pair("client_id", &client_id)
            .append_pair("redirect_uri", &redirect_uri)
            .append_pair("code_challenge", &pkce_challenge(&verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &state)
            .append_pair("resource", server_url);
        if !scopes.is_empty() {
            q.append_pair("scope", &scopes.join(" "));
        }
    }

    eprintln!("Open this URL to authorize {CLIENT_NAME}:\n\n  {auth_url}\n");
    if opts.open_browser {
        if let Err(e) = open_browser(auth_url.as_str()) {
            eprintln!("(could not open a browser: {e})");
        }
    }
    eprintln!("Waiting for authorization...");

    let (code, got_state) = wait_callback(&listener, opts.timeout)?;
    if got_state != state {
        return Err("the callback's state does not match; refusing the code".into());
    }

    let mut form = vec![
        ("grant_type", "authorization_code".to_string()),
        ("code", code),
        ("redirect_uri", redirect_uri.clone()),
        ("client_id", client_id.clone()),
        ("code_verifier", verifier),
        ("resource", server_url.to_string()),
    ];
    if !client_secret.is_empty() {
        form.push(("client_secret", client_secret.clone()));
    }
    let token = token_request(&agent, &endpoints.token, &form)
        .map_err(|e| format!("exchange the authorization code: {e}"))?;

    store.save(&Credentials {
        server_url: server_url.to_string(),
        client_id,
        client_secret,
        redirect_uri,
        scopes,
        token_endpoint: endpoints.token,
        token: Some(token),
    })
}

fn register(
    agent: &ureq::Agent,
    endpoint: &str,
    redirect_uri: &str,
    scopes: &[String],
) -> Result<(String, String), String> {
    let mut body = serde_json::json!({
        "client_name": CLIENT_NAME,
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    });
    if !scopes.is_empty() {
        body["scope"] = scopes.join(" ").into();
    }
    let resp = agent
        .post(endpoint)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_string(&body.to_string());
    let v: Value = match resp {
        Ok(r) => read_json(r)?,
        Err(ureq::Error::Status(code, r)) => {
            return Err(format!(
                "HTTP {code}: {}",
                r.into_string().unwrap_or_default().trim()
            ))
        }
        Err(e) => return Err(e.to_string()),
    };
    let id = v
        .get("client_id")
        .and_then(Value::as_str)
        .ok_or("no client_id in the registration response")?;
    let secret = v
        .get("client_secret")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Ok((id.to_string(), secret.to_string()))
}

/// Accept connections until the callback arrives or the time runs out.
fn wait_callback(listener: &TcpListener, timeout: Duration) -> Result<(String, String), String> {
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let deadline = Instant::now() + timeout;
    loop {
        if Instant::now() > deadline {
            return Err(format!(
                "timed out after {} waiting for authorization",
                super::conn::human(timeout)
            ));
        }
        let (mut stream, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
            Err(e) => return Err(e.to_string()),
        };
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).is_err() {
            continue;
        }
        let target = line.split_whitespace().nth(1).unwrap_or("");
        let Ok(u) = url::Url::parse(&format!("http://127.0.0.1{target}")) else {
            continue;
        };
        if u.path() != CALLBACK_PATH {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            continue;
        }
        let q = |k: &str| {
            u.query_pairs()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.into_owned())
        };
        let result = match (q("error"), q("code")) {
            (Some(err), _) => Err(format!(
                "authorization denied: {err} {}",
                q("error_description").unwrap_or_default()
            )),
            (None, Some(code)) => Ok((code, q("state").unwrap_or_default())),
            (None, None) => Err("the authorization callback carried no code".to_string()),
        };
        let msg = match &result {
            Ok(_) => "Authorization complete. You can close this window.".to_string(),
            Err(e) => format!("Authorization failed: {e}"),
        };
        let page = format!(
            "<!doctype html><title>nautilus-mcp</title><p>{}</p>",
            html_escape(&msg)
        );
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
            page.len()
        );
        return result;
    }
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub fn open_browser(url: &str) -> std::io::Result<()> {
    let program = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    std::process::Command::new(program)
        .arg(url)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_normalize_for_lookup() {
        assert_eq!(
            normalize("HTTPS://Example.COM/mcp/"),
            "https://example.com/mcp"
        );
        assert_eq!(
            normalize("https://example.com/mcp#x"),
            "https://example.com/mcp"
        );
        assert_eq!(normalize("https://example.com/"), "https://example.com");
        assert_eq!(
            normalize("https://example.com/mcp?a=1"),
            "https://example.com/mcp?a=1"
        );
    }

    #[test]
    fn the_store_keys_by_normalized_url_and_refuses_strangers() {
        let dir = std::env::temp_dir().join(format!("nautilus-creds-{}", std::process::id()));
        let store = Store::new(dir.clone());
        assert!(store.load("https://x.example/mcp").unwrap().is_none());
        store
            .save(&Credentials {
                server_url: "https://X.example/mcp/".into(),
                client_id: "abc".into(),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            store
                .load("https://x.example/mcp")
                .unwrap()
                .unwrap()
                .client_id,
            "abc"
        );
        // A file whose URL does not match the name it was looked up by.
        let other = store.path("https://other.example");
        std::fs::copy(store.path("https://x.example/mcp"), &other).unwrap();
        assert!(store.load("https://other.example").unwrap().is_none());
        assert!(store.delete("https://x.example/mcp").unwrap());
        assert!(!store.delete("https://x.example/mcp").unwrap());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn resource_metadata_is_read_from_the_challenge() {
        assert_eq!(
            resource_metadata_from(
                r#"Bearer error="invalid_token", resource_metadata="https://a.example/.well-known/oauth-protected-resource""#
            )
            .as_deref(),
            Some("https://a.example/.well-known/oauth-protected-resource")
        );
        assert_eq!(resource_metadata_from("Bearer realm=x"), None);
    }

    #[test]
    fn metadata_is_looked_for_where_the_specs_say() {
        assert_eq!(
            metadata_candidates("https://auth.example/tenant1"),
            vec![
                "https://auth.example/.well-known/oauth-authorization-server/tenant1",
                "https://auth.example/.well-known/openid-configuration/tenant1",
                "https://auth.example/tenant1/.well-known/openid-configuration",
            ]
        );
        assert_eq!(metadata_candidates("https://auth.example").len(), 2);
    }

    /// RFC 7636 appendix B.
    #[test]
    fn pkce_matches_the_rfc_example() {
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }
}
