import Foundation

/// Perceiving the current screen, as one call.
///
/// The primitives underneath are still there — `android_observe` then
/// `image_ocr` does the same work. But making a caller perform that pair every
/// time turns "what does the screen say?" into bookkeeping, and bookkeeping is
/// what gets skipped: reading a frame captured before the last tap returns
/// numbers that look right and describe a world that no longer exists.
///
/// So the split is: **acting on the world is a primitive, perceiving it is an
/// atomic query.** These capture first, always, and cannot be stale.
///
/// This is not a per-app composite — nothing here knows what a march or a
/// resource node is. It is the same perception the primitives offer, with the
/// capture folded in.
@MainActor
private func captureFresh(observe: MCPTool, frames: FrameStore) async throws -> Frame {
    _ = try await observe.call([:])
    guard let frame = frames.latestCapture else {
        throw ToolFailure("the device did not return a frame")
    }
    return frame
}

// MARK: - android_read_text

/// Capture the device screen and read the text on it, in one step.
@MainActor
public final class AndroidReadTextTool: MCPTool {
    private let observe: MCPTool
    private let frames: FrameStore

    public init(observe: MCPTool, frames: FrameStore) {
        self.observe = observe
        self.frames = frames
    }

    public var name: String { "android_read_text" }
    public var description: String {
        "Read the text currently on the Android screen. Captures a fresh screenshot first, so "
            + "the result always describes the screen as it is now — prefer this to "
            + "android_observe followed by image_ocr, which reads whatever was captured last and "
            + "will silently describe the screen from before your last tap. Boxes come back in "
            + "whole-frame 0.0-1.0 coordinates, ready for android_tap. Narrow with `region` when "
            + "you know roughly where to look: it is faster and much more accurate."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "region": NormRect.schema,
            "languages": .object([
                "type": .string("array"),
                "description": .string("Language hints, e.g. [\"en-US\",\"ja\"]. Default both."),
                "items": .object(["type": .string("string")]),
            ]),
            "min_confidence": .numberProperty(
                "Drop results below this confidence (default 0).", minimum: 0, maximum: 1),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let frame = try await captureFresh(observe: observe, frames: frames)
        let area = NormRect.from(arguments["region"])
        let items = try TextReader.read(
            frame: frame, area: area,
            languages: TextReader.languages(from: arguments),
            floor: arguments["min_confidence"]?.doubleValue ?? 0)

        guard !items.isEmpty else {
            return MCPToolResult(
                text: try JSONValue.object([
                    "frame_id": .string(frame.id),
                    "items": .array([]),
                    "note": .string(
                        "No text found"
                            + (area == nil ? " on screen." : " in that region.")),
                ]).serialized())
        }
        return MCPToolResult(
            text: try JSONValue.object([
                "frame_id": .string(frame.id),
                "items": .array(items),
            ]).serialized())
    }
}

// MARK: - android_look_for

/// Capture the device screen and locate a learned element on it, in one step.
@MainActor
public final class AndroidLookForTool: MCPTool {
    private let observe: MCPTool
    private let frames: FrameStore
    private let prototypes: PrototypeStore

    public init(observe: MCPTool, frames: FrameStore, prototypes: PrototypeStore) {
        self.observe = observe
        self.frames = frames
        self.prototypes = prototypes
    }

    public var name: String { "android_look_for" }
    public var description: String {
        "Find a previously learned UI element on the Android screen right now. Captures a fresh "
            + "screenshot first, so it cannot report where something used to be. Returns the "
            + "centre ready for android_tap. Judge the result by `margin` over the runner-up more "
            + "than by `score`: a solid match sits around 0.3-0.5 while unrelated things sit near "
            + "0.1. If it is not found, the element may simply not be on this screen, or it may "
            + "look different in this state — check with android_read_text."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "prototype": .property("string", "Prototype id, e.g. farlight_cod/march_button."),
                "region": NormRect.schema,
                "min_score": .numberProperty(
                    "Report nothing below this (default 0.25).", minimum: 0, maximum: 1),
                "scale_range": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Widen the size sweep as [low, high] multipliers of the taught size "
                            + "(default [0.6, 1.6]); raise it for a map sprite at unknown zoom."),
                    "items": .object(["type": .string("number")]),
                ]),
            ],
            required: ["prototype"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let name = try arguments.string("prototype")
        let prototype = try prototypes.load(name)
        let frame = try await captureFresh(observe: observe, frames: frames)

        let area = NormRect.from(arguments["region"]) ?? prototype.searchPrior?.rect ?? .full
        let floor = arguments["min_score"]?.doubleValue ?? 0.25
        var scaleRange: (low: Double, high: Double)?
        if case .array(let bounds)? = arguments["scale_range"], bounds.count == 2,
            let low = bounds[0].doubleValue, let high = bounds[1].doubleValue,
            low > 0, high >= low
        {
            scaleRange = (low, high)
        }

        let matches = try VisualMatcher.find(
            prototype: prototype, frame: frame, searchArea: area.clamped(), limit: 3,
            scaleRange: scaleRange)
        let accepted = matches.filter { $0.score >= floor }

        guard let best = accepted.first else {
            return MCPToolResult(
                text: try JSONValue.object([
                    "prototype": .string(name),
                    "frame_id": .string(frame.id),
                    "found": .bool(false),
                    "best_score": .number(
                        ((matches.first?.score ?? 0) * 1000).rounded() / 1000),
                    "note": .string(
                        "Not on this screen above \(String(format: "%.2f", floor)), or it looks "
                            + "different in this state. Some controls change appearance with "
                            + "state; if it is visibly there, visual_learn it again to teach the "
                            + "new look."),
                ]).serialized())
        }
        let margin = accepted.count > 1 ? best.score - accepted[1].score : best.score
        return MCPToolResult(
            text: try JSONValue.object([
                "prototype": .string(name),
                "frame_id": .string(frame.id),
                "found": .bool(true),
                "score": .number((best.score * 1000).rounded() / 1000),
                "margin": .number((margin * 1000).rounded() / 1000),
                "bbox": best.bbox.json,
                "center": .object([
                    "x": .number((best.bbox.centerX * 10000).rounded() / 10000),
                    "y": .number((best.bbox.centerY * 10000).rounded() / 10000),
                ]),
            ]).serialized())
    }
}
