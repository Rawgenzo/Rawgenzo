import Foundation

/// ~/.Rawgenzo/.mcp.json(AI のセッション用の MCP の登録)の中身を決める。
/// このフォルダで Claude Code を開くと、アプリに同梱した rawdev が MCP サーバーとして使われる
public enum MCPConfigFile {
    public static let serverName = "rawgenzo"

    /// 今のファイル(無ければ nil)から、書くべき中身を返す。書き直さなくてよいときは nil。
    /// - 無いときは作る
    /// - rawgenzo の登録が無い・その command のファイルが無い(アプリを動かした・消した)ときは、command を rawdev に向け直す
    /// - ほかの Rawgenzo.app の中の rawdev を指していたら、今起動したアプリのものに向け直す(リポジトリの build/ の .app を
    ///   一度起動しただけで、/Applications に入れた後もリポジトリの中を指し続けないように)
    /// - .app の外の、存在するファイルを指していれば、人が書き換えたものとして触らない
    /// 引数やほかのサーバーは保つ
    /// 読めない JSON も触らない
    public static func updated(_ existing: Data?, rawdev: String,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Data? {
        var root: [String: Any] = [:]
        if let existing {
            guard let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var entry = servers[serverName] as? [String: Any] ?? ["args": ["mcp"]]
        if let command = entry["command"] as? String {
            if command == rawdev { return nil }
            if fileExists(command) && !command.hasSuffix(".app/Contents/MacOS/rawdev") { return nil }
        }
        entry["command"] = rawdev
        servers[serverName] = entry
        root["mcpServers"] = servers
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// アプリの起動時に呼ぶ。rawdev が無い(.app でない開発用の起動)ときは何もしない
    public static func ensure(rawdev: URL, at url: URL = RawgenzoPaths.mcpConfigFile) throws {
        guard FileManager.default.isExecutableFile(atPath: rawdev.path) else { return }
        guard let data = updated(try? Data(contentsOf: url), rawdev: rawdev.path) else { return }
        try RawgenzoPaths.ensureHomeExists()
        try data.write(to: url, options: .atomic)
    }
}
