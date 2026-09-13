import CoreGraphics
import XCTest

@testable import ScreenCapture

/// `WindowInfo`'s two renderings are what the agent actually sees of the screen:
/// `summary` feeds the ambient situation, `findWindowDescription` is the output
/// of `list_windows`/`find_window`. Both take optionals from the window server.
final class WindowInfoTests: XCTestCase {

    private func info(title: String?, app: String?) -> WindowInfo {
        WindowInfo(
            windowID: 42,
            title: title,
            appName: app,
            bundleId: nil,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }

    func testSummaryRendersAppTitleAndSize() {
        XCTAssertEqual(
            info(title: "goal.rs — voice-agent", app: "Code").summary,
            "Code — goal.rs — voice-agent (1440x900)"
        )
    }

    func testFindWindowDescriptionCarriesTheWindowId() {
        let text = info(title: "Inbox", app: "Mail").findWindowDescription
        XCTAssertTrue(text.contains("id: 42"), "the id is what capture_screen is called with: \(text)")
        XCTAssertTrue(text.contains("\"Inbox\""))
        XCTAssertTrue(text.contains("app: Mail"))
    }

    /// The window server supplies neither reliably; a missing one must degrade
    /// to a placeholder rather than produce "nil" in a prompt.
    func testMissingTitleAndAppFallBackToPlaceholders() {
        let both = info(title: nil, app: nil)
        XCTAssertEqual(both.summary, "? — untitled (1440x900)")
        XCTAssertFalse(both.findWindowDescription.contains("nil"))

        XCTAssertTrue(info(title: nil, app: "Finder").summary.contains("untitled"))
        XCTAssertTrue(info(title: "Downloads", app: nil).summary.hasPrefix("? —"))
    }

    /// Fractional frames come back from Core Graphics; sizes are rendered as
    /// integers so they stay short in the prompt.
    func testSizeIsRenderedAsIntegers() {
        let w = WindowInfo(
            windowID: 1, title: "t", appName: "a", bundleId: nil,
            frame: CGRect(x: 0, y: 0, width: 1439.6, height: 899.4)
        )
        XCTAssertTrue(w.summary.contains("(1439x899)"), w.summary)
    }
}
