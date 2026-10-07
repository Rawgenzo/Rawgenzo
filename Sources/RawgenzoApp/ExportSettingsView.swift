import SwiftUI
import AppKit
import RAWCore

struct ExportSettingsView: View {
    @EnvironmentObject private var prefs: AppConfigStore
    @EnvironmentObject private var model: EditorModel

    private var export: Binding<ExportPreferences> { $prefs.config.export }

    var body: some View {
        Form {
            Section("保存先") {
                Picker("既定のフォルダ", selection: export.directoryMode) {
                    ForEach(ExportPreferences.DirectoryMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                switch prefs.config.export.directoryMode {
                case .sameAsRAW:
                    TextField("サブフォルダ名", text: export.subfolder, prompt: Text("空ならRAWと同じ場所"))
                case .fixed:
                    LabeledContent("フォルダ") {
                        HStack {
                            Text(prefs.config.export.fixedDirectory.map(Self.tilde) ?? "未選択")
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("選択…") { chooseFixedDirectory() }
                        }
                    }
                case .lastUsed:
                    LabeledContent("前回のフォルダ") {
                        Text(prefs.config.export.lastDirectory.map(Self.tilde) ?? "まだありません(RAWと同じフォルダを使います)")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("書き出すたびに保存ダイアログを表示", isOn: export.showDialog)
                if !prefs.config.export.showDialog {
                    Text("⌘E で、上のフォルダとファイル名にそのまま書き出します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("同じ名前のファイルがあるとき", selection: export.conflictPolicy) {
                    ForEach(ExportPreferences.ConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            FileNameTemplateSection(export: export, sample: sampleContext)

            Section("形式") {
                Picker("ファイル形式", selection: export.format) {
                    Text("JPEG").tag(Exporter.Format.jpeg.rawValue)
                    Text("HEIF").tag(Exporter.Format.heif.rawValue)
                    Text("TIFF 16bit").tag(Exporter.Format.tiff16.rawValue)
                }
                Picker("色空間", selection: export.colorSpace) {
                    Text("sRGB").tag(Exporter.OutputColorSpace.sRGB.rawValue)
                    Text("Display P3").tag(Exporter.OutputColorSpace.displayP3.rawValue)
                    Text("Adobe RGB").tag(Exporter.OutputColorSpace.adobeRGB.rawValue)
                }
                if prefs.config.export.exportFormat != .tiff16 {
                    LabeledContent("画質") {
                        HStack {
                            Slider(value: export.quality, in: 0.5...1)
                            Text("\(Int(prefs.config.export.quality * 100))")
                                .monospacedDigit().frame(width: 32, alignment: .trailing)
                        }
                    }
                }
                Text("「HDRディスプレイ向けに出力」をオンにした写真は、ここの設定に関わらず10bit HEIFで書き出します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// プレビューには開いている写真を使い、無ければ見本を使う
    private var sampleContext: FileNameTemplate.Context {
        guard let photo = model.photo else { return .sample }
        let size = photo.source.nativeSize
        return FileNameTemplate.Context(
            sourceURL: photo.url, metadata: photo.metadata,
            sequence: prefs.config.export.nextSequence,
            lookName: model.settings.look.flatMap { model.engine.looks.look(id: $0.id)?.displayName },
            outputSize: size)
    }

    private func chooseFixedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        if let path = prefs.config.export.fixedDirectory {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            prefs.config.export.fixedDirectory = url.path
        }
    }

    static func tilde(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct FileNameTemplateSection: View {
    @Binding var export: ExportPreferences
    let sample: FileNameTemplate.Context

    private var template: FileNameTemplate { export.template }

    /// よく使うテンプレート
    private let presets: [(String, String)] = [
        ("元のファイル名", "{name}"),
        ("撮影日_元のファイル名", "{date}_{name}"),
        ("撮影日時", "{date}-{time}"),
        ("撮影日_連番", "{date}_{seq}"),
        ("機種_ISO_元のファイル名", "{model}_ISO{iso}_{name}"),
        ("フォルダ名_連番", "{folder}_{seq:3}"),
    ]

    var body: some View {
        Section("ファイル名") {
            TextField("テンプレート", text: $export.fileNameTemplate)
                .font(.body.monospaced())

            HStack {
                Menu("変数を挿入") {
                    ForEach(FileNameTemplate.variables, id: \.token) { v in
                        Button("{\(v.token)}  \(v.summary)") {
                            export.fileNameTemplate += "{\(v.token)}"
                        }
                    }
                }
                Menu("よく使う形") {
                    ForEach(presets, id: \.1) { preset in
                        Button("\(preset.0)    \(preset.1)") { export.fileNameTemplate = preset.1 }
                    }
                }
                Spacer()
            }

            LabeledContent("例") {
                if let error = template.validate() {
                    Text(error.description).foregroundStyle(.red)
                } else {
                    let name = (try? template.render(sample)) ?? ""
                    Text("\(name).\(export.exportFormat.fileExtension)")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }

            if template.usesSequence {
                LabeledContent("次の連番") {
                    HStack {
                        TextField("", value: $export.nextSequence, format: .number)
                            .frame(width: 80)
                        Stepper("", value: $export.nextSequence, in: 0...999_999).labelsHidden()
                        Button("1に戻す") { export.nextSequence = 1 }
                    }
                }
            }

            DisclosureGroup("書式について") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("{変数} を値に置き換えます。日付と連番は書式を指定できます。")
                    Text("例: {date:yyyy-MM-dd}  {time:HH.mm}  {seq:3}")
                        .font(.caption.monospaced())
                    Text("日付の書式は y=年 M=月 d=日 H=時 m=分 s=秒 です。拡張子は形式に合わせて自動で付きます。")
                    Text("値が無い変数(レンズ情報が無いなど)は空になり、端に残った _ や - は取り除かれます。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
