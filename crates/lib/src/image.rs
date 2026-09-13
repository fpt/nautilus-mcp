//! Image payloads produced by tools.
//!
//! All that survives of the old `llm.rs`: nautilus-mcp runs no inference, so
//! the conversation types went with the agent. A screenshot still has to reach
//! the MCP client, and this is its shape.

/// An image a tool produced, base64-encoded with its media type.
#[derive(Debug, Clone)]
pub struct ImageContent {
    pub base64: String,
    /// e.g. `image/png`, `image/jpeg`.
    pub media_type: String,
}
