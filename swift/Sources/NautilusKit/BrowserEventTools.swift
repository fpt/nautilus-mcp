import BrowserAX
import Foundation

/// Watching a person browse, so a skill can be learned instead of written.
///
/// # What these are for
///
/// The rest of the browser tools let an agent *drive*. These let it *watch*.
/// Someone doing a task in their own Safari — already signed in, already past
/// the SSO redirect and the passkey prompt — is demonstrating that task, and
/// the demonstration is free. `browser_record_start`, then the person works,
/// then `browser_events_read` returns what they did as a sequence of clicks,
/// entries and navigations, each naming the element it touched.
///
/// That trajectory is the raw material a skill is distilled from, in the same
/// way the Call of Dragons skills were distilled from a session of driving the
/// game by hand — except that here nobody has to narrate.
///
/// # Why the real browser, and not a container
///
/// A headless Chromium in a container starts with no cookies, no session and no
/// person in it, so it can neither be shown a task nor reach anything behind a
/// login without being handed credentials. Recording and replay happen in the
/// browser the user actually uses, sharing one session between the two. That is
/// the whole reason this server drives the window on screen.
///
/// # What is and is not captured
///
/// Keystrokes are **not** tapped. Typed text is read from Accessibility's
/// notification about the focused field, which is scoped to the browser and
/// names the field, where a session-wide key tap would see every password in
/// every application. The value of a secure text field is never stored — only
/// that something was typed into one. Recording is started by an explicit call
/// and stopped by another.

// MARK: - browser_record_start

@MainActor
public final class BrowserRecordStartTool: MCPTool {
    private let recorder: AXBrowserRecorder
    public init(recorder: AXBrowserRecorder) { self.recorder = recorder }

    public var name: String { "browser_record_start" }
    public var description: String {
        "Begin watching what a PERSON does in the browser, so their work can be read back as a "
            + "trajectory and turned into a skill. Records clicks, scrolls, text entered into "
            + "fields, focus changes and page loads — each naming the element involved. Ask the "
            + "user to demonstrate the task, then read the result with browser_events_read. "
            + "Actions this server performs itself are recorded too, marked source=\"agent\", so "
            + "a demonstration can be told from a replay. Safari only: it is the browser that "
            + "publishes its page through Accessibility, and the one holding the user's real "
            + "logins. Typed passwords are never stored."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "app": .property("string", "Which browser to watch. Default: Safari."),
            "clear": .property(
                "boolean", "Discard anything already recorded first. Default: true."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        if arguments.bool("clear", default: true) { recorder.events.clear() }
        let summary = try recorder.startRecording(preferred: arguments.optionalString("app"))
        return MCPToolResult(
            text: try JSONValue.object([
                "recording": .bool(true),
                "target": .string(recorder.target),
                "detail": .string(summary),
                "next": .string(
                    "Ask the user to carry out the task in the browser now, then call "
                        + "browser_events_read. Nothing is reported until they act."),
            ]).serialized())
    }
}

// MARK: - browser_record_stop

@MainActor
public final class BrowserRecordStopTool: MCPTool {
    private let recorder: AXBrowserRecorder
    public init(recorder: AXBrowserRecorder) { self.recorder = recorder }

    public var name: String { "browser_record_stop" }
    public var description: String {
        "Stop watching the browser. Events already recorded stay readable until cleared. Call "
            + "this when a demonstration is finished — the recorder holds an event tap while it "
            + "runs, and leaving it on watches more than it needs to."
    }
    public var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let wasRecording = recorder.isRecording
        recorder.stopRecording()
        return MCPToolResult(
            text: try JSONValue.object([
                "recording": .bool(false),
                "was_recording": .bool(wasRecording),
                "events_held": .number(Double(recorder.events.latestSeq)),
            ]).serialized())
    }
}

// MARK: - browser_events_read

@MainActor
public final class BrowserEventsReadTool: MCPTool {
    private let recorder: AXBrowserRecorder
    public init(recorder: AXBrowserRecorder) { self.recorder = recorder }

    public var name: String { "browser_events_read" }
    public var description: String {
        "Read what has happened in the browser since a given point, oldest first. Each event has "
            + "a `seq`; pass the last one back as `after_seq` next time to get only what is new, "
            + "the way a log is tailed. Kinds: click, scroll, input, navigate, focus. Each says "
            + "whether a person (source=\"user\") or this server (source=\"agent\") caused it. "
            + "Set `wait_seconds` to block until something happens — that is how to hand control "
            + "to the user and be told when they are done, instead of polling. Requires "
            + "browser_record_start first."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "after_seq": .property(
                "integer",
                "Return only events after this sequence number. Omit or 0 for everything held."),
            "limit": .property("integer", "Maximum events to return (default 200)."),
            "wait_seconds": .numberProperty(
                "Block up to this long waiting for the user to act. Default 0 — answer "
                    + "immediately with whatever is already there. This is how to hand control to "
                    + "the user: call it with a generous budget and it returns once they have "
                    + "done something and then paused.", minimum: 0, maximum: 600),
            "settle_seconds": .numberProperty(
                "How long the browser must be quiet before a wait is considered finished "
                    + "(default 2). Raise it if the user pauses to think mid-task.",
                minimum: 0.2, maximum: 60),
            "source": .property(
                "string", "Only \"user\" events or only \"agent\" events. Default: both."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let after = UInt64(max(0, arguments.optionalInt("after_seq") ?? 0))
        let limit = arguments.optionalInt("limit") ?? 200
        let want = arguments.optionalString("source").flatMap { BrowserEvent.Source(rawValue: $0) }

        // Waiting is polling, but polling here rather than in the client: a
        // model that loops on a tool call burns a turn each time, and the whole
        // point is to stand back while a person works.
        //
        // Returning at the *first* event is the obvious implementation and the
        // wrong one. Measured against a scripted demonstration — navigate,
        // click a link, scroll, type in the address bar — it answered after the
        // navigation and reported one event, with the other three arriving
        // seconds later to nobody. A demonstration is finished when the person
        // stops, not when they start, so the wait runs on until the browser has
        // been quiet for `settle_seconds`, and `wait_seconds` is the total
        // budget rather than the answer time.
        let budget = min(600, max(0, arguments["wait_seconds"]?.doubleValue ?? 0))
        let settle = min(60, max(0.2, arguments["settle_seconds"]?.doubleValue ?? 2))
        let deadline = Date().addingTimeInterval(budget)
        var page = recorder.events.read(after: after, limit: limit)
        var lastChange = Date()
        var seen = page.events.count
        while Date() < deadline {
            guard recorder.isRecording else { break }
            // Quiet for long enough, and something to show for it.
            if seen > 0, Date().timeIntervalSince(lastChange) > settle { break }
            try await Task.sleep(nanoseconds: 250_000_000)
            page = recorder.events.read(after: after, limit: limit)
            if page.events.count != seen {
                seen = page.events.count
                lastChange = Date()
            }
        }

        let visible = want.map { wanted in page.events.filter { $0.source == wanted } }
            ?? page.events
        var payload: [String: JSONValue] = [
            "recording": .bool(recorder.isRecording),
            "events": .array(visible.map(Self.describe)),
            "count": .number(Double(visible.count)),
            "latest_seq": .number(Double(page.latest)),
        ]
        if page.more { payload["more"] = .bool(true) }
        // The queue is bounded, so a long unattended recording can outrun a
        // reader. Saying how much went beats presenting a gap as continuity —
        // the same courtesy the frame store extends about a stale frame.
        if page.dropped > 0 {
            payload["dropped_oldest"] = .number(Double(page.dropped))
            payload["dropped_note"] = .string(
                "The recording outran this reader and the oldest \(page.dropped) events were "
                    + "discarded. Read more often, or raise the capacity.")
        }
        if visible.isEmpty {
            payload["note"] = .string(
                recorder.isRecording
                    ? "Nothing has happened yet. Ask the user to carry out the task, or call "
                        + "again with wait_seconds to block until they do."
                    : "Not recording. Call browser_record_start first.")
        }
        return MCPToolResult(text: try JSONValue.object(payload).serialized())
    }

    nonisolated static func describe(_ event: BrowserEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "seq": .number(Double(event.seq)),
            "t": .number((event.time.timeIntervalSince1970 * 1000).rounded() / 1000),
            "kind": .string(event.kind.rawValue),
            "source": .string(event.source.rawValue),
        ]
        if let role = event.role { object["role"] = .string(role) }
        if let name = event.name, !name.isEmpty { object["name"] = .string(name) }
        if let value = event.value, !value.isEmpty {
            object["value"] = .string(value.count > 200 ? String(value.prefix(200)) + "…" : value)
        }
        if let url = event.url { object["url"] = .string(url) }
        if let title = event.title, !title.isEmpty { object["title"] = .string(title) }
        if let point = event.point {
            object["at"] = .object([
                "x": .number(point.x.rounded()), "y": .number(point.y.rounded()),
            ])
        }
        return .object(object)
    }
}

// MARK: - browser_events_clear

@MainActor
public final class BrowserEventsClearTool: MCPTool {
    private let recorder: AXBrowserRecorder
    public init(recorder: AXBrowserRecorder) { self.recorder = recorder }

    public var name: String { "browser_events_clear" }
    public var description: String {
        "Discard everything recorded so far, without stopping the recording. Use it to mark the "
            + "start of a fresh demonstration when the previous one is already read."
    }
    public var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        recorder.events.clear()
        return MCPToolResult(
            text: try JSONValue.object([
                "cleared": .bool(true), "recording": .bool(recorder.isRecording),
            ]).serialized())
    }
}

/// The recorder tools, or nothing when they cannot work.
///
/// They need Accessibility — both halves of the recorder do, the observer to be
/// told anything at all and the event tap to be allowed to exist. There is no
/// CDP equivalent yet, so unlike the control tools these are Accessibility-only
/// and simply absent without the grant, which is the same rule as everywhere
/// else here: a tool that is listed is a tool that works.
@MainActor
public func makeBrowserEventTools() -> (tools: [MCPTool], summary: String) {
    guard BrowserAXSession.isTrusted else {
        return ([], "no browser recording: Accessibility is not granted")
    }
    let recorder = AXBrowserRecorder.shared
    // Push each event as it happens, as well as holding it to be read.
    // One-way and advisory — see MCPNotifier for why browser_events_read with
    // `wait_seconds` remains the mechanism an agent should actually rely on.
    recorder.events.observe { event in
        MCPNotifier.shared.log(
            .info, logger: "browser_events",
            data: BrowserEventsReadTool.describe(event))
    }
    return (
        [
            BrowserRecordStartTool(recorder: recorder),
            BrowserRecordStopTool(recorder: recorder),
            BrowserEventsReadTool(recorder: recorder),
            BrowserEventsClearTool(recorder: recorder),
        ],
        "browser recording available (4): watches Safari through Accessibility plus an event tap"
    )
}
