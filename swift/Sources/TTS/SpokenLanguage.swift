import Foundation
import NaturalLanguage

/// Working out what language a passage is in, so it can be given a voice that
/// can actually pronounce it.
///
/// # Why this is not optional
///
/// `AVSpeechSynthesizer` does not fall back when the voice and the text
/// disagree. It returns normally, reports the utterance as finished, and plays
/// **nothing** — measured by synthesizing to a buffer rather than to the
/// speakers:
///
/// | | frames | peak amplitude |
/// |---|---|---|
/// | Japanese text, en-US voice | 256 | 0.0000 |
/// | Japanese text, ja-JP voice | 54,465 | 0.7649 |
/// | English text, en-US voice | 35,244 | 0.6831 |
///
/// A tool that answers "Spoke 44 character(s)." while the room stays quiet is
/// the same class of failure as a stale frame: plausible output, no signal that
/// anything is wrong. So the voice is chosen per utterance from the text.
public enum SpokenLanguage {

    /// A run of text and the language it should be spoken in.
    public struct Segment: Sendable, Equatable {
        public let language: String?
        public let text: String
    }

    /// Split a passage into runs that each deserve their own voice.
    ///
    /// Sentences are the unit, because they are where a voice change is
    /// inaudible anyway — a passage broken mid-clause would sound like a fault.
    /// Consecutive sentences in the same language are rejoined into one
    /// utterance so that normal prose is still spoken as prose.
    public static func segment(_ text: String, fallback: String? = nil) -> [Segment] {
        var sentences: [(language: String?, text: String)] = []
        var previous: String? = fallback

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences]) {
            substring, _, _, _ in
            guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            // A short sentence — "OK.", "はい。" — is often undetectable on its
            // own. Carrying the previous sentence's language forward beats
            // dropping to a default mid-paragraph.
            let detected = detect(substring) ?? previous
            previous = detected ?? previous
            sentences.append((detected, substring))
        }

        if sentences.isEmpty {
            return text.isEmpty ? [] : [Segment(language: detect(text) ?? fallback, text: text)]
        }

        var merged: [Segment] = []
        for sentence in sentences {
            if let last = merged.last, last.language == sentence.language {
                merged[merged.count - 1] = Segment(
                    language: last.language, text: last.text + sentence.text)
            } else {
                merged.append(Segment(language: sentence.language, text: sentence.text))
            }
        }
        return merged
    }

    /// The language of a passage, as a bare code such as `ja` or `en`.
    ///
    /// Script comes first and the statistical recogniser second. Kana settle
    /// Japanese outright, where `NLLanguageRecognizer` asked about a short
    /// kanji-only phrase will happily answer Chinese — the scripts genuinely
    /// overlap, and guessing wrong here costs the whole utterance.
    public static func detect(_ text: String) -> String? {
        if let script = byScript(text) { return script }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        // Below this the answer is close to a coin toss, and the fallback is
        // better than a confident mistake.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let confidence = hypotheses[language], confidence >= 0.5 else { return nil }
        return String(language.rawValue.prefix(2))
    }

    /// Languages a writing system settles on its own.
    ///
    /// Han is deliberately absent: without kana it is genuinely ambiguous
    /// between Chinese and Japanese, and that is the one case worth handing to
    /// the statistical recogniser rather than guessing from characters.
    private static func byScript(_ text: String) -> String? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9D: return "ja"  // kana
            case 0xAC00...0xD7AF, 0x1100...0x11FF: return "ko"  // hangul
            case 0x0E00...0x0E7F: return "th"
            case 0x0590...0x05FF: return "he"
            case 0x0600...0x06FF: return "ar"
            case 0x0400...0x04FF: return "ru"
            case 0x0370...0x03FF: return "el"
            default: continue
            }
        }
        return nil
    }
}
