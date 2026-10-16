import XCTest
@testable import OperationSurface

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
    }

    /// true / false を数値として読まない
    func testBoolIsNotNumber() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 0]"#.utf8))
        XCTAssertEqual(v, [true, 1, 0])
    }

    func testStableString() {
        let v: JSONValue = ["b": 1, "a": "x/y"]
        XCTAssertEqual(v.jsonString(), #"{"a":"x/y","b":1}"#)
    }

    func testCodableBridge() throws {
        struct P: Codable, Equatable { var x: Double; var name: String }
        let v = try JSONValue(encoding: P(x: 1.5, name: "n"))
        XCTAssertEqual(v["x"], 1.5)
        XCTAssertEqual(try v.decode(P.self), P(x: 1.5, name: "n"))
    }
}

final class JSONSchemaTests: XCTestCase {
    let schema = JSONSchema.object([
        .init("exposure", .number("露出", minimum: -3, maximum: 3)),
        .init("count", .integer(minimum: 1)),
        .init("mode", .string(oneOf: ["a", "b"])),
        .init("flag", .boolean()),
        .init("tint", JSONSchema.number().orNull()),
        .init("ids", .array(of: .string(), maxItems: 2)),
    ], required: ["exposure"])

    func testValidInput() {
        XCTAssertEqual(schema.validate(["exposure": 0.5, "count": 3, "mode": "a", "flag": true,
                                        "tint": nil, "ids": ["x"]]), [])
    }

    func testErrorsNameThePath() {
        let errors = schema.validate(["count": 1.5, "mode": "c", "flag": 1, "ids": ["x", 2, "z"], "extra": 1])
        let text = errors.joined(separator: "\n")
        XCTAssertTrue(text.contains("$.exposure: 必須"), text)
        XCTAssertTrue(text.contains("$.count: 整数"), text)
        XCTAssertTrue(text.contains("$.mode: \"c\""), text)
        XCTAssertTrue(text.contains("$.flag: boolean が必要"), text)
        XCTAssertTrue(text.contains("$.ids: 要素は 2 個まで"), text)
        XCTAssertTrue(text.contains("$.ids[1]: string が必要"), text)
        XCTAssertTrue(text.contains("$.extra: 未知の項目"), text)
    }

    func testRange() {
        XCTAssertEqual(schema.validate(["exposure": 3]), [])
        XCTAssertEqual(schema.validate(["exposure": 3.5]).count, 1)
        XCTAssertEqual(schema.validate(["exposure": -4]).count, 1)
        XCTAssertEqual(schema.validate(["exposure": nil]).count, 1, "nullable でない項目に null は使えない")
    }

    func testToJSON() {
        let json = schema.toJSON()
        XCTAssertEqual(json["type"], "object")
        XCTAssertEqual(json["required"], ["exposure"])
        XCTAssertEqual(json["additionalProperties"], false)
        XCTAssertEqual(json["properties"]?["exposure"]?["maximum"], 3)
        XCTAssertEqual(json["properties"]?["exposure"]?["description"], "露出")
        XCTAssertEqual(json["properties"]?["tint"]?["type"], ["number", "null"])
        XCTAssertEqual(json["properties"]?["mode"]?["enum"], ["a", "b"])
        XCTAssertEqual(json["properties"]?["ids"]?["items"]?["type"], "string")
    }
}

final class SurfaceTests: XCTestCase {
    /// 値を 1 つ持つだけの小さなソフト
    final class Counter { var value = 0 }

    private let ai = Caller.agent("test-ai")
    private let person = Caller.human("owner")

    private func makeSurface(_ counter: Counter) -> Surface {
        let s = Surface(name: "counter", version: "1")
        s.register(ToolDescriptor(name: "get", title: "読む", description: "値を返す", effect: .read)) { _, _ in
            .json(.number(Double(counter.value)))
        }
        s.register(ToolDescriptor(
            name: "add", title: "足す", description: "値に足す",
            input: .object([.init("amount", .integer(minimum: -100, maximum: 100)),
                            .init("target", .string())], required: ["amount"]),
            effect: .modify)) { args, ctx in
            let before = counter.value
            counter.value += args["amount"]!.intValue!
            ctx.registerUndo("足す", resource: args["target"]?.stringValue ?? "counter") { counter.value = before }
            return .text("\(counter.value)")
        }
        s.register(ToolDescriptor(name: "add_then_fail", title: "足して失敗", description: "途中で失敗する",
                                  effect: .modify)) { _, ctx in
            let before = counter.value
            counter.value += 1
            ctx.registerUndo("1 足す", resource: "counter") { counter.value = before }
            struct Boom: Error {}
            throw Boom()
        }
        s.register(ToolDescriptor(name: "export", title: "書き出す", description: "ファイルを書く",
                                  effect: .writeFiles)) { _, _ in .text("書きました") }
        s.registerStandardTools()
        return s
    }

    func testCallAndAudit() {
        let counter = Counter()
        let s = makeSurface(counter)
        let r = s.call("add", arguments: ["amount": 5], as: ai)
        XCTAssertFalse(r.isError)
        XCTAssertEqual(counter.value, 5)
        let e = s.auditLog.last!
        XCTAssertEqual(e.tool, "add")
        XCTAssertEqual(e.caller, ai)
        XCTAssertEqual(e.outcome, .succeeded)
        XCTAssertEqual(e.effect, .modify)
        XCTAssertTrue(e.undoable)
        XCTAssertEqual(e.sequence, 1)
    }

    func testInvalidArgumentsAreRejectedBeforeRunning() {
        let counter = Counter()
        let s = makeSurface(counter)
        let r = s.call("add", arguments: ["amount": 500], as: ai)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(s.auditLog.last?.outcome, .invalidArguments)
        XCTAssertTrue(r.summary.contains("$.amount"), r.summary)
    }

    func testUnknownTool() {
        let s = makeSurface(Counter())
        let r = s.call("nope", as: ai)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.summary.contains("add"), "使える道具を知らせる")
        XCTAssertEqual(s.auditLog.last?.outcome, .unknownTool)
    }

    /// AI の既定ではファイルを書く道具は確認が要る。確認の手段が無ければ拒否
    func testPolicy() {
        let s = makeSurface(Counter())
        XCTAssertTrue(s.call("export", as: ai).isError)
        XCTAssertEqual(s.auditLog.last?.outcome, .denied)

        var asked: [String] = []
        s.confirm = { _, d, _ in asked.append(d.name); return true }
        XCTAssertFalse(s.call("export", as: ai).isError)
        XCTAssertEqual(asked, ["export"])

        s.policies[ai] = .readOnly
        XCTAssertTrue(s.call("add", arguments: ["amount": 1], as: ai).isError)
        XCTAssertEqual(s.descriptors(for: ai).map(\.name), ["get", "recent_operations"])

        s.policies[person] = .allowAll
        XCTAssertFalse(s.call("add", arguments: ["amount": 1], as: person).isError)
    }

    func testUndoIsPerCallerAndInReverseOrder() throws {
        let counter = Counter()
        let s = makeSurface(counter)
        _ = s.call("add", arguments: ["amount": 1], as: ai)     // 1
        _ = s.call("add", arguments: ["amount": 10], as: ai)    // 11
        XCTAssertEqual(s.undoCount(for: ai), 2)
        XCTAssertEqual(s.undoCount(for: person), 0)
        XCTAssertTrue(s.call("undo", as: person).isError, "人は AI の変更を取り消せない(自分の変更が無い)")
        XCTAssertFalse(s.call("undo", as: ai).isError)
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(s.call("undo", as: ai).isError)
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(s.call("undo", as: ai).isError, "もう取り消せるものが無い")
    }

    /// AI の変更の後に人が同じ対象を変えていたら、AI の取り消しは断る(戻すと人の変更まで消えるため)。
    /// 別の対象なら取り消せる
    func testUndoRefusesWhenAnotherCallerChangedTheSameResource() throws {
        let counter = Counter()
        let s = makeSurface(counter)
        s.policies[person] = .allowAll
        _ = s.call("add", arguments: ["amount": 1], as: ai)                          // 1
        _ = s.call("add", arguments: ["amount": 10], as: person)                     // 11
        let r = s.call("undo", as: ai)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.summary.contains("human:owner"), r.summary)
        XCTAssertEqual(counter.value, 11, "何も変えない")
        XCTAssertEqual(s.undoCount(for: ai), 1, "取り消しの履歴も残る")

        let other = Counter()
        let s2 = makeSurface(other)
        s2.policies[person] = .allowAll
        _ = s2.call("add", arguments: ["amount": 1, "target": "photo-a"], as: ai)
        _ = s2.call("add", arguments: ["amount": 10, "target": "photo-b"], as: person)
        XCTAssertFalse(s2.call("undo", as: ai).isError, "別の対象なら取り消せる")
    }

    /// 途中で失敗した呼び出しは、それまでの変更をその場で戻し、取り消しの履歴にも残さない
    func testFailedCallIsRolledBack() {
        let counter = Counter()
        let s = makeSurface(counter)
        let r = s.call("add_then_fail", as: ai)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(s.undoCount(for: ai), 0)
        XCTAssertEqual(s.auditLog.last?.outcome, .failed)
    }

    func testRecentOperations() {
        let s = makeSurface(Counter())
        _ = s.call("get", as: ai)
        _ = s.call("add", arguments: ["amount": 2], as: ai)
        _ = s.call("add", arguments: ["amount": 3], as: ai)
        func list(_ args: JSONValue) -> [JSONValue] {
            guard case .json(let v)? = s.call("recent_operations", arguments: args, as: ai).content.first else { return [] }
            return v.arrayValue ?? []
        }
        let changes = list(["limit": 5])
        XCTAssertEqual(changes.map { $0["tool"] }, ["add", "add"], "既定では読むだけの操作を含めない。新しい順")
        XCTAssertEqual(changes[0]["arguments"], #"{"amount":3}"#)
        XCTAssertEqual(changes[0]["undoable"], true)
        let all = list(["limit": 2, "include_reads": true])
        XCTAssertEqual(all.map { $0["tool"] }, ["recent_operations", "add"])
    }

    func testDescriptorsKeepRegistrationOrder() {
        let s = makeSurface(Counter())
        XCTAssertEqual(s.descriptors.map(\.name), ["get", "add", "add_then_fail", "export", "undo", "recent_operations"])
    }

    func testAuditSinkAndLimit() {
        let s = makeSurface(Counter())
        var sunk = 0
        s.auditSink = { _ in sunk += 1 }
        s.auditLimit = 3
        for _ in 0..<5 { _ = s.call("get", as: ai) }
        XCTAssertEqual(sunk, 5)
        XCTAssertEqual(s.auditLog.map(\.sequence), [3, 4, 5])
    }
}

/// MCP サーバー(stdio の JSON-RPC)
final class MCPServerTests: XCTestCase {
    private func makeServer() -> MCPServer {
        let s = Surface(name: "demo", version: "9", instructions: "説明")
        s.register(ToolDescriptor(
            name: "echo", title: "こだま", description: "そのまま返す",
            input: .object([.init("text", .string())], required: ["text"]), effect: .read)) { args, _ in
            .json(["echo": args["text"]!])
        }
        s.register(ToolDescriptor(name: "picture", title: "絵", description: "画像", effect: .read)) { _, _ in
            // 2×3 の PNG のヘッダー(IHDR まで)
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                                0, 0, 0, 2, 0, 0, 0, 3, 8, 2, 0, 0, 0]
            return ToolResult([.image(data: Data(png), mimeType: "image/png")])
        }
        s.register(ToolDescriptor(name: "wipe", title: "消す", description: "消す", effect: .destructive)) { _, _ in .text("x") }
        return MCPServer(surface: s)
    }

    private func send(_ server: MCPServer, _ json: String) throws -> JSONValue {
        let line = try XCTUnwrap(server.handle(line: json), "返事が無い")
        XCTAssertFalse(line.contains("\n"), "1 行で返す")
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    func testInitialize() throws {
        let server = makeServer()
        let r = try send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        XCTAssertEqual(r["id"], 1)
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-06-18", "対応している版はそのまま返す")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"], "demo")
        XCTAssertEqual(r["result"]?["instructions"], "説明")
        XCTAssertNotNil(r["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(server.caller, .agent("mcp:claude-code"))

        let old = try send(makeServer(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(old["id"], "a")
        XCTAssertEqual(old["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(makeServer().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(makeServer().handle(line: ""))
    }

    /// 拒否される段階(消す)の道具は一覧に出さない
    func testToolsList() throws {
        let r = try send(makeServer(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(r["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.map { $0["name"] }, ["echo", "picture"])
        XCTAssertEqual(tools[0]["inputSchema"]?["required"], ["text"])
        XCTAssertEqual(tools[0]["annotations"]?["readOnlyHint"], true)
    }

    func testToolsCall() throws {
        let server = makeServer()
        var records: [MCPServer.CallRecord] = []
        server.onToolCall = { records.append($0) }
        let r = try send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"こんにちは"}}}"#)
        XCTAssertEqual(r["result"]?["isError"], false)
        XCTAssertEqual(r["result"]?["content"]?.arrayValue?.first?["text"], #"{"echo":"こんにちは"}"#)

        let bad = try send(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual(bad["result"]?["isError"], true, "道具の失敗は JSON-RPC のエラーではなく結果で返す")

        let pic = try send(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"picture"}}"#)
        let image = try XCTUnwrap(pic["result"]?["content"]?.arrayValue?.first)
        XCTAssertEqual(image["type"], "image")
        XCTAssertEqual(image["mimeType"], "image/png")
        XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(image["data"]?.stringValue)))

        XCTAssertEqual(records.map(\.tool), ["echo", "echo", "picture"])
        XCTAssertEqual(records[2].images.first?.width, 2)
        XCTAssertEqual(records[2].images.first?.height, 3)
    }

    func testProtocolErrors() throws {
        let server = makeServer()
        XCTAssertEqual(try send(server, "{not json")["error"]?["code"], -32700)
        XCTAssertEqual(try send(server, #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)["error"]?["code"], -32601)
        XCTAssertEqual(try send(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try send(server, #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)["result"], .object([:]))
    }

    func testJPEGSize() {
        // SOI, APP0(長さ 4), SOF0(高さ 0x0100, 幅 0x0200)
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00,
                             0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03]
        let size = MCPServer.imageSize(Data(jpeg))
        XCTAssertEqual(size.0, 512)
        XCTAssertEqual(size.1, 256)
    }
}
