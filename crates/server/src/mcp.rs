//! MCP over line-delimited JSON-RPC 2.0 — the same protocol behaviour as the
//! Swift `MCPServer`, so a client cannot tell which one it launched:
//!
//! - the protocol revision is negotiated, not asserted;
//! - a tool that ran and failed is `{content, isError: true}`, while a request
//!   that was never valid is a JSON-RPC error (`-32602`, `-32601`, `-32700`);
//! - requests are handled one at a time.

use serde_json::{json, Map, Value};

use crate::proxy::hub::{Hub, UnknownTool};

pub const PROTOCOL_VERSION: &str = "2025-06-18";
pub const SUPPORTED_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

pub fn negotiate(requested: Option<&str>) -> &str {
    match requested {
        Some(v) if SUPPORTED_VERSIONS.contains(&v) => v,
        _ => PROTOCOL_VERSION,
    }
}

/// A tool ran and failed. The message is written for a model to read.
#[derive(Debug)]
pub struct ToolFailure {
    pub message: String,
}

impl ToolFailure {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl From<nautilus_core::NautilusError> for ToolFailure {
    fn from(e: nautilus_core::NautilusError) -> Self {
        Self::new(e.to_string())
    }
}

/// The request itself was invalid. Deliberately a different type from
/// [`ToolFailure`], so the two cannot be confused by accident.
#[derive(Debug)]
struct ProtocolFailure {
    code: i64,
    message: String,
}

pub struct Image {
    pub base64: String,
    pub mime_type: String,
}

#[derive(Default)]
pub struct ToolOutput {
    pub text: String,
    pub images: Vec<Image>,
}

impl ToolOutput {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            images: vec![],
        }
    }
}

pub type Args = Map<String, Value>;

/// A tool the server advertises. Not `Send`: the loop is single-threaded and
/// requests are serialized, so tools share state through `Rc<RefCell<_>>`.
pub trait Tool {
    fn name(&self) -> String;
    fn description(&self) -> String;
    fn input_schema(&self) -> Value;
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure>;
}

/// The protocol half. What the tools are, and how a call reaches one, is the
/// [`Hub`]'s business.
pub struct Server {
    name: String,
    version: String,
    /// Set once the client has sent `initialize`; `tools/list_changed` is not
    /// sent before that.
    pub initialized: bool,
}

impl Server {
    pub fn new(name: &str, version: &str) -> Self {
        Self {
            name: name.to_string(),
            version: version.to_string(),
            initialized: false,
        }
    }

    /// Handle one line. `None` for a notification, which takes no response.
    pub fn handle(&mut self, line: &str, hub: &mut Hub) -> Option<String> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return None;
        }
        let message: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                return Some(error_line(
                    Value::Null,
                    -32700,
                    &format!("parse error: {e}"),
                ))
            }
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            // A response to something we never send, or garbage. Only answer
            // what claims to be a request.
            let id = message.get("id").cloned()?;
            return Some(error_line(id, -32600, "no method"));
        };
        let id = message.get("id").cloned();
        let empty = Map::new();
        let params = message
            .get("params")
            .and_then(Value::as_object)
            .unwrap_or(&empty);

        match self.dispatch(method, params, hub) {
            Ok(None) => None,
            Ok(Some(result)) => {
                let id = id?;
                Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string())
            }
            Err(f) => Some(error_line(id.unwrap_or(Value::Null), f.code, &f.message)),
        }
    }

    fn dispatch(
        &mut self,
        method: &str,
        params: &Args,
        hub: &mut Hub,
    ) -> Result<Option<Value>, ProtocolFailure> {
        match method {
            "initialize" => {
                self.initialized = true;
                Ok(Some(json!({
                    "protocolVersion":
                        negotiate(params.get("protocolVersion").and_then(Value::as_str)),
                    // listChanged is true and honest: a rebuilt upstream or a
                    // config edit really does change the list, and we say so.
                    "capabilities": { "tools": { "listChanged": true } },
                    "serverInfo": { "name": self.name, "version": self.version },
                })))
            }
            m if m.starts_with("notifications/") => Ok(None),
            "ping" => Ok(Some(json!({}))),
            "tools/list" => Ok(Some(json!({ "tools": hub.list() }))),
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Err(ProtocolFailure {
                        code: -32602,
                        message: "tools/call needs a `name`".into(),
                    });
                };
                let empty = Map::new();
                let args = params
                    .get("arguments")
                    .and_then(Value::as_object)
                    .unwrap_or(&empty);
                hub.call(name, args)
                    .map(Some)
                    .map_err(|UnknownTool(message)| ProtocolFailure {
                        code: -32602,
                        message,
                    })
            }
            other => Err(ProtocolFailure {
                code: -32601,
                message: format!("Method not found: {other}"),
            }),
        }
    }
}

pub fn list_changed_line() -> String {
    json!({ "jsonrpc": "2.0", "method": "notifications/tools/list_changed" }).to_string()
}

fn error_line(id: Value, code: i64, message: &str) -> String {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proxy::auth::Store;
    use crate::proxy::hub::Core;
    use crate::proxy::upstream::Options;

    struct Echo;
    impl Tool for Echo {
        fn name(&self) -> String {
            "echo".into()
        }
        fn description(&self) -> String {
            "echoes".into()
        }
        fn input_schema(&self) -> Value {
            json!({ "type": "object" })
        }
        fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
            match args.get("text").and_then(Value::as_str) {
                Some(t) => Ok(ToolOutput::text(t)),
                None => Err(ToolFailure::new("no text")),
            }
        }
    }

    fn hub() -> Hub {
        Hub::new(
            Options {
                settle: std::time::Duration::ZERO,
                start_timeout: std::time::Duration::from_secs(1),
                pass_stderr: false,
                events: None,
            },
            Store::new(std::env::temp_dir()),
            "/nonexistent/config.toml".into(),
            Core::Local(vec![Box::new(Echo)]),
            vec![],
        )
    }

    fn reply(s: &mut Server, h: &mut Hub, line: &str) -> Value {
        serde_json::from_str(&s.handle(line, h).unwrap()).unwrap()
    }

    #[test]
    fn version_is_negotiated() {
        let (mut s, mut h) = (Server::new("t", "0"), hub());
        let r = reply(
            &mut s,
            &mut h,
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#,
        );
        assert_eq!(r["result"]["protocolVersion"], "2024-11-05");
        let r = reply(
            &mut s,
            &mut h,
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999"}}"#,
        );
        assert_eq!(r["result"]["protocolVersion"], PROTOCOL_VERSION);
        assert!(r["result"]["capabilities"].get("logging").is_none());
        assert!(s.initialized);
    }

    #[test]
    fn the_list_holds_core_tools_and_builtins() {
        let (mut s, mut h) = (Server::new("t", "0"), hub());
        let r = reply(
            &mut s,
            &mut h,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        );
        let names: Vec<&str> = r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            vec![
                "echo",
                "nautilus_status",
                "nautilus_restart",
                "nautilus_search_tools",
                "nautilus_call_tool"
            ]
        );
    }

    #[test]
    fn a_failing_tool_is_a_result_and_an_unknown_one_is_an_error() {
        let (mut s, mut h) = (Server::new("t", "0"), hub());
        let r = reply(
            &mut s,
            &mut h,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#,
        );
        assert_eq!(r["result"]["isError"], true);
        let r = reply(
            &mut s,
            &mut h,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#,
        );
        assert_eq!(r["error"]["code"], -32602);
        assert!(r["error"]["message"].as_str().unwrap().contains("echo"));
    }

    #[test]
    fn protocol_errors_have_their_codes() {
        let (mut s, mut h) = (Server::new("t", "0"), hub());
        assert_eq!(reply(&mut s, &mut h, "{not json")["error"]["code"], -32700);
        assert_eq!(
            reply(
                &mut s,
                &mut h,
                r#"{"jsonrpc":"2.0","id":5,"method":"logging/setLevel"}"#
            )["error"]["code"],
            -32601
        );
        assert!(s
            .handle(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                &mut h
            )
            .is_none());
    }
}
