import BrowserAX
import BrowserCDP
import Foundation

/// Browser control through semantics rather than pixels.
///
/// The Android side has to learn what a button *looks like*, because a game
/// draws its own widgets and publishes nothing about them. A web page is the
/// opposite: it already declares its roles and names, and macOS surfaces them
/// for Safari and Chrome alike. So these tools speak in `button named "Sign in"`
/// rather than in coordinates, and a skill written against them survives a site
/// restyling its markup as long as the accessible semantics hold.
///
/// The backend is deliberately hidden. Every element reports where its facts
/// came from — `ax` for macOS Accessibility, `cdp` for Chrome's DevTools
/// protocol — so a skill written against these tools does not know or care
/// which one answered. `BrowserRouter` picks; see it for the rule.

// MARK: - browser_observe

@MainActor
public final class BrowserObserveTool: MCPTool {
    private let session: any BrowserBackend
    public init(session: any BrowserBackend) { self.session = session }

    public var name: String { "browser_observe" }
    public var description: String {
        "Read the page in the frontmost browser window as a list of elements — buttons, links, "
            + "text fields, headings — each with a role, its accessible name, and an id. Use this "
            + "instead of a screenshot: it is what the page says about itself, so it does not "
            + "depend on layout, styling or language, and the ids can be acted on directly. Works "
            + "the same for Safari and Chrome. The list covers the WHOLE page, not just what is "
            + "scrolled into view, so reading a long page needs no scrolling. Fall back to "
            + "macos_capture_window only for things a page does not describe, such as a canvas, a "
            + "chart or a map."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "app": .property("string", "Which browser, e.g. \"Safari\" or \"Chrome\". Default: whichever is running."),
            "interactive_only": .property(
                "boolean", "Only things that can be acted on — drop plain text and headings."),
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
        var elements = snapshot.elements
        if let needle = arguments.optionalString("filter"), !needle.isEmpty {
            elements = elements.filter {
                $0.name.localizedCaseInsensitiveContains(needle)
                    || ($0.value?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }

        var payload: [String: JSONValue] = [
            "app": .string(snapshot.app),
            "title": .string(snapshot.title),
            "page_epoch": .number(Double(snapshot.epoch)),
            "elements": .array(
                elements.map { Self.describe($0, frames: withFrames) }),
            "count": .number(Double(elements.count)),
            "backend": .string(session.backendName),
        ]
        payload["url"] = snapshot.url.map { JSONValue.string($0) } ?? .null
        if snapshot.truncated { payload["truncated"] = .bool(true) }
        if elements.isEmpty {
            payload["note"] = .string(
                "Nothing addressable was found. The page may still be loading, or its content may "
                    + "be drawn rather than described — a canvas or WebGL view publishes no "
                    + "semantics, and for those macos_capture_window plus image_ocr is the way.")
        }
        return MCPToolResult(text: try JSONValue.object(payload).serialized())
    }

    static func describe(_ element: BrowserElement, frames: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
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

// MARK: - browser_activate

@MainActor
public final class BrowserActivateTool: MCPTool {
    private let session: any BrowserBackend
    public init(session: any BrowserBackend) { self.session = session }

    public var name: String { "browser_activate" }
    public var description: String {
        "Activate an element from the last browser_observe by its id: press a button, follow a "
            + "link, tick a checkbox. Pass the page_epoch that observation reported — if the page "
            + "has changed since, the call is refused rather than acting on whatever now sits at "
            + "that id. Observe again afterwards to see the result."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "element_id": .property("string", "An id from browser_observe, e.g. \"e17\"."),
                "page_epoch": .property(
                    "integer", "The page_epoch of the observation that produced the id."),
            ],
            required: ["element_id"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let id = try arguments.string("element_id")
        let epoch = UInt64(arguments.optionalInt("page_epoch") ?? Int(session.epoch))
        try await session.activate(id, observedEpoch: epoch)
        return MCPToolResult(
            text: "Activated \(id). The page may have changed — browser_observe to see it, and "
                + "note the ids are renewed each time.")
    }
}

// MARK: - browser_set_value

@MainActor
public final class BrowserSetValueTool: MCPTool {
    private let session: any BrowserBackend
    public init(session: any BrowserBackend) { self.session = session }

    public var name: String { "browser_set_value" }
    public var description: String {
        "Type into a text field from the last browser_observe, by id. Replaces whatever the field "
            + "held. Unlike typing key by key this is not affected by keyboard layout or IME, so "
            + "it handles non-ASCII text. Some fields only react to keystrokes; if a value looks "
            + "accepted but the page does not respond, activate the field and use the device "
            + "keyboard instead."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "element_id": .property("string", "An id from browser_observe."),
                "value": .property("string", "Text to put in the field."),
                "page_epoch": .property(
                    "integer", "The page_epoch of the observation that produced the id."),
            ],
            required: ["element_id", "value"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let id = try arguments.string("element_id")
        let value = try arguments.string("value")
        let epoch = UInt64(arguments.optionalInt("page_epoch") ?? Int(session.epoch))
        try await session.setValue(id, to: value, observedEpoch: epoch)
        return MCPToolResult(
            text: "Set \(id) to \(value.count) character(s). browser_observe to confirm it took.")
    }
}

// MARK: - browser_scroll

@MainActor
public final class BrowserScrollTool: MCPTool {
    private let session: any BrowserBackend
    public init(session: any BrowserBackend) { self.session = session }

    public var name: String { "browser_scroll" }
    public var description: String {
        "Scroll the page in the frontmost browser window. Use it when browser_observe's list "
            + "looks short or you are told the result was truncated — a long page is read in "
            + "viewport-sized pieces. Element ids are renewed by scrolling, so observe again "
            + "afterwards. This brings the browser to the front, which is visible on screen."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "direction": .property(
                    "string", "down, up, top or bottom. Default down."),
                "pages": .numberProperty(
                    "How many viewports to move, for up/down (default 1).", minimum: 0.1,
                    maximum: 20),
                "app": .property("string", "Which browser. Default: whichever is running."),
            ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let raw = (arguments.optionalString("direction") ?? "down").lowercased()
        guard let direction = BrowserScrollDirection(rawValue: raw) else {
            throw ToolFailure("direction must be down, up, top or bottom — got \(raw.debugDescription)")
        }
        let text = try await session.scroll(
            direction, pages: arguments["pages"]?.doubleValue ?? 1,
            preferred: arguments.optionalString("app"))
        return MCPToolResult(text: text + " Observe again: the ids have been renewed.")
    }
}

// MARK: - browser_back

@MainActor
public final class BrowserBackTool: MCPTool {
    private let session: any BrowserBackend
    public init(session: any BrowserBackend) { self.session = session }

    public var name: String { "browser_back" }
    public var description: String {
        "Go back in the browser's history — the way out of a page you did not mean to open. "
            + "Element ids from before are invalid afterwards, so observe again. This brings the "
            + "browser to the front, which is visible on screen."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "steps": .property("integer", "How many pages back (default 1)."),
            "app": .property("string", "Which browser. Default: whichever is running."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let text = try await session.goBack(
            steps: arguments.optionalInt("steps") ?? 1,
            preferred: arguments.optionalString("app"))
        return MCPToolResult(text: text + " Observe again: the ids have been renewed.")
    }
}

/// The browser tools, or nothing at all when no backend can serve them —
/// advertising controls that can only fail is worse than omitting them.
///
/// Two independent ways in, and either is enough:
///
/// - **Accessibility**, for Safari. Needs the grant, given to the application
///   that launches this server.
/// - **CDP**, for Chrome. Needs no grant at all, but Chrome must have been
///   started with `--remote-debugging-port`.
///
/// So a Mac with the port open but no Accessibility grant still gets browser
/// control, which the old build refused outright.
@MainActor
public func makeBrowserTools(cdpPort: Int? = CDPSession.defaultPort) async -> (
    tools: [MCPTool], summary: String
) {
    let ax = BrowserAXSession.isTrusted ? BrowserAXSession() : nil
    var cdp: CDPSession?
    if let cdpPort, await CDPSession.isReachable(port: cdpPort) {
        cdp = CDPSession(port: cdpPort)
    }

    guard ax != nil || cdp != nil else {
        return (
            [],
            "no browser tools: Accessibility is not granted (grant it to the app that launches "
                + "this server in System Settings > Privacy & Security > Accessibility), and no "
                + "Chrome is listening for DevTools"
                + (cdpPort.map { " on 127.0.0.1:\($0)" } ?? "")
        )
    }

    let router = BrowserRouter(ax: ax, cdp: cdp)
    let tools: [MCPTool] = [
        BrowserObserveTool(session: router),
        BrowserActivateTool(session: router),
        BrowserSetValueTool(session: router),
        BrowserScrollTool(session: router),
        BrowserBackTool(session: router),
    ]

    var served: [String] = []
    if cdp != nil, let cdpPort { served.append("cdp on \(cdpPort) (Chrome)") }
    if ax != nil { served.append("ax (Safari, Edge)") }
    // Chrome rejects AXManualAccessibility, so an AX-only setup cannot read a
    // Chrome page at all. Say so at startup rather than let it look like a bug.
    if cdp == nil {
        served.append(
            "no CDP endpoint, so Chrome pages are unreadable — Chrome answers AX with its "
                + "toolbar only; start it with --remote-debugging-port to fix that")
    }
    return (tools, "browser tools available (\(tools.count)): " + served.joined(separator: "; "))
}
