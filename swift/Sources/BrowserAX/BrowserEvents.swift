import CoreGraphics
import Foundation

/// A record of what happened in the browser, whether a person or the agent did it.
///
/// # Why this exists
///
/// `browser_observe` answers "what is on the page now". It cannot answer "what
/// did the user just do", and that second question is the more valuable one: a
/// person using their own browser, already logged in, already past the SSO and
/// the passkey prompt, is demonstrating a task. Watching that costs them
/// nothing and produces a trajectory a skill can be distilled from.
///
/// This is the part that a container-based browser cannot do at all. A
/// throwaway Chromium in Docker has no cookies, no session, and no human in it.
/// Here the person and the agent share one browser, so a demonstration and a
/// replay happen in the same place, against the same logins.
///
/// # What macOS will and will not tell us
///
/// Measured against Safari, and it decided the whole design:
///
/// | | |
/// |---|---|
/// | navigation | `AXLoadComplete` fires, and `AXURL` on the web area is the real URL |
/// | page title | `AXTitleChanged` on the window, twice per load |
/// | typing | `AXValueChanged` carries the text as it is typed |
/// | moving between fields | `AXFocusedUIElementChanged`, with role and name |
/// | **a click** | **nothing at all** — Accessibility has no input event |
/// | **a scroll** | **nothing at all** |
///
/// So Accessibility alone records consequences and misses causes. A click that
/// navigates is visible only as the navigation; a click that opens a menu, or
/// ticks a box, or does nothing, is invisible. A `CGEventTap` supplies exactly
/// the two that are missing, and `AXUIElementCopyElementAtPosition` turns a
/// click at (411, 341) back into `link "Learn more"`.
///
/// The division of labour is therefore: **the tap knows the verbs, Accessibility
/// knows the nouns and the effects.**
///
/// # The tap is deliberately not a keylogger
///
/// A session event tap can see every keystroke in every application, and this
/// one does not ask for them. Typed text comes from `AXValueChanged` on
/// Safari's focused field instead — already scoped to the browser, already
/// naming the field it went into, and worth more to a trajectory than a stream
/// of key codes. The tap subscribes to mouse-down and scroll-wheel only, which
/// is the smallest set that covers what Accessibility cannot see.
///
/// Two further limits, for the same reason: recording is started explicitly and
/// stops on request, and the value of a secure text field is never stored —
/// only the fact that something was typed into one.
public struct BrowserEvent: Sendable {
    public enum Kind: String, Sendable {
        /// A mouse-down, resolved to the element under it.
        case click
        /// A run of wheel movement, coalesced.
        case scroll
        /// A field's value settled after typing.
        case input
        /// A page finished loading.
        case navigate
        /// Keyboard focus moved to another element.
        case focus
    }

    /// Who caused it. A trajectory that cannot tell the demonstration from the
    /// replay is not a demonstration.
    public enum Source: String, Sendable { case user, agent }

    /// Monotonic, never reused, and the cursor a reader pages with.
    public var seq: UInt64
    public var time: Date
    public var kind: Kind
    public var source: Source
    /// Normalized role of the element involved, when there is one.
    public var role: String?
    /// Its accessible name.
    public var name: String?
    /// The field's text, the scroll distance, the load's outcome.
    public var value: String?
    /// The page it happened on, as last seen.
    public var url: String?
    public var title: String?
    /// Where on screen, for a click.
    public var point: CGPoint?

    public init(
        seq: UInt64 = 0, time: Date = Date(), kind: Kind, source: Source = .user,
        role: String? = nil, name: String? = nil, value: String? = nil,
        url: String? = nil, title: String? = nil, point: CGPoint? = nil
    ) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.source = source
        self.role = role
        self.name = name
        self.value = value
        self.url = url
        self.title = title
        self.point = point
    }
}

/// A bounded, append-only log of browser events.
///
/// Bounded because a recorder left running all afternoon must not grow without
/// limit, and append-only because a reader pages forward with `after` and never
/// has to reason about anything moving underneath it. When the capacity is
/// reached the oldest go, and the count of what went is reported — a reader
/// that asks for a sequence already discarded is told so rather than quietly
/// handed a later one, which is the same courtesy the frame store extends about
/// a stale frame.
///
/// Locked rather than an `actor` because the writers are C callbacks on a
/// CFRunLoop thread with no `await` available to them.
public final class BrowserEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrowserEvent] = []
    private var nextSeq: UInt64 = 1
    private var droppedCount: UInt64 = 0
    public let capacity: Int

    /// Called once per event, outside the lock, for anyone who wants to hear
    /// about one as it happens rather than when it is next read. The MCP layer
    /// hangs a notification off this; the queue itself knows nothing about the
    /// protocol.
    private var onAppend: (@Sendable (BrowserEvent) -> Void)?

    public init(capacity: Int = 2000) { self.capacity = capacity }

    public func observe(_ handler: @escaping @Sendable (BrowserEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onAppend = handler
    }

    @discardableResult
    public func append(_ event: BrowserEvent) -> UInt64 {
        lock.lock()
        var stored = event
        stored.seq = nextSeq
        nextSeq &+= 1
        events.append(stored)
        if events.count > capacity {
            let excess = events.count - capacity
            events.removeFirst(excess)
            droppedCount &+= UInt64(excess)
        }
        let handler = onAppend
        lock.unlock()
        // Outside the lock: a handler that came back in here would deadlock,
        // and one that blocks on a socket would stall the recorder thread.
        handler?(stored)
        return stored.seq
    }

    /// Events after `seq`, oldest first. `after: 0` means everything held.
    public func read(after seq: UInt64 = 0, limit: Int = 200) -> (
        events: [BrowserEvent], latest: UInt64, dropped: UInt64, more: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        let matching = events.filter { $0.seq > seq }
        let page = Array(matching.prefix(max(1, limit)))
        return (page, nextSeq &- 1, droppedCount, page.count < matching.count)
    }

    /// The highest sequence issued so far, whether or not it is still held.
    public var latestSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSeq &- 1
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
        droppedCount = 0
    }
}

/// Something that can watch a browser and report what happened in it.
///
/// Split out from `BrowserBackend` because the two capabilities are genuinely
/// independent: Accessibility can observe a page it cannot record (no
/// permission to tap events) and could record one it cannot read. Safari
/// implements this today; a CDP implementation would subscribe to
/// `Page.frameNavigated` and `Runtime` bindings instead, and nothing above here
/// would change.
///
/// Not actor-isolated: the implementation is driven by C callbacks on a
/// CFRunLoop thread that have no `await` available to them, and it guards its
/// own state with a lock. Callers here happen to be `@MainActor` tools.
public protocol BrowserEventSource: AnyObject, Sendable {
    var events: BrowserEventQueue { get }
    var isRecording: Bool { get }
    /// Returns a human-readable description of what is now being watched.
    func startRecording(preferred: String?) throws -> String
    func stopRecording()
}
