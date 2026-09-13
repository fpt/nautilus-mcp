import AppKit
import ApplicationServices

/// Semantic access to a browser window through macOS Accessibility.
///
/// # Why this rather than templates
///
/// The Android side had to learn what a button *looks like*, because a game
/// draws its own widgets and tells no one what they are. A browser is the
/// opposite: the page already publishes its own semantics, and macOS exposes
/// them for Safari and Chrome alike. So the model can ask for
/// `button named "Sign in"` instead of matching pixels, and a skill survives a
/// site restyling its markup as long as the accessible role and name hold.
///
/// The same layer serves both browsers, which is the point — a skill written
/// against it does not know or care which one is in front.

// MARK: - Errors

public enum BrowserAXError: LocalizedError {
    case notTrusted
    case noBrowser([String])
    case noWindow(String)
    case staleElement(id: String, observedEpoch: UInt64, currentEpoch: UInt64)
    case noSuchElement(id: String, known: Int)
    case actionFailed(String, AXError)

    public var errorDescription: String? {
        switch self {
        case .notTrusted:
            return """
                Accessibility permission is not granted, so no browser can be read \
                (AXIsProcessTrusted is false; the API returns kAXErrorAPIDisabled). \
                Grant it in System Settings → Privacy & Security → Accessibility to the \
                application that launches this server — the terminal or MCP client, not \
                the browser — then restart that application.
                """
        case .noBrowser(let wanted):
            return "no supported browser is running (looked for \(wanted.joined(separator: ", ")))"
        case .noWindow(let app):
            return "\(app) is running but has no window open"
        case .staleElement(let id, let observed, let current):
            return """
                {"error":"stale_element","element_id":"\(id)",\
                "observed_epoch":\(observed),"current_epoch":\(current),\
                "recovery":"The page has changed since it was read, so this handle may now \
                point at something else. Call browser_observe again and use the fresh ids."}
                """
        case .noSuchElement(let id, let known):
            return "no element \(id); the last observation held \(known). Observe again."
        case .actionFailed(let what, let code):
            return "\(what) failed (AXError \(code.rawValue))"
        }
    }
}

// MARK: - Model

/// One thing on the page the caller can reason about or act on.
public struct BrowserElement: Sendable {
    public var id: String
    /// Normalized role: button, link, textbox, checkbox, radio, combobox, heading, text, image.
    public var role: String
    /// The accessible name — what a screen reader would announce.
    public var name: String
    /// Current value, for fields and controls.
    public var value: String?
    public var enabled: Bool
    public var focused: Bool
    /// Screen rectangle, for the rare case a caller needs to fall back to pixels.
    public var frame: CGRect?
    /// Where the fact came from. Always "ax" today; a CDP backend would say "cdp".
    public var source: String
}

public struct BrowserSnapshot: Sendable {
    public var app: String
    public var title: String
    public var url: String?
    public var epoch: UInt64
    public var elements: [BrowserElement]
    public var truncated: Bool
}

// MARK: - Session

/// Reads and drives the frontmost window of a supported browser.
///
/// Element ids are only meaningful within the observation that produced them.
/// A page re-renders constantly, so a handle from before a click may now point
/// at something else entirely — the same failure the Android side hit with
/// stale frames, and solved the same way: an epoch, bumped by every action,
/// with reads refused against an older one. Selenium calls it
/// `StaleElementReferenceException`; here it is a structured error saying what
/// to do next.
@MainActor
public final class BrowserAXSession {
    /// Browsers this knows how to address, in preference order.
    public static let supported: [(name: String, bundleID: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Chrome", "com.google.Chrome"),
        ("Chrome Canary", "com.google.Chrome.canary"),
        ("Edge", "com.microsoft.edgemac"),
    ]

    /// Roles worth showing a caller, mapped to plain names. An accessibility
    /// tree contains thousands of grouping nodes that are pure structure; a
    /// list dominated by them buries the handful of things that can be acted on.
    static let roleNames: [String: String] = [
        kAXButtonRole: "button",
        "AXLink": "link",
        kAXTextFieldRole: "textbox",
        kAXTextAreaRole: "textbox",
        kAXCheckBoxRole: "checkbox",
        kAXRadioButtonRole: "radio",
        kAXPopUpButtonRole: "combobox",
        kAXComboBoxRole: "combobox",
        kAXMenuButtonRole: "menubutton",
        kAXStaticTextRole: "text",
        "AXHeading": "heading",
        kAXImageRole: "image",
    ]

    /// Guard against pathological pages. A large document can hold tens of
    /// thousands of nodes and walking all of them helps nobody.
    static let visitLimit = 20000
    public static let defaultElementLimit = 250

    private var table: [String: AXUIElement] = [:]
    public private(set) var epoch: UInt64 = 0

    public init() {}

    /// Record that the page may have moved on. Every action calls this.
    public func pageChanged() { epoch &+= 1 }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Reading

    public func observe(
        preferred: String? = nil, limit: Int = BrowserAXSession.defaultElementLimit,
        interactiveOnly: Bool = false
    ) throws -> BrowserSnapshot {
        guard Self.isTrusted else { throw BrowserAXError.notTrusted }

        let running = NSWorkspace.shared.runningApplications
        var chosen: (name: String, pid: pid_t)?
        for candidate in Self.supported {
            if let want = preferred,
                !candidate.name.localizedCaseInsensitiveContains(want),
                candidate.bundleID != want
            { continue }
            if let app = running.first(where: { $0.bundleIdentifier == candidate.bundleID }) {
                chosen = (candidate.name, app.processIdentifier)
                break
            }
        }
        guard let chosen else {
            throw BrowserAXError.noBrowser(preferred.map { [$0] } ?? Self.supported.map(\.name))
        }

        let app = AXUIElementCreateApplication(chosen.pid)
        // The focused window, falling back to the first — a browser with a
        // dialog up would otherwise report the wrong one.
        let window =
            Self.value(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            ?? (Self.value(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else {
            // Nothing at all came back: on a modern macOS that is the API being
            // switched off for us, not a browser with no windows.
            throw Self.isTrusted
                ? BrowserAXError.noWindow(chosen.name) : BrowserAXError.notTrusted
        }

        // Safari builds the web area's tree lazily. The first read after
        // attaching can return the browser's own toolbar and nothing else — 26
        // nodes where a moment later there are 397 — so a thin result with no
        // web area is retried once rather than reported as an empty page.
        var root = window
        for attempt in 0..<2 {
            if Self.countWebArea(root).hasWebArea || attempt == 1 { break }
            Thread.sleep(forTimeInterval: 0.6)
            root = Self.value(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement } ?? root
        }

        table.removeAll()
        var elements: [BrowserElement] = []
        var visited = 0
        var truncated = false
        var webAreaURL: String?

        func walk(_ node: AXUIElement) {
            if visited >= Self.visitLimit || elements.count >= limit {
                truncated = true
                return
            }
            visited += 1
            let rawRole = Self.string(node, kAXRoleAttribute) ?? ""

            if rawRole == "AXWebArea", webAreaURL == nil {
                webAreaURL =
                    (Self.value(node, "AXURL") as? NSURL)?.absoluteString
                    ?? Self.string(node, "AXURL")
            }

            if let role = Self.roleNames[rawRole] {
                let name = Self.name(node)
                let interactive = !["text", "heading", "image"].contains(role)
                // A nameless, valueless node is not addressable and not worth a
                // line in the listing.
                let worthReporting =
                    (!name.isEmpty || Self.string(node, kAXValueAttribute) != nil)
                    && (!interactiveOnly || interactive)
                if worthReporting {
                    let id = "e\(elements.count + 1)"
                    table[id] = node
                    elements.append(
                        BrowserElement(
                            id: id, role: role, name: name,
                            value: Self.string(node, kAXValueAttribute),
                            enabled: (Self.value(node, kAXEnabledAttribute) as? Bool) ?? true,
                            focused: (Self.value(node, kAXFocusedAttribute) as? Bool) ?? false,
                            frame: Self.frame(node), source: "ax"))
                }
            }
            for child in (Self.value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                walk(child)
            }
        }
        walk(root)

        return BrowserSnapshot(
            app: chosen.name,
            title: Self.string(root, kAXTitleAttribute) ?? "",
            url: webAreaURL, epoch: epoch, elements: elements, truncated: truncated)
    }

    // MARK: Acting

    public func element(_ id: String, observedEpoch: UInt64) throws -> AXUIElement {
        guard observedEpoch == epoch else {
            throw BrowserAXError.staleElement(
                id: id, observedEpoch: observedEpoch, currentEpoch: epoch)
        }
        guard let node = table[id] else {
            throw BrowserAXError.noSuchElement(id: id, known: table.count)
        }
        return node
    }

    /// Activate: press a button, follow a link, toggle a checkbox.
    public func activate(_ id: String, observedEpoch: UInt64) throws {
        let node = try element(id, observedEpoch: observedEpoch)
        let code = AXUIElementPerformAction(node, kAXPressAction as CFString)
        guard code == .success else { throw BrowserAXError.actionFailed("press \(id)", code) }
        pageChanged()
    }

    /// Put text into a field. Focuses first, because some fields ignore a value
    /// written to them while they do not have focus.
    public func setValue(_ id: String, to text: String, observedEpoch: UInt64) throws {
        let node = try element(id, observedEpoch: observedEpoch)
        AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let code = AXUIElementSetAttributeValue(
            node, kAXValueAttribute as CFString, text as CFTypeRef)
        guard code == .success else { throw BrowserAXError.actionFailed("set value on \(id)", code) }
        pageChanged()
    }

    /// Does this window's tree contain a web area yet? Used to tell "the page
    /// has no content" from "the tree has not been built".
    static func countWebArea(_ window: AXUIElement) -> (hasWebArea: Bool, nodes: Int) {
        var nodes = 0
        var found = false
        func walk(_ el: AXUIElement) {
            if found || nodes > 600 { return }
            nodes += 1
            if string(el, kAXRoleAttribute) == "AXWebArea" { found = true; return }
            for child in (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child) }
        }
        walk(window)
        return (found, nodes)
    }

    // MARK: Attribute helpers

    static func value(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key as CFString, &out) == .success ? out : nil
    }

    static func string(_ el: AXUIElement, _ key: String) -> String? {
        guard let raw = value(el, key) else { return nil }
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// The accessible name, in the order a screen reader would prefer.
    ///
    /// Collapsed to one line: a page's names carry newlines and runs of spaces
    /// from its markup — GitHub's issues tab announces itself as
    /// "Issues\n\n\u{a0}(1)" — which makes a listing hard to read and a name
    /// awkward to match on.
    static func name(_ el: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute] {
            if let s = string(el, key) { return tidy(s) }
        }
        // A link's text often lives only in its value.
        if let v = string(el, kAXValueAttribute), v.count <= 120 { return tidy(v) }
        return ""
    }

    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posRef = value(el, kAXPositionAttribute),
            let sizeRef = value(el, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
