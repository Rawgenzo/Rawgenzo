import SwiftUI
import AppKit
import RAWCore
import RawgenzoSurface

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
            AgentSettingsSection()
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

/// AI(MCP の中継 rawdev mcp)からの操作の受け付け
struct AgentSettingsSection: View {
    @EnvironmentObject private var prefs: AppConfigStore
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        Section("AI からの操作") {
            Toggle("AI からの操作を受け付ける", isOn: $prefs.config.agent.enabled)
            LabeledContent("状態") {
                Text(model.agentStatus).foregroundStyle(.secondary)
            }
            Text("オンにすると、MCP クライアント(Claude Code など)に登録した rawdev mcp が、このアプリを通して現像設定を変えます。"
                 + "AI の変更は画面にその場で反映され、変わったスライダーが一時的に強調されます。"
                 + "オンの間は、同じユーザーの他のプログラムも現像設定を変えられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("受け口") {
                Text(RawgenzoBridge.socketPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
