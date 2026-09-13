import CoreGraphics
import Foundation
import ScreenCapture

/// How a screen tool names the window it should act on.
///
/// All three screen tools take the same target, so a caller that found a window
/// with `macos_list_windows` can pass its id to any of them unchanged.
private struct WindowTarget {
    static let schemaProperties: [String: JSONValue] = [
        "window_id": .property(
            "integer", "Window id from macos_list_windows. The most reliable target."),
        "title": .property("string", "Substring of the window title, if no id is known."),
        "app": .property("string", "Application name, if no id or title is known."),
        "crop": .object([
            "type": .string("object"),
            "description": .string(
                "Optional sub-region in normalized 0.0-1.0 coordinates of the window."),
            "properties": .object([
                "x": .numberProperty("Left edge.", minimum: 0, maximum: 1),
                "y": .numberProperty("Top edge.", minimum: 0, maximum: 1),
                "w": .numberProperty("Width.", minimum: 0, maximum: 1),
                "h": .numberProperty("Height.", minimum: 0, maximum: 1),
            ]),
            "required": .array([.string("x"), .string("y"), .string("w"), .string("h")]),
        ]),
    ]

    let windowID: UInt32?
    let title: String?
    let app: String?
    let crop: (x: Double, y: Double, w: Double, h: Double)?

    init(_ args: [String: JSONValue]) {
        windowID = args.optionalInt("window_id").map(UInt32.init)
        title = args.optionalString("title")
        app = args.optionalString("app")
        if let c = args["crop"]?.objectValue,
            let x = c["x"]?.doubleValue, let y = c["y"]?.doubleValue,
            let w = c["w"]?.doubleValue, let h = c["h"]?.doubleValue
        {
            crop = (x, y, w, h)
        } else {
            crop = nil
        }
    }

    @MainActor
    func resolve(_ manager: WindowManager) async throws -> (CGImage, WindowInfo) {
        var captured: (CGImage, WindowInfo)
        if let windowID {
            captured = try await manager.captureWindow(windowId: windowID)
        } else if let title {
            captured = try await manager.captureByTitle(title)
        } else if let app {
            captured = try await manager.captureByProcess(app)
        } else {
            throw ToolFailure(
                "name a window: pass window_id (from macos_list_windows), title, or app")
        }
        if let crop {
            guard
                let cropped = WindowManager.cropCGImage(
                    captured.0, x: crop.x, y: crop.y, w: crop.w, h: crop.h)
            else {
                throw ToolFailure("crop region is outside the window")
            }
            captured.0 = cropped
        }
        return captured
    }
}

// MARK: - macos_list_windows

@MainActor
public final class ListWindowsTool: MCPTool {
    private let manager: WindowManager
    public init(manager: WindowManager) { self.manager = manager }

    public nonisolated var name: String { "macos_list_windows" }
    public nonisolated var description: String {
        "List the windows currently open on the Mac, with the window id, title, app and size of "
            + "each. Start here when you need to act on a window: the id it returns is the most "
            + "reliable way to name one for the other macos_ tools."
    }
    public nonisolated var inputSchema: JSONValue {
        .objectSchema(properties: [
            "exclude_noise": .property(
                "boolean",
                "Drop tiny and system windows that are rarely what you want (default true).")
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let windows = try await manager.listWindows(
            excludeNoise: arguments.bool("exclude_noise", default: true))
        guard !windows.isEmpty else {
            return MCPToolResult(text: "No windows found.")
        }
        let lines = windows.map { $0.findWindowDescription }.joined(separator: "\n")
        return MCPToolResult(text: "\(windows.count) window(s):\n\(lines)")
    }
}

// MARK: - macos_capture_window

@MainActor
public final class CaptureWindowTool: MCPTool {
    private let manager: WindowManager
    private let store: FrameStore
    public init(manager: WindowManager, store: FrameStore) {
        self.manager = manager
        self.store = store
    }

    public nonisolated var name: String { "macos_capture_window" }
    public nonisolated var description: String {
        "Screenshot one window on the Mac and return it as an image. Optionally crop to a "
            + "sub-region first, which is the cheaper way to inspect a detail than sending the "
            + "whole window."
    }
    public nonisolated var inputSchema: JSONValue {
        .objectSchema(properties: WindowTarget.schemaProperties)
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (image, info) = try await WindowTarget(arguments).resolve(manager)
        guard let base64 = ImageCoding.encodeBase64(image) else {
            throw ToolFailure("could not encode the capture as PNG")
        }
        // Registered like an Android observe, so image_crop / image_ocr /
        // image_regions / image_diff work identically on either source.
        let frame = store.register(image: image, source: "macos:\(info.appName ?? "?")")
        return MCPToolResult(
            text: "Captured \(info.summary) — \(image.width)x\(image.height). "
                + "frame_id=\(frame.id) — crop, OCR or diff it without re-capturing.",
            images: [MCPImage(base64: base64)])
    }
}

// MARK: - macos_read_text

@MainActor
public final class ReadTextTool: MCPTool {
    private let manager: WindowManager
    public init(manager: WindowManager) { self.manager = manager }

    public nonisolated var name: String { "macos_read_text" }
    public nonisolated var description: String {
        "Read the text in a Mac window with OCR and return it as text rather than an image. Much "
            + "cheaper than capturing when you only need to know what a window says. Recognizes "
            + "English and Japanese."
    }
    public nonisolated var inputSchema: JSONValue {
        var props = WindowTarget.schemaProperties
        props["grouped"] = .property(
            "boolean", "Group results into lines by position instead of listing each fragment.")
        return .objectSchema(properties: props)
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (image, info) = try await WindowTarget(arguments).resolve(manager)
        let entries = try performOCR(on: image)
        guard !entries.isEmpty else {
            return MCPToolResult(text: "No text recognized in \(info.summary).")
        }
        let body =
            arguments.bool("grouped", default: true)
            ? formatOCRResultsGrouped(entries) : formatOCRResults(entries)
        return MCPToolResult(text: "Text in \(info.summary):\n\(body)")
    }
}

// MARK: - macos_detect_objects

@MainActor
public final class DetectObjectsTool: MCPTool {
    private let manager: WindowManager
    public init(manager: WindowManager) { self.manager = manager }

    public nonisolated var name: String { "macos_detect_objects" }
    public nonisolated var description: String {
        "Run Vision object detection over a Mac window and return what it found with bounding "
            + "boxes. Useful for locating things OCR cannot name; it recognizes general object "
            + "classes, not application-specific UI."
    }
    public nonisolated var inputSchema: JSONValue {
        .objectSchema(properties: WindowTarget.schemaProperties)
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (image, info) = try await WindowTarget(arguments).resolve(manager)
        let objects = try performObjectDetection(on: image)
        guard !objects.isEmpty else {
            return MCPToolResult(text: "No objects detected in \(info.summary).")
        }
        return MCPToolResult(
            text: "Objects in \(info.summary):\n\(formatDetectionResults(objects))")
    }
}
