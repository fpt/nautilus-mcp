//! The proxy half of nautilus-mcp: other MCP servers behind this one.
//!
//! This is a port of go-mcpproxy into the server itself, so a client registers
//! one server and reaches everything through it. Its settings live only in the
//! nautilus config (`[servers.*]`, `[wrapper.*]`); go-mcpproxy's own config
//! file and `MCPPROXY_CONFIG` are not read.

pub mod auth;
pub mod config;
pub mod conn;
pub mod http;
pub mod hub;
pub mod search;
pub mod stream;
pub mod upstream;
pub mod wrapper;
