//! The terminal side: edit the config, and talk to configured servers.
//!
//! Exit status: 0 success; 1 the tool reported an error, validation failed, the
//! server is unknown, or connecting or authorizing failed; 2 a usage error.
//! Flags go before positional arguments, and may be spelled `-x` or `--x`.

use std::collections::BTreeMap;
use std::io::Read;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::proxy::auth::{self, AuthOptions, Store};
use crate::proxy::config::{self, Config, Editor, Server, Wrapper, TOOL_SEPARATOR};
use crate::proxy::conn::ConnError;
use crate::proxy::http::{self, RemoteSpec};
use crate::proxy::search;
use crate::proxy::upstream::{tool_name, Dialer, Options, Upstream, PROTOCOL_VERSION};
use crate::proxy::wrapper;

const COMMANDS: [&str; 8] = ["add", "wrap", "rm", "ls", "tools", "call", "auth", "logout"];

pub fn is_command(s: &str) -> bool {
    COMMANDS.contains(&s)
}

pub fn help(cmd: &str) -> Option<&'static str> {
    Some(match cmd {
        "add" => ADD,
        "wrap" => WRAP,
        "rm" => "rm <name>...\n  Remove servers or wrapper tools from the config. A running server applies\n  the change. Stored OAuth credentials are kept; see `logout`.",
        "ls" => "ls [-v]\n  List servers (name, tab, command or URL), then wrapper tools. -v also shows\n  the config path, missing executables and stored credentials.",
        "tools" => TOOLS,
        "call" => CALL,
        "auth" => AUTH,
        "logout" => "logout <name>\n  Delete the OAuth registration and tokens stored by `auth`.",
        _ => return None,
    })
}

const ADD: &str = "\
add [flags] <name> -- <command> [args...]
add [flags] <name> <url>
  Add a backend MCP server to the config, or replace the one with that name.
  Only servers in the config are ever launched or contacted. A running
  nautilus-mcp picks the change up; its tools appear as <name>__<tool>.

  -env KEY=VALUE        command server environment; ${NAME} expands (repeatable)
  -watch path           extra file whose change restarts it (repeatable)
  -transport http|sse   for a URL server, if the guess from the path is wrong
  -header 'Name: value' for a URL server; ${NAME} expands (repeatable)";

const WRAP: &str = "\
wrap [flags] <name> '<shell command>'
wrap [flags] <name> -- <command> [args...]
  Define a tool <name> that runs a fixed shell command with sh -c and returns
  its exit code, stdout and stderr. The agent cannot pass it arguments.

  -d text            description shown to the agent
  -dir path          working directory (default: the server's, i.e. the project)
  -env KEY=VALUE     environment; ${NAME} expands (repeatable)
  -timeout d         kill it after this long (default 10m)
  -max-output n      bytes kept from the end of each stream (default 100000)";

const TOOLS: &str = "\
tools [flags] [<name>...]
  List the tools of the named servers (default: all), as <server>__<tool>.

  -q query   filter with the nautilus_search_tools query forms
  -json      full definitions
  -v         show command servers' stderr";

const CALL: &str = "\
call [flags] <name> <tool> [arguments...]
call [flags] <name>__<tool> [arguments...]
call [flags] <wrapper>
  Call a tool of a configured server, or run a wrapper. Arguments: one JSON
  object, `-` to read one from stdin, or any number of key=value (string)
  and key:=json.

  -json        print the raw result
  -timeout d   give up after d
  -v           show a command server's stderr";

const AUTH: &str = "\
auth [flags] <name>
  Run the OAuth flow in the browser for the URL server <name> and store the
  credentials. A running nautilus-mcp uses them on its next reconnect.

  -scope s              scope to request (repeatable or comma-separated)
  -client-id, -client-secret  a pre-registered client
  -port n               callback port (default: reuse, or any free one)
  -no-browser           print the URL instead of opening it
  -force                authorize even if the server needs no authorization
  -timeout d            how long to wait (default 5m)";

struct Flags {
    values: BTreeMap<String, Vec<String>>,
    bools: Vec<String>,
    rest: Vec<String>,
}

impl Flags {
    fn one(&self, k: &str) -> Option<&str> {
        self.values
            .get(k)
            .and_then(|v| v.last())
            .map(String::as_str)
    }
    fn all(&self, k: &str) -> &[String] {
        self.values.get(k).map(Vec::as_slice).unwrap_or(&[])
    }
    fn has(&self, k: &str) -> bool {
        self.bools.iter().any(|b| b == k)
    }
}

/// Flags until the first positional or `--` (which is kept for the caller).
fn parse_flags(args: &[String], valued: &[&str], boolean: &[&str]) -> Result<Flags, String> {
    let mut f = Flags {
        values: BTreeMap::new(),
        bools: vec![],
        rest: vec![],
    };
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" || !a.starts_with('-') || a == "-" {
            break;
        }
        let name = a.trim_start_matches('-');
        let (name, inline) = match name.split_once('=') {
            Some((n, v)) => (n, Some(v.to_string())),
            None => (name, None),
        };
        if boolean.contains(&name) {
            f.bools.push(name.to_string());
        } else if valued.contains(&name) {
            let v = match inline {
                Some(v) => v,
                None => {
                    i += 1;
                    args.get(i)
                        .cloned()
                        .ok_or_else(|| format!("{a} needs a value"))?
                }
            };
            f.values.entry(name.to_string()).or_default().push(v);
        } else {
            return Err(format!("unknown flag {a}"));
        }
        i += 1;
    }
    f.rest = args[i..].to_vec();
    Ok(f)
}

fn fail(e: impl std::fmt::Display) -> i32 {
    eprintln!("nautilus-mcp: {e}");
    1
}

fn usage(cmd: &str, e: impl std::fmt::Display) -> i32 {
    eprintln!("nautilus-mcp: {e}\n\n{}", help(cmd).unwrap_or(""));
    2
}

fn env_path() -> std::path::PathBuf {
    config::resolve_path(None).0
}

fn store() -> Store {
    Store::new(config::credentials_dir(&env_path()))
}

fn load() -> Result<Config, String> {
    config::load(&env_path())
}

pub fn run(cmd: &str, args: &[String]) -> i32 {
    let r = match cmd {
        "add" => add(args),
        "wrap" => wrap(args),
        "rm" => rm(args),
        "ls" => ls(args),
        "tools" => tools(args),
        "call" => call(args),
        "auth" => auth_cmd(args),
        "logout" => logout(args),
        _ => unreachable!(),
    };
    match r {
        Ok(code) => code,
        Err(Exit::Usage(e)) => usage(cmd, e),
        Err(Exit::Fail(e)) => fail(e),
    }
}

enum Exit {
    Usage(String),
    Fail(String),
}

impl From<String> for Exit {
    fn from(s: String) -> Self {
        Exit::Fail(s)
    }
}

fn add(args: &[String]) -> Result<i32, Exit> {
    let f =
        parse_flags(args, &["env", "watch", "transport", "header"], &[]).map_err(Exit::Usage)?;
    let mut rest = f.rest.clone();
    if rest.len() < 2 {
        return Err(Exit::Usage("need a name and a command or URL".into()));
    }
    let name = rest.remove(0);
    if rest.first().map(String::as_str) == Some("--") {
        rest.remove(0);
    }
    if rest.is_empty() {
        return Err(Exit::Usage("missing command or URL".into()));
    }
    config::validate_name(&name)?;

    let srv = if config::is_url(&rest[0]) {
        if rest.len() > 1 {
            return Err(Exit::Fail(format!(
                "unexpected arguments after the URL: {:?}",
                &rest[1..]
            )));
        }
        if !f.all("env").is_empty() || !f.all("watch").is_empty() {
            return Err(Exit::Fail(
                "-env and -watch apply only to command servers".into(),
            ));
        }
        let mut headers = BTreeMap::new();
        for h in f.all("header") {
            let (k, v) = config::parse_header(h)?;
            headers.insert(k, v);
        }
        Server {
            url: rest[0].clone(),
            transport: f.one("transport").unwrap_or("").to_string(),
            headers,
            ..Default::default()
        }
    } else {
        if f.one("transport").is_some() || !f.all("header").is_empty() {
            return Err(Exit::Fail(
                "-transport and -header apply only to URL servers".into(),
            ));
        }
        let mut env = BTreeMap::new();
        for kv in f.all("env") {
            let (k, v) = kv
                .split_once('=')
                .filter(|(k, _)| !k.is_empty())
                .ok_or_else(|| format!("-env {kv:?} must be KEY=VALUE"))?;
            env.insert(k.to_string(), v.to_string());
        }
        let watch = f
            .all("watch")
            .iter()
            .map(|w| config::abs_path(w).map(|p| p.display().to_string()))
            .collect::<Result<Vec<_>, _>>()?;
        Server {
            command: config::resolve_command(&rest[0])?.display().to_string(),
            args: rest[1..].to_vec(),
            env,
            watch,
            ..Default::default()
        }
    };
    srv.validate()?;

    let mut ed = Editor::open(&env_path())?;
    let existed = ed.set_server(&name, &srv);
    ed.save()?;
    println!(
        "{}: {name}\t{}",
        if existed { "updated" } else { "added" },
        srv.target()
    );
    if !srv.is_remote() && !std::path::Path::new(&srv.command).exists() {
        eprintln!("note: {} does not exist yet", srv.command);
    }
    Ok(0)
}

/// Quote words for sh so `-- go test ./...` round-trips.
fn shell_join(words: &[String]) -> String {
    words
        .iter()
        .map(|w| {
            let safe = !w.is_empty()
                && w.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c));
            if safe {
                w.clone()
            } else {
                format!("'{}'", w.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn wrap(args: &[String]) -> Result<i32, Exit> {
    let f = parse_flags(args, &["d", "dir", "env", "timeout", "max-output"], &[])
        .map_err(Exit::Usage)?;
    let rest = &f.rest;
    if rest.len() < 2 {
        return Err(Exit::Usage("need a name and a command".into()));
    }
    let name = &rest[0];
    let words = &rest[1..];
    let command = match words {
        [dd, more @ ..] if dd == "--" && !more.is_empty() => shell_join(more),
        [one] if one != "--" => one.clone(),
        _ => {
            return Err(Exit::Fail(
                "give the command as one quoted string, or after --".into(),
            ))
        }
    };
    config::validate_name(name)?;
    let mut w = Wrapper {
        command: command.clone(),
        description: f.one("d").unwrap_or("").to_string(),
        timeout: f.one("timeout").unwrap_or("").to_string(),
        ..Default::default()
    };
    if let Some(n) = f.one("max-output") {
        w.max_output = n
            .parse()
            .map_err(|_| format!("-max-output {n:?} is not a number"))?;
    }
    if let Some(d) = f.one("dir") {
        w.dir = config::abs_path(d)?.display().to_string();
    }
    for kv in f.all("env") {
        let (k, v) = kv
            .split_once('=')
            .filter(|(k, _)| !k.is_empty())
            .ok_or_else(|| format!("-env {kv:?} must be KEY=VALUE"))?;
        w.env.insert(k.to_string(), v.to_string());
    }
    w.validate()?;
    if load()?.servers.contains_key(name) {
        return Err(Exit::Fail(format!("{name:?} is already a server name")));
    }
    let mut ed = Editor::open(&env_path())?;
    let existed = ed.set_wrapper(name, &w);
    ed.save()?;
    println!(
        "{}: {name}\twrapper: {command}",
        if existed { "updated" } else { "added" }
    );
    Ok(0)
}

fn rm(args: &[String]) -> Result<i32, Exit> {
    if args.is_empty() {
        return Err(Exit::Usage("name at least one server or wrapper".into()));
    }
    let cfg = load()?;
    // All or nothing: an unknown name removes nothing.
    for n in args {
        if !cfg.servers.contains_key(n) && !cfg.wrapper.contains_key(n) {
            return Err(Exit::Fail(format!("no server or wrapper named {n:?}")));
        }
    }
    let mut ed = Editor::open(&env_path())?;
    for n in args {
        ed.remove(n);
    }
    ed.save()?;
    for n in args {
        println!("removed: {n}");
    }
    Ok(0)
}

fn ls(args: &[String]) -> Result<i32, Exit> {
    let f = parse_flags(args, &[], &["v"]).map_err(Exit::Usage)?;
    let verbose = f.has("v");
    if verbose {
        println!("# config: {}", env_path().display());
    }
    let cfg = load()?;
    let creds = store();
    for (name, s) in &cfg.servers {
        let mut line = format!("{name}\t{}", s.target());
        if verbose {
            if !s.is_remote() && !std::path::Path::new(&s.command).exists() {
                line.push_str("\t(missing)");
            }
            if s.is_remote() && creds.load(&s.url).ok().flatten().is_some() {
                line.push_str("\t(authorized)");
            }
        }
        println!("{line}");
    }
    for (name, w) in &cfg.wrapper {
        let mut line = format!("{name}\twrapper: {}", w.command);
        if verbose && !w.dir.is_empty() {
            line.push_str(&format!("\t(in {})", w.dir));
        }
        println!("{line}");
    }
    Ok(0)
}

/// Start one configured server for one-shot use.
fn connect(name: &str, verbose: bool) -> Result<Upstream, String> {
    let cfg = load()?;
    let srv = cfg.servers.get(name).ok_or_else(|| {
        let names: Vec<&str> = cfg.servers.keys().map(String::as_str).collect();
        if names.is_empty() {
            format!(
                "no server named {name:?}; none are configured (add one with `nautilus-mcp add`)"
            )
        } else {
            format!("no server named {name:?}; configured: {}", names.join(", "))
        }
    })?;
    let dialer = Dialer::for_server(name, srv, Some(store()))?;
    let mut up = Upstream::new(
        name,
        &format!("{name}{TOOL_SEPARATOR}"),
        dialer,
        &srv.watch,
        Options {
            settle: Duration::ZERO,
            start_timeout: Duration::from_secs(30),
            pass_stderr: verbose,
            events: None,
        },
    );
    if let Err(e) = up.start() {
        up.close();
        return Err(e);
    }
    Ok(up)
}

fn tools(args: &[String]) -> Result<i32, Exit> {
    let f = parse_flags(args, &["q"], &["json", "v"]).map_err(Exit::Usage)?;
    let cfg = load()?;
    let mut names = f.rest.clone();
    if names.is_empty() {
        names = cfg
            .servers
            .keys()
            .chain(cfg.wrapper.keys())
            .cloned()
            .collect();
        if names.is_empty() {
            return Err(Exit::Fail(
                "nothing is configured (see `nautilus-mcp add` and `wrap`)".into(),
            ));
        }
    }
    let mut out = Vec::new();
    let mut status = 0;
    for name in &names {
        if let Some(w) = cfg.wrapper.get(name) {
            out.push(wrapper::definition(name, w));
            continue;
        }
        match connect(name, f.has("v")) {
            Ok(mut up) => {
                for t in up.tools() {
                    let mut t = t.clone();
                    if let Some(n) = tool_name(&t).map(String::from) {
                        t["name"] = format!("{name}{TOOL_SEPARATOR}{n}").into();
                        out.push(t);
                    }
                }
                up.close();
            }
            Err(e) => {
                eprintln!("nautilus-mcp: {name}: {e}");
                status = 1;
            }
        }
    }
    if let Some(q) = f.one("q") {
        out = search::search(&out, q, 0).tools;
    }
    if f.has("json") {
        println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
    } else {
        for t in &out {
            let desc = t
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .lines()
                .next()
                .unwrap_or("");
            println!("{}\t{desc}", tool_name(t).unwrap_or(""));
        }
    }
    Ok(status)
}

/// `key=value`, `key:=json`, one JSON object, or `-` for stdin.
pub fn parse_tool_arguments(
    words: &[String],
    stdin: impl Read,
) -> Result<Map<String, Value>, String> {
    if let [only] = words {
        if only == "-" || only.trim_start().starts_with('{') {
            let text = if only == "-" {
                let mut s = String::new();
                let mut stdin = stdin;
                stdin
                    .read_to_string(&mut s)
                    .map_err(|e| format!("read arguments from stdin: {e}"))?;
                s
            } else {
                only.clone()
            };
            return match serde_json::from_str::<Value>(&text) {
                Ok(Value::Object(o)) => Ok(o),
                Ok(_) => Err("arguments must be a JSON object".into()),
                Err(e) => Err(format!("arguments must be a JSON object: {e}")),
            };
        }
    }
    let mut args = Map::new();
    for w in words {
        if let Some((k, raw)) = w
            .split_once(":=")
            .filter(|(k, _)| !k.is_empty() && !k.contains('='))
        {
            let v: Value = serde_json::from_str(raw)
                .map_err(|e| format!("argument {w:?}: invalid JSON after \":=\": {e}"))?;
            args.insert(k.to_string(), v);
            continue;
        }
        let (k, v) = w
            .split_once('=')
            .filter(|(k, _)| !k.is_empty())
            .ok_or_else(|| format!("argument {w:?} must be key=value or key:=json"))?;
        args.insert(k.to_string(), Value::String(v.to_string()));
    }
    Ok(args)
}

fn print_result(res: &Value, to_stderr: bool) {
    let print = |s: String| {
        if to_stderr {
            eprintln!("{s}");
        } else {
            println!("{s}");
        }
    };
    let content = res
        .get("content")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for c in &content {
        match c.get("type").and_then(Value::as_str) {
            Some("text") => print(
                c["text"]
                    .as_str()
                    .unwrap_or("")
                    .trim_end_matches('\n')
                    .to_string(),
            ),
            Some(kind @ ("image" | "audio")) => print(format!(
                "[{kind} {}, {} bytes base64]",
                c["mimeType"].as_str().unwrap_or("?"),
                c["data"].as_str().map(str::len).unwrap_or(0)
            )),
            _ => print(c.to_string()),
        }
    }
    if content.is_empty() {
        if let Some(s) = res.get("structuredContent") {
            print(serde_json::to_string_pretty(s).unwrap_or_default());
        }
    }
}

fn call(args: &[String]) -> Result<i32, Exit> {
    let f = parse_flags(args, &["timeout"], &["json", "v"]).map_err(Exit::Usage)?;
    let timeout = f.one("timeout").map(config::parse_duration).transpose()?;
    let rest = &f.rest;
    if rest.is_empty() {
        return Err(Exit::Usage("missing server name".into()));
    }

    let cfg = load()?;
    if let Some(w) = cfg.wrapper.get(&rest[0]) {
        if rest.len() > 1 {
            return Err(Exit::Fail(format!(
                "wrapper tool {:?} takes no arguments",
                rest[0]
            )));
        }
        let limit = match timeout {
            Some(t) if !t.is_zero() && t < w.timeout() => t,
            _ => w.timeout(),
        };
        let r = wrapper::run_with_timeout(w, limit);
        if f.has("json") {
            println!(
                "{}",
                serde_json::to_string_pretty(&r.json()).unwrap_or_default()
            );
        } else {
            print!("{}", r.stdout);
            eprint!("{}", r.stderr);
            if r.stdout_truncated || r.stderr_truncated {
                eprintln!("nautilus-mcp: output was truncated (see max_output)");
            }
        }
        if let Some(e) = &r.error {
            eprintln!("nautilus-mcp: {e}");
        }
        return Ok(if r.exit_code < 0 { 1 } else { r.exit_code });
    }

    let (server, tool, words) = match rest[0].split_once(TOOL_SEPARATOR) {
        Some((s, t)) if !s.is_empty() && !t.is_empty() => {
            (s.to_string(), t.to_string(), &rest[1..])
        }
        _ if rest.len() >= 2 => (rest[0].clone(), rest[1].clone(), &rest[2..]),
        _ => return Err(Exit::Usage("missing tool name".into())),
    };
    let arguments = parse_tool_arguments(words, std::io::stdin())?;
    let mut up = connect(&server, f.has("v"))?;

    let result = match timeout.filter(|t| !t.is_zero()) {
        // The call itself has no deadline; a watchdog ends the process instead.
        Some(t) => {
            std::thread::spawn(move || {
                std::thread::sleep(t);
                eprintln!(
                    "nautilus-mcp: call timed out after {}",
                    crate::proxy::conn::human(t)
                );
                std::process::exit(1);
            });
            up.call(&tool, Value::Object(arguments))
        }
        None => up.call(&tool, Value::Object(arguments)),
    };
    up.close();

    let is_error = result
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if f.has("json") {
        println!(
            "{}",
            serde_json::to_string_pretty(&result).unwrap_or_default()
        );
    } else {
        print_result(&result, is_error);
    }
    Ok(i32::from(is_error))
}

fn remote_server(name: &str) -> Result<Server, String> {
    let cfg = load()?;
    let srv = cfg
        .servers
        .get(name)
        .ok_or_else(|| format!("no server named {name:?}"))?;
    if !srv.is_remote() {
        return Err(format!(
            "server {name:?} is a command, not a URL; only URL servers use authorization"
        ));
    }
    Ok(srv.clone())
}

/// Connect without credentials. `Ok(None)`: no authorization needed.
/// `Ok(Some(meta))`: a 401, with the resource metadata URL if it named one.
fn probe(srv: &Server) -> Result<Option<Option<String>>, String> {
    let spec = RemoteSpec {
        url: srv.url.clone(),
        transport: config::resolve_transport(&srv.url, &srv.transport)?,
        headers: srv
            .headers
            .iter()
            .map(|(k, v)| (k.clone(), config::expand_env(v)))
            .collect(),
        bearer: None,
        events: None,
    };
    let attempt = http::connect(spec).and_then(|mut c| {
        let r = c.request(
            "initialize",
            serde_json::json!({ "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                                "clientInfo": { "name": auth::CLIENT_NAME, "version": env!("CARGO_PKG_VERSION") } }),
            Some(Duration::from_secs(30)),
        );
        c.close();
        r
    });
    match attempt {
        Ok(_) => Ok(None),
        Err(ConnError::Auth {
            resource_metadata, ..
        }) => Ok(Some(resource_metadata)),
        Err(e) => Err(format!("probe {}: {e}", srv.url)),
    }
}

fn auth_cmd(args: &[String]) -> Result<i32, Exit> {
    let f = parse_flags(
        args,
        &["client-id", "client-secret", "scope", "port", "timeout"],
        &["no-browser", "force"],
    )
    .map_err(Exit::Usage)?;
    let [name] = f.rest.as_slice() else {
        return Err(Exit::Usage("name exactly one URL server".into()));
    };
    let srv = remote_server(name)?;
    let meta = match probe(&srv)? {
        Some(meta) => meta,
        None if f.has("force") => None,
        None => {
            eprintln!(
                "{name} ({}) accepts unauthenticated requests; nothing to do (use -force to \
                 authorize anyway).",
                srv.url
            );
            return Ok(0);
        }
    };
    let opts = AuthOptions {
        client_id: f.one("client-id").unwrap_or("").to_string(),
        client_secret: f.one("client-secret").unwrap_or("").to_string(),
        scopes: f
            .all("scope")
            .iter()
            .flat_map(|s| s.split(','))
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect(),
        port: match f.one("port") {
            Some(p) => p
                .parse()
                .map_err(|_| format!("-port {p:?} is not a port"))?,
            None => 0,
        },
        open_browser: !f.has("no-browser"),
        timeout: match f.one("timeout") {
            Some(t) => config::parse_duration(t)?,
            None => Duration::from_secs(300),
        },
    };
    auth::authorize(&store(), &srv.url, meta.as_deref(), &opts)?;

    let mut up = connect(name, false)
        .map_err(|e| format!("authorized, but connecting with the new credentials failed: {e}"))?;
    eprintln!("Authorized. {name} has {} tools.", up.tools().len());
    up.close();
    Ok(0)
}

fn logout(args: &[String]) -> Result<i32, Exit> {
    let [name] = args else {
        return Err(Exit::Usage("name exactly one URL server".into()));
    };
    let srv = remote_server(name)?;
    if store().delete(&srv.url)? {
        eprintln!("deleted credentials for {name}");
        Ok(0)
    } else {
        eprintln!("no stored credentials for {name}");
        Ok(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn arguments_mix_strings_and_json() {
        let a = parse_tool_arguments(
            &s(&["query=go mcp", "limit:=5", "expr=a=b", "tags:=[\"x\"]"]),
            &b""[..],
        )
        .unwrap();
        assert_eq!(a["query"], "go mcp");
        assert_eq!(a["limit"], 5);
        assert_eq!(a["expr"], "a=b");
        assert_eq!(a["tags"][0], "x");
        let a = parse_tool_arguments(&s(&["{\"q\": 1}"]), &b""[..]).unwrap();
        assert_eq!(a["q"], 1);
        let a = parse_tool_arguments(&s(&["-"]), &b"{\"q\": 2}"[..]).unwrap();
        assert_eq!(a["q"], 2);
        assert!(parse_tool_arguments(&s(&["novalue"]), &b""[..]).is_err());
        assert!(parse_tool_arguments(&s(&["n:=nope"]), &b""[..]).is_err());
    }

    #[test]
    fn flags_stop_at_the_first_positional() {
        let f = parse_flags(
            &s(&["-env", "A=1", "--watch=/x", "dev", "--", "./bin", "-v"]),
            &["env", "watch"],
            &[],
        )
        .unwrap();
        assert_eq!(f.all("env"), ["A=1"]);
        assert_eq!(f.one("watch"), Some("/x"));
        assert_eq!(f.rest, s(&["dev", "--", "./bin", "-v"]));
        assert!(parse_flags(&s(&["-nope"]), &[], &[]).is_err());
    }

    #[test]
    fn shell_join_quotes_what_needs_it() {
        assert_eq!(shell_join(&s(&["go", "test", "./..."])), "go test ./...");
        assert_eq!(
            shell_join(&s(&["printf", "%s|", "a b", "it's"])),
            r"printf '%s|' 'a b' 'it'\''s'"
        );
    }
}
