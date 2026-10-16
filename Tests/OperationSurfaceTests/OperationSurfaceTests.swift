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
        let r = s.call("recent_operations", arguments: ["limit": 2], as: ai)
        guard case .json(let v)? = r.content.first, let list = v.arrayValue else { return XCTFail("JSON が返らない") }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["tool"], "add", "新しい順")
        XCTAssertEqual(list[1]["tool"], "get")
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
