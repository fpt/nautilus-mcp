import Foundation

/// How an agent observes the world around the user.
///
/// The three operations are deliberately abstract, because the useful shape is
/// the same whatever the sensor:
///
/// | | macOS (screen) | iOS (camera) |
/// |---|---|---|
/// | ``overview()`` | list open windows | describe the scene |
/// | ``find(_:)`` | match a window by keywords | locate an object |
/// | ``read(_:)`` | OCR a window | OCR what the camera sees |
///
/// The model-facing names and descriptions come from ``descriptions`` rather
/// than being fixed here: "list_windows" is wrong wording for a camera, and a
/// model given accurate tool names uses them far more reliably.
public protocol EnvironmentPerception: Sendable {

    /// What to call these operations when offering them to a model.
    var descriptions: PerceptionDescriptions { get }

    /// A broad look at the environment — the first thing to reach for.
    func overview() async throws -> String

    /// Narrow the environment down by keywords.
    func find(_ keywords: String) async throws -> String

    /// Read text out of one part of the environment. Usually the most expensive
    /// call and the most likely to overrun a context window, so implementations
    /// should cap what they return (see ``PerceptionLimits/maxResultChars``).
    func read(_ target: String) async throws -> String
}

/// Model-facing naming for an ``EnvironmentPerception``.
public struct PerceptionDescriptions: Sendable {
    public let overviewName: String
    public let overviewDescription: String
    public let findName: String
    public let findDescription: String
    public let findArgumentDescription: String
    public let readName: String
    public let readDescription: String
    public let readArgumentDescription: String

    public init(
        overviewName: String,
        overviewDescription: String,
        findName: String,
        findDescription: String,
        findArgumentDescription: String,
        readName: String,
        readDescription: String,
        readArgumentDescription: String
    ) {
        self.overviewName = overviewName
        self.overviewDescription = overviewDescription
        self.findName = findName
        self.findDescription = findDescription
        self.findArgumentDescription = findArgumentDescription
        self.readName = readName
        self.readDescription = readDescription
        self.readArgumentDescription = readArgumentDescription
    }
}

/// Bounds every perception implementation should respect.
public enum PerceptionLimits {

    /// Hard cap on any single tool result, in characters.
    ///
    /// ~4 chars/token puts this near 375 tokens — under 10% of the on-device
    /// model's 4096-token window, which is shared between input and output and
    /// *throws* rather than truncating on overflow. OCR of a screen or a camera
    /// frame runs to tens of thousands of characters and would spend the whole
    /// budget in one call.
    public static let maxResultChars = 1500

    /// Truncate so the returned string is at most ``maxResultChars``, notice
    /// included. Reserving room for the notice matters: appending it after
    /// taking a full-size prefix overshoots the cap on every truncation.
    public static func cap(_ text: String) -> String {
        guard text.count > maxResultChars else { return text }
        let notice = { (kept: Int) in
            "\n… (truncated: \(kept)/\(text.count) chars — narrow the query)"
        }
        let reserve = notice(maxResultChars).count
        let keep = max(0, maxResultChars - reserve)
        return String(text.prefix(keep)) + notice(keep)
    }
}
