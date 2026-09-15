import XCTest

@testable import NautilusKit

/// The two ways `browser_observe` comes back empty, which are different
/// failures and must not read as the same one.
///
/// This is worth a test rather than a careful read because it is pure branch
/// and string logic — unlike the image paths, where `xctest` being Apple-signed
/// makes a green suite meaningless and only the built binary tells the truth.
final class BrowserObserveNoteTests: XCTestCase {

    func testAPageThatYieldedElementsGetsNoNote() {
        XCTAssertNil(
            BrowserObserveTool.note(scanned: 435, matched: 435, filter: nil, truncated: false))
        XCTAssertNil(
            BrowserObserveTool.note(scanned: 435, matched: 3, filter: "merge", truncated: false),
            "a filter that matched is not a failure worth explaining")
    }

    func testAPageThatPublishedNothingIsExplainedAsTheBrowserOrTheContent() throws {
        let note = try XCTUnwrap(
            BrowserObserveTool.note(scanned: 0, matched: 0, filter: nil, truncated: false))
        XCTAssertTrue(note.contains("still be loading"), note)
        XCTAssertTrue(note.contains("Chrome"), "the most likely cause should be named — \(note)")
        XCTAssertTrue(note.contains("image_ocr"), "and the fallback offered — \(note)")
    }

    /// The bug this was written for. A filter that matches nothing on a page
    /// that read 435 elements used to answer "the page may still be loading",
    /// which sends someone debugging a browser that is working perfectly.
    func testAnEmptyFilterResultBlamesTheFilterAndNotThePage() throws {
        let note = try XCTUnwrap(
            BrowserObserveTool.note(
                scanned: 435, matched: 0, filter: "zzz-no-such-element", truncated: false))
        XCTAssertTrue(note.contains("435"), "say how many the page did yield — \(note)")
        XCTAssertTrue(
            note.contains("zzz-no-such-element"), "and what was searched for — \(note)")
        XCTAssertFalse(
            note.contains("still be loading"),
            "the page read fine; nothing about it is broken — \(note)")
        XCTAssertFalse(note.contains("Chrome"), "Chrome has nothing to do with it — \(note)")
    }

    /// Filtering happens after the walk, so a capped walk never offered the
    /// rest of the page to the filter. "No match" is then not the same claim
    /// as "not on the page", and the reply has to say which it means.
    func testATruncatedWalkSaysTheFilterNeverSawTheWholePage() throws {
        let note = try XCTUnwrap(
            BrowserObserveTool.note(scanned: 250, matched: 0, filter: "Privacy", truncated: true))
        XCTAssertTrue(note.contains("truncated"), note)
        XCTAssertTrue(note.contains("limit"), "raising the limit is the recovery — \(note)")

        let complete = try XCTUnwrap(
            BrowserObserveTool.note(scanned: 250, matched: 0, filter: "Privacy", truncated: false))
        XCTAssertFalse(
            complete.contains("truncated"),
            "a complete walk must not hedge about what it searched — \(complete)")
    }

    /// Without a filter there is nothing to blame but the page, and that case
    /// is already covered above. An unfiltered zero with elements scanned
    /// cannot happen, and inventing a message for it would be noise.
    func testNoFilterAndNoMatchIsNotADescribableState() {
        XCTAssertNil(
            BrowserObserveTool.note(scanned: 435, matched: 0, filter: nil, truncated: false))
    }
}
