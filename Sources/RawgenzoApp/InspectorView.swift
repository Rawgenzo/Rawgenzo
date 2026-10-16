import SwiftUI
import AppKit
import RAWCore

struct InspectorView: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        if let photo = model.photo {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(photo)
                    basicSection(photo)
                    lensSection(photo)
                    hdrSection(photo)
                    colorSection(photo)
                    detailSection(photo)
                    cropSection(photo)
                    lookSection
                    HStack {
                        Spacer()
                        Button("すべて初期値に戻す") { model.resetAll() }
                    }
                }
                .padding(16)
            }
        } else {
            Color.clear
        }
    }

    private func header(_ photo: Photo) -> some View {
        let m = photo.metadata
        return VStack(alignment: .leading, spacing: 2) {
            Text(photo.url.lastPathComponent).font(.headline).lineLimit(1)
            Text("\(photo.profile.displayName)  ISO \(m.iso.map { String($0) } ?? "-")")
                .font(.caption).foregroundStyle(.secondary)
            if let lens = m.lensModel {
                Text(lens).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func basicSection(_ photo: Photo) -> some View {
        InspectorSection("基本", id: .basic) {
            parameterSliders(.basic, photo)
        }
    }

    private func hdrSection(_ photo: Photo) -> some View {
        InspectorSection("HDR", id: .hdr) {
            parameterSliders(.hdr, photo)
            Toggle("HDRディスプレイ向けに出力", isOn: $model.settings.hdr.extendedOutput)
            if model.settings.hdr.extendedOutput {
                Text("書き出しは10bit HEIFになります。プレビューは通常の明るさで表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func colorSection(_ photo: Photo) -> some View {
        InspectorSection("色", id: .color) {
            parameterSliders(.color, photo)
        }
    }

    /// シャープネス・ノイズ除去(デコーダの機能。nil = デコーダ既定値)。範囲は ParameterCatalog / DetailRanges
    private func detailSection(_ photo: Photo) -> some View {
        InspectorSection("ディテール", id: .detail) {
            parameterSlider(ParameterCatalog["sharpness"], photo)
            Text("シャープネスは拡大表示(⌘0 など)と書き出しで効きます。ウインドウに合わせた表示では変わりません")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            parameterSlider(ParameterCatalog["luminanceNoiseReduction"], photo)
            parameterSlider(ParameterCatalog["colorNoiseReduction"], photo)
        }
    }

    /// まとまりのスライダーをカタログの順に並べる
    private func parameterSliders(_ group: ParameterGroup, _ photo: Photo) -> some View {
        ForEach(ParameterCatalog.parameters(in: group), id: \.id) { p in
            parameterSlider(p, photo)
        }
    }

    /// カタログの記述からスライダーを作る(範囲・基準値・表示の書式はカタログが持つ)。
    /// AI が直前に変えた項目は、数秒だけ背景に色を付ける
    private func parameterSlider(_ p: ParameterDescriptor, _ photo: Photo) -> some View {
        let context = photo.parameterContext
        return AdjustSlider(p.label, value: Binding(
            get: { p.value(model.settings, context: context) },
            set: { p.set($0, in: &model.settings) }),
            range: p.range, neutral: p.baselineValue(in: context), format: p.displayFormat,
            displayScale: p.displayScale,
            onReset: { p.reset(&model.settings) })
        .modifier(AgentHighlight(isOn: model.agentHighlights.contains(p.id)))
    }

    /// レンズ補正。サイドカーで指定が無ければ撮影時のカメラ設定に従う(チェックを触るとこの写真用の設定になる)
    private func lensSection(_ photo: Photo) -> some View {
        InspectorSection("レンズ補正", id: .lens) {
            if photo.lensCorrection != nil {
                Toggle("周辺減光", isOn: lensBinding(photo, \.vignetting))
                Toggle("歪曲", isOn: lensBinding(photo, \.distortion))
                Toggle("倍率色収差", isOn: lensBinding(photo, \.chromaticAberration))
                HStack {
                    Text(model.settings.lens == nil ? "撮影時のカメラの設定に従っています" : "この写真用に変更しています")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.settings.lens != nil {
                        Button("カメラの設定に戻す") { model.settings.lens = nil }
                            .controlSize(.small)
                    }
                }
            } else {
                Text("このレンズには補正情報がありません")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lensBinding(_ photo: Photo, _ key: WritableKeyPath<LensCorrectionSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { (photo.effectiveLensSettings(model.settings) ?? .off)[keyPath: key] },
            set: { value in
                var s = photo.effectiveLensSettings(model.settings) ?? .all
                s[keyPath: key] = value
                model.settings.lens = s
            })
    }

    private func cropSection(_ photo: Photo) -> some View {
        InspectorSection("クロップ", id: .crop) {
            Toggle(model.isCropping ? "枠を調整中" : "枠を調整する", isOn: $model.isCropping)
                .toggleStyle(.button)
                .modifier(AgentHighlight(isOn: model.agentHighlights.contains("crop.frame")))

            Picker("比率", selection: Binding(
                get: { model.settings.crop?.aspect ?? .free },
                set: { aspect in
                    let angle = model.settings.crop?.angle ?? 0
                    model.settings.crop = .centered(aspect: aspect, imageAspect: photo.imageAspect, angle: angle)
                })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .modifier(AgentHighlight(isOn: model.agentHighlights.contains("crop.aspect")))

            AdjustSlider("傾き補正", value: Binding(
                get: { model.settings.crop?.angle ?? 0 },
                set: { model.setTiltAngle($0) }),
                range: CropSettings.angleRange, neutral: 0, format: "%+.1f°")
                .modifier(AgentHighlight(isOn: model.agentHighlights.contains("crop.angle")))

            Button("収まる最大まで広げる") {
                model.maximizeCrop()
            }
            .disabled(model.settings.crop == nil)
            .help("今の比率のまま、傾き補正後の画像に収まる最大の大きさにします(位置はなるべく動かしません)")

            Button("クロップを解除") {
                model.isCropping = false
                model.settings.crop = nil
            }
            .disabled(model.settings.crop == nil)
        }
    }

    private var lookSection: some View {
        InspectorSection("ルック", id: .look) {
            Picker("スタイル", selection: Binding(
                get: { model.settings.look?.id ?? "" },
                set: { id in
                    model.settings.look = id.isEmpty
                        ? nil
                        : LookSelection(id: id, strength: model.settings.look?.strength ?? 1)
                })) {
                Text("なし").tag("")
                ForEach(model.engine.looks.builtIns, id: \.id) { look in
                    Text(look.displayName).tag(look.id)
                }
                if !model.engine.looks.userLooks.isEmpty {
                    Divider()
                    ForEach(model.engine.looks.userLooks, id: \.id) { look in
                        Text(look.displayName).tag(look.id)
                    }
                }
            }
            .modifier(AgentHighlight(isOn: model.agentHighlights.contains("look.style")))
            if model.settings.look != nil {
                AdjustSlider("強さ", value: Binding(
                    get: { model.settings.look?.strength ?? 1 },
                    set: { model.settings.look?.strength = $0 }),
                    range: 0...1, neutral: 1, format: "%.0f%%", displayScale: 100)
                    .modifier(AgentHighlight(isOn: model.agentHighlights.contains("look.strength")))
            }
        }
    }
}

/// 調整パネルのセクションの ID。折りたたみの状態を config.json に保存するので、値は変えないこと
enum InspectorSectionID: String, CaseIterable {
    case basic, lens, hdr, color, detail, crop, look
}

/// 折りたためるセクション。見出しの行のどこをクリックしても開閉する。
/// ⌥ を押しながらクリックすると、全セクションをまとめて同じ状態にする(Finder などと同じ慣例)
struct InspectorSection<Content: View>: View {
    let title: String
    let id: InspectorSectionID
    @ViewBuilder let content: Content
    @EnvironmentObject private var prefs: AppConfigStore

    init(_ title: String, id: InspectorSectionID, @ViewBuilder content: () -> Content) {
        self.title = title
        self.id = id
        self.content = content()
    }

    private var isExpanded: Bool { !prefs.config.inspector.collapsed.contains(id.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "クリックで折りたたむ(⌥クリックですべて)" : "クリックで開く(⌥クリックですべて)")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "開いています" : "折りたたまれています")
            .accessibilityAddTraits(.isHeader)

            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
    }

    private func toggle() {
        let expand = !isExpanded
        let all = NSEvent.modifierFlags.contains(.option)
        withAnimation(.easeInOut(duration: 0.15)) {
            var collapsed = prefs.config.inspector.collapsed
            let targets = all ? InspectorSectionID.allCases : [id]
            for t in targets {
                if expand { collapsed.remove(t.rawValue) } else { collapsed.insert(t.rawValue) }
            }
            prefs.config.inspector.collapsed = collapsed
        }
    }
}

/// ラベル・値表示付きスライダー。右端のボタンでそのパラメータだけ初期値に戻す。
struct AdjustSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let format: String
    var displayScale: Double = 1
    var onReset: (() -> Void)? = nil

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double,
         format: String, displayScale: Double = 1, onReset: (() -> Void)? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.neutral = neutral
        self.format = format
        self.displayScale = displayScale
        self.onReset = onReset
    }

    private var isAtNeutral: Bool {
        abs(value - neutral) < max(abs(range.upperBound - range.lowerBound) * 1e-4, 1e-9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * displayScale))
                    .monospacedDigit()
                    .foregroundStyle(isAtNeutral ? Color.secondary : Color.primary)
            }
            .font(.callout)

            HStack(spacing: 6) {
                Slider(value: $value, in: range)
                    .controlSize(.small)
                Button(action: reset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(isAtNeutral)
                .help("\(title)を初期値に戻す")
                .accessibilityLabel("\(title)を初期値に戻す")
            }
        }
    }

    private func reset() {
        if let onReset { onReset() } else { value = neutral }
    }
}

/// AI が変えた項目の強調(背景に薄くアクセントカラー)
struct AgentHighlight: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isOn ? 0.18 : 0)))
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .animation(.easeInOut(duration: isOn ? 0.15 : 0.8), value: isOn)
            .help(isOn ? "AI が変更しました" : "")
    }
}
