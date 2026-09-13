import Foundation

/// Model Context Protocol server over line-delimited JSON-RPC 2.0.
///
/// Handles one request at a time. MCP permits pipelining, but every tool here
/// ultimately touches a single shared resource — one screen, one device, one
/// speaker — so serializing is the honest behaviour rather than a limitation to
/// work around.
@MainActor
public final class MCPServer {
    /// The MCP revision this server prefers.
    public static let protocolVersion = "2025-06-18"

    /// Revisions this server will speak, newest first.
    ///
    /// It implements `initialize`, `tools/list` and `tools/call`, which are
    /// compatible across all of these; nothing here depends on a feature that
    /// arrived in a particular revision. So the honest answer to a client
    /// asking for one of them is yes.
    ///
    /// Answering with a fixed version regardless of what was asked is legal but
    /// unfriendly, and a client is entitled to give up on it. Codex requests
    /// 2025-06-18.
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Echo back the client's revision when we speak it, otherwise offer ours
    /// and let the client decide.
    static func negotiate(_ requested: String?) -> String {
        guard let requested, supportedVersions.contains(requested) else { return protocolVersion }
        return requested
    }

    private let serverName: String
    private let serverVersion: String
    private var tools: [String: MCPTool] = [:]
    private var order: [String] = []

    public init(name: String, version: String, tools: [MCPTool]) {
        self.serverName = name
        self.serverVersion = version
        for tool in tools {
            // A duplicate name would otherwise shadow silently and the caller
            // would never learn which implementation it reached.
            guard self.tools[tool.name] == nil else {
                FileHandle.standardError.write(
                    Data("nautilus-mcp: duplicate tool \(tool.name), keeping the first\n".utf8))
                continue
            }
            self.tools[tool.name] = tool
            self.order.append(tool.name)
        }
    }

    /// Build from a list that may contain absent capabilities.
    ///
    /// A capability this Mac does not have — no Apple Intelligence, no attached
    /// Android device — must not appear in `tools/list` at all. Advertising a
    /// tool that always fails is worse than omitting it: a model reads the list
    /// as what the machine can do, and will keep choosing a tool that is there.
    public convenience init(name: String, version: String, optionalTools: [MCPTool?]) {
        self.init(name: name, version: version, tools: optionalTools.compactMap { $0 })
    }

    public var toolNames: [String] { order }

    /// Handle one line of input. Returns the line to write back, or `nil` for a
    /// notification (which by JSON-RPC takes no response).
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let message: JSONValue
        do {
            message = try JSONValue.parse(trimmed)
        } catch {
            return Self.errorLine(id: .null, code: -32700, message: "parse error: \(error)")
        }

        guard let method = message["method"]?.stringValue else {
            return Self.errorLine(id: message["id"] ?? .null, code: -32600, message: "no method")
        }
        // Absent id means notification: act on it, answer nothing.
        let id = message["id"]
        let params = message["params"]?.objectValue ?? [:]

        do {
            guard let result = try await dispatch(method: method, params: params) else {
                return nil  // a notification we recognise and do not answer
            }
            guard let id else { return nil }
            return Self.line(["jsonrpc": .string("2.0"), "id": id, "result": result])
        } catch let failure as ProtocolFailure {
            return Self.errorLine(id: id ?? .null, code: failure.code, message: failure.message)
        } catch let failure as ToolFailure {
            return Self.errorLine(id: id ?? .null, code: -32603, message: failure.message)
        } catch {
            return Self.errorLine(id: id ?? .null, code: -32603, message: Self.explain(error))
        }
    }

    /// Returns the result, or `nil` when the method is a notification.
    private func dispatch(method: String, params: [String: JSONValue]) async throws -> JSONValue? {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string(
                    Self.negotiate(params["protocolVersion"]?.stringValue)),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string(serverName), "version": .string(serverVersion),
                ]),
            ])

        // Notifications: no response, and an unknown one must not be an error.
        case let m where m.hasPrefix("notifications/"):
            return nil

        case "ping":
            return .object([:])

        case "tools/list":
            return .object([
                "tools": .array(
                    order.compactMap { name in
                        guard let tool = tools[name] else { return nil }
                        return .object([
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "inputSchema": tool.inputSchema,
                        ])
                    })
            ])

        case "tools/call":
            return try await callTool(params: params)

        default:
            throw ProtocolFailure(code: -32601, "Method not found: \(method)")
        }
    }

    private func callTool(params: [String: JSONValue]) async throws -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            throw ProtocolFailure(code: -32602, "tools/call needs a `name`")
        }
        guard let tool = tools[name] else {
            // Name what exists: a caller that guessed wrong can recover from
            // that, but not from a bare "unknown tool".
            throw ProtocolFailure(
                code: -32602,
                "Unknown tool: \(name). Available: \(order.joined(separator: ", "))")
        }
        let arguments = params["arguments"]?.objectValue ?? [:]

        do {
            let result = try await tool.call(arguments)
            var content: [JSONValue] = []
            if !result.text.isEmpty {
                content.append(.object(["type": .string("text"), "text": .string(result.text)]))
            }
            for image in result.images {
                content.append(
                    .object([
                        "type": .string("image"),
                        "data": .string(image.base64),
                        "mimeType": .string(image.mimeType),
                    ]))
            }
            return .object(["content": .array(content), "isError": .bool(false)])
        } catch {
            // A tool that fails is a *result*, not a protocol error: MCP wants
            // the model to see the message and try something else, which a
            // JSON-RPC error would deny it.
            let message = Self.explain(error)
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("\(name) failed: \(message)")])
                ]),
                "isError": .bool(true),
            ])
        }
    }

    /// The message a caller should actually read.
    ///
    /// `"\(error)"` prints an enum's case name and associated values —
    /// `staleElement(id: "e1", observedEpoch: 5, currentEpoch: 0)` — which
    /// throws away a carefully written explanation of what to do next. Anything
    /// conforming to `LocalizedError` has said what it wants said.
    static func explain(_ error: Error) -> String {
        if let failure = error as? ToolFailure { return failure.message }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    // MARK: - Wire helpers

    private static func line(_ object: [String: JSONValue]) -> String {
        (try? JSONValue.object(object).serialized())
            ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#
    }

    private static func errorLine(id: JSONValue, code: Int, message: String) -> String {
        line([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }
}
