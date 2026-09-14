import XCTest

@testable import NautilusKit

/// The denied branch, which a machine that already has the grants can never
/// show by running the server.
final class PermissionsTests: XCTestCase {

    private func denied(_ name: String, toolsRemoved: Bool = true) -> Permissions.Status {
        Permissions.Status(
            name: name, granted: false, affects: ["some_tool"], toolsRemoved: toolsRemoved,
            whenDenied: "what actually happens", settingsURL: "x-apple.systempreferences:test")
    }

    private func granted(_ name: String) -> Permissions.Status {
        Permissions.Status(
            name: name, granted: true, affects: ["some_tool"], toolsRemoved: true,
            whenDenied: "unused", settingsURL: "x-apple.systempreferences:test")
    }

    func testADeniedPermissionSaysHowToGrantItAndToWhom() throws {
        let payload = PermissionsTool.describe(
            statuses: [denied("accessibility")],
            responsible: ("Ghostty", "com.mitchellh.ghostty"),
            startupNotes: [], actions: [])

        guard case .object(let permissions)? = payload["permissions"],
            case .object(let entry)? = permissions["accessibility"]
        else { return XCTFail("no accessibility entry") }

        XCTAssertEqual(entry["granted"]?.boolValue, false)
        let how = try XCTUnwrap(entry["how_to_grant"]?.stringValue)
        // Naming the launcher is the whole point: telling someone to add
        // "nautilus-mcp" sends them looking for a row that never appears.
        XCTAssertTrue(how.contains("Ghostty"), how)
        XCTAssertFalse(how.contains("nautilus-mcp"), how)
        XCTAssertNotNil(entry["settings_url"])
        XCTAssertNotNil(entry["what_happens"])
    }

    /// The correction that mattered: the two grants do not behave the same way.
    /// Accessibility removes its tools from the list; Screen Recording does
    /// not — those are built unconditionally and fail when called. A report
    /// claiming otherwise sends someone hunting for a tool that is right there.
    func testTheReportDistinguishesRemovedToolsFromFailingOnes() throws {
        let payload = PermissionsTool.describe(
            statuses: [
                denied("accessibility", toolsRemoved: true),
                denied("screen_recording", toolsRemoved: false),
            ],
            responsible: nil, startupNotes: [], actions: [])

        guard case .object(let permissions)? = payload["permissions"],
            case .object(let ax)? = permissions["accessibility"],
            case .object(let screen)? = permissions["screen_recording"]
        else { return XCTFail("missing entries") }

        XCTAssertEqual(ax["effect"]?.stringValue, "tools_removed_from_list")
        XCTAssertEqual(screen["effect"]?.stringValue, "tools_listed_but_failing")

        let summary = try XCTUnwrap(payload["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("absent from tools/list"), summary)
        XCTAssertTrue(summary.contains("still listed"), summary)
    }

    func testAGrantedPermissionClaimsNothingAboutBehaviour() throws {
        let payload = PermissionsTool.describe(
            statuses: [granted("screen_recording")], responsible: nil, startupNotes: [],
            actions: [])
        guard case .object(let permissions)? = payload["permissions"],
            case .object(let entry)? = permissions["screen_recording"]
        else { return XCTFail("no entry") }
        XCTAssertNil(entry["effect"], "nothing is being prevented, so nothing to explain")
        XCTAssertNil(entry["what_happens"])
    }

    func testAGrantedPermissionDoesNotExplainItself() throws {
        let payload = PermissionsTool.describe(
            statuses: [granted("screen_recording")],
            responsible: ("Terminal", "com.apple.Terminal"), startupNotes: [], actions: [])

        guard case .object(let permissions)? = payload["permissions"],
            case .object(let entry)? = permissions["screen_recording"]
        else { return XCTFail("no entry") }
        XCTAssertEqual(entry["granted"]?.boolValue, true)
        // Recovery text on something that is already working is noise.
        XCTAssertNil(entry["how_to_grant"])
        XCTAssertNil(entry["settings_url"])
    }

    func testTheSummaryNamesEveryMissingGrant() throws {
        let payload = PermissionsTool.describe(
            statuses: [denied("accessibility"), denied("screen_recording")],
            responsible: nil, startupNotes: [], actions: [])
        let summary = try XCTUnwrap(payload["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("accessibility"), summary)
        XCTAssertTrue(summary.contains("screen_recording"), summary)
    }

    /// The affected lists have to match what main.swift actually builds. These
    /// are the real ones, and the recorder tools are the strictly
    /// Accessibility-only set — the browser control tools survive on CDP.
    func testTheRealStatusesNameTheToolsTheyAffect() {
        let statuses = Permissions.all()
        let accessibility = statuses.first { $0.name == "accessibility" }
        let screen = statuses.first { $0.name == "screen_recording" }
        XCTAssertEqual(accessibility?.toolsRemoved, true)
        XCTAssertEqual(screen?.toolsRemoved, false, "the macos_ tools are built unconditionally")
        XCTAssertTrue(accessibility?.affects.contains("browser_record_start") ?? false)
        XCTAssertTrue(screen?.affects.contains("macos_capture_window") ?? false)
        XCTAssertTrue(
            screen?.affects.contains("macos_list_windows") ?? false,
            "it reaches the screen through SCShareableContent like the rest")
    }

    func testAnUnknownLauncherStillProducesUsableAdvice() throws {
        let payload = PermissionsTool.describe(
            statuses: [denied("accessibility")], responsible: nil, startupNotes: [], actions: [])
        guard case .object(let belongs)? = payload["grant_belongs_to"] else {
            return XCTFail("no grant_belongs_to")
        }
        XCTAssertEqual(belongs["bundle_id"], .null)
        XCTAssertTrue(
            try XCTUnwrap(belongs["application"]?.stringValue).contains("launched"),
            "should describe the launcher rather than assert a name it does not know")
    }

    func testStartupReasonsAreCarriedThroughSoAbsenceIsExplainable() throws {
        let payload = PermissionsTool.describe(
            statuses: [granted("accessibility")], responsible: nil,
            startupNotes: ["no Android tools: no device attached"], actions: [])
        guard case .array(let notes)? = payload["startup"] else { return XCTFail("no startup") }
        XCTAssertEqual(notes.first?.stringValue, "no Android tools: no device attached")
    }

    func testNothingEmptyIsIncluded() throws {
        let payload = PermissionsTool.describe(
            statuses: [granted("accessibility")], responsible: nil, startupNotes: [], actions: [])
        XCTAssertNil(payload["startup"], "an empty list is noise in a reply")
        XCTAssertNil(payload["actions"])
    }

    /// The probes themselves cannot assert a value — they report what this
    /// machine happens to be set to — but they must answer without throwing or
    /// hanging, which is what a status tool is for.
    func testProbesAnswer() {
        _ = Permissions.accessibilityGranted
        _ = Permissions.screenRecordingGranted
        XCTAssertEqual(Permissions.all().count, 2)
    }
}
