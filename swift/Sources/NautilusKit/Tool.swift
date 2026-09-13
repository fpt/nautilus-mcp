import Foundation

/// An image a tool produced, ready for MCP's `image` content block.
public struct MCPImage {
    public let base64: String
    public let mimeType: String

    public init(base64: String, mimeType: String = "image/png") {
        self.base64 = base64
        self.mimeType = mimeType
    }
}

/// What a tool call produced.
public struct MCPToolResult {
    public var text: String
    public var images: [MCPImage]

    public init(text: String, images: [MCPImage] = []) {
        self.text = text
        self.images = images
    }
}

/// A tool the MCP server advertises and can invoke.
///
/// Not `Sendable` on purpose: the server runs on the `MainActor` (macOS screen
/// capture requires it), so tools are only ever touched from there.
public protocol MCPTool: AnyObject {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments object.
    var inputSchema: JSONValue { get }

    func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult
}

/// A JSON-RPC protocol error — malformed or unanswerable *as a request*.
///
/// Distinct from ``ToolFailure`` on purpose. MCP draws the line between a tool
/// that ran and failed (reported in the result, so the model can read it and
/// try something else) and a request that was never valid (an error object).
/// Naming a tool that does not exist is the latter.
public struct ProtocolFailure: LocalizedError {
    public let code: Int
    public let message: String
    public init(code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// A tool failure with a message meant to be read by a model.
public struct ToolFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Argument helpers

extension [String: JSONValue] {
    func string(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue else {
            throw ToolFailure("missing string `\(key)`")
        }
        return v
    }

    func optionalString(_ key: String) -> String? { self[key]?.stringValue }

    func double(_ key: String) throws -> Double {
        guard let v = self[key]?.doubleValue else {
            throw ToolFailure("missing number `\(key)`")
        }
        return v
    }

    func optionalInt(_ key: String) -> Int? { self[key]?.intValue }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        self[key]?.boolValue ?? fallback
    }
}

// MARK: - Schema helpers

extension JSONValue {
    /// `{"type":"object","properties":{…},"required":[…]}`
    public static func objectSchema(
        properties: [String: JSONValue], required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    public static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    public static func numberProperty(
        _ description: String, minimum: Double? = nil, maximum: Double? = nil
    ) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": .string("number"), "description": .string(description),
        ]
        if let minimum { o["minimum"] = .number(minimum) }
        if let maximum { o["maximum"] = .number(maximum) }
        return .object(o)
    }
}
