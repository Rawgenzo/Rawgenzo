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
                    hdrSection
                    colorSection
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
            AdjustSlider("露出", value: $model.settings.exposure, range: -3...3,
                         neutral: 0, format: "%+.2f EV")
            AdjustSlider("コントラスト", value: $model.settings.contrast, range: ContrastCurve.range,
                         neutral: 0, format: "%+.0f", displayScale: 100)
            AdjustSlider("色温度", value: Binding(
                get: { model.settings.temperature ?? photo.source.asShot.temperature },
                set: { model.settings.temperature = $0 }),
                range: 2000...12000, neutral: photo.source.asShot.temperature, format: "%.0f K",
                onReset: { model.settings.temperature = nil })
            AdjustSlider("色かぶり", value: Binding(
                get: { model.settings.tint ?? photo.source.asShot.tint },
                set: { model.settings.tint = $0 }),
                range: -150...150, neutral: photo.source.asShot.tint, format: "%+.0f",
                onReset: { model.settings.tint = nil })
        }
    }

    private var hdrSection: some View {
        InspectorSection("HDR", id: .hdr) {
            AdjustSlider("HDRの強さ", value: $model.settings.hdr.strength, range: 0...1,
                         neutral: 0, format: "%.2f")
            AdjustSlider("ハイライト回復", value: $model.settings.hdr.highlights, range: 0...1,
                         neutral: 0, format: "%.2f")
            AdjustSlider("シャドウ持ち上げ", value: $model.settings.hdr.shadows, range: 0...1,
                         neutral: 0, format: "%.2f")
            Toggle("HDRディスプレイ向けに出力", isOn: $model.settings.hdr.extendedOutput)
            if model.settings.hdr.extendedOutput {
                Text("書き出しは10bit HEIFになります。プレビューは通常の明るさで表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var colorSection: some View {
        InspectorSection("色", id: .color) {
            AdjustSlider("彩度", value: $model.settings.saturation, range: 0...2,
                         neutral: 1, format: "%.2f")
            AdjustSlider("自然な彩度", value: $model.settings.vibrance, range: -1...1,
                         neutral: 0, format: "%+.2f")
        }
    }

    /// シャープネス・ノイズ除去(デコーダの機能。nil = デコーダ既定値)。範囲はオーナーの希望で広げてある
    /// (輝度ノイズ除去だけは 1 を超えると効き方が逆になるので 0...1)
    private func detailSection(_ photo: Photo) -> some View {
        let d = photo.source.detailDefaults
        return InspectorSection("ディテール", id: .detail) {
            AdjustSlider("シャープネス", value: Binding(
                get: { model.settings.sharpness ?? d.sharpness },
                set: { model.settings.sharpness = $0 }),
                range: DetailRanges.sharpness, neutral: d.sharpness, format: "%.0f", displayScale: 100,
                onReset: { model.settings.sharpness = nil })
            Text("シャープネスは拡大表示(⌘0 など)と書き出しで効きます。ウインドウに合わせた表示では変わりません")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AdjustSlider("輝度ノイズ除去", value: Binding(
                get: { model.settings.luminanceNoiseReduction ?? d.luminanceNoiseReduction },
                set: { model.settings.luminanceNoiseReduction = $0 }),
                range: DetailRanges.luminanceNoiseReduction, neutral: d.luminanceNoiseReduction,
                format: "%.0f", displayScale: 100,
                onReset: { model.settings.luminanceNoiseReduction = nil })
            AdjustSlider("色ノイズ除去", value: Binding(
                get: { model.settings.colorNoiseReduction ?? d.colorNoiseReduction },
                set: { model.settings.colorNoiseReduction = $0 }),
                range: DetailRanges.colorNoiseReduction, neutral: d.colorNoiseReduction,
                format: "%.0f", displayScale: 100,
                onReset: { model.settings.colorNoiseReduction = nil })
        }
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

            Picker("比率", selection: Binding(
                get: { model.settings.crop?.aspect ?? .free },
                set: { aspect in
                    let angle = model.settings.crop?.angle ?? 0
                    model.settings.crop = .centered(aspect: aspect, imageAspect: photo.imageAspect, angle: angle)
                })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            AdjustSlider("傾き補正", value: Binding(
                get: { model.settings.crop?.angle ?? 0 },
                set: { model.setTiltAngle($0) }),
                range: -15...15, neutral: 0, format: "%+.1f°")

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
            if model.settings.look != nil {
                AdjustSlider("強さ", value: Binding(
                    get: { model.settings.look?.strength ?? 1 },
                    set: { model.settings.look?.strength = $0 }),
                    range: 0...1, neutral: 1, format: "%.0f%%", displayScale: 100)
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
