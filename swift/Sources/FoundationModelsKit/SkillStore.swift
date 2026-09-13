import AgentCore
import Foundation

/// Skills the model can look up, for the in-process backend.
///
/// The other two backends each hold their own: gallium registers them from
/// `skillPaths` and serves `LookupSkill`; codex takes `skills/extraRoots/set`
/// and renders a body when one is mentioned. This is the equivalent for the
/// on-device path, which has no separate process to keep them in.
///
/// Bodies live here rather than in the session instructions on purpose. The
/// window is 4096 tokens shared between input and output, and our two skills
/// cost ~866 tokens inlined against ~101 for their names and descriptions. The
/// catalog goes in the instructions so the model knows they exist; the body
/// comes from here when it asks.
public final class SkillStore: @unchecked Sendable {

    struct Skill {
        let name: String
        let description: String
        let body: String
    }

    private let lock = NSLock()
    private var skills: [Skill] = []

    public init() {}

    public func add(name: String, description: String, body: String) {
        lock.lock()
        defer { lock.unlock() }
        // Last writer wins, matching gallium's registry — and "same name" has to
        // mean what `get` means by it. Matching exactly here while looking up
        // case-insensitively would let "Desk-Activity" register alongside
        // "desk-activity" and leave `get` returning the older body.
        let key = Self.key(name)
        skills.removeAll { Self.key($0.name) == key }
        skills.append(Skill(name: name, description: description, body: body))
    }

    /// The one definition of "the same skill", used by both `add` and `get`.
    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        skills.removeAll()
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return skills.isEmpty
    }

    /// Names and descriptions, one per line — what goes in the instructions.
    public func catalog() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return skills
            .sorted { $0.name < $1.name }
            .map { "- \($0.name): \($0.description)" }
    }

    /// The same lines the catalog holds, for the lookup tool's `list`.
    func list() -> String {
        let entries = catalog()
        guard !entries.isEmpty else { return "No skills registered." }
        return entries.joined(separator: "\n")
    }

    /// One skill's full instructions.
    ///
    /// A miss names what *is* there. A model that guessed the name otherwise
    /// learns nothing from the failure and tends to guess again.
    func get(_ name: String) -> String {
        let wanted = Self.key(name)
        let match = lock.withLock {
            skills.first { Self.key($0.name) == wanted }
        }
        guard let match else {
            let known = catalog()
            return known.isEmpty
                ? "No skill named '\(name)'. No skills are registered."
                : "No skill named '\(name)'. Available:\n\(known.joined(separator: "\n"))"
        }
        return PerceptionLimits.cap("## \(match.name) — \(match.description)\n\(match.body)")
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
