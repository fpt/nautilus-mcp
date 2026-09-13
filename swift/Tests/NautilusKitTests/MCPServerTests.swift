import XCTest

@testable import NautilusKit

/// A tool with no side effects, so the protocol can be exercised without a
/// screen or a device.
private final class EchoTool: MCPTool {
    let name = "echo"
    let description = "echoes"
    var inputSchema: JSONValue {
        .objectSchema(properties: ["text": .property("string", "what to echo")], required: ["text"])
    }
    var shouldFail = false

    func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        if shouldFail { throw ToolFailure("deliberate failure") }
        return MCPToolResult(text: try arguments.string("text"))
    }
}

@MainActor
final class MCPServerTests: XCTestCase {
    private func makeServer(_ tool: MCPTool = EchoTool()) -> MCPServer {
        MCPServer(name: "test", version: "0.0.0", tools: [tool])
    }

    private func send(_ server: MCPServer, _ json: String) async -> JSONValue? {
        guard let line = await server.handle(line: json) else { return nil }
        return try? JSONValue.parse(line)
    }

    func testInitializeAnnouncesProtocolAndTools() async {
        let r = await send(makeServer(), #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertEqual(r?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
        XCTAssertNotNil(r?["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(r?["id"]?.intValue, 1)
    }

    /// A client that asks for a revision we speak must be answered in that
    /// revision. Replying with a fixed version regardless is legal but
    /// unfriendly, and a client is entitled to give up on it — codex asks for
    /// 2025-06-18.
    func testInitializeEchoesARevisionWeSpeak() async {
        for requested in MCPServer.supportedVersions {
            let r = await send(
                makeServer(),
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)"}}"#
            )
            XCTAssertEqual(
                r?["result"]?["protocolVersion"]?.stringValue, requested,
                "asked for \(requested)")
        }
    }

    /// An unknown revision gets ours back, so the client can decide.
    func testInitializeOffersOursForAnUnknownRevision() async {
        let r = await send(
            makeServer(),
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
        )
        XCTAssertEqual(
            r?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
    }

    func testNegotiationIsPureAndTotal() {
        XCTAssertEqual(MCPServer.negotiate(nil), MCPServer.protocolVersion)
        XCTAssertEqual(MCPServer.negotiate(""), MCPServer.protocolVersion)
        XCTAssertEqual(MCPServer.negotiate("2024-11-05"), "2024-11-05")
        XCTAssertTrue(MCPServer.supportedVersions.contains(MCPServer.protocolVersion))
    }

    /// A notification has no id and must draw no response at all — answering one
    /// is a protocol violation that some clients treat as fatal.
    func testNotificationsAreNotAnswered() async {
        let server = makeServer()
        let initialized = await server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized)
        // Nor is an unknown notification an error.
        let unknown = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/x"}"#)
        XCTAssertNil(unknown)
    }

    func testToolsListCarriesTheSchema() async {
        let r = await send(makeServer(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools)? = r?["result"]?["tools"] else {
            return XCTFail("no tools array")
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"]?.stringValue, "echo")
        XCTAssertEqual(tools[0]["inputSchema"]?["type"]?.stringValue, "object")
    }

    func testToolCallReturnsTextContent() async {
        let r = await send(
            makeServer(),
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#
        )
        XCTAssertEqual(r?["result"]?["isError"]?.boolValue, false)
        guard case .array(let content)? = r?["result"]?["content"] else {
            return XCTFail("no content")
        }
        XCTAssertEqual(content.first?["type"]?.stringValue, "text")
        XCTAssertEqual(content.first?["text"]?.stringValue, "hi")
    }

    /// A tool that ran and failed is a *result* with isError, not a JSON-RPC
    /// error: the model has to be able to read the message and try again.
    func testToolFailureIsAResultNotAProtocolError() async {
        let tool = EchoTool()
        tool.shouldFail = true
        let r = await send(
            makeServer(tool),
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#
        )
        XCTAssertNil(r?["error"], "a failing tool must not be a protocol error")
        XCTAssertEqual(r?["result"]?["isError"]?.boolValue, true)
        let text = r?["result"]?["content"]?.arrayFirstText ?? ""
        XCTAssertTrue(text.contains("deliberate failure"), "got \(text)")
    }

    /// Naming a tool that does not exist *is* a protocol error, and MCP spells
    /// it -32602. The message names the alternatives so a caller can recover.
    func testUnknownToolIsInvalidParams() async {
        let r = await send(
            makeServer(),
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ghost"}}"#)
        XCTAssertEqual(r?["error"]?["code"]?.intValue, -32602)
        XCTAssertTrue(r?["error"]?["message"]?.stringValue?.contains("echo") == true)
    }

    func testUnknownMethodIsMethodNotFound() async {
        let r = await send(makeServer(), #"{"jsonrpc":"2.0","id":6,"method":"no/such"}"#)
        XCTAssertEqual(r?["error"]?["code"]?.intValue, -32601)
    }

    func testMalformedInputIsAParseError() async {
        let r = await send(makeServer(), "{not json")
        XCTAssertEqual(r?["error"]?["code"]?.intValue, -32700)
    }

    func testBlankLinesAreIgnored() async {
        let response = await makeServer().handle(line: "   ")
        XCTAssertNil(response)
    }

    /// A duplicate name would otherwise shadow silently.
    func testDuplicateToolNamesKeepTheFirst() {
        let server = MCPServer(name: "t", version: "0", tools: [EchoTool(), EchoTool()])
        XCTAssertEqual(server.toolNames, ["echo"])
    }
}

final class JSONValueTests: XCTestCase {
    /// An id that arrived as an integer must go back as one: a client matching
    /// responses by exact value never sees `1.0` as the `1` it sent.
    func testWholeNumbersEncodeWithoutADecimalPoint() throws {
        XCTAssertEqual(try JSONValue.number(1).serialized(), "1")
        XCTAssertEqual(try JSONValue.number(-42).serialized(), "-42")
        XCTAssertEqual(try JSONValue.number(1.5).serialized(), "1.5")
    }

    func testRoundTripPreservesShape() throws {
        let original = #"{"a":[1,"two",null,true],"b":{"c":2.5}}"#
        let parsed = try JSONValue.parse(original)
        XCTAssertEqual(parsed["a"]?.arrayCount, 4)
        XCTAssertEqual(parsed["b"]?["c"]?.doubleValue, 2.5)
        XCTAssertEqual(try JSONValue.parse(parsed.serialized()), parsed)
    }

    /// String ids are legal in JSON-RPC and must survive too.
    func testStringIdsSurvive() throws {
        XCTAssertEqual(try JSONValue.parse(#""abc""#).stringValue, "abc")
    }
}

// MARK: - Test helpers

extension JSONValue {
    fileprivate var arrayCount: Int? {
        if case .array(let a) = self { return a.count }
        return nil
    }
    fileprivate var arrayFirstText: String? {
        if case .array(let a) = self { return a.first?["text"]?.stringValue }
        return nil
    }
}

/// A Mac without Apple Intelligence, or with no device attached, must advertise
/// fewer tools — never a tool that is present but always fails.
@MainActor
final class AbsentCapabilityTests: XCTestCase {
    func testAbsentCapabilitiesDoNotAppearInTheList() {
        let present: MCPTool? = EchoTool()
        let absent: MCPTool? = nil
        let server = MCPServer(
            name: "t", version: "0", optionalTools: [present, absent, absent])
        XCTAssertEqual(server.toolNames, ["echo"])
    }

    func testEveryCapabilityAbsentIsAnEmptyButValidServer() async {
        let server = MCPServer(name: "t", version: "0", optionalTools: [nil, nil])
        XCTAssertEqual(server.toolNames, [])
        // It must still complete a handshake: a client should see an honest
        // empty tool list, not a dead server.
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let parsed = try? JSONValue.parse(line ?? "")
        guard case .array(let tools)? = parsed?["result"]?["tools"] else {
            return XCTFail("tools/list must still answer")
        }
        XCTAssertTrue(tools.isEmpty)
    }
}
