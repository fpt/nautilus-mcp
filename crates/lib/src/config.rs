//! TOML for the Swift side.
//!
//! Swift has no TOML parser and this project carries no Swift package
//! dependencies, so configuration is parsed here and handed over as JSON —
//! which Swift already decodes everywhere else. The same reasoning as the PNG
//! codec next door, for a milder reason: there, Swift's own library is broken;
//! here, it simply does not have one, and a hand-rolled subset parser would
//! quietly reject valid TOML the day somebody writes an array.

use crate::NautilusError;

/// Parse TOML and return it as JSON.
///
/// Errors carry the parser's own message, which names the line and column —
/// worth passing through verbatim, because a configuration file that is
/// silently ignored is worse than one that refuses to load.
pub fn toml_to_json(text: String) -> Result<String, NautilusError> {
    let value: toml::Value = text
        .parse()
        .map_err(|e| NautilusError::ConfigError(format!("{e}")))?;
    serde_json::to_string(&value)
        .map_err(|e| NautilusError::InternalError(format!("serializing parsed TOML: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_tables_become_nested_objects() {
        let json = toml_to_json(
            r#"
            [tts]
            rate = 0.5

            [tts.ja]
            voice = "com.apple.voice.enhanced.ja-JP.Kyoko"
            "#
            .to_string(),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["tts"]["rate"], 0.5);
        assert_eq!(
            v["tts"]["ja"]["voice"],
            "com.apple.voice.enhanced.ja-JP.Kyoko"
        );
    }

    #[test]
    fn a_syntax_error_says_where() {
        let err = toml_to_json("[tts\nvoice = 1".to_string()).unwrap_err();
        let message = format!("{err}");
        // The parser names the line; a config that fails silently is worse than
        // one that refuses to load.
        assert!(
            message.contains("line") || message.contains("1"),
            "{message}"
        );
    }
}
