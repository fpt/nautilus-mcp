import Foundation
import NautilusBridge

/// One Android primitive, forwarded to the Rust core.
///
/// The Rust side owns the tool list and their schemas, so adding an Android
/// primitive there makes it appear here with no Swift change at all — this
/// class is the whole binding.
public final class AndroidTool: MCPTool {
    private let controller: AndroidController
    private let spec: ToolSpec
    private let schema: JSONValue

    public var name: String { spec.name }
    public var description: String { spec.description }
    public var inputSchema: JSONValue { schema }

    init(controller: AndroidController, spec: ToolSpec) {
        self.controller = controller
        self.spec = spec
        // Rust renders the schema as JSON. If it ever fails to parse, advertise
        // an empty object rather than dropping the tool: a tool that takes no
        // arguments is still usable, a missing one is not.
        self.schema = (try? JSONValue.parse(spec.inputSchema)) ?? .objectSchema(properties: [:])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let argsJson = try JSONValue.object(arguments).serialized()
        let output = try controller.call(name: spec.name, argsJson: argsJson)
        return MCPToolResult(
            text: output.text,
            images: output.images.map { MCPImage(base64: $0.base64, mimeType: $0.mediaType) })
    }
}

/// Bind an Android device and wrap every primitive it offers.
///
/// Throws when no usable device is attached, so start-up can report the cause
/// once instead of every call failing later.
public func makeAndroidTools(serial: String?) throws -> [MCPTool] {
    let controller = try AndroidController(serial: serial)
    return controller.tools().map { AndroidTool(controller: controller, spec: $0) }
}
