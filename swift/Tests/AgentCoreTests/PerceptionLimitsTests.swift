import XCTest

@testable import AgentCore

/// The tool-result cap is a hard context budget, not a hint: Foundation Models
/// throws on overflow rather than truncating, so a result that overshoots the
/// cap can fail a turn outright.
final class PerceptionLimitsTests: XCTestCase {

    func testShortTextPassesThroughUntouched() {
        let text = "Safari — Apple Developer Documentation"
        XCTAssertEqual(PerceptionLimits.cap(text), text)
    }

    func testTextExactlyAtTheCapIsNotTruncated() {
        let text = String(repeating: "x", count: PerceptionLimits.maxResultChars)
        XCTAssertEqual(PerceptionLimits.cap(text), text)
    }

    /// The regression this guards: the notice used to be appended *after* taking
    /// a full-size prefix, so every truncated result exceeded the cap.
    func testTruncatedResultHonoursTheCapIncludingItsNotice() {
        for overshoot in [1, 100, 50_000] {
            let text = String(repeating: "y", count: PerceptionLimits.maxResultChars + overshoot)
            let capped = PerceptionLimits.cap(text)
            XCTAssertLessThanOrEqual(
                capped.count, PerceptionLimits.maxResultChars,
                "cap overshot by \(capped.count - PerceptionLimits.maxResultChars) for +\(overshoot)"
            )
            XCTAssertTrue(capped.contains("truncated"), "truncation must be visible to the model")
        }
    }

    /// OCR over a full screen is the realistic case, and the one most likely to
    /// blow the window in a single tool call.
    func testOcrSizedInputIsBroughtWithinBudget() {
        let ocr = String(repeating: "The quick brown fox. ", count: 3_000)  // ~63k chars
        let capped = PerceptionLimits.cap(ocr)
        XCTAssertLessThanOrEqual(capped.count, PerceptionLimits.maxResultChars)
        // ~4 chars/token: the whole point is staying a small share of 4096.
        XCTAssertLessThan(capped.count / 4, 500)
    }
}
