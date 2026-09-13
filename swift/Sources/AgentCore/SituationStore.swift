import Foundation

/// Ambient observations the frontend pushes between turns, readable by the agent
/// on demand.
///
/// The Swift twin of Rust's `SituationMessages`, kept deliberately in step with
/// it so both backends behave the same way: same time window, same count cap,
/// same "the model reads this when it wants it" access. The app-server path uses
/// the Rust store; the in-process Foundation Models path uses this one.
///
/// Both bounds matter. Time alone does not bound the store — a producer polling
/// every 30 seconds against a 10-minute window keeps twenty entries alive, all
/// of which the agent then reads. Producers should also skip unchanged
/// observations (the window-list poller dedupes), but the cap means a chatty one
/// degrades the context budget rather than destroying it.
public final class SituationStore: @unchecked Sendable {

    /// Matches `situation.rs`'s default TTL.
    public static let defaultTTL: TimeInterval = 600

    /// Matches `situation::DEFAULT_MAX_MESSAGES`.
    public static let defaultMaxMessages = 20

    struct Entry {
        let text: String
        let source: String
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let ttl: TimeInterval
    private let maxMessages: Int

    public init(
        ttl: TimeInterval = SituationStore.defaultTTL,
        maxMessages: Int = SituationStore.defaultMaxMessages
    ) {
        self.ttl = ttl
        self.maxMessages = max(1, maxMessages)
    }

    public func push(text: String, source: String) {
        lock.lock()
        defer { lock.unlock() }
        prune()
        entries.append(Entry(text: text, source: source, at: Date()))
        if entries.count > maxMessages {
            entries.removeFirst(entries.count - maxMessages)
        }
    }

    /// Non-expired observations, oldest first.
    public func read() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return entries.map { "[\($0.source)] \($0.text)" }
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return entries.count
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Caller must hold `lock`.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries.removeAll { $0.at < cutoff }
    }
}
