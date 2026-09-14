import NautilusBridge
import TTS
import XCTest

@testable import NautilusKit

/// Configuration, and the language detection the `say` tool now depends on.
///
/// The thing these cannot check is whether a voice makes a sound — that was
/// established by synthesizing to a buffer and counting frames, and is recorded
/// in `SpokenLanguage`'s own comment.
final class ConfigTests: XCTestCase {

    // MARK: TOML, parsed by the Rust core

    func testNestedTablesSurviveTheCrossing() throws {
        let json = try JSONValue.parse(
            tomlToJson(
                text: """
                    [tts]
                    rate = 0.45

                    [tts.ja]
                    voice = "com.apple.voice.enhanced.ja-JP.Kyoko"
                    """))
        let config = NautilusConfig.parseTTS(json, voiceOverride: nil)
        XCTAssertEqual(config.rate, 0.45, accuracy: 0.0001)
        XCTAssertEqual(
            config.byLanguage["ja"]?.identifier, "com.apple.voice.enhanced.ja-JP.Kyoko")
    }

    func testAMalformedFileIsRejectedRatherThanIgnored() {
        XCTAssertThrowsError(try tomlToJson(text: "[tts\nvoice = 1")) { error in
            guard let error = error as? NautilusError else { return XCTFail("wrong error type") }
            // The parser names the line; a config silently not in effect is the
            // failure worth preventing.
            XCTAssertTrue(NautilusConfig.message(of: error).contains("line 1"))
        }
    }

    func testPerLanguageOverridesFallBackToTheDefaults() throws {
        let json = try JSONValue.parse(
            tomlToJson(
                text: """
                    [tts]
                    rate = 0.5
                    volume = 0.8

                    [tts.ja]
                    rate = 0.45
                    """))
        let config = NautilusConfig.parseTTS(json, voiceOverride: nil)
        XCTAssertEqual(config.byLanguage["ja"]?.rate, 0.45)
        XCTAssertNil(config.byLanguage["ja"]?.volume, "unset means inherit, not zero")
        XCTAssertEqual(config.volume, 0.8, accuracy: 0.0001)
    }

    func testTheFlagBeatsTheFile() throws {
        let json = try JSONValue.parse(
            tomlToJson(text: "[tts]\nvoice = \"from.the.file\""))
        let config = NautilusConfig.parseTTS(json, voiceOverride: "from.the.flag")
        // A flag typed just now should win over a file written last month.
        XCTAssertEqual(config.voice, "from.the.flag")
    }

    func testAnUnknownKeyDoesNotStopTheServerStarting() throws {
        let json = try JSONValue.parse(
            tomlToJson(text: "[tts]\nsomething_from_a_later_version = true\nrate = 0.3"))
        let config = NautilusConfig.parseTTS(json, voiceOverride: nil)
        XCTAssertEqual(config.rate, 0.3, accuracy: 0.0001)
    }

    // MARK: Language detection

    func testKanaSettleJapaneseWithoutAskingTheRecogniser() {
        XCTAssertEqual(SpokenLanguage.detect("こんにちは"), "ja")
        XCTAssertEqual(SpokenLanguage.detect("設定ファイル"), "ja")
    }

    func testEnglishIsDetected() {
        XCTAssertEqual(SpokenLanguage.detect("The quick brown fox jumps over the lazy dog."), "en")
    }

    func testAMixedPassageIsSplitBySentence() {
        let segments = SpokenLanguage.segment(
            "Mixed sentence test. 設定ファイルは TOML です。Back to English now.")
        XCTAssertEqual(segments.map(\.language), ["en", "ja", "en"])
        // Nothing may be dropped: every character still has to be spoken.
        XCTAssertEqual(
            segments.map(\.text).joined().filter { !$0.isWhitespace },
            "Mixed sentence test. 設定ファイルは TOML です。Back to English now."
                .filter { !$0.isWhitespace })
    }

    func testConsecutiveSentencesInOneLanguageStayOneUtterance() {
        let segments = SpokenLanguage.segment("First sentence here. Second sentence here.")
        XCTAssertEqual(segments.count, 1, "prose should not be chopped into one utterance each")
    }

    func testEmptyTextProducesNothingToSay() {
        XCTAssertTrue(SpokenLanguage.segment("").isEmpty)
    }
}
