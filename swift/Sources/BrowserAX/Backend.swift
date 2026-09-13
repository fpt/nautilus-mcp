import Foundation

/// What a browser backend has to be able to do.
///
/// Two implementations answer this: `BrowserAXSession`, which reads macOS
/// Accessibility, and `CDPSession`, which speaks the DevTools protocol to
/// Chrome. The tools above hold one of these and never ask which — every
/// element reports its own `source`, so a caller can tell, but nothing has to.
///
/// # Why there are two
///
/// Accessibility was the only backend, and it is still the right one for
/// Safari. Chrome closed the door: setting `AXManualAccessibility` — the
/// documented way to ask Chromium to build its web tree for an assistive
/// client — returns `kAXErrorAttributeUnsupported` (-25205) on Chrome 153, so
/// `browser_observe` sees the toolbar and the tab strip and nothing of the
/// page. Measured on this machine: 43 elements, not one of them page content,
/// and a null URL because there is no `AXWebArea` to read it from.
///
/// CDP asks the renderer directly and so cannot be shut out that way. It is
/// also better behaved for actions — scrolling and history are function calls
/// in the page rather than synthesized keystrokes, so nothing has to be brought
/// to the front and nothing depends on which window has focus.
///
/// Every method is `async` because CDP is a socket conversation. The
/// Accessibility implementation simply never suspends.
@MainActor
public protocol BrowserBackend: AnyObject {
    /// Bumped by every action. An id observed under an older value is refused.
    var epoch: UInt64 { get }
    /// Which backend this is, for diagnostics: "ax" or "cdp".
    var backendName: String { get }

    func observe(preferred: String?, limit: Int, interactiveOnly: Bool) async throws
        -> BrowserSnapshot
    func activate(_ id: String, observedEpoch: UInt64) async throws
    func setValue(_ id: String, to text: String, observedEpoch: UInt64) async throws
    @discardableResult
    func scroll(_ direction: BrowserScrollDirection, pages: Double, preferred: String?) async throws
        -> String
    @discardableResult
    func goBack(steps: Int, preferred: String?) async throws -> String
}

/// Where the page scrolls: `down`/`up` move by viewports, `top`/`bottom` jump.
public enum BrowserScrollDirection: String, Sendable {
    case down, up, top, bottom
}
