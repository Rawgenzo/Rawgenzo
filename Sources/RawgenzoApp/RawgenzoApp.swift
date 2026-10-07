import SwiftUI
import AppKit

@main
struct RawgenzoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // 設定を先に読み込んでから編集モデルを作る(前回のフォルダを開き直すため)
    @StateObject private var prefs = AppConfigStore.shared
    @StateObject private var model = EditorModel()

    var body: some Scene {
        WindowGroup("Rawgenzo") {
            ContentView()
                .environmentObject(model)
                .environmentObject(prefs)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Rawgenzo について") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("フォルダを開く…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Toggle("サムネイルを表示", isOn: $prefs.config.thumbnails.show)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Menu("構図ガイド") {
                    GuideMenuItems(display: $prefs.config.guides, withShortcuts: true)
                }
                Divider()
                Button("ウインドウに合わせる") { model.zoomToFit() }
                    .keyboardShortcut("9")
                    .disabled(!model.canZoom)
                Button("実際のサイズ") { model.zoomToActualSize() }
                    .keyboardShortcut("0")
                    .disabled(!model.canZoom)
                Button("拡大") { model.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!model.canZoom)
                Button("縮小") { model.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!model.canZoom)
            }
            CommandGroup(after: .saveItem) {
                Button(prefs.config.export.showDialog ? "書き出し…" : "書き出し") { model.exportCurrent() }
                    .keyboardShortcut("e")
                    .disabled(model.photo == nil)
                Button("保存先を選んで書き出し…") { model.exportCurrent(forceDialog: true) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.photo == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(prefs)
        }
    }
}

/// `swift run` で起動したときにもDockに出て前面に来るようにする
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 保存待ちの設定を確実に書き出す
        AppConfigStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
