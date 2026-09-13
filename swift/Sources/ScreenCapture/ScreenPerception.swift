import AgentCore
import Foundation

/// ``EnvironmentPerception`` over the user's screen — the macOS answer to "what
/// is around the user".
///
/// The iOS counterpart looks through the camera instead. Both satisfy the same
/// three operations, which is what lets the Foundation Models backend be written
/// once: `overview` / `find` / `read` mean "list windows" / "match a window" /
/// "OCR a window" here, and would mean "describe the scene" / "locate an object"
/// / "read visible text" there.
///
/// Everything returns text. Nothing returns an image: the on-device model has a
/// 4096-token window shared between input and output, so a screenshot is not
/// something it can afford. See docs/FOUNDATION_MODELS.md.
@MainActor
public final class ScreenPerception: EnvironmentPerception {

    private let windows = WindowManager()

    public init() {}

    /// Screen wording. A camera implementation supplies its own — a model given
    /// "list_windows" on a phone will not use it well.
    public nonisolated var descriptions: PerceptionDescriptions {
        PerceptionDescriptions(
            overviewName: "list_windows",
            overviewDescription:
                "List the user's currently open windows (app name and title). Use this first to see what they are working on.",
            findName: "find_window",
            findDescription: "Find open windows whose app name or title matches some keywords.",
            findArgumentDescription: "Words to match against window titles and app names",
            readName: "read_window",
            readDescription:
                "Read the visible text of a window by its title or app name, via OCR. Results are truncated, so prefer a specific window.",
            readArgumentDescription: "Title or app name of the window to read"
        )
    }

    /// The user's real windows, system/incognito noise filtered out.
    public func overview() async throws -> String {
        let list = try await windows.listWindows(excludeNoise: true)
        guard !list.isEmpty else { return "No user windows found." }
        let lines = list.map { $0.findWindowDescription }.joined(separator: "\n  ")
        return PerceptionLimits.cap("Open windows (\(list.count)):\n  \(lines)")
    }

    /// Windows whose title or process matches `keywords`.
    public func find(_ keywords: String) async throws -> String {
        let list = try await windows.listWindows()
        let needle = keywords.lowercased()
        let hits = list.filter { $0.findWindowDescription.lowercased().contains(needle) }
        guard !hits.isEmpty else { return "No window matching '\(keywords)'." }
        let lines = hits.map { $0.findWindowDescription }.joined(separator: "\n  ")
        return PerceptionLimits.cap("Matching windows (\(hits.count)):\n  \(lines)")
    }

    /// Text read off a window via OCR. Capped hard — this is the call most
    /// likely to overrun the context window.
    public func read(_ target: String) async throws -> String {
        let (image, info) = try await windows.captureByTitle(target)
        let entries = try performOCR(on: image)
        let text = formatOCRResults(entries)
        guard !text.isEmpty else { return "No text found in '\(info.title ?? target)'." }
        return PerceptionLimits.cap("Text in '\(info.title ?? target)':\n\(text)")
    }
}
