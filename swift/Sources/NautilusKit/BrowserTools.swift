import BrowserAX
import Foundation

/// Reading a browser page as semantics rather than pixels.
///
/// The Android side has to learn what a button *looks like*, because a game
/// draws its own widgets and publishes nothing about them. A web page is the
/// opposite: it already declares its roles and names, and macOS surfaces them
/// through Accessibility. So this tool answers in `button named "Sign in"`
/// rather than in coordinates, and what it reads survives a site restyling its
/// markup as long as the accessible semantics hold.
///
/// # One tool, and why the rest went
///
/// There were five here — activate, set value, scroll, back — plus a Chrome
/// backend over the DevTools protocol that served them without an Accessibility
/// grant. They are gone, and this is deliberate rather than a gap waiting to be
/// filled.
///
/// The browser this server can reach is the one on the user's screen, with
/// their logins in it and their attention on it. That is exactly what makes it
/// worth reading — no container full of expired cookies can answer what this
/// page says — and exactly what makes driving it the wrong trade: a synthesized
/// click lands in the window they are looking at, on whatever the id resolved
/// to this time round, and a link opened by mistake cannot be taken back. A
/// misread page costs a retry. A mis-click costs whatever was on the other side
/// of the link.
///
/// So the page is read and never touched. Anything that has to act on a browser
/// belongs above this server, where a person can see it coming.

// MARK: - browser_observe

@MainActor
public final class BrowserObserveTool: MCPTool {
    private let session: BrowserAXSession
    public init(session: BrowserAXSession) { self.session = session }

    public var name: String { "browser_observe" }
    public var description: String {
        "Read the page the browser is showing as a list of elements — buttons, links, text "
            + "fields, headings — each with a role, its accessible name, and an id. Use this "
            + "instead of a screenshot: it is what the page says about itself, so it does not "
            + "depend on layout, styling or language. The list covers the WHOLE page, not just "
            + "what is scrolled into view, so reading a long page needs no scrolling. This READS "
            + "and never acts — there is no tool here that clicks, types, scrolls or navigates, "
            + "because this is the user's own browser window and a stray click cannot be undone; "
            + "ask the user to do it and observe again. Safari and Edge only: Chrome publishes no "
            + "page through Accessibility and answers with its toolbar alone. Fall back to "
            + "macos_capture_window only for things a page does not describe, such as a canvas, a "
            + "chart or a map."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "app": .property(
                "string", "Which browser, e.g. \"Safari\". Default: whichever is running."),
            "interactive_only": .property(
                "boolean",
                "Only controls — buttons, links, fields — dropping plain text and headings. They "
                    + "cannot be activated from here; this is for seeing what a page offers."),
            "filter": .property(
                "string", "Only elements whose name contains this (case-insensitive)."),
            "limit": .property("integer", "Maximum elements to return (default 250)."),
            "include_frames": .property(
                "boolean",
                "Include each element's on-screen rectangle. Needed only when handing a position "
                    + "to a pixel tool, or to tell what is currently scrolled into view — the "
                    + "list itself covers the whole page either way."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let snapshot = try await session.observe(
            preferred: arguments.optionalString("app"),
            limit: arguments.optionalInt("limit") ?? BrowserAXSession.defaultElementLimit,
            interactiveOnly: arguments.bool("interactive_only", default: false))

        let withFrames = arguments.bool("include_frames", default: false)
        // Filtering happens *after* the walk, so the two ways of ending up with
        // nothing are different failures and must not share an explanation.
        let needle = arguments.optionalString("filter").flatMap { $0.isEmpty ? nil : $0 }
        var elements = snapshot.elements
        if let needle {
            elements = elements.filter {
                $0.name.localizedCaseInsensitiveContains(needle)
                    || ($0.value?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }

        var payload: [String: JSONValue] = [
            "app": .string(snapshot.app),
            "title": .string(snapshot.title),
            "elements": .array(
                elements.map { Self.describe($0, frames: withFrames) }),
            "count": .number(Double(elements.count)),
            "backend": .string(session.backendName),
        ]
        payload["url"] = snapshot.url.map { JSONValue.string($0) } ?? .null
        // How many the page actually yielded, when that is not what `count`
        // says. Without it a filtered reply cannot be told from a blank page.
        if needle != nil {
            payload["filtered_from"] = .number(Double(snapshot.elements.count))
        }
        if snapshot.truncated { payload["truncated"] = .bool(true) }
        if let note = Self.note(
            scanned: snapshot.elements.count, matched: elements.count, filter: needle,
            truncated: snapshot.truncated)
        {
            payload["note"] = .string(note)
        }
        return MCPToolResult(text: try JSONValue.object(payload).serialized())
    }

    /// Why the reply is empty, when it is — and `nil` when it is not.
    ///
    /// There are two ways to come back with nothing and they are different
    /// failures, so they must not share an explanation. The walk finding no
    /// elements means the page published none. A filter excluding all of them
    /// means the page read perfectly and the needle simply did not match;
    /// telling someone their page may still be loading, when 435 elements came
    /// back off it, sends them debugging a browser that is working.
    ///
    /// `truncated` compounds the second one. Filtering happens after the walk,
    /// so a walk that stopped at the limit never offered the rest to the
    /// filter, and "no match" is then not the same claim as "not on the page".
    /// A long page hits the default easily: measured, a GitHub pull request
    /// holds 435 elements against a default limit of 250.
    /// `nonisolated` because it is pure arithmetic over three numbers and a
    /// string — nothing here touches Accessibility or AppKit, and a test should
    /// not need the main actor to check which explanation comes back.
    nonisolated static func note(
        scanned: Int, matched: Int, filter: String?, truncated: Bool
    ) -> String? {
        guard matched == 0 else { return nil }

        if scanned == 0 {
            return
                "Nothing was found to report. The page may still be loading, or its content may "
                + "be drawn rather than described — a canvas or WebGL view publishes no "
                + "semantics, and for those macos_capture_window plus image_ocr is the way. "
                + "On Chrome this is expected: it does not publish its page through "
                + "Accessibility at all."
        }
        guard let filter else { return nil }

        let capped =
            truncated
            ? " The walk also stopped early — `truncated` is set, so only the first \(scanned) "
                + "element(s) were searched and a match further down the page would not have "
                + "been seen. Raise `limit` and try again."
            : ""
        return
            "The page was read fine — \(scanned) element(s) — but none of them matched the "
            + "filter \(filter.debugDescription). Nothing is wrong with the page or the "
            + "browser. Matching is a case-insensitive substring of an element's name or value, "
            + "so a shorter fragment is likelier to hit; observe without `filter` to see what "
            + "the page actually calls things." + capped
    }

    static func describe(_ element: BrowserElement, frames: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            // A label for this listing only. Nothing takes it back — ids are
            // for saying which element you mean, not for acting on one.
            "id": .string(element.id),
            "role": .string(element.role),
            "name": .string(element.name),
            "source": .string(element.source),
        ]
        if let value = element.value, value != element.name, !value.isEmpty {
            object["value"] = .string(value.count > 200 ? String(value.prefix(200)) + "…" : value)
        }
        // Only worth saying when it is not the default; a list where every row
        // repeats `enabled: true` is harder to read, not easier.
        if !element.enabled { object["enabled"] = .bool(false) }
        if element.focused { object["focused"] = .bool(true) }
        if frames, let rect = element.frame {
            object["frame"] = .object([
                "x": .number(rect.origin.x.rounded()),
                "y": .number(rect.origin.y.rounded()),
                "w": .number(rect.width.rounded()),
                "h": .number(rect.height.rounded()),
            ])
        }
        return .object(object)
    }
}

/// `browser_observe`, or nothing at all without the Accessibility grant —
/// advertising a tool that can only fail is worse than omitting it.
///
/// There is one way in now. Accessibility is what Safari and Edge answer
/// through, and the grant belongs to the application that launches this server.
/// Chrome is a known blank: it rejects `AXManualAccessibility`
/// (`kAXErrorAttributeUnsupported`, -25205) and answers the walk with its
/// toolbar and tab strip, no `AXWebArea` and a null URL. That used to be
/// covered by a DevTools-protocol backend, which went with the control tools.
/// The summary says so at startup, because a Chrome page reading as 43 toolbar
/// elements looks like a bug rather than a browser refusing to talk.
@MainActor
public func makeBrowserTools() -> (tools: [MCPTool], summary: String) {
    guard BrowserAXSession.isTrusted else {
        return (
            [],
            "no browser tools: Accessibility is not granted (grant it to the app that launches "
                + "this server in System Settings > Privacy & Security > Accessibility)"
        )
    }
    return (
        [BrowserObserveTool(session: BrowserAXSession())],
        "browser tools available (1): browser_observe over ax (Safari, Edge); Chrome publishes "
            + "no page through Accessibility, so its tabs read as toolbar only"
    )
}
