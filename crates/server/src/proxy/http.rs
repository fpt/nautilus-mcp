//! Remote MCP servers: streamable HTTP, and the older HTTP+SSE transport.
//!
//! Streamable HTTP is one POST per message; the answer is either a JSON body
//! or an SSE stream that carries it. The session id handed out on
//! `initialize` is sent back on every request. There is no standing GET
//! stream, so a server that changes its tools without saying so is caught by
//! the supervisor's re-list-once-before-rejecting rule instead.
//!
//! The SSE transport keeps a GET stream open; its first event names the URL to
//! POST to, and responses come back over the stream.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crossbeam_channel::{bounded, Sender};
use serde_json::{json, Value};

use super::auth::{resource_metadata_from, Bearer};
use super::conn::{
    await_response, handle_incoming, response_result, ConnError, Connection, Events,
};

pub struct RemoteSpec {
    pub url: String,
    /// `http` or `sse`, already resolved.
    pub transport: &'static str,
    pub headers: Vec<(String, String)>,
    pub bearer: Option<Bearer>,
    pub events: Option<(Events, String, u64)>,
}

pub fn connect(spec: RemoteSpec) -> Result<Box<dyn Connection>, ConnError> {
    let agent = super::auth::agent();
    if spec.transport == "sse" {
        return SseConn::connect(spec, agent).map(|c| Box::new(c) as Box<dyn Connection>);
    }
    Ok(Box::new(HttpConn {
        agent,
        spec,
        session: None,
        protocol: None,
        next_id: 1,
    }))
}

/// Turn a failed HTTP exchange into the error the supervisor acts on.
fn http_error(url: &str, err: ureq::Error) -> ConnError {
    match err {
        ureq::Error::Status(401, resp) => {
            let meta = resp
                .header("WWW-Authenticate")
                .and_then(resource_metadata_from);
            ConnError::Auth {
                message: format!("{url} answered 401 Unauthorized"),
                resource_metadata: meta,
            }
        }
        ureq::Error::Status(code, resp) => {
            let body = resp.into_string().unwrap_or_default();
            let body = body.trim();
            let excerpt: String = body.chars().take(300).collect();
            ConnError::Closed(format!("HTTP {code} from {url}: {excerpt}"))
        }
        ureq::Error::Transport(t) => ConnError::Closed(format!("{url}: {t}")),
    }
}

/// Read SSE events, calling `on` with (event, data) until it returns true or
/// the stream ends.
fn read_sse(reader: impl Read, mut on: impl FnMut(&str, &str) -> bool) {
    let mut event = String::new();
    let mut data = String::new();
    for line in BufReader::new(reader).lines() {
        let Ok(line) = line else { return };
        if line.is_empty() {
            if !data.is_empty() || !event.is_empty() {
                let name = if event.is_empty() { "message" } else { &event };
                if on(name, data.trim_end_matches('\n')) {
                    return;
                }
            }
            event.clear();
            data.clear();
            continue;
        }
        if line.starts_with(':') {
            continue;
        }
        let (field, value) = line.split_once(':').unwrap_or((&line, ""));
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "event" => event = value.to_string(),
            "data" => {
                data.push_str(value);
                data.push('\n');
            }
            _ => {}
        }
    }
}

struct HttpConn {
    agent: ureq::Agent,
    spec: RemoteSpec,
    session: Option<String>,
    protocol: Option<String>,
    next_id: u64,
}

impl HttpConn {
    fn post(
        &mut self,
        body: &Value,
        timeout: Option<Duration>,
        force_refresh: bool,
    ) -> Result<ureq::Response, ConnError> {
        let mut req = self
            .agent
            .post(&self.spec.url)
            .set("Content-Type", "application/json")
            .set("Accept", "application/json, text/event-stream");
        for (k, v) in &self.spec.headers {
            req = req.set(k, v);
        }
        if let Some(s) = &self.session {
            req = req.set("Mcp-Session-Id", s);
        }
        if let Some(p) = &self.protocol {
            req = req.set("MCP-Protocol-Version", p);
        }
        if let Some(b) = &self.spec.bearer {
            if let Some(h) = b.header(&self.agent, force_refresh)? {
                req = req.set("Authorization", &h);
            }
        }
        if let Some(t) = timeout {
            req = req.timeout(t);
        }
        req.send_string(&body.to_string())
            .map_err(|e| http_error(&self.spec.url, e))
    }

    /// POST, retrying once after refreshing the token if the server says 401.
    fn exchange(
        &mut self,
        body: &Value,
        timeout: Option<Duration>,
    ) -> Result<ureq::Response, ConnError> {
        match self.post(body, timeout, false) {
            Err(ConnError::Auth { .. }) if self.spec.bearer.is_some() => {
                self.post(body, timeout, true)
            }
            Err(ConnError::Closed(m)) if m.starts_with("HTTP 404") && self.session.is_some() => {
                Err(ConnError::Closed(format!(
                    "the session ended ({m}); reconnecting on the next call"
                )))
            }
            other => other,
        }
    }
}

impl Connection for HttpConn {
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value, ConnError> {
        let id = self.next_id;
        self.next_id += 1;
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        let resp = self.exchange(&body, timeout)?;
        if method == "initialize" {
            self.session = resp.header("Mcp-Session-Id").map(String::from);
        }
        let is_sse = resp
            .header("Content-Type")
            .is_some_and(|c| c.starts_with("text/event-stream"));

        let result = if is_sse {
            let mut found = None;
            let events = self
                .spec
                .events
                .as_ref()
                .map(|(tx, s, g)| (tx.clone(), s.clone(), *g));
            read_sse(resp.into_reader(), |_, data| {
                let Ok(msg) = serde_json::from_str::<Value>(data) else {
                    return false;
                };
                if msg.get("method").is_none() && msg.get("id").and_then(Value::as_u64) == Some(id)
                {
                    found = Some(response_result(&msg));
                    return true;
                }
                // Notifications interleaved with the answer. Requests the server
                // makes mid-stream cannot be answered on this transport without
                // a second POST, which we do not attempt.
                let ev = events.as_ref().map(|(tx, s, g)| (tx, s.as_str(), *g));
                let _ = handle_incoming(&msg, ev);
                false
            });
            found.unwrap_or_else(|| {
                Err(ConnError::Closed(format!(
                    "{} ended the stream without answering {method}",
                    self.spec.url
                )))
            })
        } else {
            let text = resp
                .into_string()
                .map_err(|e| ConnError::Closed(format!("{}: {e}", self.spec.url)))?;
            let msg: Value = serde_json::from_str(&text).map_err(|e| {
                ConnError::Closed(format!(
                    "{} answered with something that is not JSON: {e}",
                    self.spec.url
                ))
            })?;
            response_result(&msg)
        }?;

        if method == "initialize" {
            self.protocol = result
                .get("protocolVersion")
                .and_then(Value::as_str)
                .map(String::from);
        }
        Ok(result)
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), ConnError> {
        let body = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        self.exchange(&body, Some(Duration::from_secs(30)))
            .map(|_| ())
    }

    fn close(self: Box<Self>) {
        if let Some(s) = &self.session {
            let mut req = self
                .agent
                .delete(&self.spec.url)
                .set("Mcp-Session-Id", s)
                .timeout(Duration::from_secs(5));
            for (k, v) in &self.spec.headers {
                req = req.set(k, v);
            }
            let _ = req.call();
        }
    }
}

type Pending = Arc<Mutex<HashMap<u64, Sender<Result<Value, ConnError>>>>>;

struct SseConn {
    agent: ureq::Agent,
    endpoint: String,
    headers: Vec<(String, String)>,
    bearer: Option<Bearer>,
    pending: Pending,
    closed: Arc<AtomicBool>,
    next_id: AtomicU64,
    url: String,
}

impl SseConn {
    fn connect(spec: RemoteSpec, agent: ureq::Agent) -> Result<Self, ConnError> {
        let mut req = agent.get(&spec.url).set("Accept", "text/event-stream");
        for (k, v) in &spec.headers {
            req = req.set(k, v);
        }
        if let Some(b) = &spec.bearer {
            if let Some(h) = b.header(&agent, false)? {
                req = req.set("Authorization", &h);
            }
        }
        let resp = req.call().map_err(|e| http_error(&spec.url, e))?;
        let base = url::Url::parse(&spec.url).map_err(|e| ConnError::Closed(e.to_string()))?;

        let pending: Pending = Arc::default();
        let closed = Arc::new(AtomicBool::new(false));
        let (endpoint_tx, endpoint_rx) = bounded::<String>(1);
        {
            let pending = pending.clone();
            let closed = closed.clone();
            let events = spec.events;
            std::thread::spawn(move || {
                let mut endpoint_tx = Some(endpoint_tx);
                read_sse(resp.into_reader(), |event, data| {
                    if event == "endpoint" {
                        if let (Some(tx), Ok(u)) = (endpoint_tx.take(), base.join(data.trim())) {
                            let _ = tx.send(u.to_string());
                        }
                        return false;
                    }
                    let Ok(msg) = serde_json::from_str::<Value>(data) else {
                        return false;
                    };
                    if msg.get("method").is_none() {
                        if let Some(id) = msg.get("id").and_then(Value::as_u64) {
                            if let Some(tx) = pending.lock().unwrap().remove(&id) {
                                let _ = tx.send(response_result(&msg));
                            }
                        }
                        return false;
                    }
                    let ev = events.as_ref().map(|(tx, s, g)| (tx, s.as_str(), *g));
                    let _ = handle_incoming(&msg, ev);
                    false
                });
                closed.store(true, Ordering::SeqCst);
                pending.lock().unwrap().clear();
            });
        }
        let endpoint = endpoint_rx
            .recv_timeout(Duration::from_secs(15))
            .map_err(|_| ConnError::Closed(format!("{} sent no endpoint event", spec.url)))?;
        Ok(Self {
            agent,
            endpoint,
            headers: spec.headers,
            bearer: spec.bearer,
            pending,
            closed,
            next_id: AtomicU64::new(1),
            url: spec.url,
        })
    }

    fn post(&self, body: &Value) -> Result<(), ConnError> {
        let mut attempt = 0;
        loop {
            let mut req = self
                .agent
                .post(&self.endpoint)
                .set("Content-Type", "application/json")
                .timeout(Duration::from_secs(30));
            for (k, v) in &self.headers {
                req = req.set(k, v);
            }
            if let Some(b) = &self.bearer {
                if let Some(h) = b.header(&self.agent, attempt > 0)? {
                    req = req.set("Authorization", &h);
                }
            }
            match req
                .send_string(&body.to_string())
                .map_err(|e| http_error(&self.url, e))
            {
                Err(ConnError::Auth { .. }) if self.bearer.is_some() && attempt == 0 => {
                    attempt += 1
                }
                other => return other.map(|_| ()),
            }
        }
    }
}

impl Connection for SseConn {
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value, ConnError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(ConnError::Closed(format!(
                "the event stream from {} ended",
                self.url
            )));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(e) =
            self.post(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
        {
            self.pending.lock().unwrap().remove(&id);
            return Err(e);
        }
        let url = self.url.clone();
        let r = await_response(rx, timeout, method, || {
            format!("the event stream from {url} ended")
        });
        self.pending.lock().unwrap().remove(&id);
        r
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), ConnError> {
        self.post(&json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }

    fn close(self: Box<Self>) {
        // The reader thread ends when the server closes the stream; dropping
        // the agent's response is not possible from here, so mark it closed.
        self.closed.store(true, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_events_are_split_on_blank_lines() {
        let stream =
            ": comment\nevent: endpoint\ndata: /messages?s=1\n\ndata: {\"a\":\ndata: 1}\n\n";
        let mut got = Vec::new();
        read_sse(stream.as_bytes(), |e, d| {
            got.push((e.to_string(), d.to_string()));
            false
        });
        assert_eq!(
            got,
            vec![
                ("endpoint".to_string(), "/messages?s=1".to_string()),
                ("message".to_string(), "{\"a\":\n1}".to_string()),
            ]
        );
    }
}
