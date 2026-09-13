import AppKit
import ApplicationServices
import Foundation

/// Watches a person use Safari and writes down what they did.
///
/// See `BrowserEvent` for what macOS does and does not report, and why this
/// needs both an `AXObserver` and a `CGEventTap` to see a whole interaction.
///
/// # It runs on its own thread
///
/// Both mechanisms deliver through a `CFRunLoop`, and this server's main thread
/// is parked in the stdio loop reading JSON-RPC. So the recorder starts a
/// thread, builds the observer and the tap on it, and runs a run loop there for
/// as long as recording lasts. Nothing else in the process has to know.
///
/// # Noise is the real problem, and focus is the filter
///
/// Raw Accessibility notifications are nowhere near a trajectory. Measured
/// here: pressing ⌘L and typing four characters produced **about eighty**
/// `AXValueChanged` notifications in three hundred milliseconds — every
/// suggestion row in the address-bar dropdown, every favicon beside one, the
/// headings "Google Suggestions" and "Top Hit". Logging that verbatim buries
/// the four keystrokes that mattered.
///
/// One rule removes almost all of it: **report a value change only for the
/// element that currently has keyboard focus.** A suggestion row is not
/// focused; the field being typed into is. What survives is then debounced per
/// element, so a word typed one letter at a time settles into a single `input`
/// event carrying the finished text rather than one event per character.
///
/// Scrolls get the same treatment by distance and time — a flick of the wheel
/// is one gesture and one event, not forty.
public final class AXBrowserRecorder: BrowserEventSource, @unchecked Sendable {
    /// One per process. Shared rather than injected because the *actions* have
    /// to reach it — `BrowserAXSession` marks its own work as it does it, and
    /// threading a recorder through every call site to say "this was me" would
    /// be a lot of plumbing for one boolean.
    public static let shared = AXBrowserRecorder()

    public let events: BrowserEventQueue

    /// Tags the `CGEvent`s this process synthesizes, so the tap can recognise
    /// its own reflection. Without it, `browser_scroll` would be recorded as a
    /// person scrolling, and a replay would be indistinguishable from the
    /// demonstration it came from.
    public static let agentEventMagic: Int64 = 0x4E41_5554  // "NAUT"

    /// Roles a click is worth attributing to. A hit test lands on the deepest
    /// node under the cursor, which for a link is its `AXStaticText` child —
    /// measured: clicking "Learn more" on example.com resolved to
    /// `AXStaticText "Learn more"`, not to the link that actually navigated. So
    /// the resolver walks up until it finds something that could have been
    /// pressed.
    static let actionableRoles: Set<String> = [
        "AXLink", kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXComboBoxRole, kAXMenuButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXMenuItemRole,
        kAXDisclosureTriangleRole, kAXTabGroupRole, kAXSliderRole, kAXIncrementorRole,
    ]

    /// Roles whose gaining focus means something in a trajectory. Everything
    /// else that can hold focus — the window, a group, a scroll area — is
    /// structure, and reporting it buries the field the person actually moved
    /// into.
    static let focusWorthReporting: Set<String> = [
        "textbox", "combobox", "button", "link", "checkbox", "radio", "menubutton",
    ]

    private let lock = NSRecursiveLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var observer: AXObserver?
    private var tap: CFMachPort?
    private var flushTimer: CFRunLoopTimer?

    private var appElement: AXUIElement?
    private var browserPID: pid_t = 0
    private var browserName = ""
    private var recording = false

    /// Which application is in front, cached so the tap callback stays cheap:
    /// it runs for every click in every application, and a tap whose callback
    /// is ever too slow is switched off by the system.
    ///
    /// Read through the system-wide Accessibility element rather than from an
    /// `NSWorkspace` notification. The notification is delivered on the main
    /// run loop, and this server's main thread is parked in the stdio loop
    /// rather than running one — so the cached value would have been whatever
    /// was frontmost when recording started, forever, and every click would
    /// have been discarded as belonging to another application. Accessibility
    /// answers from any thread and needs no run loop at all.
    private var frontPID: pid_t = 0

    private var lastURL: String?
    private var lastTitle: String?
    private var agentUntil = Date.distantPast
    private var lastFocusKey = ""

    private var pendingScroll: (dy: Double, at: Date, role: String?, name: String?)?
    private var pendingInput: (role: String, name: String, value: String, at: Date)?

    public init(capacity: Int = 2000) { self.events = BrowserEventQueue(capacity: capacity) }

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    /// What is being watched, for the tool's reply.
    public var target: String {
        lock.lock()
        defer { lock.unlock() }
        return browserName
    }

    // MARK: - Agent attribution

    /// Called by every action this server performs, just before it performs it.
    ///
    /// Two mechanisms are needed because agent actions arrive by two routes.
    /// Synthesized input carries `agentEventMagic` and is recognised exactly.
    /// An `AXPress` or a value written through Accessibility posts no event at
    /// all — its only trace is the `AXValueChanged` or `AXLoadComplete` that
    /// follows, which looks precisely like a person's. For those there is
    /// nothing to tag, so a short window after the call is attributed to the
    /// agent. A second and a half covers a page load; a person who clicks
    /// something else inside that window has it credited to the agent, which is
    /// the mistake worth making in this direction.
    public func markAgentAction() {
        lock.lock()
        defer { lock.unlock() }
        agentUntil = Date().addingTimeInterval(1.5)
    }

    private func sourceNow(tagged: Bool = false) -> BrowserEvent.Source {
        if tagged { return .agent }
        lock.lock()
        defer { lock.unlock() }
        return Date() < agentUntil ? .agent : .user
    }

    // MARK: - Start and stop

    public func startRecording(preferred: String? = nil) throws -> String {
        lock.lock()
        let already = recording
        lock.unlock()
        if already { return "already recording \(target)" }

        guard AXIsProcessTrusted() else { throw BrowserAXError.notTrusted }

        // Safari is the one that answers through Accessibility, and is the
        // point of this: it is the browser holding the person's real sessions.
        let wanted = preferred ?? "Safari"
        let running = NSWorkspace.shared.runningApplications
        guard
            let candidate = BrowserAXSession.supported.first(where: {
                $0.name.localizedCaseInsensitiveContains(wanted) || $0.bundleID == wanted
            }), let app = running.first(where: { $0.bundleIdentifier == candidate.bundleID })
        else { throw BrowserAXError.noBrowser([wanted]) }

        lock.lock()
        browserPID = app.processIdentifier
        browserName = candidate.name
        appElement = AXUIElementCreateApplication(app.processIdentifier)
        lock.unlock()
        refreshFrontPID()

        // Start the run loop thread and wait for it to report whether the
        // observer and the tap actually came up. Reporting success before
        // knowing would mean a recorder that silently records nothing.
        let ready = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let thread = Thread { [weak self] in self?.runLoopMain(ready: ready, box: box) }
        thread.name = "nautilus.browser-recorder"
        thread.stackSize = 512 * 1024
        thread.start()
        self.thread = thread
        ready.wait()
        if let error = box.error {
            stopRecording()
            throw error
        }

        lock.lock()
        recording = true
        lock.unlock()
        refreshPageContext()

        let where_ = lastURL.map { " on \($0)" } ?? ""
        return "recording \(browserName)\(where_)"
    }

    public func stopRecording() {
        lock.lock()
        recording = false
        let loop = runLoop
        lock.unlock()

        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    final class ErrorBox: @unchecked Sendable { var error: Error? }

    private func runLoopMain(ready: DispatchSemaphore, box: ErrorBox) {
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        runLoop = loop
        let pid = browserPID
        lock.unlock()

        let me = Unmanaged.passUnretained(self).toOpaque()

        // --- Accessibility: the nouns and the effects ---
        var made: AXObserver?
        let axError = AXObserverCreate(pid, axCallback, &made)
        guard axError == .success, let made else {
            box.error = BrowserAXError.actionFailed("create an AX observer", axError)
            ready.signal()
            return
        }
        for name in [
            "AXLoadComplete", kAXTitleChangedNotification, kAXValueChangedNotification,
            kAXFocusedUIElementChangedNotification,
        ] {
            lock.lock()
            let element = appElement
            lock.unlock()
            if let element { AXObserverAddNotification(made, element, name as CFString, me) }
        }
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(made), .defaultMode)

        // --- Event tap: the verbs Accessibility cannot see ---
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard
            let made2 = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: me)
        else {
            box.error = BrowserAXError.actionFailed(
                "create an event tap (clicks and scrolls are invisible to Accessibility, so "
                    + "recording needs one; this needs the same Accessibility grant)", .failure)
            ready.signal()
            return
        }
        CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, made2, 0), .commonModes)
        CGEvent.tapEnable(tap: made2, enable: true)

        // Debounced coalescing: typing and wheel movement arrive as bursts and
        // are written down once each, when they go quiet.
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.2, 0.2, 0, 0)
        { [weak self] _ in self?.flushPending() }
        CFRunLoopAddTimer(loop, timer, .defaultMode)

        lock.lock()
        observer = made
        tap = made2
        flushTimer = timer
        lock.unlock()
        ready.signal()

        CFRunLoopRun()

        // Torn down on the thread that built them.
        lock.lock()
        if let timer = flushTimer { CFRunLoopTimerInvalidate(timer) }
        if let tap { CFMachPortInvalidate(tap) }
        observer = nil
        tap = nil
        flushTimer = nil
        runLoop = nil
        lock.unlock()
    }

    // MARK: - Accessibility notifications

    fileprivate func handleAX(_ element: AXUIElement, _ notification: String) {
        guard isRecording else { return }
        switch notification {
        case "AXLoadComplete":
            refreshPageContext()
            flushPending(force: true)
            lock.lock()
            let (url, title) = (lastURL, lastTitle)
            lock.unlock()
            // A load fires the title change twice as well; only the load itself
            // is written down, and only when it went somewhere new.
            emit(
                BrowserEvent(
                    kind: .navigate, source: sourceNow(), value: url, url: url, title: title))

        case kAXTitleChangedNotification:
            let title = BrowserAXSession.string(element, kAXTitleAttribute)
            lock.lock()
            lastTitle = title
            lock.unlock()

        case kAXFocusedUIElementChangedNotification:
            let role = normalizedRole(element)
            let name = BrowserAXSession.name(element)
            let key = "\(role ?? "-")|\(name)"
            lock.lock()
            let repeated = key == lastFocusKey
            lock.unlock()
            // One ⌘L produced three of these for the same field, two of them
            // on the window itself. Focus landing on a window, a group or a
            // scroll area is not a step in anybody's task — only focus on
            // something that can be typed into or pressed is worth writing
            // down, and saying the same one three times adds nothing either.
            guard !repeated, let role, Self.focusWorthReporting.contains(role), !name.isEmpty
            else { return }
            // Remembered only for what is actually reported. Updating it for
            // the filtered-out ones too let a window-level focus slip between
            // two entries into the same field and defeat the check — measured:
            // the address bar was reported twice in the same millisecond.
            lock.lock()
            lastFocusKey = key
            lock.unlock()
            flushPending(force: true)
            emit(
                BrowserEvent(
                    kind: .focus, source: sourceNow(), role: role, name: name, url: currentURL))

        case kAXValueChangedNotification:
            // The filter that makes this usable at all — see the type comment.
            guard isFocused(element) else { return }
            guard let role = normalizedRole(element), role == "textbox" || role == "combobox"
            else { return }
            let secure =
                BrowserAXSession.string(element, kAXSubroleAttribute) == "AXSecureTextField"
            let text =
                secure ? "«secure field, not recorded»" : BrowserAXSession.string(element, kAXValueAttribute) ?? ""
            lock.lock()
            pendingInput = (role, BrowserAXSession.name(element), text, Date())
            lock.unlock()

        default:
            break
        }
    }

    /// Is this the element the keyboard is in? One AX round-trip, and it is
    /// what separates four keystrokes from eighty dropdown repaints.
    private func isFocused(_ element: AXUIElement) -> Bool {
        lock.lock()
        let app = appElement
        lock.unlock()
        guard let app,
            let focused = BrowserAXSession.value(app, kAXFocusedUIElementAttribute)
        else { return false }
        return CFEqual(focused, element)
    }

    /// Ask the window server, through Accessibility, which application has the
    /// keyboard. One round trip, from any thread, no run loop needed.
    @discardableResult
    private func refreshFrontPID() -> pid_t {
        var pid: pid_t = 0
        if let app = BrowserAXSession.value(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)
        {
            AXUIElementGetPid(app as! AXUIElement, &pid)
        }
        lock.lock()
        frontPID = pid
        lock.unlock()
        return pid
    }

    private func normalizedRole(_ element: AXUIElement) -> String? {
        guard let raw = BrowserAXSession.string(element, kAXRoleAttribute) else { return nil }
        return BrowserAXSession.roleNames[raw] ?? raw
    }

    private var currentURL: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastURL
    }

    /// Re-read the window's URL and title. Bounded, because it runs on every
    /// navigation and a large document is a large tree — the web area sat at
    /// depth 7 in Safari, so there is no reason to go deep looking for it.
    private func refreshPageContext() {
        lock.lock()
        let app = appElement
        lock.unlock()
        guard let app else { return }
        let window =
            BrowserAXSession.value(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            ?? (BrowserAXSession.value(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return }
        var url: String?
        var visited = 0
        func walk(_ node: AXUIElement, _ depth: Int) {
            if url != nil || depth > 12 || visited > 400 { return }
            visited += 1
            if BrowserAXSession.string(node, kAXRoleAttribute) == "AXWebArea" {
                url =
                    (BrowserAXSession.value(node, "AXURL") as? NSURL)?.absoluteString
                    ?? BrowserAXSession.string(node, "AXURL")
                return
            }
            for child in (BrowserAXSession.value(node, kAXChildrenAttribute) as? [AXUIElement])
                ?? []
            { walk(child, depth + 1) }
        }
        walk(window, 0)
        lock.lock()
        if let url { lastURL = url }
        lastTitle = BrowserAXSession.string(window, kAXTitleAttribute) ?? lastTitle
        lock.unlock()
    }

    // MARK: - Tapped input

    fileprivate func handleTap(_ type: CGEventType, _ event: CGEvent) {
        guard isRecording else { return }
        let tagged = event.getIntegerValueField(.eventSourceUserData) == Self.agentEventMagic

        lock.lock()
        var (front, mine, app) = (frontPID, browserPID, appElement)
        lock.unlock()
        // A session tap sees every application. Anything outside the browser is
        // none of this recorder's business and is dropped before it is looked
        // at, let alone written down.
        //
        // The cache is refreshed periodically, so a click that arrives just
        // after the user switched to the browser can still see the old value.
        // Rather than lose the first click of a demonstration, a miss is
        // checked once against the live answer — one Accessibility round trip,
        // and only on clicks that look like they belong to somebody else.
        if front != mine { front = refreshFrontPID() }
        guard front == mine, let app else { return }

        switch type {
        case .leftMouseDown:
            let point = event.location
            let hit = resolve(app, at: point)
            flushPending(force: true)
            emit(
                BrowserEvent(
                    kind: .click, source: sourceNow(tagged: tagged), role: hit.role,
                    name: hit.name, url: currentURL, point: point))

        case .scrollWheel:
            // Point delta, not line delta. `scrollWheelEventDeltaAxis1` counts
            // wheel notches and reported 72 for a gesture that moved the page
            // 720 points, which is a tenth of the truth and useless for saying
            // how far a demonstration scrolled.
            var dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            if dy == 0 { dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10 }
            lock.lock()
            if var pending = pendingScroll {
                pending.dy += dy
                pending.at = Date()
                pendingScroll = pending
            } else {
                pendingScroll = (dy, Date(), nil, nil)
            }
            lock.unlock()

        default:
            break
        }
    }

    /// Turn a screen position into something worth naming.
    ///
    /// The hit test answers with the deepest node, which is usually a label
    /// inside the control that was actually pressed, so this climbs to the
    /// nearest actionable ancestor and reports that. If nothing on the way up
    /// is actionable — a click on empty page background — the hit itself is
    /// reported, because "clicked on nothing in particular" is still part of a
    /// trajectory.
    private func resolve(_ app: AXUIElement, at point: CGPoint) -> (role: String?, name: String?) {
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
            let hit
        else { return (nil, nil) }

        var node = hit
        for _ in 0..<6 {
            let raw = BrowserAXSession.string(node, kAXRoleAttribute) ?? ""
            if Self.actionableRoles.contains(raw) {
                return (BrowserAXSession.roleNames[raw] ?? raw, BrowserAXSession.name(node))
            }
            guard let parent = BrowserAXSession.value(node, kAXParentAttribute) else { break }
            node = parent as! AXUIElement
        }
        let raw = BrowserAXSession.string(hit, kAXRoleAttribute) ?? ""
        return (BrowserAXSession.roleNames[raw] ?? raw, BrowserAXSession.name(hit))
    }

    // MARK: - Coalescing

    /// Write down anything that has gone quiet.
    ///
    /// Typing settles slower than scrolling because a person pauses mid-word
    /// and means to continue; a wheel that has been still for four hundred
    /// milliseconds is a finished gesture.
    /// `force` ends whatever is in flight regardless of how recently it moved.
    /// A click, a focus change or a page load definitively finishes a scroll
    /// gesture and a run of typing, and without this the coalesced event is
    /// written down *after* the thing that ended it — measured: an agent
    /// scroll took sequence 3 while the navigation it preceded took 2, which
    /// is a trajectory in the wrong order.
    private func flushPending(force: Bool = false) {
        refreshFrontPID()
        let now = Date()
        var toEmit: [BrowserEvent] = []

        lock.lock()
        if let scroll = pendingScroll, force || now.timeIntervalSince(scroll.at) > 0.4 {
            pendingScroll = nil
            let direction = scroll.dy < 0 ? "down" : "up"
            toEmit.append(
                BrowserEvent(
                    kind: .scroll, source: Date() < agentUntil ? .agent : .user,
                    value: "\(direction) \(Int(abs(scroll.dy))) points", url: lastURL))
        }
        if let input = pendingInput, force || now.timeIntervalSince(input.at) > 0.7 {
            pendingInput = nil
            toEmit.append(
                BrowserEvent(
                    kind: .input, source: Date() < agentUntil ? .agent : .user, role: input.role,
                    name: input.name, value: input.value, url: lastURL))
        }
        lock.unlock()

        for event in toEmit { events.append(event) }
    }

    private func emit(_ event: BrowserEvent) { events.append(event) }
}

// MARK: - C callbacks

/// Free functions because both APIs take C function pointers, which cannot
/// capture. The recorder travels through the refcon instead.
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let recorder = Unmanaged<AXBrowserRecorder>.fromOpaque(refcon).takeUnretainedValue()
    recorder.handleAX(element, notification as String)
}

private let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    // The system switches a tap off if its callback is ever too slow, and says
    // so by sending this. Re-enabling is the whole recovery; without it the
    // recorder goes quiet and nothing says why.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon {
            let recorder = Unmanaged<AXBrowserRecorder>.fromOpaque(refcon).takeUnretainedValue()
            recorder.reenableTap()
        }
        return Unmanaged.passUnretained(event)
    }
    if let refcon {
        let recorder = Unmanaged<AXBrowserRecorder>.fromOpaque(refcon).takeUnretainedValue()
        recorder.handleTap(type, event)
    }
    return Unmanaged.passUnretained(event)
}

extension AXBrowserRecorder {
    fileprivate func reenableTap() {
        lock.lock()
        let port = tap
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}
