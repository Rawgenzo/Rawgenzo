import SwiftUI
import AppKit
import RAWCore

/// アプリ全体の設定。~/.Rawgenzo/config.json に保存する。
/// "export" はCLI(rawdev)とも共有する。
struct AppConfig: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = AppConfig.currentSchemaVersion
    var export = ExportPreferences()
    var thumbnails = ThumbnailPreferences()
    var guides = GuideDisplay()
    /// 右側の調整パネル(折りたたんだセクション)
    var inspector = InspectorPreferences()
    /// 最後に開いていたフォルダ(次回起動時に開き直す)
    var lastFolder: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, export, thumbnails, guides, inspector, lastFolder
    }

    // 項目の追加・欠けに強くする(手で編集されても既定値で補う)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        export = try c.decodeIfPresent(ExportPreferences.self, forKey: .export) ?? d.export
        thumbnails = try c.decodeIfPresent(ThumbnailPreferences.self, forKey: .thumbnails) ?? d.thumbnails
        guides = try c.decodeIfPresent(GuideDisplay.self, forKey: .guides) ?? d.guides
        inspector = (try? c.decodeIfPresent(InspectorPreferences.self, forKey: .inspector)) ?? d.inspector
        lastFolder = try c.decodeIfPresent(String.self, forKey: .lastFolder)
    }
}

/// 右側の調整パネルの表示設定
struct InspectorPreferences: Codable, Equatable {
    /// 折りたたんでいるセクションの ID(InspectorSectionID の rawValue。保存されるので ID は変えない)
    var collapsed: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey { case collapsed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsed = (try? c.decodeIfPresent(Set<String>.self, forKey: .collapsed)) ?? []
    }
}

struct ThumbnailPreferences: Codable, Equatable {
    var show = true
    var size = ThumbnailSize.medium

    init() {}

    private enum CodingKeys: String, CodingKey { case show, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? true
        size = (try? c.decodeIfPresent(ThumbnailSize.self, forKey: .size)) ?? .medium
    }
}

/// config.json の読み書き。変更は少し待ってまとめて保存する。
@MainActor
final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }
    /// 読み込み・保存で起きた問題(設定画面に表示)
    @Published private(set) var notice: String?

    let fileURL = RawgenzoPaths.configFile
    private var saveTask: Task<Void, Never>?

    private init() {
        config = AppConfig()
        reload()
    }

    /// ファイルから読み直す(手で編集したあとに使う)
    func reload() {
        let fm = FileManager.default
        notice = nil
        if let data = try? Data(contentsOf: fileURL) {
            do {
                setWithoutSaving(try JSONDecoder().decode(AppConfig.self, from: data))
            } catch {
                // 壊れたファイルは消さずに退避して、既定値で起動する
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("config.broken-\(stamp).json")
                try? fm.moveItem(at: fileURL, to: backup)
                notice = "設定ファイルを読めなかったため既定値で起動しました。元のファイルは \(backup.lastPathComponent) に退避しています。"
                setWithoutSaving(AppConfig())
                saveNow()
            }
        } else {
            // 初回: 既定値で作る
            setWithoutSaving(AppConfig())
            saveNow()
        }
    }

    private var suppressSave = false
    private func setWithoutSaving(_ value: AppConfig) {
        suppressSave = true
        config = value
        suppressSave = false
    }

    private func scheduleSave() {
        guard !suppressSave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try RawgenzoPaths.ensureHomeExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            notice = "設定を保存できません: \(error.localizedDescription)"
        }
    }

    func revealInFinder() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
