//! `[servers.*]` and `[wrapper.*]` in the nautilus config file.
//!
//! The same file the Swift server reads for `[tts]`: one config for one
//! server. The proxied servers are **the allowlist** — nothing is launched,
//! contacted or run that is not listed here, and the file lives in the user's
//! home, outside any project, so a project's MCP configuration cannot widen it.
//!
//! Inside `[servers.*]` and `[wrapper.*]` an unknown key is an error, so a typo
//! such as `comand` is reported rather than silently disabling a setting. At
//! the top level unknown keys are left alone: `[tts]` belongs to the Swift
//! server, and a config written for a later version still loads.
//!
//! Edits (`add`, `wrap`, `rm`) go through `toml_edit`, so comments and
//! formatting written by hand survive — and so does `[tts]`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;

/// Joins a server name and a tool name: `godev__search_godoc`.
pub const TOOL_SEPARATOR: &str = "__";

/// Built-in tool names start with this; server and wrapper names may not.
pub const RESERVED_PREFIX: &str = "nautilus";

pub const DEFAULT_WRAPPER_TIMEOUT: Duration = Duration::from_secs(600);
pub const DEFAULT_MAX_OUTPUT: usize = 100_000;

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Server {
    /// Absolute path of a stdio server executable.
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Added to the command's environment; values may reference `${NAME}`.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// Extra absolute paths whose change restarts the server.
    #[serde(default)]
    pub watch: Vec<String>,

    /// A streamable HTTP or SSE endpoint.
    #[serde(default)]
    pub url: String,
    /// `http` or `sse`; empty picks by the URL path.
    #[serde(default)]
    pub transport: String,
    /// Sent with every request; values may reference `${NAME}`.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

impl Server {
    pub fn is_remote(&self) -> bool {
        !self.url.is_empty()
    }

    /// The target, for humans.
    pub fn target(&self) -> String {
        if self.is_remote() {
            return self.url.clone();
        }
        let mut s = self.command.clone();
        for a in &self.args {
            s.push(' ');
            s.push_str(a);
        }
        s
    }

    pub fn validate(&self) -> Result<(), String> {
        match (self.command.is_empty(), self.url.is_empty()) {
            (false, false) => return Err("set either command or url, not both".into()),
            (true, true) => return Err("command or url is required".into()),
            _ => {}
        }
        if self.is_remote() {
            if !self.args.is_empty() || !self.env.is_empty() || !self.watch.is_empty() {
                return Err("args, env and watch apply only to command servers".into());
            }
            resolve_transport(&self.url, &self.transport)?;
            for name in self.headers.keys() {
                parse_header(&format!("{name}: x"))
                    .map_err(|_| format!("invalid header name {name:?}"))?;
            }
        } else {
            if !Path::new(&self.command).is_absolute() {
                return Err(format!(
                    "command {:?} must be an absolute path",
                    self.command
                ));
            }
            if !self.transport.is_empty() || !self.headers.is_empty() {
                return Err("transport and headers apply only to url servers".into());
            }
            for w in &self.watch {
                if !Path::new(w).is_absolute() {
                    return Err(format!("watch path {w:?} must be absolute"));
                }
            }
        }
        Ok(())
    }
}

/// A tool that runs one fixed shell command. The agent passes no arguments.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wrapper {
    pub command: String,
    #[serde(default)]
    pub description: String,
    /// Working directory; `~/` and `${NAME}` expand.
    #[serde(default)]
    pub dir: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// Go duration syntax: `90s`, `5m`, `1h30m`. Default 10m.
    #[serde(default)]
    pub timeout: String,
    /// Bytes kept from the end of stdout and of stderr each.
    #[serde(default)]
    pub max_output: usize,
}

impl Wrapper {
    pub fn validate(&self) -> Result<(), String> {
        if self.command.trim().is_empty() {
            return Err("command is required".into());
        }
        if !self.timeout.is_empty() {
            parse_duration(&self.timeout)?;
        }
        Ok(())
    }

    pub fn timeout(&self) -> Duration {
        match parse_duration(&self.timeout) {
            Ok(d) if !d.is_zero() => d,
            _ => DEFAULT_WRAPPER_TIMEOUT,
        }
    }

    pub fn max_output(&self) -> usize {
        if self.max_output == 0 {
            DEFAULT_MAX_OUTPUT
        } else {
            self.max_output
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub servers: BTreeMap<String, Server>,
    #[serde(default)]
    pub wrapper: BTreeMap<String, Wrapper>,
}

impl Config {
    pub fn validate(&self) -> Result<(), String> {
        for (name, s) in &self.servers {
            validate_name(name)?;
            s.validate().map_err(|e| format!("server {name:?}: {e}"))?;
        }
        for (name, w) in &self.wrapper {
            validate_name(name)?;
            if self.servers.contains_key(name) {
                return Err(format!(
                    "{name:?} is defined both as a server and as a wrapper"
                ));
            }
            w.validate().map_err(|e| format!("wrapper {name:?}: {e}"))?;
        }
        Ok(())
    }
}

/// Names become tool names or tool-name prefixes.
pub fn validate_name(name: &str) -> Result<(), String> {
    let ok_chars = name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    let ok_start = name
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    if !ok_chars || !ok_start || name.len() > 32 || name.contains(TOOL_SEPARATOR) {
        return Err(format!(
            "invalid name {name:?}: use up to 32 letters, digits, '-' or '_' \
             (starting with a letter or digit, without {TOOL_SEPARATOR:?})"
        ));
    }
    if name.to_ascii_lowercase().starts_with(RESERVED_PREFIX) {
        return Err(format!(
            "invalid name {name:?}: names starting with {RESERVED_PREFIX:?} are reserved"
        ));
    }
    Ok(())
}

/// `--config`, else `$NAUTILUS_CONFIG`, else `~/.config/nautilus/config.toml` —
/// the same resolution as the Swift server. `explicit` says whether the user
/// named the path, in which case a missing file is an error, not an empty config.
pub fn resolve_path(flag: Option<&str>) -> (PathBuf, bool) {
    if let Some(p) = flag.filter(|p| !p.is_empty()) {
        return (expand_home(p), true);
    }
    if let Some(p) = std::env::var("NAUTILUS_CONFIG")
        .ok()
        .filter(|p| !p.is_empty())
    {
        return (expand_home(&p), true);
    }
    (home().join(".config/nautilus/config.toml"), false)
}

/// Credentials live next to the config.
pub fn credentials_dir(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .unwrap_or(Path::new("."))
        .join("credentials")
}

/// Load and validate. A missing file is an empty config.
pub fn load(path: &Path) -> Result<Config, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Config::default()),
        Err(e) => return Err(format!("read {}: {e}", path.display())),
    };
    let cfg: Config = toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    cfg.validate()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(cfg)
}

/// An edit of the file that keeps everything it does not touch.
pub struct Editor {
    path: PathBuf,
    doc: toml_edit::DocumentMut,
}

impl Editor {
    pub fn open(path: &Path) -> Result<Self, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(format!("read {}: {e}", path.display())),
        };
        let doc = text
            .parse::<toml_edit::DocumentMut>()
            .map_err(|e| format!("{}: {e}", path.display()))?;
        // Refuse to edit a file that does not validate: rewriting it would
        // bless whatever is wrong with it.
        load(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            doc,
        })
    }

    fn section(&mut self, key: &str) -> &mut toml_edit::Table {
        let item = self.doc.entry(key).or_insert_with(|| {
            let mut t = toml_edit::Table::new();
            t.set_implicit(true);
            toml_edit::Item::Table(t)
        });
        if !item.is_table() {
            *item = toml_edit::Item::Table(toml_edit::Table::new());
        }
        item.as_table_mut().expect("table")
    }

    /// Insert or replace; returns whether the name existed.
    pub fn set_server(&mut self, name: &str, s: &Server) -> bool {
        let mut t = toml_edit::Table::new();
        let mut put_str = |k: &str, v: &str| {
            if !v.is_empty() {
                t.insert(k, toml_edit::value(v));
            }
        };
        put_str("command", &s.command);
        put_str("url", &s.url);
        put_str("transport", &s.transport);
        if !s.args.is_empty() {
            t.insert("args", toml_edit::value(array(&s.args)));
        }
        if !s.watch.is_empty() {
            t.insert("watch", toml_edit::value(array(&s.watch)));
        }
        if !s.env.is_empty() {
            t.insert("env", toml_edit::value(inline(&s.env)));
        }
        if !s.headers.is_empty() {
            t.insert("headers", toml_edit::value(inline(&s.headers)));
        }
        self.section("servers")
            .insert(name, toml_edit::Item::Table(t))
            .is_some()
    }

    pub fn set_wrapper(&mut self, name: &str, w: &Wrapper) -> bool {
        let mut t = toml_edit::Table::new();
        t.insert("command", toml_edit::value(&w.command));
        for (k, v) in [
            ("description", &w.description),
            ("dir", &w.dir),
            ("timeout", &w.timeout),
        ] {
            if !v.is_empty() {
                t.insert(k, toml_edit::value(v.as_str()));
            }
        }
        if !w.env.is_empty() {
            t.insert("env", toml_edit::value(inline(&w.env)));
        }
        if w.max_output != 0 {
            t.insert("max_output", toml_edit::value(w.max_output as i64));
        }
        self.section("wrapper")
            .insert(name, toml_edit::Item::Table(t))
            .is_some()
    }

    /// Remove a server or wrapper; returns whether anything was removed.
    pub fn remove(&mut self, name: &str) -> bool {
        let mut removed = false;
        for key in ["servers", "wrapper"] {
            if let Some(t) = self.doc.get_mut(key).and_then(|i| i.as_table_mut()) {
                removed |= t.remove(name).is_some();
            }
        }
        removed
    }

    /// Validate the result, then write atomically with mode 0600 (headers may
    /// hold credentials).
    pub fn save(&self) -> Result<(), String> {
        let text = self.doc.to_string();
        let cfg: Config = toml::from_str(&text).map_err(|e| e.to_string())?;
        cfg.validate()?;
        let dir = self.path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        write_private(&self.path, text.as_bytes())
    }
}

fn array(items: &[String]) -> toml_edit::Array {
    items.iter().map(String::as_str).collect()
}

fn inline(map: &BTreeMap<String, String>) -> toml_edit::InlineTable {
    let mut t = toml_edit::InlineTable::new();
    for (k, v) in map {
        t.insert(k, v.as_str().into());
    }
    t
}

/// Write via a temporary file and rename, with mode 0600.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write as _;
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    let result = (|| {
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| format!("write {}: {e}", path.display()))
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn expand_home(p: &str) -> PathBuf {
    let p = p.trim();
    if p == "~" {
        return home();
    }
    match p.strip_prefix("~/") {
        Some(rest) => home().join(rest),
        None => PathBuf::from(p),
    }
}

/// `~/` expanded, made absolute against the working directory. Symlinks are
/// kept, so a symlink retargeted by a build is followed on the next restart.
pub fn abs_path(p: &str) -> Result<PathBuf, String> {
    let p = expand_home(p);
    if p.is_absolute() {
        return Ok(clean(&p));
    }
    std::env::current_dir()
        .map(|cwd| clean(&cwd.join(p)))
        .map_err(|e| format!("working directory: {e}"))
}

/// Lexical `.`/`..` removal, as Go's `filepath.Clean`: no filesystem access,
/// so symlinks stay symlinks.
pub fn clean(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// A command-line argument as the absolute path stored in the config: a bare
/// name is looked up in `PATH`.
pub fn resolve_command(arg: &str) -> Result<PathBuf, String> {
    let arg = arg.trim();
    if arg.is_empty() {
        return Err("empty command".into());
    }
    if arg.contains('/') || arg.starts_with('~') {
        return abs_path(arg);
    }
    look_path(arg).ok_or_else(|| format!("locate {arg:?}: not found in PATH"))
}

pub fn look_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        p.metadata()
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

/// Replace `${NAME}` with the environment variable. A bare `$` is left alone,
/// so values containing dollar signs need no escaping.
pub fn expand_env(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find('}') {
            Some(end)
                if !after[..end].is_empty()
                    && after[..end]
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_')
                    && !after[..end].starts_with(|c: char| c.is_ascii_digit()) =>
            {
                out.push_str(&std::env::var(&after[..end]).unwrap_or_default());
                rest = &after[end + 1..];
            }
            _ => {
                out.push_str("${");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Go's duration syntax, which the config shares with mcpproxy: `90s`, `5m`,
/// `1h30m`, `500ms`.
pub fn parse_duration(s: &str) -> Result<Duration, String> {
    let s = s.trim();
    let bad = || format!("invalid duration {s:?} (want e.g. 90s, 5m, 1h30m)");
    if s == "0" {
        return Ok(Duration::ZERO);
    }
    if s.is_empty() {
        return Err(bad());
    }
    let mut total = 0f64;
    let mut rest = s;
    while !rest.is_empty() {
        let num_len = rest
            .find(|c: char| !(c.is_ascii_digit() || c == '.'))
            .ok_or_else(bad)?;
        let value: f64 = rest[..num_len].parse().map_err(|_| bad())?;
        rest = &rest[num_len..];
        let unit_len = rest
            .find(|c: char| c.is_ascii_digit() || c == '.')
            .unwrap_or(rest.len());
        let scale = match &rest[..unit_len] {
            "h" => 3600.0,
            "m" => 60.0,
            "s" => 1.0,
            "ms" => 0.001,
            "us" | "µs" => 0.000_001,
            "ns" => 0.000_000_001,
            _ => return Err(bad()),
        };
        total += value * scale;
        rest = &rest[unit_len..];
    }
    Ok(Duration::from_secs_f64(total))
}

pub fn is_url(s: &str) -> bool {
    s.starts_with("http://") || s.starts_with("https://")
}

/// An explicit choice wins; otherwise a path ending in `/sse` means SSE.
pub fn resolve_transport(server_url: &str, choice: &str) -> Result<&'static str, String> {
    match choice {
        "http" => Ok("http"),
        "sse" => Ok("sse"),
        "" => {
            let u = url::Url::parse(server_url)
                .map_err(|e| format!("parse server URL {server_url:?}: {e}"))?;
            if !matches!(u.scheme(), "http" | "https") || u.host_str().is_none() {
                return Err(format!(
                    "server URL {server_url:?} must be an absolute http(s) URL"
                ));
            }
            Ok(if u.path().trim_end_matches('/').ends_with("/sse") {
                "sse"
            } else {
                "http"
            })
        }
        other => Err(format!(
            "unknown transport {other:?} (want \"http\" or \"sse\")"
        )),
    }
}

/// A curl-style `Name: value` header.
pub fn parse_header(h: &str) -> Result<(String, String), String> {
    let bad = || format!("header {h:?} must look like \"Name: value\"");
    let (name, value) = h.split_once(':').ok_or_else(bad)?;
    let name = name.trim();
    if name.is_empty() || name.contains([' ', '\t']) {
        return Err(bad());
    }
    Ok((name.to_string(), value.trim().to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_restricted() {
        assert!(validate_name("godev").is_ok());
        assert!(validate_name("my-server_2").is_ok());
        for bad in [
            "",
            "-x",
            "a__b",
            "a b",
            "nautilus_x",
            "NautilusFoo",
            &"x".repeat(33),
        ] {
            assert!(validate_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_typo_inside_a_server_is_an_error_but_tts_is_left_alone() {
        let ok: Config =
            toml::from_str("[tts]\nrate = 0.5\n[servers.a]\ncommand = \"/bin/a\"\n").unwrap();
        assert!(ok.validate().is_ok());
        let err = toml::from_str::<Config>("[servers.a]\ncomand = \"/bin/a\"\n").unwrap_err();
        assert!(err.to_string().contains("comand"), "{err}");
    }

    #[test]
    fn server_kinds_are_exclusive() {
        let both = Server {
            command: "/x".into(),
            url: "https://x".into(),
            ..Default::default()
        };
        assert!(both.validate().is_err());
        let rel = Server {
            command: "x".into(),
            ..Default::default()
        };
        assert!(rel.validate().is_err());
        let remote_env = Server {
            url: "https://x/mcp".into(),
            env: [("A".into(), "b".into())].into(),
            ..Default::default()
        };
        assert!(remote_env.validate().is_err());
    }

    #[test]
    fn transport_is_picked_by_path() {
        assert_eq!(resolve_transport("https://x/sse", "").unwrap(), "sse");
        assert_eq!(resolve_transport("https://x/sse/", "").unwrap(), "sse");
        assert_eq!(resolve_transport("https://x/mcp", "").unwrap(), "http");
        assert_eq!(resolve_transport("https://x/mcp", "sse").unwrap(), "sse");
        assert!(resolve_transport("ftp://x", "").is_err());
        assert!(resolve_transport("https://x", "ws").is_err());
    }

    #[test]
    fn env_references_expand_and_bare_dollars_stay() {
        std::env::set_var("NAUTILUS_TEST_TOKEN", "s3cret");
        assert_eq!(expand_env("Bearer ${NAUTILUS_TEST_TOKEN}"), "Bearer s3cret");
        assert_eq!(expand_env("cost $5 ${"), "cost $5 ${");
        assert_eq!(expand_env("${1X}"), "${1X}");
        assert_eq!(expand_env("${NAUTILUS_TEST_UNSET_VAR}"), "");
    }

    #[test]
    fn paths_are_cleaned_lexically() {
        assert_eq!(clean(Path::new("/a/./b/../c")), PathBuf::from("/a/c"));
        assert_eq!(abs_path("/x/./y").unwrap(), PathBuf::from("/x/y"));
    }

    #[test]
    fn durations_use_go_syntax() {
        assert_eq!(parse_duration("90s").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_duration("1h30m").unwrap(), Duration::from_secs(5400));
        assert_eq!(parse_duration("5m0s").unwrap(), Duration::from_secs(300));
        assert_eq!(parse_duration("500ms").unwrap(), Duration::from_millis(500));
        assert!(parse_duration("5 minutes").is_err());
        assert!(parse_duration("").is_err());
    }

    #[test]
    fn headers_parse_like_curl() {
        assert_eq!(
            parse_header("Authorization: Bearer x").unwrap(),
            ("Authorization".into(), "Bearer x".into())
        );
        assert!(parse_header("no colon").is_err());
        assert!(parse_header("Bad Name: x").is_err());
    }

    #[test]
    fn editing_keeps_comments_and_other_sections() {
        let dir = std::env::temp_dir().join(format!("nautilus-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(&path, "# my voice settings\n[tts]\nrate = 0.5 # slow\n").unwrap();

        let mut ed = Editor::open(&path).unwrap();
        let existed = ed.set_server(
            "godev",
            &Server {
                command: "/bin/godev".into(),
                args: vec!["serve".into()],
                ..Default::default()
            },
        );
        assert!(!existed);
        ed.set_wrapper(
            "test",
            &Wrapper {
                command: "make test".into(),
                timeout: "5m".into(),
                ..Default::default()
            },
        );
        ed.save().unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# my voice settings"), "{text}");
        assert!(text.contains("rate = 0.5 # slow"), "{text}");
        assert!(text.contains("[servers.godev]"), "{text}");
        assert!(!text.contains("[servers]\n"), "implicit parent: {text}");
        let cfg = load(&path).unwrap();
        assert_eq!(cfg.servers["godev"].args, vec!["serve"]);
        assert_eq!(cfg.wrapper["test"].timeout(), Duration::from_secs(300));

        let mut ed = Editor::open(&path).unwrap();
        assert!(ed.remove("godev"));
        assert!(!ed.remove("nothing"));
        ed.save().unwrap();
        assert!(load(&path).unwrap().servers.is_empty());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
