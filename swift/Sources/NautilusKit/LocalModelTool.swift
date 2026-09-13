import Foundation
import FoundationModelsKit
import ScreenCapture

/// Apple's on-device model, offered as a tool.
///
/// nautilus-mcp runs no agent of its own — but the on-device model *is* a macOS
/// framework, and it is the one capability here that can look at the screen and
/// answer a question about it in one call. It is given ``ScreenPerception``, so
/// it can list windows and read them itself rather than being handed a
/// screenshot.
///
/// Registered only when the model is actually available (Apple silicon, Apple
/// Intelligence enabled); otherwise the tool list stays honest about what the
/// server can do.
public final class LocalModelTool: MCPTool {
    private let backend: FoundationModelsBackend

    public init(backend: FoundationModelsBackend) {
        self.backend = backend
    }

    /// Build the tool, or `nil` when this Mac cannot run the model.
    @MainActor
    public static func make() -> LocalModelTool? {
        do {
            return LocalModelTool(backend: try FoundationModelsBackend.make(
                perception: ScreenPerception()))
        } catch {
            return nil
        }
    }

    public var name: String { "ask_local_model" }
    public var description: String {
        "Ask Apple's on-device model a question, answered entirely on this Mac with nothing sent "
            + "off the device. It can inspect the screen itself to answer, so questions like "
            + "\"what is on screen right now?\" work without capturing first. It is a small model: "
            + "prefer it for quick, local questions rather than hard reasoning."
    }
    public var inputSchema: JSONValue {
        .objectSchema(
            properties: ["prompt": .property("string", "The question to ask.")],
            required: ["prompt"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let prompt = try arguments.string("prompt")
        guard !prompt.isEmpty else { throw ToolFailure("prompt is empty") }
        let response = try await backend.step(prompt)
        return MCPToolResult(text: response.content)
    }
}
