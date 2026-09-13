use crate::image::ImageContent;
use crate::NautilusError;

/// Result of a tool call, containing text and optional images
#[derive(Debug)]
pub struct ToolResult {
    pub text: String,
    pub images: Vec<ImageContent>,
}

impl ToolResult {
    pub fn text(s: String) -> Self {
        Self {
            text: s,
            images: vec![],
        }
    }

    pub fn with_images(text: String, images: Vec<ImageContent>) -> Self {
        Self { text, images }
    }
}

impl From<String> for ToolResult {
    fn from(s: String) -> Self {
        Self::text(s)
    }
}

/// Trait for tool implementations
pub trait ToolHandler: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn parameters_schema(&self) -> serde_json::Value;
    fn call(&self, args: serde_json::Value) -> Result<ToolResult, NautilusError>;

    /// Optional live state snippet appended to description (e.g. "3 messages, last at 12:34").
    /// The framework combines it as: `"{description} [{dynamic_state}]"`.
    fn dynamic_state(&self) -> Option<String> {
        None
    }
}

/// Build the full description for a tool: static description + optional dynamic state.
pub fn full_description(tool: &dyn ToolHandler) -> String {
    match tool.dynamic_state() {
        Some(state) => format!("{} [{}]", tool.description(), state),
        None => tool.description().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A trivial tool for exercising the registry surface without any built-ins.
    struct EchoTool {
        n: String,
        state: Option<String>,
    }

    impl ToolHandler for EchoTool {
        fn name(&self) -> &str {
            &self.n
        }
        fn description(&self) -> &str {
            "echoes its input"
        }
        fn parameters_schema(&self) -> serde_json::Value {
            serde_json::json!({ "type": "object", "properties": { "text": { "type": "string" } } })
        }
        fn call(&self, args: serde_json::Value) -> Result<ToolResult, NautilusError> {
            let text = args
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            Ok(ToolResult::text(text))
        }
        fn dynamic_state(&self) -> Option<String> {
            self.state.clone()
        }
    }

    #[test]
    fn full_description_appends_dynamic_state() {
        let plain = EchoTool {
            n: "a".into(),
            state: None,
        };
        assert_eq!(full_description(&plain), "echoes its input");
        let stateful = EchoTool {
            n: "b".into(),
            state: Some("2 items".into()),
        };
        assert_eq!(full_description(&stateful), "echoes its input [2 items]");
    }
}
