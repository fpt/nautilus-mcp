import CoreGraphics
import Foundation
import NautilusBridge

/// One Android primitive, forwarded to the Rust core.
///
/// The Rust side owns the tool list and their schemas, so adding an Android
/// primitive there makes it appear here with no Swift change at all — this
/// class is the whole binding.
///
/// The one thing it adds is frame capture: any Android tool that returns an
/// image gets that image registered in the [`FrameStore`] and its id appended
/// to the text. That is what lets `android_observe` be followed by `image_ocr`
/// without sending the screenshot back across the protocol.
@MainActor
public final class AndroidTool: MCPTool {
    private let controller: AndroidController
    private let spec: ToolSpec
    private let schema: JSONValue
    private let store: FrameStore?

    public var name: String { spec.name }
    public var description: String { spec.description }
    public var inputSchema: JSONValue { schema }

    init(controller: AndroidController, spec: ToolSpec, store: FrameStore?) {
        self.controller = controller
        self.spec = spec
        self.store = store
        // Rust renders the schema as JSON. If it ever fails to parse, advertise
        // an empty object rather than dropping the tool: a tool that takes no
        // arguments is still usable, a missing one is not.
        self.schema = (try? JSONValue.parse(spec.inputSchema)) ?? .objectSchema(properties: [:])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let argsJson = try JSONValue.object(arguments).serialized()
        let output = try controller.call(name: spec.name, argsJson: argsJson)

        var text = output.text
        let images = output.images.map { MCPImage(base64: $0.base64, mimeType: $0.mediaType) }

        if let store, let first = output.images.first,
            let decoded = ImageCoding.decode(base64: first.base64)
        {
            let frame = store.register(image: decoded, source: "android")
            text += " frame_id=\(frame.id) — crop, OCR or diff it without re-capturing."
        }
        return MCPToolResult(text: text, images: images)
    }
}

/// Tap the centre of a region found by `image_regions`.
///
/// Thin sugar over `android_tap`, not a new capability: it converts the
/// region's centre to normalized coordinates and calls the same primitive. It
/// exists because transcribing four floats from a region listing into a tap is
/// exactly the step where a digit gets dropped.
@MainActor
public final class AndroidTapRegionTool: MCPTool {
    private let controller: AndroidController
    private let store: FrameStore

    public init(controller: AndroidController, store: FrameStore) {
        self.controller = controller
        self.store = store
    }

    public var name: String { "android_tap_region" }
    public var description: String {
        "Tap the centre of a region on the Android screen, naming it by the id image_regions gave "
            + "it, or by an explicit box. Equivalent to computing the centre yourself and calling "
            + "android_tap. Like any tap it claims nothing: observe again to see what happened."
    }
    public var inputSchema: JSONValue {
        .objectSchema(properties: [
            "frame_id": FrameArgs.frameIdProperty,
            "region_id": .property("string", "A region id from image_regions on that frame."),
            "region": NormRect.schema,
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let (frame, area) = try FrameArgs.resolve(arguments, in: store)
        guard let target = area else {
            throw ToolFailure("android_tap_region needs a `region_id` or `region`")
        }
        // A region on a crop is already stored in root coordinates, and Android
        // input is normalized against that same root frame — so the centre goes
        // straight through with no conversion.
        guard frame.source == "android" else {
            throw ToolFailure(
                "frame \(frame.id) came from \(frame.source), not the Android device")
        }
        let centre = NormRect(
            x1: target.centerX, y1: target.centerY, x2: target.centerX, y2: target.centerY)
        let args = try JSONValue.object([
            "x": .number(centre.x1), "y": .number(centre.y1),
        ]).serialized()
        let output = try controller.call(name: "android_tap", argsJson: args)
        return MCPToolResult(text: output.text)
    }
}

/// Bind an Android device and wrap every primitive it offers.
///
/// Throws when no usable device is attached, so start-up can report the cause
/// once instead of every call failing later.
@MainActor
public func makeAndroidTools(serial: String?, store: FrameStore) throws -> [MCPTool] {
    let controller = try AndroidController(serial: serial)
    var tools: [MCPTool] = controller.tools().map {
        AndroidTool(controller: controller, spec: $0, store: store)
    }
    tools.append(AndroidTapRegionTool(controller: controller, store: store))
    return tools
}
