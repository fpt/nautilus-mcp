import Foundation
import AVFoundation
import Util

/// Text-to-Speech manager using AVSpeechSynthesizer
public class TextToSpeech: NSObject, @unchecked Sendable {
    private let synthesizer: AVSpeechSynthesizer
    private let logger = Logger("TTS")
    private var isSpeaking = false
    private var completion: (() -> Void)?
    /// How many queued utterances are still to finish. A passage that changes
    /// language becomes several utterances, and the caller is not done until
    /// the last of them has been spoken — completing on the first is how a
    /// bilingual sentence would come back half-said.
    private var pending = 0
    /// Whether speech is on. Initialized from config; can be toggled at runtime
    /// (e.g. `/listen` enables it when switching into voice mode).
    private var _enabled: Bool

    /// Enable/disable spoken output at runtime.
    public func setEnabled(_ on: Bool) { _enabled = on }
    public var enabled: Bool { _enabled }

    /// How one language should sound.
    ///
    /// Every field is optional and falls back to the defaults, so a config that
    /// only pins `[tts.ja] voice = "…"` changes nothing else.
    public struct Voice: Sendable {
        public var identifier: String?
        public var rate: Float?
        public var pitchMultiplier: Float?
        public var volume: Float?

        public init(
            identifier: String? = nil, rate: Float? = nil, pitchMultiplier: Float? = nil,
            volume: Float? = nil
        ) {
            self.identifier = identifier
            self.rate = rate
            self.pitchMultiplier = pitchMultiplier
            self.volume = volume
        }
    }

    /// Configuration for TTS.
    ///
    /// `byLanguage` is keyed by bare language code — `en`, `ja` — which is what
    /// `[tts.en]` and `[tts.ja]` in the config file become.
    public struct Config: Sendable {
        public let enabled: Bool
        public let rate: Float
        public let pitchMultiplier: Float
        public let volume: Float
        /// Used when nothing more specific matches.
        public let voice: String?
        public let byLanguage: [String: Voice]

        public init(
            enabled: Bool = true,
            voice: String? = nil,
            rate: Float = 0.5,
            pitchMultiplier: Float = 1.0,
            volume: Float = 1.0,
            byLanguage: [String: Voice] = [:]
        ) {
            self.enabled = enabled
            self.voice = voice
            self.rate = rate
            self.pitchMultiplier = pitchMultiplier
            self.volume = volume
            self.byLanguage = byLanguage
        }
    }

    private let config: Config
    /// Resolved voices, keyed by language code. Built lazily: enumerating all
    /// 185 installed voices for every utterance would be wasteful, and the set
    /// does not change while the server runs.
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
    private let cacheLock = NSLock()

    public init(config: Config) {
        self.config = config
        self._enabled = config.enabled
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        self.synthesizer.delegate = self

        // Warn about a configured voice that is not installed — an *enhanced*
        // voice that has never been downloaded is the usual case — rather than
        // letting it fail silently at the first utterance.
        for (language, voice) in config.byLanguage {
            guard let id = voice.identifier else { continue }
            if AVSpeechSynthesisVoice(identifier: id) == nil {
                logger.warning(
                    "[tts.\(language)] voice \"\(id)\" is not installed; falling back to the "
                        + "best installed \(language) voice. Install it in System Settings > "
                        + "Accessibility > Spoken Content > System Voice > Manage Voices.")
            }
        }
        if let id = config.voice, AVSpeechSynthesisVoice(identifier: id) == nil {
            logger.warning("[tts] voice \"\(id)\" is not installed; falling back.")
        }
    }

    /// The voice to speak `language` with, in order of preference:
    /// the one configured for it, the best installed voice for it, then the
    /// configured default.
    ///
    /// The middle step is what makes an unconfigured Mac work: asking for the
    /// highest-quality installed `ja` voice finds Kyoko (Enhanced) without
    /// anybody naming it, and without a hardcoded table of language-to-locale.
    func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let key = language ?? ""
        cacheLock.lock()
        if let cached = voiceCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var resolved: AVSpeechSynthesisVoice?
        if let language, let id = config.byLanguage[language]?.identifier {
            resolved = AVSpeechSynthesisVoice(identifier: id)
        }
        if resolved == nil, let language {
            resolved = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
                .max { $0.quality.rawValue < $1.quality.rawValue }
        }
        if resolved == nil, let id = config.voice {
            resolved = AVSpeechSynthesisVoice(identifier: id)
        }
        if resolved == nil {
            resolved = AVSpeechSynthesisVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice.speechVoices().first
        }

        cacheLock.lock()
        voiceCache[key] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Per-language overrides on top of the defaults.
    private func settings(for language: String?) -> (rate: Float, pitch: Float, volume: Float) {
        let override = language.flatMap { config.byLanguage[$0] }
        return (
            override?.rate ?? config.rate,
            override?.pitchMultiplier ?? config.pitchMultiplier,
            override?.volume ?? config.volume
        )
    }

    /// Build one utterance per language run in the text.
    func utterances(for text: String) -> [AVSpeechUtterance] {
        SpokenLanguage.segment(text).compactMap { segment in
            guard let voice = voice(for: segment.language) else { return nil }
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            let tuned = settings(for: segment.language)
            utterance.rate = tuned.rate
            utterance.pitchMultiplier = tuned.pitch
            utterance.volume = tuned.volume
            return utterance
        }
    }

    /// Remove `<think>…</think>` reasoning blocks so the synthesizer reads the
    /// answer aloud, not the model's chain-of-thought. Local models (e.g. LFM2.5)
    /// emit these inline in the reply text when no Harmony template is applied.
    /// The full text is still printed by the caller; only speech is sanitized.
    static func sanitizeForSpeech(_ text: String) -> String {
        var s = text
        // Complete blocks (dotall + case-insensitive via inline flags).
        s = s.replacingOccurrences(
            of: "(?is)<think>.*?</think>", with: " ", options: .regularExpression)
        // A dangling/unterminated <think> with no closing tag → drop to end.
        s = s.replacingOccurrences(
            of: "(?is)<think>.*", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speak the given text asynchronously
    /// - Parameter text: The text to speak
    public func speakAsync(_ text: String) async {
        await withCheckedContinuation { continuation in
            self.speak(text) { continuation.resume() }
        }
    }

    /// Speak the given text (callback version for compatibility)
    /// - Parameters:
    ///   - text: The text to speak
    ///   - completion: Called when speech completes
    public func speak(_ text: String, completion: (() -> Void)? = nil) {
        guard _enabled else {
            logger.debug("TTS disabled, skipping speech")
            completion?()
            return
        }

        let spoken = Self.sanitizeForSpeech(text)
        guard !spoken.isEmpty else {
            logger.debug("Empty text (after stripping reasoning), skipping speech")
            completion?()
            return
        }

        if isSpeaking {
            logger.debug("Already speaking, stopping current speech")
            stop()
        }

        // One utterance per language run — see SpokenLanguage for why a single
        // voice for the whole passage is not good enough.
        let queue = utterances(for: spoken)
        guard !queue.isEmpty else {
            logger.error("No usable TTS voice for this text, skipping speech")
            completion?()
            return
        }

        self.completion = completion
        isSpeaking = true
        pending = queue.count

        let described = queue.map { utterance in
            "\(utterance.voice?.language ?? "?"):\(utterance.speechString.prefix(24))"
        }
        logger.info("Speaking \(queue.count) segment(s): \(described.joined(separator: " | "))")

        for utterance in queue { synthesizer.speak(utterance) }
    }

    /// Stop current speech
    public func stop() {
        guard isSpeaking else { return }

        logger.debug("Stopping speech")
        pending = 0
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        completion?()
        completion = nil
    }

    /// Check if currently speaking
    public var speaking: Bool {
        return isSpeaking
    }

    /// List available voices
    public static func availableVoices() -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
    }

    /// List available voices for a specific language
    public static func availableVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
    }

    /// Print available voices (useful for debugging)
    public static func printAvailableVoices() {
        print("\nAvailable TTS Voices:")
        print("====================")

        let voices = AVSpeechSynthesisVoice.speechVoices()

        // Separate enhanced and standard voices
        let enhanced = voices.filter { $0.quality == .enhanced }
        let standard = voices.filter { $0.quality != .enhanced }

        // Print enhanced voices first
        if !enhanced.isEmpty {
            print("\n✨ Enhanced Quality Voices (Premium):")
            print("-------------------------------------")
            let groupedEnhanced = Dictionary(grouping: enhanced, by: { $0.language })
            for (language, voiceList) in groupedEnhanced.sorted(by: { $0.key < $1.key }) {
                print("\n\(language):")
                for voice in voiceList.sorted(by: { $0.name < $1.name }) {
                    print("  ✨ \(voice.name) [\(voice.identifier)]")
                }
            }
        }

        // Print standard voices
        if !standard.isEmpty {
            print("\n📢 Standard Quality Voices:")
            print("---------------------------")
            let groupedStandard = Dictionary(grouping: standard, by: { $0.language })
            for (language, voiceList) in groupedStandard.sorted(by: { $0.key < $1.key }) {
                print("\n\(language):")
                for voice in voiceList.sorted(by: { $0.name < $1.name }) {
                    print("  📢 \(voice.name) [\(voice.identifier)]")
                }
            }
        }

        print("\n💡 Tip: Use enhanced voices for best quality!")
        print("   Example: Set voice to \"com.apple.voice.enhanced.en-US.Zoe\" in config")
        print()
    }

    /// Get enhanced voices for English
    public static func enhancedEnglishVoices() -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-") && $0.quality == .enhanced }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TextToSpeech: AVSpeechSynthesizerDelegate {
    // No `print` anywhere in here. stdout is the MCP transport, and this class
    // has form: its startup announcement of the chosen voice is what first put
    // a non-JSON line in the middle of the protocol. Diagnostics go through the
    // logger, which writes to stderr.
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        logger.debug("Speech started")
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        pending = max(0, pending - 1)
        guard pending == 0 else { return }
        logger.debug("Speech finished")
        isSpeaking = false
        completion?()
        completion = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        logger.debug("Speech paused")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        logger.debug("Speech continued")
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        logger.debug("Speech cancelled")
        pending = 0
        isSpeaking = false
        completion?()
        completion = nil
    }
}
