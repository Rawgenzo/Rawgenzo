import Foundation

/// 操作面を MCP(Model Context Protocol)のサーバーとして公開する。
/// 通信は stdio: MCP クライアント(Claude Desktop / Claude Code など)がこのプロセスを起動し、
/// 標準入力・標準出力で 1 行 1 メッセージの JSON-RPC 2.0 をやり取りする。ネットワークは使わない。
///
/// 対応するのは道具(tools)だけ: initialize / ping / tools/list / tools/call。
/// 標準出力にはメッセージ以外を書かないこと(ログは標準エラーへ)
public final class MCPServer {
    /// 対応する MCP の版。クライアントが求めた版がこの中にあればそれを、無ければ先頭(最新)を返す
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let surface: Surface
    /// 呼び出しの主体。initialize でクライアントの名前が分かったら "mcp:<名前>" にする
    public private(set) var caller = Caller.agent("mcp")
    /// 道具の呼び出しごとに、大きさ(AI に渡す量の目安)を知らせる
    public var onToolCall: ((CallRecord) -> Void)?

    public struct CallRecord: Sendable {
        public var tool: String
        public var isError: Bool
        public var durationMs: Int
        /// 結果の文字(JSON・説明)のバイト数
        public var textBytes: Int
        /// 画像の大きさ(ピクセル)とバイト数
        public var images: [(width: Int, height: Int, bytes: Int)]
    }

    public init(surface: Surface) {
        self.surface = surface
    }

    // MARK: - 実行

    /// 標準入力を読み終えるまで処理する
    public func run() {
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// 1 行(1 メッセージ)を処理し、返す行を返す(通知には返さないので nil)
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              case .object(let m) = message else {
            return reply(id: .null, error: (-32700, "JSON として読めません"))
        }
        if m["jsonrpc"] != "2.0" {
            return reply(id: m["id"] ?? .null, error: (-32600, "jsonrpc は \"2.0\" にしてください"))
        }
        guard let method = m["method"]?.stringValue else {
            // クライアントからの返事(このサーバーは要求を送らないので来ないはず)は読み捨てる
            return nil
        }
        let params = m["params"] ?? .object([:])
        guard let id = m["id"] else {
            // 通知(notifications/initialized など)には返事をしない
            return nil
        }
        do {
            return reply(id: id, result: try respond(method: method, params: params))
        } catch let e as RPCError {
            return reply(id: id, error: (e.code, e.message))
        } catch {
            return reply(id: id, error: (-32603, "\(error)"))
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    func respond(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.stringValue {
                caller = .agent("mcp:\(name)")
            }
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(surface.name), "version": .string(surface.version)],
            ]
            if !surface.instructions.isEmpty { result["instructions"] = .string(surface.instructions) }
            return .object(result)
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(surface.descriptors(for: caller).map(Self.toolJSON))]
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                throw RPCError(code: -32602, message: "params.name(道具の名前)がありません")
            }
            let start = Date()
            let result = surface.call(name, arguments: params["arguments"] ?? .object([:]), as: caller)
            let (json, record) = Self.resultJSON(result, tool: name, start: start)
            onToolCall?(record)
            return json
        default:
            throw RPCError(code: -32601, message: "対応していないメソッドです: \(method)")
        }
    }

    // MARK: - 変換

    static func toolJSON(_ d: ToolDescriptor) -> JSONValue {
        [
            "name": .string(d.name),
            "title": .string(d.title),
            "description": .string(d.description + "(影響: \(d.effect.label))"),
            "inputSchema": d.input.toJSON(),
            // クライアントが確認の要否を決める手がかり。取り消せる変更は destructive にしない
            "annotations": [
                "title": .string(d.title),
                "readOnlyHint": .bool(d.effect <= .propose),
                "destructiveHint": .bool(d.effect >= .destructive),
                "openWorldHint": false,
            ],
        ]
    }

    static func resultJSON(_ r: ToolResult, tool: String, start: Date) -> (JSONValue, CallRecord) {
        var content: [JSONValue] = []
        var textBytes = 0
        var images: [(Int, Int, Int)] = []
        for c in r.content {
            switch c {
            case .text(let s):
                content.append(["type": "text", "text": .string(s)])
                textBytes += s.utf8.count
            case .json(let v):
                let s = v.jsonString()
                content.append(["type": "text", "text": .string(s)])
                textBytes += s.utf8.count
            case .image(let data, let mime):
                content.append(["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)])
                let size = imageSize(data)
                images.append((size.0, size.1, data.count))
            }
        }
        let record = CallRecord(tool: tool, isError: r.isError,
                                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                                textBytes: textBytes, images: images)
        return (["content": .array(content), "isError": .bool(r.isError)], record)
    }

    /// JPEG・PNG の大きさ(ピクセル)。ImageIO を使わずにヘッダーから読む(Foundation だけで済ませるため)
    static func imageSize(_ data: Data) -> (Int, Int) {
        let b = [UInt8](data)
        if b.count > 24, b[0] == 0x89, b[1] == 0x50 {   // PNG: IHDR の幅・高さ
            func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
            return (be32(16), be32(20))
        }
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return (0, 0) }
        var i = 2
        while i + 9 < b.count {   // JPEG: SOF マーカーを探す
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                return (Int(b[i + 7]) << 8 | Int(b[i + 8]), Int(b[i + 5]) << 8 | Int(b[i + 6]))
            }
            i += 2 + length
        }
        return (0, 0)
    }

    private func reply(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
    }

    private func reply(id: JSONValue, error: (Int, String)) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .number(Double(error.0)), "message": .string(error.1)]]).jsonString()
    }
}
