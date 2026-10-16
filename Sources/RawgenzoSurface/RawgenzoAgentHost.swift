import Foundation
import OperationSurface
import RAWCore

/// 起動中のアプリと、MCP の中継(rawdev mcp)の間の決まり
public enum RawgenzoBridge {
    /// 中継が最初に送る通知のメソッド名。params.folder に作業フォルダ
    public static let workspaceMethod = "rawgenzo/workspace"

    /// アプリが受け付けるソケット(本人だけが読み書きできる)。環境変数 RAWGENZO_AGENT_SOCKET で変えられる(テスト用)
    public static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["RAWGENZO_AGENT_SOCKET"], !p.isEmpty { return p }
        return RawgenzoPaths.home.appendingPathComponent("agent.sock").path
    }

    public static func handshake(folder: URL) -> String {
        JSONValue.object(["jsonrpc": "2.0", "method": .string(workspaceMethod),
                          "params": ["folder": .string(folder.standardizedFileURL.path)]]).jsonString()
    }
}

/// アプリの中で AI からの操作を受け付ける。ソケットの接続ごとに、中継が知らせた作業フォルダの操作面につなぐ。
/// 操作面はフォルダごとに 1 つ持ち、接続が切れても残す(取り消しの履歴と、人の変更の記録を保つため)。
///
/// スレッド: 道具の処理はすべて queue(直列)で行う。編集中の写真への反映(LiveEditing)はその実装がメインに移る
public final class RawgenzoAgentHost {
    public let queue = DispatchQueue(label: "Rawgenzo.agent", qos: .userInitiated)
    public let socketPath: String
    public weak var live: LiveEditing?
    /// 道具が呼ばれたとき(queue から呼ぶ)
    public var onToolCall: ((Caller, MCPServer.CallRecord) -> Void)?

    private let engine: RAWEngine
    private var surfaces: [URL: Surface] = [:]   // queue の中だけで触る
    private var server: UnixSocketServer?
    /// 人の変更の記録を残す主体
    public static let human = Caller.human("rawgenzo-app")

    public init(engine: RAWEngine = RAWEngine(), socketPath: String = RawgenzoBridge.socketPath) {
        self.engine = engine
        self.socketPath = socketPath
    }

    public var isRunning: Bool { server?.isRunning ?? false }

    public func start() throws {
        guard server == nil else { return }
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let server = UnixSocketServer(path: socketPath, handlerQueue: queue) { [weak self] in
            self?.makeConnection() ?? { _ in nil }
        }
        try server.start()
        self.server = server
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    /// アプリの画面で人が写真の設定を変えて保存したことを記録する(AI の取り消しを断る判断に使う)
    public func noteHumanChange(_ url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            self.surfaces[folder]?.noteChange(by: Self.human, resource: url.path, description: "アプリでの変更")
        }
    }

    /// queue の中で呼ぶ
    func surface(for folder: URL) -> Surface {
        let key = folder.standardizedFileURL
        if let s = surfaces[key] { return s }
        let ws = RawgenzoWorkspace(folder: key, engine: engine)
        ws.live = live
        let s = RawgenzoTools.makeSurface(workspace: ws)
        surfaces[key] = s
        return s
    }

    /// 接続 1 つ分の処理。最初に作業フォルダの知らせが来るまで MCP のメッセージは受けない
    func makeConnection() -> UnixSocketServer.LineHandler {
        var mcp: MCPServer?
        return { [weak self] line in
            guard let self else { return nil }
            guard let mcp else {
                guard let m = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      m["method"]?.stringValue == RawgenzoBridge.workspaceMethod,
                      let folder = m["params"]?["folder"]?.stringValue else {
                    return JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": [
                        "code": -32600, "message": .string("最初に \(RawgenzoBridge.workspaceMethod) で作業フォルダを知らせてください"),
                    ]]).jsonString()
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
                    return JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": [
                        "code": -32602, "message": .string("フォルダが見つかりません: \(folder)"),
                    ]]).jsonString()
                }
                let server = MCPServer(surface: self.surface(for: URL(fileURLWithPath: folder, isDirectory: true)))
                server.onToolCall = { [weak self, weak server] r in
                    guard let self, let server else { return }
                    self.onToolCall?(server.caller, r)
                }
                mcp = server
                return nil
            }
            return mcp.handle(line: line)
        }
    }
}
