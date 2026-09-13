import Foundation

/// A minimal Chrome DevTools Protocol client: one websocket, one request at a
/// time, events ignored.
///
/// CDP is a big protocol and almost none of it is needed here. Everything this
/// backend does is `Runtime.evaluate` against the active tab, so the client is
/// a request/response pair over a socket rather than a session manager. Events
/// arrive on the same socket and are skipped while waiting for a reply, which
/// is correct precisely because nothing subscribes to any.
public final class CDPConnection {
    /// A wedged browser must fail the tool call, not hang the server — the same
    /// rule the Android side applies to `adb`.
    public static let timeout: TimeInterval = 15

    private let task: URLSessionWebSocketTask
    private var nextID = 0

    public init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = CDPConnection.timeout
        task = URLSession(configuration: config).webSocketTask(with: url)
        task.resume()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    public func close() { task.cancel(with: .goingAway, reason: nil) }

    /// Send one command and wait for the reply with the matching id.
    @discardableResult
    public func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let body: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))

        return try await withTimeout {
            while true {
                let message = try await self.task.receive()
                guard case .string(let text) = message,
                    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any]
                else { continue }
                // Not our reply: an event, or a response to something else.
                guard (object["id"] as? Int) == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CDPError.command(method, (error["message"] as? String) ?? "\(error)")
                }
                return (object["result"] as? [String: Any]) ?? [:]
            }
        }
    }

    /// Evaluate an expression in the page and return it by value.
    ///
    /// A thrown exception in the page comes back as a `CDPError` rather than as
    /// a nil result, because "the script failed" and "the script returned
    /// nothing" need to read differently to a caller.
    public func evaluate(_ expression: String) async throws -> Any? {
        let result = try await call(
            "Runtime.evaluate",
            [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
                // Some pages freeze timers when a tab is backgrounded; this
                // keeps an evaluate from waiting on one.
                "userGesture": true,
            ])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let text =
                ((details["exception"] as? [String: Any])?["description"] as? String)
                ?? (details["text"] as? String) ?? "\(details)"
            throw CDPError.evaluation(text)
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func withTimeout<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(CDPConnection.timeout * 1_000_000_000))
                throw CDPError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CDPError.timedOut }
            return first
        }
    }
}

// MARK: - Errors

public enum CDPError: LocalizedError {
    case notReachable(port: Int)
    case noPage(port: Int)
    case command(String, String)
    case evaluation(String)
    case timedOut
    case staleElement(id: String, observedEpoch: UInt64, currentEpoch: UInt64)
    case noSuchElement(id: String, known: Int)
    case detached(id: String)

    public var errorDescription: String? {
        switch self {
        case .notReachable(let port):
            return """
                no Chrome is listening for DevTools on 127.0.0.1:\(port). Chrome only opens that \
                port when it is started with --remote-debugging-port, and since Chrome 136 it \
                also refuses to do so for the default profile directory — so it needs its own \
                --user-data-dir as well. Start one with:
                  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                --remote-debugging-port=\(port) --user-data-dir="$HOME/.nautilus-chrome"
                """
        case .noPage(let port):
            return
                "Chrome is listening on \(port) but has no page open to drive (only pages count — "
                + "extensions and service workers are skipped)."
        case .command(let method, let message):
            return "\(method) failed: \(message)"
        case .evaluation(let message):
            return "the page threw while being read: \(message)"
        case .timedOut:
            return
                "Chrome did not answer within \(Int(CDPConnection.timeout))s. The tab may be "
                + "blocked by a modal dialog, or stopped in the debugger."
        case .staleElement(let id, let observed, let current):
            return """
                {"error":"stale_element","element_id":"\(id)",\
                "observed_epoch":\(observed),"current_epoch":\(current),\
                "recovery":"The page has changed since it was read, so this handle may now \
                point at something else. Call browser_observe again and use the fresh ids."}
                """
        case .noSuchElement(let id, let known):
            return "no element \(id); the last observation held \(known). Observe again."
        case .detached(let id):
            return """
                {"error":"stale_element","element_id":"\(id)",\
                "recovery":"That element is no longer in the document — the page re-rendered \
                since it was read. Call browser_observe again and use the fresh ids."}
                """
        }
    }
}
