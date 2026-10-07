import SwiftUI
import AppKit
import RAWCore

enum ThumbnailSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    /// 一覧に表示する枠の長辺(ポイント)
    var points: CGFloat {
        switch self {
        case .small: return 48
        case .medium: return 80
        case .large: return 140
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ExportSettingsView()
                .tabItem { Label("書き出し", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: AppConfigStore

    var body: some View {
        Form {
            Section("ファイル一覧") {
                Toggle("サムネイルを表示", isOn: $prefs.config.thumbnails.show)
                Picker("サムネイルの大きさ", selection: $prefs.config.thumbnails.size) {
                    ForEach(ThumbnailSize.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!prefs.config.thumbnails.show)
                Text("サムネイルはカメラがRAWに埋め込んだ画像を使うため、現像設定は反映されません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GuideSettingsSection(display: $prefs.config.guides)
            ConfigFileSection()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// 設定ファイルの場所と操作
struct ConfigFileSection: View {
    @EnvironmentObject private var prefs: AppConfigStore

    var body: some View {
        Section("設定ファイル") {
            LabeledContent("保存場所") {
                Text(prefs.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Finderで表示") { prefs.revealInFinder() }
                Button("ファイルから読み直す") { prefs.reload() }
                    .help("config.json を直接編集したあとに使う")
            }
            if let notice = prefs.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
