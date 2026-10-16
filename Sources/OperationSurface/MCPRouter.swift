import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// MCP のメッセージを、起動中のアプリ(ソケットの先の操作面)か、自分の操作面(local)に振り分ける。
/// メッセージのたびにアプリにつながるかを確かめるので、AI の会話の途中でアプリを起動・終了しても切り替わる。
///
/// - アプリに切り替えたときは、最初に preamble(作業フォルダの知らせなど)と、クライアントの initialize を送り直す
///   (アプリの側で誰の操作かが分かるように)
/// - 要求をアプリに送った後で接続が切れたら、その要求は失敗として返す。自分で処理し直さない
///   (アプリが処理を済ませていたら、同じ変更を二重に当ててしまうため)
/// - 取り消しの履歴はアプリと自分とで別々。切り替える前の変更は、切り替えた後には取り消せない
public final class MCPRouter {
    public let local: MCPServer
    private let connect: () -> Int32?
    private let preamble: [String]
    private var remote: LineConnection?
    /// クライアントの initialize(アプリに切り替えたときに送り直す)
    private var initializeMessage: JSONValue?

    /// アプリとの切り替え(標準エラーへの記録用)
    public var onSwitch: ((String) -> Void)?
    /// アプリで処理した道具の呼び出しの記録(自分で処理した分は local.onToolCall)
    public var onRemoteToolCall: ((MCPServer.CallRecord) -> Void)?

    public var isRemote: Bool { remote != nil }

    public init(local: MCPServer, preamble: [String] = [], connect: @escaping () -> Int32?) {
        self.local = local
        self.preamble = preamble
        self.connect = connect
    }

    public func run() {
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    public func handle(line: String) -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return local.handle(line: line)   // 読めない行の扱い(エラーの返事)は local に任せる
        }
        let method = message["method"]?.stringValue
        var localReply: String?
        if method == "initialize" {
            initializeMessage = message
            // 自分の側も初期化しておく(いつアプリが居なくなっても続けられるように)
            localReply = local.handle(line: line)
        } else if method?.hasPrefix("notifications/") == true {
            _ = local.handle(line: line)
        }

        if let remote = ensureRemote(sendingInitialize: method != "initialize") {
            guard remote.send(line) else {
                // 送れなかった = アプリは受け取っていない。自分で処理する
                dropRemote("アプリとの接続が切れたので、自分で処理します")
                return localReply ?? local.handle(line: line)
            }
            guard let id = message["id"], method != nil else { return nil }   // 通知には返事が無い
            let start = Date()
            guard let reply = remote.receiveLine() else {
                dropRemote("アプリとの接続が処理の途中で切れました")
                return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": [
                    "code": -32000,
                    "message": "Rawgenzo アプリとの接続が処理の途中で切れました。変更が当たったかどうかは分かりません。状態を読み直してから続けてください",
                ]]).jsonString()
            }
            if method == "tools/call", let name = message["params"]?["name"]?.stringValue,
               let response = try? JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8)) {
                onRemoteToolCall?(MCPServer.record(tool: name, arguments: message["params"]?["arguments"] ?? .object([:]),
                                                   response: response,
                                                   durationMs: Int(Date().timeIntervalSince(start) * 1000)))
            }
            return reply
        }
        if method == "initialize" || method?.hasPrefix("notifications/") == true { return localReply }
        return local.handle(line: line)
    }

    /// アプリにつながっていればその接続を返す。つながっていなければつなぎにいく
    private func ensureRemote(sendingInitialize: Bool) -> LineConnection? {
        if let remote {
            if remote.isOpen { return remote }
            dropRemote("アプリとの接続が切れたので、自分で処理します")
        }
        guard let fd = connect() else { return nil }
        let conn = LineConnection(fd: fd)
        for line in preamble where !conn.send(line) { return nil }
        if sendingInitialize, var initialize = initializeMessage {
            // クライアントの initialize を、こちらの id で送り直し、返事は読み捨てる
            if case .object(var o) = initialize { o["id"] = "router-initialize"; initialize = .object(o) }
            guard conn.send(initialize.jsonString()), conn.receiveLine() != nil,
                  conn.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) else { return nil }
        }
        remote = conn
        onSwitch?("起動中のアプリに中継します")
        return conn
    }

    private func dropRemote(_ reason: String) {
        remote?.close()
        remote = nil
        onSwitch?(reason)
    }
}

/// ソケットの 1 本の接続を、1 行ずつ送り・受け取る(同期)
final class LineConnection {
    private var fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }
    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// 相手が閉じていないか(読める状態で 0 バイト = 閉じた)
    var isOpen: Bool {
        guard fd >= 0 else { return false }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 { return false }
        if n < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
        return true
    }

    func send(_ line: String) -> Bool {
        fd >= 0 && UnixSocketBridge.write(fd, line + "\n")
    }

    func receiveLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while fd >= 0 {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return nil
    }
}
