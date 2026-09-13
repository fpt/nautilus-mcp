import BrowserAX
import BrowserCDP
import Foundation

/// Picks a backend per call and keeps actions on the one that did the reading.
///
/// Two backends exist because the browsers diverged: Safari still publishes its
/// page through macOS Accessibility, and Chrome no longer does — it rejects
/// `AXManualAccessibility` outright, so the AX walk sees a toolbar and no page.
/// CDP covers Chrome; AX covers everything else.
///
/// The routing rule is deliberately boring, because a caller debugging a skill
/// should never have to guess which one answered:
///
/// - `app` naming Safari or Edge → Accessibility.
/// - anything else, when a DevTools endpoint is live → CDP.
/// - no endpoint → Accessibility, as before.
///
/// Actions do not take an `app`, so they cannot re-run that rule. They go to
/// whichever backend served the last `observe`, which is the only answer that
/// can be right: the ids they carry were minted there. Each backend keeps its
/// own epoch for the same reason.
@MainActor
public final class BrowserRouter: BrowserBackend {
    private let ax: BrowserAXSession?
    private let cdp: CDPSession?
    /// The backend that produced the ids currently in a caller's hands.
    private var current: (any BrowserBackend)?

    public init(ax: BrowserAXSession?, cdp: CDPSession?) {
        self.ax = ax
        self.cdp = cdp
        self.current = cdp ?? ax
    }

    public var backendName: String { current?.backendName ?? "none" }
    public var epoch: UInt64 { current?.epoch ?? 0 }
    // Every protocol requirement has to be forwarded, not inherited: the router
    // is itself a `BrowserBackend`, so anything it leaves out is answered by the
    // protocol's own default and the real backend is never asked. This one went
    // missing first time round and silently swallowed the window warning.
    public var ambiguousWindows: [String]? { current?.ambiguousWindows }

    /// Browsers that still answer through Accessibility. Chrome is absent on
    /// purpose — see the type comment.
    private static let axOnly = ["safari", "edge", "webkit"]

    private func backend(for preferred: String?) throws -> any BrowserBackend {
        if let preferred, Self.axOnly.contains(where: { preferred.lowercased().contains($0) }) {
            guard let ax else {
                throw ToolFailure(
                    "\(preferred) can only be read through Accessibility, which is not granted. "
                        + "Grant it to the application that launches this server in System "
                        + "Settings → Privacy & Security → Accessibility, then restart it.")
            }
            return ax
        }
        if let cdp { return cdp }
        guard let ax else { throw ToolFailure("no browser backend is available") }
        return ax
    }

    public func observe(preferred: String?, limit: Int, interactiveOnly: Bool) async throws
        -> BrowserSnapshot
    {
        let chosen = try backend(for: preferred)
        current = chosen
        return try await chosen.observe(
            preferred: preferred, limit: limit, interactiveOnly: interactiveOnly)
    }

    /// Actions follow the last observation — never the routing rule, because an
    /// id from one backend means nothing to the other.
    private func acting() throws -> any BrowserBackend {
        guard let current else { throw ToolFailure("observe a page before acting on it") }
        return current
    }

    public func activate(_ id: String, observedEpoch: UInt64) async throws {
        try await acting().activate(id, observedEpoch: observedEpoch)
    }

    public func setValue(_ id: String, to text: String, observedEpoch: UInt64) async throws {
        try await acting().setValue(id, to: text, observedEpoch: observedEpoch)
    }

    @discardableResult
    public func scroll(_ direction: BrowserScrollDirection, pages: Double, preferred: String?)
        async throws -> String
    {
        // Scrolling renews ids, so it is also a re-route point.
        let chosen = try backend(for: preferred)
        current = chosen
        return try await chosen.scroll(direction, pages: pages, preferred: preferred)
    }

    @discardableResult
    public func goBack(steps: Int, preferred: String?) async throws -> String {
        let chosen = try backend(for: preferred)
        current = chosen
        return try await chosen.goBack(steps: steps, preferred: preferred)
    }
}
