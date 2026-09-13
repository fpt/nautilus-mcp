import Foundation

/// Server-initiated messages, for the one case that needs them.
///
/// Everything else here is request/response: a client asks, the server answers,
/// and nothing is ever sent unbidden. Recording is the exception — the whole
/// point is that a person acts on their own schedule and the server is the only
/// one that knows when. MCP allows for this: a server that declares the
/// `logging` capability may send `notifications/message` whenever it likes,
/// and JSON-RPC requires a notification to carry no id and get no reply.
///
/// # What this is honestly worth
///
/// A notification is one-way and does not wake a model. Clients differ in what
/// they do with one — display it, log it, drop it — and none of them will
/// interrupt an agent mid-turn to deliver it. So this is for a human watching
/// the client's log while they demonstrate a task, and for clients that grow
/// better handling later. **It is not a substitute for `wait_seconds` on
/// `browser_events_read`**, which is what actually lets an agent stand back and
/// be told when the user has finished.
///
/// Nothing is emitted unless a recording is running, so a client that ignores
/// unknown notifications never sees one it did not ask for.
public final class MCPNotifier: @unchecked Sendable {
    public static let shared = MCPNotifier()

    /// The syslog-shaped levels MCP uses, most verbose first.
    public enum Level: String, CaseIterable, Sendable {
        case debug, info, notice, warning, error, critical, alert, emergency

        var severity: Int { Level.allCases.firstIndex(of: self)! }
    }

    private let lock = NSLock()
    private var sink: (@Sendable (String) -> Void)?
    private var minimum: Level = .info

    private init() {}

    /// Point the notifier at the transport. Called once, from the place that
    /// owns stdout — nothing else in the process may write there.
    public func attach(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    /// `logging/setLevel`. Returns false for a level the spec does not define.
    @discardableResult
    public func setLevel(_ name: String) -> Bool {
        guard let level = Level(rawValue: name) else { return false }
        lock.lock()
        defer { lock.unlock() }
        minimum = level
        return true
    }

    public func log(_ level: Level, logger: String, data: JSONValue) {
        lock.lock()
        let (sink, minimum) = (self.sink, self.minimum)
        lock.unlock()
        guard let sink, level.severity >= minimum.severity else { return }
        notify(
            sink,
            method: "notifications/message",
            params: .object([
                "level": .string(level.rawValue),
                "logger": .string(logger),
                "data": data,
            ]))
    }

    private func notify(
        _ sink: @Sendable (String) -> Void, method: String, params: JSONValue
    ) {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
        ])
        guard let line = try? message.serialized() else { return }
        sink(line)
    }
}
