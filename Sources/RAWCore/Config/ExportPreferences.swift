import Foundation

/// 書き出しの既定設定。アプリとCLIで共有する(config.json の "export")。
public struct ExportPreferences: Codable, Equatable, Sendable {
    public enum DirectoryMode: String, Codable, CaseIterable, Sendable {
        case sameAsRAW   // RAWと同じフォルダ(+サブフォルダ)
        case fixed       // 指定したフォルダ
        case lastUsed    // 前回保存したフォルダ

        public var label: String {
            switch self {
            case .sameAsRAW: return "RAWと同じフォルダ"
            case .fixed: return "指定したフォルダ"
            case .lastUsed: return "前回保存したフォルダ"
            }
        }
    }

    public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
        case addNumber   // DSC01234-2.jpg のように番号を付ける
        case overwrite

        public var label: String {
            switch self {
            case .addNumber: return "番号を付けて別名で保存"
            case .overwrite: return "上書きする"
            }
        }
    }

    public var directoryMode: DirectoryMode = .sameAsRAW
    /// sameAsRAW のときのサブフォルダ名(空ならRAWと同じ場所)
    public var subfolder: String = "developed"
    public var fixedDirectory: String? = nil
    public var lastDirectory: String? = nil
    /// 書き出すたびに保存ダイアログを出すか
    public var showDialog: Bool = true

    public var fileNameTemplate: String = FileNameTemplate.default.pattern
    /// 次に使う連番 ({seq})
    public var nextSequence: Int = 1
    public var conflictPolicy: ConflictPolicy = .addNumber

    public var format: String = Exporter.Format.jpeg.rawValue
    public var colorSpace: String = Exporter.OutputColorSpace.sRGB.rawValue
    public var quality: Double = 0.92

    public init() {}

    public var template: FileNameTemplate { FileNameTemplate(fileNameTemplate) }
    public var exportFormat: Exporter.Format { Exporter.Format(rawValue: format) ?? .jpeg }
    public var outputColorSpace: Exporter.OutputColorSpace {
        Exporter.OutputColorSpace(rawValue: colorSpace) ?? .sRGB
    }

    /// このRAWを書き出すときの既定フォルダ
    public func directory(for raw: URL) -> URL {
        let nextToRAW: URL = {
            let base = raw.deletingLastPathComponent()
            let sub = subfolder.trimmingCharacters(in: .whitespaces)
            return sub.isEmpty ? base : base.appendingPathComponent(sub, isDirectory: true)
        }()
        switch directoryMode {
        case .sameAsRAW: return nextToRAW
        case .fixed: return fixedDirectory.map(Self.url) ?? nextToRAW
        case .lastUsed: return lastDirectory.map(Self.url) ?? nextToRAW
        }
    }

    private static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 同名ファイルがあったときの保存先を決める
    public static func resolve(directory: URL, baseName: String, fileExtension: String,
                               policy: ConflictPolicy, fileManager: FileManager = .default) -> URL {
        let first = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        guard policy == .addNumber, fileManager.fileExists(atPath: first.path) else { return first }
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName)-\(n)")
                .appendingPathExtension(fileExtension)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // 項目が増えても古い設定ファイルを読めるよう、欠けた項目は既定値で補う
    private enum CodingKeys: String, CodingKey {
        case directoryMode, subfolder, fixedDirectory, lastDirectory, showDialog
        case fileNameTemplate, nextSequence, conflictPolicy, format, colorSpace, quality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportPreferences()
        directoryMode = (try? c.decodeIfPresent(DirectoryMode.self, forKey: .directoryMode)) ?? d.directoryMode   // 未知の値なら既定
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? d.subfolder
        fixedDirectory = try c.decodeIfPresent(String.self, forKey: .fixedDirectory)
        lastDirectory = try c.decodeIfPresent(String.self, forKey: .lastDirectory)
        showDialog = try c.decodeIfPresent(Bool.self, forKey: .showDialog) ?? d.showDialog
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? d.fileNameTemplate
        nextSequence = max(0, try c.decodeIfPresent(Int.self, forKey: .nextSequence) ?? d.nextSequence)
        conflictPolicy = (try? c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)) ?? d.conflictPolicy
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? d.format
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? d.colorSpace
        quality = min(max(try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality, 0.1), 1)
    }
}

/// CLIなど、アプリ以外から config.json の共有部分だけを読むための型
public struct SharedConfig: Decodable {
    public var export = ExportPreferences()

    public init() {}

    private enum CodingKeys: String, CodingKey { case export }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        export = try c.decodeIfPresent(ExportPreferences.self, forKey: .export) ?? ExportPreferences()
    }

    /// ファイルが無い・読めないときは既定値
    public static func load(from url: URL = RawgenzoPaths.configFile) -> SharedConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SharedConfig.self, from: data) else { return SharedConfig() }
        return config
    }
}
