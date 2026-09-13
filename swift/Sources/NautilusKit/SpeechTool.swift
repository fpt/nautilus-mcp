import Foundation
import TTS

/// Speak text aloud through the Mac's speech synthesizer.
///
/// The only thing kept from the voice stack: nautilus-mcp is headless, but
/// speaking is a macOS framework capability a client may legitimately want, and
/// unlike the microphone it needs no session, no permission prompt and no
/// half-duplex handling.
@MainActor
public final class SayTool: MCPTool {
    private let speech: TextToSpeech

    public init(speech: TextToSpeech) { self.speech = speech }

    public nonisolated var name: String { "say" }
    public nonisolated var description: String {
        "Speak text aloud through the Mac's speakers. Returns once speech has finished, so a "
            + "long passage holds the call open for as long as it takes to say it."
    }
    public nonisolated var inputSchema: JSONValue {
        .objectSchema(
            properties: ["text": .property("string", "What to say.")],
            required: ["text"])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let text = try arguments.string("text")
        guard !text.isEmpty else { throw ToolFailure("text is empty") }
        await speech.speakAsync(text)
        return MCPToolResult(text: "Spoke \(text.count) character(s).")
    }
}
