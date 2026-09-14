import Foundation
import NautilusBridge
import TTS

/// The server's configuration file.
///
/// ```toml
/// # ~/.config/nautilus/config.toml
///
/// [tts]
/// rate = 0.5              # defaults, for any language
/// volume = 1.0
///
/// [tts.en]
/// voice = "com.apple.voice.enhanced.en-US.Ava"
///
/// [tts.ja]
/// voice = "com.apple.voice.enhanced.ja-JP.Kyoko"
/// rate = 0.45             # Kyoko reads a little fast at 0.5
/// ```
///
/// Sections under `[tts]` are keyed by **bare language code**, matching what
/// `SpokenLanguage.detect` returns. Nothing has to be configured: an
/// unconfigured Mac still picks the best installed voice for whatever language
/// the text turns out to be in, and the file exists to pin a particular voice
/// or slow one down.
///
/// # Where it is read from
///
/// | | |
/// |---|---|
/// | `--config <path>` | that file, and it must exist |
/// | `NAUTILUS_CONFIG` | that file, and it must exist |
/// | neither | `~/.config/nautilus/config.toml` if present, defaults otherwise |
///
/// The asymmetry is deliberate. Naming a path and being given defaults because
/// of a typo is the failure that wastes an afternoon, so an explicit path that
/// is missing or malformed is an error. The default path is a convention, and
/// not having one is the normal case.
///
/// TOML is parsed by the Rust core, which has a real parser; Swift has none and
/// this project carries no Swift package dependencies. See `config.rs`.
public struct NautilusConfig: Sendable {
    public var tts: TextToSpeech.Config
    /// Where it came from, for the startup log. `nil` when nothing was found.
    public var source: String?

    public init(tts: TextToSpeech.Config = .init(), source: String? = nil) {
        self.tts = tts
        self.source = source
    }

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/nautilus/config.toml")
    }

    /// Load configuration, applying the precedence above.
    ///
    /// `voiceOverride` is `--voice`, which still works and beats the file for
    /// the default voice — a flag the caller typed just now should win over a
    /// file they wrote last month.
    public static func load(explicitPath: String? = nil, voiceOverride: String? = nil) throws
        -> NautilusConfig
    {
        // An empty NAUTILUS_CONFIG means unset, not "a file named nothing".
        // `NAUTILUS_CONFIG= nautilus-mcp` is how a shell says "ignore it", and
        // answering that with `no configuration file at ` helps nobody.
        let environment = ProcessInfo.processInfo.environment["NAUTILUS_CONFIG"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let named = explicitPath.flatMap { $0.isEmpty ? nil : $0 } ?? environment
        let path = named ?? defaultPath

        guard FileManager.default.fileExists(atPath: path) else {
            if let named {
                throw ToolFailure(
                    "no configuration file at \(named) (named by "
                        + (explicitPath != nil ? "--config" : "NAUTILUS_CONFIG") + ")")
            }
            var config = NautilusConfig()
            if let voiceOverride {
                config.tts = TextToSpeech.Config(voice: voiceOverride)
            }
            return config
        }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        let json: JSONValue
        do {
            json = try JSONValue.parse(tomlToJson(text: text))
        } catch let error as NautilusError {
            // The generated bridge enum is not a LocalizedError, so describing
            // it gives `NautilusBridge.NautilusError.ConfigError(message: "…")`
            // wrapped around the part that matters. The parser's own message
            // names the line and column; that is the whole value here.
            throw ToolFailure("\(path): \(Self.message(of: error))")
        }
        var config = NautilusConfig(tts: parseTTS(json, voiceOverride: voiceOverride), source: path)
        config.source = path
        return config
    }

    static func message(of error: NautilusError) -> String {
        switch error {
        case .ConfigError(let message), .InternalError(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Read the `[tts]` table. Unknown keys are ignored rather than rejected —
    /// a config written for a later version should still start this one.
    static func parseTTS(_ root: JSONValue, voiceOverride: String?) -> TextToSpeech.Config {
        guard case .object(let top) = root, case .object(let tts)? = top["tts"] else {
            return TextToSpeech.Config(voice: voiceOverride)
        }

        let defaults = TextToSpeech.Config()
        var byLanguage: [String: TextToSpeech.Voice] = [:]
        for (key, value) in tts {
            // A nested table is a language; a scalar is a default.
            guard case .object(let table) = value else { continue }
            byLanguage[key] = TextToSpeech.Voice(
                identifier: table["voice"]?.stringValue,
                rate: table["rate"]?.doubleValue.map(Float.init),
                pitchMultiplier: table["pitch"]?.doubleValue.map(Float.init),
                volume: table["volume"]?.doubleValue.map(Float.init))
        }

        return TextToSpeech.Config(
            enabled: tts["enabled"]?.boolValue ?? defaults.enabled,
            voice: voiceOverride ?? tts["voice"]?.stringValue,
            rate: tts["rate"]?.doubleValue.map(Float.init) ?? defaults.rate,
            pitchMultiplier: tts["pitch"]?.doubleValue.map(Float.init) ?? defaults.pitchMultiplier,
            volume: tts["volume"]?.doubleValue.map(Float.init) ?? defaults.volume,
            byLanguage: byLanguage)
    }

    /// One line for the startup log, saying what was actually loaded — a config
    /// that is silently not in effect is the thing worth preventing.
    public var summary: String {
        guard let source else {
            return "no config file (looked for \(Self.defaultPath)); voices chosen per language"
        }
        let languages = tts.byLanguage.keys.sorted().joined(separator: ", ")
        return "config: \(source)"
            + (languages.isEmpty ? " (no [tts.<lang>] sections)" : "; tts voices for \(languages)")
    }
}
