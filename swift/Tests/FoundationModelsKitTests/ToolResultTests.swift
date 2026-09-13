import XCTest

@testable import FoundationModelsKit

#if canImport(FoundationModels)

/// A failing tool reports to the *model* instead of aborting the turn — the same
/// contract the app-server backend has, where `item/tool/call` answers
/// `success: false` with the detail.
///
/// The detail is the point. A screen-recording denial and a transient glitch
/// need to look different to the model, and a bridged error localizes both to
/// "The operation couldn't be completed".
final class ToolResultTests: XCTestCase {

    func testSuccessPassesTheValueThrough() async throws {
        let out = try await toolResult { "Open windows (2): …" }
        XCTAssertEqual(out, "Open windows (2): …")
    }

    func testFailureBecomesAResultNotAThrow() async throws {
        struct Boom: Error {}
        let out = try await toolResult { throw Boom() }
        XCTAssertTrue(out.hasPrefix("Tool failed:"), out)
    }

    /// The regression this guards: reporting only `localizedDescription` drops
    /// the cause, so "audio/video capture failure" never reaches the model.
    func testUnderlyingCauseSurvives() async throws {
        let cause = NSError(
            domain: "com.apple.ScreenCaptureKit", code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "Failed to start stream due to audio/video capture failure"]
        )
        let wrapper = NSError(
            domain: "FoundationModels.ToolCallError", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed.",
                NSMultipleUnderlyingErrorsKey: [cause],
            ]
        )

        let out = try await toolResult { throw wrapper }
        XCTAssertTrue(
            out.contains("audio/video capture failure"),
            "the actionable cause must reach the model: \(out)"
        )
        XCTAssertTrue(out.contains("com.apple.ScreenCaptureKit"), out)
    }

    func testSingleUnderlyingErrorKeyIsAlsoRead() {
        let cause = NSError(domain: "TestDomain", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "the real reason"])
        let wrapper = NSError(
            domain: "Outer", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed.",
                NSUnderlyingErrorKey: cause,
            ]
        )
        let detail = errorDetail(wrapper)
        XCTAssertTrue(detail.contains("the real reason"), detail)
        XCTAssertTrue(detail.contains("TestDomain 42"), detail)
    }

    /// Cancellation is not a tool outcome — swallowing it would have the model
    /// reason about a turn that is being torn down.
    func testCancellationPropagates() async {
        do {
            _ = try await toolResult { throw CancellationError() }
            XCTFail("cancellation should propagate, not become a tool result")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

#endif
