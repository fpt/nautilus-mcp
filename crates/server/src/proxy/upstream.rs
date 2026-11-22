//! One upstream MCP server, supervised.
//!
//! The hot path is [`Upstream::call`]: stat the watched files, restart if they
//! changed or the process is down, check the tool exists, validate the
//! arguments against **the running build's** input schema, forward. A call
//! shaped for an older build fails fast with the current schema attached.
//! Failures are tool error results the agent can read, never protocol errors.
//!
//! A failed restart stops the old process — it no longer reflects the code on
//! disk — but keeps the last tool list, so the agent still sees the tools and
//! gets the start error, with the server's stderr, when it calls one.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};

use super::auth::{Bearer, Store};
use super::config::{expand_env, resolve_transport, Server, TOOL_SEPARATOR};
use super::conn::{ConnError, Connection, Events, SharedTail, StdioConn, StdioSpec, Tail};
use super::http::{self, RemoteSpec};

/// What we ask upstreams for. They may answer with an older revision; every
/// method used here exists in all of them.
pub const PROTOCOL_VERSION: &str = "2025-06-18";
const STDERR_TAIL_BYTES: usize = 4096;
const MAX_SETTLE_WAIT: Duration = Duration::from_secs(30);

/// How to reach an upstream.
pub enum Dialer {
    Stdio {
        command: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    },
    Remote {
        url: String,
        transport: &'static str,
        headers: Vec<(String, String)>,
        creds: Option<Store>,
        auth_command: String,
    },
}

impl Dialer {
    pub fn for_server(name: &str, srv: &Server, creds: Option<Store>) -> Result<Self, String> {
        srv.validate()?;
        if srv.is_remote() {
            Ok(Dialer::Remote {
                url: srv.url.clone(),
                transport: resolve_transport(&srv.url, &srv.transport)?,
                headers: srv
                    .headers
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect(),
                creds,
                auth_command: format!("nautilus-mcp auth {name}"),
            })
        } else {
            Ok(Dialer::Stdio {
                command: srv.command.clone(),
                args: srv.args.clone(),
                env: srv
                    .env
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect(),
            })
        }
    }

    pub fn target(&self) -> String {
        match self {
            Dialer::Stdio { command, args, .. } => std::iter::once(command.as_str())
                .chain(args.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join(" "),
            Dialer::Remote { url, .. } => url.clone(),
        }
    }

    /// The executable is watched without resolving symlinks, so a retargeted
    /// symlink counts as a change.
    fn watch_paths(&self) -> Vec<PathBuf> {
        match self {
            Dialer::Stdio { command, .. } => vec![PathBuf::from(command)],
            Dialer::Remote { .. } => vec![],
        }
    }

    pub fn auth_hint(&self) -> Option<String> {
        match self {
            Dialer::Remote { auth_command, .. } => Some(format!(
                "The server requires authorization. Run `{auth_command}` in a terminal (ask the \
                 user to do so if you are an AI agent), then retry."
            )),
            Dialer::Stdio { .. } => None,
        }
    }

    fn dial(
        &self,
        label: Option<String>,
        tail: SharedTail,
        events: Option<(Events, String, u64)>,
    ) -> Result<Box<dyn Connection>, ConnError> {
        match self {
            Dialer::Stdio { command, args, env } => {
                // Resolved on every start, so a retargeted symlink is followed.
                let path = std::fs::canonicalize(command)
                    .map_err(|e| ConnError::Closed(format!("start {command}: {e}")))?;
                let env: Vec<(String, String)> = env
                    .iter()
                    .map(|(k, v)| (k.clone(), expand_env(v)))
                    .collect();
                StdioConn::spawn(StdioSpec {
                    path: &path,
                    args,
                    env: &env,
                    stderr_label: label,
                    tail,
                    events,
                })
                .map(|c| Box::new(c) as Box<dyn Connection>)
            }
            Dialer::Remote {
                url,
                transport,
                headers,
                creds,
                ..
            } => http::connect(RemoteSpec {
                url: url.clone(),
                transport,
                // Expanded per connection, so secrets stay in the environment.
                headers: headers
                    .iter()
                    .map(|(k, v)| (k.clone(), expand_env(v)))
                    .collect(),
                bearer: creds.as_ref().map(|s| Bearer {
                    store: s.clone(),
                    server_url: url.clone(),
                }),
                events,
            }),
        }
    }
}

/// Size and modification time of every watched file.
type Fingerprint = Vec<Option<(u64, SystemTime)>>;

fn fingerprint(paths: &[PathBuf]) -> Fingerprint {
    paths
        .iter()
        .map(|p| {
            std::fs::metadata(p)
                .ok()
                .map(|m| (m.len(), m.modified().unwrap_or(SystemTime::UNIX_EPOCH)))
        })
        .collect()
}

/// Wait until the files stop changing for `settle`, so a binary the compiler
/// is still writing is not executed. Gives up after `max_wait`.
fn wait_settled(paths: &[PathBuf], settle: Duration, max_wait: Duration) -> Fingerprint {
    let mut cur = fingerprint(paths);
    if settle.is_zero() || paths.is_empty() {
        return cur;
    }
    let deadline = Instant::now() + max_wait;
    loop {
        std::thread::sleep(settle);
        let next = fingerprint(paths);
        if next == cur || Instant::now() > deadline {
            return next;
        }
        cur = next;
    }
}

#[derive(Clone)]
pub struct Options {
    pub settle: Duration,
    pub start_timeout: Duration,
    /// Pass the server's stderr through to ours (the CLI hides it without -v).
    pub pass_stderr: bool,
    pub events: Option<Events>,
}

pub struct Status {
    pub target: String,
    pub running: bool,
    pub generation: u64,
    pub started: Option<SystemTime>,
    pub tools: Vec<String>,
    pub last_error: Option<String>,
    pub stderr: String,
}

pub struct Upstream {
    pub name: String,
    /// `<name>__`, or empty for the core server whose tools are unprefixed.
    pub prefix: String,
    dialer: Dialer,
    watch: Vec<PathBuf>,
    opts: Options,
    conn: Option<Box<dyn Connection>>,
    tools: Vec<Value>,
    validators: HashMap<String, jsonschema::Validator>,
    fp: Fingerprint,
    last_err: Option<String>,
    generation: u64,
    started: Option<SystemTime>,
    tail: SharedTail,
}

pub fn error_result(text: impl Into<String>) -> Value {
    json!({ "content": [{ "type": "text", "text": text.into() }], "isError": true })
}

impl Upstream {
    pub fn new(
        name: &str,
        prefix: &str,
        dialer: Dialer,
        extra_watch: &[String],
        opts: Options,
    ) -> Self {
        let mut watch = dialer.watch_paths();
        watch.extend(extra_watch.iter().map(PathBuf::from));
        Self {
            name: name.to_string(),
            prefix: prefix.to_string(),
            dialer,
            watch,
            opts,
            conn: None,
            tools: Vec::new(),
            validators: HashMap::new(),
            fp: Vec::new(),
            last_err: None,
            generation: 0,
            started: None,
            tail: Arc::new(Mutex::new(Tail::new(STDERR_TAIL_BYTES))),
        }
    }

    pub fn target(&self) -> String {
        self.dialer.target()
    }

    /// The tools of the most recent successful start, unprefixed.
    pub fn tools(&self) -> &[Value] {
        &self.tools
    }

    pub fn status(&self) -> Status {
        Status {
            target: self.target(),
            running: self.conn.is_some(),
            generation: self.generation,
            started: self.started,
            tools: self
                .tools
                .iter()
                .filter_map(tool_name)
                .map(String::from)
                .collect(),
            last_error: self.last_err.clone(),
            stderr: self.tail.lock().unwrap().text(),
        }
    }

    pub fn start(&mut self) -> Result<(), String> {
        self.restart(true)
    }

    /// Restart if a rebuild was detected or the process is down.
    pub fn refresh(&mut self) -> Result<(), String> {
        if !self.stale() {
            return Ok(());
        }
        self.restart(false)
    }

    /// Something on disk changed since the running build started.
    pub fn changed(&self) -> bool {
        !self.watch.is_empty() && fingerprint(&self.watch) != self.fp
    }

    fn stale(&self) -> bool {
        self.conn.is_none() || self.changed()
    }

    pub fn restart(&mut self, force: bool) -> Result<(), String> {
        if !force && !self.stale() {
            return Ok(());
        }
        let fp = wait_settled(&self.watch, self.opts.settle, MAX_SETTLE_WAIT);
        self.tail.lock().unwrap().reset();

        let next = self.generation + 1;
        match self.launch(next) {
            Ok((conn, tools)) => {
                if let Some(old) = self.conn.replace(conn) {
                    old.close();
                }
                self.validators = compile_validators(&tools);
                self.tools = tools;
                self.fp = fp;
                self.last_err = None;
                self.generation = next;
                self.started = Some(SystemTime::now());
                Ok(())
            }
            Err(e) => {
                let mut msg = self.explain(&e);
                let tail = self.tail.lock().unwrap().text();
                if !tail.trim().is_empty() {
                    msg.push_str(&format!("\n\nupstream stderr:\n{}", tail.trim_end()));
                }
                if let Some(old) = self.conn.take() {
                    old.close();
                }
                self.fp = fp;
                self.last_err = Some(msg.clone());
                Err(msg)
            }
        }
    }

    fn launch(&self, generation: u64) -> Result<(Box<dyn Connection>, Vec<Value>), ConnError> {
        let label = self.opts.pass_stderr.then(|| format!("[{}] ", self.name));
        let events = self
            .opts
            .events
            .clone()
            .map(|tx| (tx, self.name.clone(), generation));
        let mut conn = self.dialer.dial(label, self.tail.clone(), events)?;
        let t = Some(self.opts.start_timeout);
        let target = self.target();
        let init = conn.request(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": { "name": "nautilus-mcp", "version": env!("CARGO_PKG_VERSION") },
            }),
            t,
        );
        if let Err(e) = init {
            conn.close();
            return Err(prefix_err(e, &format!("initialize {target}")));
        }
        let _ = conn.notify("notifications/initialized", json!({}));
        match list_tools(conn.as_mut(), t) {
            Ok(tools) => Ok((conn, tools)),
            Err(e) => {
                conn.close();
                Err(prefix_err(e, &format!("list tools of {target}")))
            }
        }
    }

    /// Re-fetch the tool list without restarting. `generation` guards against
    /// a notification from a process that has since been replaced.
    pub fn relist(&mut self, generation: Option<u64>) -> Result<(), String> {
        if generation.is_some_and(|g| g != self.generation) {
            return Ok(());
        }
        let Some(conn) = self.conn.as_mut() else {
            return Ok(());
        };
        let tools =
            list_tools(conn.as_mut(), Some(self.opts.start_timeout)).map_err(|e| e.to_string())?;
        self.validators = compile_validators(&tools);
        self.tools = tools;
        Ok(())
    }

    fn explain(&self, e: &ConnError) -> String {
        match (e.is_auth(), self.dialer.auth_hint()) {
            (true, Some(hint)) => format!("{e}\n\n{hint}"),
            _ => e.to_string(),
        }
    }

    /// `None` if the call can go ahead, otherwise the result explaining why not.
    fn check(&self, tool: &str, args: &Value) -> Option<Value> {
        if self.conn.is_none() {
            let why = self
                .last_err
                .as_deref()
                .unwrap_or("upstream server is not running");
            return Some(error_result(format!("nautilus-mcp: {why}")));
        }
        let Some(def) = self.tools.iter().find(|t| tool_name(t) == Some(tool)) else {
            let names: Vec<String> = self
                .tools
                .iter()
                .filter_map(tool_name)
                .map(|n| format!("{}{n}", self.prefix))
                .collect();
            return Some(error_result(format!(
                "nautilus-mcp: tool {:?} does not exist on the upstream server (its tools may have \
                 changed since you listed them). Available tools: {}",
                format!("{}{tool}", self.prefix),
                names.join(", ")
            )));
        };
        let validator = self.validators.get(tool)?;
        let errors: Vec<String> = validator
            .iter_errors(args)
            .map(|e| {
                let path = e.instance_path().to_string();
                format!("{}: {e}", if path.is_empty() { "/" } else { &path })
            })
            .collect();
        if errors.is_empty() {
            return None;
        }
        let schema = def.get("inputSchema").cloned().unwrap_or(Value::Null);
        Some(error_result(format!(
            "nautilus-mcp: arguments for {:?} do not match the tool's current input schema (it may \
             have changed since you listed it): {}\n\nCurrent input schema:\n{}",
            format!("{}{tool}", self.prefix),
            errors.join("; "),
            serde_json::to_string_pretty(&schema).unwrap_or_default()
        )))
    }

    /// Forward a call. Always returns a `CallToolResult`.
    pub fn call(&mut self, tool: &str, args: Value) -> Value {
        let args = if args.is_null() { json!({}) } else { args };
        if let Err(e) = self.refresh() {
            return error_result(format!(
                "nautilus-mcp: upstream {} could not be (re)started: {e}",
                self.target()
            ));
        }
        let mut rejected = self.check(tool, &args);
        if rejected.is_some() && self.conn.is_some() {
            // The cached list may be out of date — a remote server that reloaded
            // itself. Re-list once before rejecting; free on the happy path.
            if self.relist(None).is_ok() {
                rejected = self.check(tool, &args);
            }
        }
        if let Some(r) = rejected {
            return r;
        }

        let full = format!("{}{tool}", self.prefix);
        let conn = self.conn.as_mut().expect("checked");
        let err = match conn.request(
            "tools/call",
            json!({ "name": tool, "arguments": args }),
            None,
        ) {
            Ok(result) => return result,
            Err(e) => e,
        };
        if err.is_auth() {
            // Drop the connection so the next call reconnects with whatever
            // `nautilus-mcp auth` has stored meanwhile.
            self.mark_crashed(&err);
            return error_result(format!(
                "nautilus-mcp: call to upstream tool {full:?} failed: {}",
                self.explain(&err)
            ));
        }
        let mut msg = format!("nautilus-mcp: call to upstream tool {full:?} failed: {err}");
        let dead = !matches!(err, ConnError::Rpc { .. }) && !conn.alive();
        if dead {
            self.mark_crashed(&err);
            let tail = self.tail.lock().unwrap().text();
            if !tail.trim().is_empty() {
                msg.push_str(&format!(
                    "\n\nThe upstream process appears to have exited. Recent stderr:\n{}",
                    tail.trim_end()
                ));
            }
        }
        error_result(msg)
    }

    fn mark_crashed(&mut self, err: &ConnError) {
        if let Some(c) = self.conn.take() {
            c.close();
        }
        self.last_err = Some(format!("upstream server is not running: crashed: {err}"));
    }

    pub fn close(&mut self) {
        if let Some(c) = self.conn.take() {
            c.close();
        }
        self.last_err = Some("upstream server is not running".into());
    }
}

fn prefix_err(e: ConnError, what: &str) -> ConnError {
    match e {
        ConnError::Closed(m) => ConnError::Closed(format!("{what}: {m}")),
        ConnError::Timeout(m) => ConnError::Timeout(format!("{what}: {m}")),
        other => other,
    }
}

pub fn tool_name(t: &Value) -> Option<&str> {
    t.get("name").and_then(Value::as_str)
}

/// `tools/list`, following pagination.
fn list_tools(
    conn: &mut dyn Connection,
    timeout: Option<Duration>,
) -> Result<Vec<Value>, ConnError> {
    let mut tools = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..100 {
        let params = match &cursor {
            Some(c) => json!({ "cursor": c }),
            None => json!({}),
        };
        let page = conn.request("tools/list", params, timeout)?;
        if let Some(list) = page.get("tools").and_then(Value::as_array) {
            // A name with the separator in it could never be routed back.
            tools.extend(
                list.iter()
                    .filter(|t| tool_name(t).is_some_and(|n| !n.contains(TOOL_SEPARATOR)))
                    .cloned(),
            );
        }
        cursor = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|c| !c.is_empty())
            .map(String::from);
        if cursor.is_none() {
            break;
        }
    }
    Ok(tools)
}

/// A tool whose schema does not compile is forwarded unvalidated: the server
/// will judge the arguments itself.
fn compile_validators(tools: &[Value]) -> HashMap<String, jsonschema::Validator> {
    let mut out = HashMap::new();
    for t in tools {
        let (Some(name), Some(schema)) = (tool_name(t), t.get("inputSchema")) else {
            continue;
        };
        if !schema.is_object() || schema.as_object().is_some_and(|o| o.is_empty()) {
            continue;
        }
        match jsonschema::validator_for(schema) {
            Ok(v) => {
                out.insert(name.to_string(), v);
            }
            Err(e) => eprintln!(
                "nautilus-mcp: input schema of {name} does not compile, not validating: {e}"
            ),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_reports_leaf_errors_with_their_location() {
        let tools = vec![json!({
            "name": "echo",
            "inputSchema": { "type": "object", "properties": { "text": { "type": "string" },
                                                              "n": { "type": "integer" } },
                             "required": ["text"] }
        })];
        let mut up = Upstream::new(
            "godev",
            "godev__",
            Dialer::Stdio {
                command: "/nonexistent".into(),
                args: vec![],
                env: vec![],
            },
            &[],
            Options {
                settle: Duration::ZERO,
                start_timeout: Duration::from_secs(1),
                pass_stderr: false,
                events: None,
            },
        );
        up.validators = compile_validators(&tools);
        up.tools = tools;
        // Not running: the start error wins.
        assert!(up.check("echo", &json!({})).is_some());
        assert!(up.check("echo", &json!({"text": "x"})).is_some());

        struct Never;
        impl Connection for Never {
            fn request(
                &mut self,
                _: &str,
                _: Value,
                _: Option<Duration>,
            ) -> Result<Value, ConnError> {
                Err(ConnError::Closed("never".into()))
            }
            fn notify(&mut self, _: &str, _: Value) -> Result<(), ConnError> {
                Ok(())
            }
            fn close(self: Box<Self>) {}
        }
        up.conn = Some(Box::new(Never));
        assert!(up.check("echo", &json!({"text": "x"})).is_none());
        let r = up.check("echo", &json!({"n": "five"})).unwrap();
        let text = r["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("godev__echo"), "{text}");
        assert!(text.contains("/n:"), "{text}");
        assert!(text.contains("text"), "{text}");
        assert!(text.contains("Current input schema"), "{text}");
        let r = up.check("gone", &json!({})).unwrap();
        assert!(r["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Available tools: godev__echo"));
    }

    #[test]
    fn a_missing_file_has_a_fingerprint_too() {
        let p = std::env::temp_dir().join(format!("nautilus-fp-{}", std::process::id()));
        let _ = std::fs::remove_file(&p);
        let before = fingerprint(std::slice::from_ref(&p));
        assert_eq!(before, vec![None]);
        std::fs::write(&p, b"x").unwrap();
        assert_ne!(fingerprint(std::slice::from_ref(&p)), before);
        std::fs::remove_file(&p).unwrap();
    }
}
