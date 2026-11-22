//! A JSON-RPC connection to one upstream MCP server, and the stdio transport.
//!
//! The HTTP and SSE transports are in [`super::http`]. Every transport offers
//! the same blocking request/response surface, so the supervisor in
//! [`super::upstream`] does not care how a server is reached.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, Receiver, RecvTimeoutError, Sender};
use serde_json::{json, Value};

/// What the main loop is woken by. Upstreams send `ToolsChanged` when a server
/// announces `notifications/tools/list_changed` on its own.
#[derive(Debug)]
pub enum Event {
    Line(String),
    Eof,
    Tick,
    ToolsChanged { server: String, generation: u64 },
}

pub type Events = Sender<Event>;

#[derive(Debug, Clone)]
pub enum ConnError {
    /// The server answered with a JSON-RPC error.
    Rpc {
        code: i64,
        message: String,
    },
    /// The server wants (new) authorization.
    Auth {
        message: String,
        resource_metadata: Option<String>,
    },
    Timeout(String),
    /// The connection or process is gone.
    Closed(String),
}

impl ConnError {
    pub fn is_auth(&self) -> bool {
        matches!(self, ConnError::Auth { .. })
    }
}

impl std::fmt::Display for ConnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnError::Rpc { code, message } => write!(f, "{message} (JSON-RPC error {code})"),
            ConnError::Auth { message, .. } => write!(f, "{message}"),
            ConnError::Timeout(m) | ConnError::Closed(m) => write!(f, "{m}"),
        }
    }
}

pub trait Connection: Send {
    /// Send a request and wait for its result. `None` waits as long as the
    /// connection lives.
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value, ConnError>;
    fn notify(&mut self, method: &str, params: Value) -> Result<(), ConnError>;
    /// Cheap liveness check, used after a failed call to tell a tool error
    /// from a dead server.
    fn alive(&mut self) -> bool {
        self.request("ping", json!({}), Some(Duration::from_secs(2)))
            .is_ok()
    }
    fn close(self: Box<Self>);
}

/// Keeps the last `limit` bytes of a stream: a crashed build's panic is at the end.
pub struct Tail {
    limit: usize,
    buf: Vec<u8>,
    pub truncated: bool,
}

impl Tail {
    pub fn new(limit: usize) -> Self {
        Self {
            limit,
            buf: Vec::new(),
            truncated: false,
        }
    }

    pub fn write(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
        if self.buf.len() > self.limit {
            let over = self.buf.len() - self.limit;
            self.buf.drain(..over);
            self.truncated = true;
        }
    }

    pub fn reset(&mut self) {
        self.buf.clear();
        self.truncated = false;
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.buf).into_owned()
    }
}

pub type SharedTail = Arc<Mutex<Tail>>;

/// Pending requests, by id, waiting for their response.
type Pending = Arc<Mutex<HashMap<u64, Sender<Result<Value, ConnError>>>>>;

/// Decode one response object into a result.
pub fn response_result(msg: &Value) -> Result<Value, ConnError> {
    if let Some(err) = msg.get("error") {
        return Err(ConnError::Rpc {
            code: err.get("code").and_then(Value::as_i64).unwrap_or(0),
            message: err
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
                .to_string(),
        });
    }
    Ok(msg.get("result").cloned().unwrap_or(Value::Null))
}

/// Shared handling of anything a server sends that is not a response we wait
/// for. Returns the reply to send back, if it was a request.
pub fn handle_incoming(msg: &Value, events: Option<(&Events, &str, u64)>) -> Option<Value> {
    let method = msg.get("method").and_then(Value::as_str)?;
    match msg.get("id") {
        // A request from the server. Answer what is cheap to answer honestly;
        // refuse the rest so the server does not wait forever.
        Some(id) => Some(match method {
            "ping" => json!({ "jsonrpc": "2.0", "id": id, "result": {} }),
            "roots/list" => json!({ "jsonrpc": "2.0", "id": id, "result": { "roots": [] } }),
            _ => json!({ "jsonrpc": "2.0", "id": id,
                         "error": { "code": -32601, "message": format!("nautilus-mcp does not support {method}") } }),
        }),
        None => {
            if method == "notifications/tools/list_changed" {
                if let Some((tx, server, generation)) = events {
                    let _ = tx.send(Event::ToolsChanged {
                        server: server.to_string(),
                        generation,
                    });
                }
            }
            None
        }
    }
}

/// Wait on a pending response with an optional deadline.
pub fn await_response(
    rx: Receiver<Result<Value, ConnError>>,
    timeout: Option<Duration>,
    method: &str,
    gone: impl Fn() -> String,
) -> Result<Value, ConnError> {
    match timeout {
        Some(t) => match rx.recv_timeout(t) {
            Ok(r) => r,
            Err(RecvTimeoutError::Timeout) => Err(ConnError::Timeout(format!(
                "{method} timed out after {}",
                human(t)
            ))),
            Err(RecvTimeoutError::Disconnected) => Err(ConnError::Closed(gone())),
        },
        None => rx.recv().unwrap_or_else(|_| Err(ConnError::Closed(gone()))),
    }
}

pub fn human(d: Duration) -> String {
    let s = d.as_secs_f64();
    if s < 1.0 {
        format!("{}ms", d.as_millis())
    } else if s < 120.0 {
        format!("{s:.0}s")
    } else {
        format!("{:.0}m", s / 60.0)
    }
}

/// A local executable speaking MCP over stdio.
pub struct StdioConn {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    pending: Pending,
    next_id: AtomicU64,
    exited: Arc<AtomicBool>,
    path: PathBuf,
}

pub struct StdioSpec<'a> {
    pub path: &'a std::path::Path,
    pub args: &'a [String],
    pub env: &'a [(String, String)],
    /// Prefix for passing the server's stderr through to ours, or `None` to
    /// keep it only in the tail (the CLI without `-v`).
    pub stderr_label: Option<String>,
    pub tail: SharedTail,
    pub events: Option<(Events, String, u64)>,
}

impl StdioConn {
    pub fn spawn(spec: StdioSpec) -> Result<Self, ConnError> {
        let mut child = Command::new(spec.path)
            .args(spec.args)
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| ConnError::Closed(format!("start {}: {e}", spec.path.display())))?;

        let stdin = Arc::new(Mutex::new(child.stdin.take().expect("piped")));
        let stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let pending: Pending = Arc::default();
        let exited = Arc::new(AtomicBool::new(false));

        {
            let tail = spec.tail.clone();
            let label = spec.stderr_label.clone();
            std::thread::spawn(move || copy_stderr(stderr, tail, label));
        }
        {
            let pending = pending.clone();
            let exited = exited.clone();
            let stdin = stdin.clone();
            let events = spec.events;
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    let Ok(msg) = serde_json::from_str::<Value>(line.trim()) else {
                        continue; // A stray print from the server; not ours to parse.
                    };
                    if msg.get("method").is_none() {
                        if let Some(id) = msg.get("id").and_then(Value::as_u64) {
                            if let Some(tx) = pending.lock().unwrap().remove(&id) {
                                let _ = tx.send(response_result(&msg));
                            }
                        }
                        continue;
                    }
                    let ev = events.as_ref().map(|(tx, s, g)| (tx, s.as_str(), *g));
                    if let Some(reply) = handle_incoming(&msg, ev) {
                        let mut w = stdin.lock().unwrap();
                        let _ = writeln!(w, "{reply}").and_then(|_| w.flush());
                    }
                }
                exited.store(true, Ordering::SeqCst);
                // Dropping the senders wakes every waiter with "closed".
                pending.lock().unwrap().clear();
            });
        }

        Ok(Self {
            child,
            stdin,
            pending,
            next_id: AtomicU64::new(1),
            exited,
            path: spec.path.to_path_buf(),
        })
    }

    fn send(&self, msg: &Value) -> Result<(), ConnError> {
        let mut w = self.stdin.lock().unwrap();
        writeln!(w, "{msg}")
            .and_then(|_| w.flush())
            .map_err(|e| ConnError::Closed(format!("{} is not reading: {e}", self.path.display())))
    }

    fn gone(&mut self) -> String {
        match self.child.try_wait() {
            Ok(Some(status)) => format!("{} exited ({status})", self.path.display()),
            _ => format!("{} closed its output", self.path.display()),
        }
    }
}

fn copy_stderr(mut stderr: impl Read, tail: SharedTail, label: Option<String>) {
    let mut buf = [0u8; 4096];
    let mut at_line_start = true;
    loop {
        let n = match stderr.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        tail.lock().unwrap().write(&buf[..n]);
        if let Some(label) = &label {
            let mut out = Vec::with_capacity(n + 32);
            for &b in &buf[..n] {
                if at_line_start {
                    out.extend_from_slice(label.as_bytes());
                }
                out.push(b);
                at_line_start = b == b'\n';
            }
            let _ = std::io::stderr().write_all(&out);
        }
    }
}

impl Connection for StdioConn {
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value, ConnError> {
        if self.exited.load(Ordering::SeqCst) {
            return Err(ConnError::Closed(self.gone()));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(e) =
            self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
        {
            self.pending.lock().unwrap().remove(&id);
            return Err(e);
        }
        let result = await_response(rx, timeout, method, String::new);
        self.pending.lock().unwrap().remove(&id);
        match result {
            Err(ConnError::Closed(_)) => {
                // Give the exit status a moment to land, so the message can say how it died.
                let deadline = Instant::now() + Duration::from_millis(200);
                while Instant::now() < deadline && matches!(self.child.try_wait(), Ok(None)) {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(ConnError::Closed(self.gone()))
            }
            other => other,
        }
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), ConnError> {
        self.send(&json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }

    fn alive(&mut self) -> bool {
        if self.exited.load(Ordering::SeqCst) || !matches!(self.child.try_wait(), Ok(None)) {
            return false;
        }
        self.request("ping", json!({}), Some(Duration::from_secs(2)))
            .is_ok()
    }

    fn close(mut self: Box<Self>) {
        // Closing stdin is the polite stop; most servers exit on EOF. Give it a
        // moment, then make sure.
        drop(self.stdin);
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            if !matches!(self.child.try_wait(), Ok(None)) {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tail_keeps_the_end() {
        let mut t = Tail::new(5);
        t.write(b"hello ");
        t.write(b"world");
        assert_eq!(t.text(), "world");
        assert!(t.truncated);
        t.reset();
        assert_eq!(t.text(), "");
    }

    #[test]
    fn server_requests_are_answered_or_refused() {
        let r = handle_incoming(&json!({"jsonrpc":"2.0","id":7,"method":"ping"}), None).unwrap();
        assert_eq!(r["result"], json!({}));
        let r = handle_incoming(
            &json!({"jsonrpc":"2.0","id":8,"method":"sampling/createMessage"}),
            None,
        )
        .unwrap();
        assert_eq!(r["error"]["code"], -32601);
        let (tx, rx) = crossbeam_channel::unbounded();
        assert!(handle_incoming(
            &json!({"jsonrpc":"2.0","method":"notifications/tools/list_changed"}),
            Some((&tx, "godev", 3))
        )
        .is_none());
        assert!(matches!(
            rx.try_recv().unwrap(),
            Event::ToolsChanged { generation: 3, .. }
        ));
    }
}
