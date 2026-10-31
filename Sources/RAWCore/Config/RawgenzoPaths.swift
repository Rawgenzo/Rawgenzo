import Foundation

/// アプリとCLIが共有する保存場所。
///   ~/.Rawgenzo/config.json   設定
///   ~/.Rawgenzo/Looks/        .cube ファイル(ルック)
///   ~/.Rawgenzo/.mcp.json     AI のセッション用の MCP の登録(アプリが作る。このフォルダで Claude Code を開く)
public enum RawgenzoPaths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Rawgenzo", isDirectory: true)
    }

    public static var configFile: URL { home.appendingPathComponent("config.json") }

    public static var looksDirectory: URL { home.appendingPathComponent("Looks", isDirectory: true) }

    public static var mcpConfigFile: URL { home.appendingPathComponent(".mcp.json") }

    public static func ensureHomeExists() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: looksDirectory, withIntermediateDirectories: true)
    }
}
