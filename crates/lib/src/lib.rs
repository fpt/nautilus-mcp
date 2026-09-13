//! nautilus-core — the Rust half of nautilus-mcp.
//!
//! nautilus-mcp is a **headless MCP server** exposing macOS perception and
//! Android device control. Swift owns the MCP server and the main loop (the
//! macOS frameworks need an AppKit context, and most tools are Swift anyway);
//! this library contributes the Android controls and nothing else.
//!
//! It runs no inference and spawns no agent. Those lived here when this was
//! voice-agent and went with the app-server client.
//!
//! # The surface
//!
//! Deliberately generic: [`AndroidController::tools`] lists what the MCP server
//! should advertise and [`AndroidController::call`] invokes one by name. Adding
//! an Android primitive therefore needs no `.udl` change and no regenerated
//! bindings — the new tool simply appears in the list.

// UniFFI's generated scaffolding (pulled in by `include_scaffolding!` below)
// trips this lint. It is not our source and we cannot edit it, so allow it
// crate-wide rather than drop `-D warnings` in CI and lose the lint everywhere.
#![allow(clippy::empty_line_after_doc_comments)]

pub mod android;
pub mod image;
pub mod tool;

use std::sync::Arc;

uniffi::include_scaffolding!("nautilus");

/// Everything that can go wrong across the FFI boundary.
#[derive(Debug, thiserror::Error)]
pub enum NautilusError {
    /// Bad input, or a device that cannot be bound. The message is written to
    /// be shown to a user or a model verbatim.
    #[error("{0}")]
    ConfigError(String),
    /// Something failed while talking to the device.
    #[error("{0}")]
    InternalError(String),
}

pub use image::RawImage;

/// Decode a base64 PNG into RGBA8 pixels. See [`image`] for why this is here
/// rather than in Swift.
pub fn decode_png_base64(base64_png: String) -> Result<RawImage, NautilusError> {
    image::decode_png_base64(&base64_png)
}

/// Encode RGBA8 pixels as a base64 PNG for an MCP image block.
pub fn encode_png_base64(image: RawImage) -> Result<String, NautilusError> {
    image::encode_png_base64(&image)
}

/// One tool, shaped for an MCP `tools/list` entry.
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// JSON Schema for the arguments, as a JSON string — passed to the MCP
    /// client verbatim rather than re-modelled on the Swift side.
    pub input_schema: String,
}

/// An image a tool produced.
pub struct ToolImage {
    pub base64: String,
    pub media_type: String,
}

/// The result of a tool call.
pub struct ToolOutput {
    pub text: String,
    pub images: Vec<ToolImage>,
}

/// A bound Android device and the tools that drive it.
///
/// Construction resolves the device up front so a misconfiguration surfaces at
/// start-up with a cause ("no device attached", "unauthorized", "two attached")
/// rather than as every tool call failing later.
pub struct AndroidController {
    device: Arc<android::Device>,
    tools: Vec<Box<dyn tool::ToolHandler>>,
}

impl AndroidController {
    /// Bind a device. `serial` of `None` means "the only one attached".
    pub fn new(serial: Option<String>) -> Result<Self, NautilusError> {
        let spec = serial.unwrap_or_else(|| "auto".to_string());
        let device = Arc::new(android::Device::resolve(&spec)?);
        let tools = android::android_tools(device.clone());
        Ok(Self { device, tools })
    }

    pub fn serial(&self) -> String {
        self.device.serial().unwrap_or_default().to_string()
    }

    pub fn tools(&self) -> Vec<ToolSpec> {
        self.tools
            .iter()
            .map(|t| ToolSpec {
                name: t.name().to_string(),
                description: tool::full_description(t.as_ref()),
                input_schema: t.parameters_schema().to_string(),
            })
            .collect()
    }

    /// Invoke a tool by name with the MCP client's arguments object.
    ///
    /// An unknown name lists what does exist: a model that guessed wrong
    /// recovers from that, but not from "unknown tool".
    pub fn call(&self, name: String, args_json: String) -> Result<ToolOutput, NautilusError> {
        let handler = self
            .tools
            .iter()
            .find(|t| t.name() == name)
            .ok_or_else(|| {
                NautilusError::ConfigError(format!(
                    "no such tool: {name:?}. Available: {}",
                    self.tools
                        .iter()
                        .map(|t| t.name())
                        .collect::<Vec<_>>()
                        .join(", ")
                ))
            })?;

        // An absent or empty argument object means "no arguments", which is how
        // MCP clients spell a call to a zero-parameter tool.
        let args: serde_json::Value = if args_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&args_json).map_err(|e| {
                NautilusError::ConfigError(format!("arguments for {name} are not valid JSON: {e}"))
            })?
        };

        let result = handler.call(args)?;
        Ok(ToolOutput {
            text: result.text,
            images: result
                .images
                .into_iter()
                .map(|i| ToolImage {
                    base64: i.base64,
                    media_type: i.media_type,
                })
                .collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Binding must fail with a cause, not bind to nothing. Which cause depends
    /// on what is plugged in, so assert only that the message names a device
    /// situation the user can act on.
    #[test]
    fn binding_reports_why_it_could_not() {
        if let Err(e) = AndroidController::new(Some("definitely-not-a-serial".into())) {
            let m = e.to_string();
            assert!(!m.is_empty(), "an error must explain itself");
        }
    }
}
