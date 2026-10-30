import SwiftUI
import AppKit
import RAWCore

/// 調整パネルの「色別補正」(docs/color-grading-design.md の A)。8 色の帯と、スポイトで拾った色の 2 つの形を切り替える
struct ColorAdjustSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection("色別補正", id: .hsl) {
            HStack(spacing: 8) {
                Picker("", selection: $model.colorPanelShowsPoints) {
                    Text("8 色").tag(false)
                    Text("拾った色").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !model.colorPanelShowsPoints {
                    EyedropperButton(isOn: model.colorPick == .band) {
                        model.colorPick = model.colorPick == .band ? nil : .band
                    }
                    .help("プレビューの色を押すと、その色の帯を選びます。押したまま上下にドラッグすると彩度(option で色相、shift で輝度)を変えます")
                }
            }
            if model.colorPanelShowsPoints {
                ColorPointsPanel()
            } else {
                ColorBandsPanel()
            }
            if let message = model.colorPickMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 8 色

struct ColorBandsPanel: View {
    @EnvironmentObject private var model: EditorModel
    @State private var showsTable = false

    private var band: ColorBand { model.selectedBand }
    private var adjust: ColorBandAdjust { model.settings.colorAdjust?.bands[band] ?? ColorBandAdjust() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 色のチップ。値を変えた色には下に点
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases, id: \.self) { b in
                    let edited = !(model.settings.colorAdjust?.bands[b]?.isNeutral ?? true)
                    Button { model.selectedBand = b } label: {
                        VStack(spacing: 3) {
                            Circle().fill(ColorAdjustColors.band(b)).frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.primary, lineWidth: b == band ? 2 : 0).padding(-3))
                            Circle().fill(edited ? Color.primary : Color.clear).frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(b.label)
                }
            }
            HueStrip(band: band).frame(height: 18)
            HStack {
                Text(band.label).font(.callout.weight(.semibold))
                Spacer()
                Text("効く範囲 ±\(Int(ColorAdjustColors.halfSpan(band).rounded()))°").font(.caption).foregroundStyle(.secondary)
            }

            ColorSlider("色相", value: bandBinding(\.hue), range: ColorBandAdjust.range, neutral: 0, format: "%+.0f",
                        track: ColorAdjustColors.hueTrack(band), onEditing: showMask)
            ColorSlider("彩度", value: bandBinding(\.saturation), range: ColorBandAdjust.range, neutral: 0, format: "%+.0f",
                        track: ColorAdjustColors.saturationTrack(band), onEditing: showMask)
            ColorSlider("輝度", value: bandBinding(\.luminance), range: ColorBandAdjust.range, neutral: 0, format: "%+.0f",
                        track: ColorAdjustColors.luminanceTrack(band), onEditing: showMask)

            Toggle("効く場所を表示(ドラッグ中だけ)", isOn: $model.showsColorMask)
            HStack {
                Button("この色をリセット") { model.updateColorAdjust { $0.bands[band] = nil } }
                    .disabled(adjust.isNeutral)
                Spacer()
                Button("すべての色をリセット") { model.updateColorAdjust { $0.bands = [:] } }
                    .disabled(model.settings.colorAdjust?.bands.values.allSatisfy(\.isNeutral) ?? true)
            }
            .controlSize(.small)

            DisclosureGroup("すべての色を一覧", isExpanded: $showsTable) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("色相"); Text("彩度"); Text("輝度")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(ColorBand.allCases, id: \.self) { b in
                        let a = model.settings.colorAdjust?.bands[b] ?? ColorBandAdjust()
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(ColorAdjustColors.band(b)).frame(width: 9, height: 9)
                                Text(b.label)
                            }
                            .gridColumnAlignment(.leading)
                            ForEach([a.hue, a.saturation, a.luminance], id: \.self) { v in
                                Text(v == 0 ? "0" : String(format: "%+.0f", v)).monospacedDigit()
                                    .foregroundStyle(v == 0 ? Color.secondary : Color.primary)
                            }
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedBand = b }
                        .background(b == band ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func bandBinding(_ key: WritableKeyPath<ColorBandAdjust, Double>) -> Binding<Double> {
        let b = band
        return Binding(
            get: { model.settings.colorAdjust?.bands[b]?[keyPath: key] ?? 0 },
            set: { v in model.updateColorAdjust { var a = $0.bands[b] ?? ColorBandAdjust(); a[keyPath: key] = v; $0.bands[b] = a } })
    }

    private func showMask(_ editing: Bool) {
        model.colorMask = editing && model.showsColorMask ? .band(band) : nil
    }
}

/// 色相の帯(0〜360°)と、選んだ帯の効く範囲(山の形)
struct HueStrip: View {
    let band: ColorBand

    var body: some View {
        Canvas { ctx, size in
            let bar = CGRect(x: 0, y: 8, width: size.width, height: 8)
            let stops = (0...36).map { k -> Gradient.Stop in
                .init(color: ColorAdjustColors.hue(Double(k) * 10), location: Double(k) / 36)
            }
            ctx.fill(Path(roundedRect: bar, cornerRadius: 4),
                     with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
            let (lo, center, hi) = ColorAdjustColors.span(band)
            // 0〜360 に丸めない。範囲が 0° をまたぐ帯は、下で ±360° ずらして左右の端に分けて描くので、
            // 丸めるとずらした分が戻り、右から左へ戻る長い弧が余計に描かれた(赤・マゼンタ。オーナーの指摘)
            func x(_ h: Double) -> CGFloat { size.width * CGFloat(h / 360) }
            // 範囲が 0° をまたぐ帯(赤・マゼンタ)は、山を 2 つに分けて描く
            for shift in [-360.0, 0, 360] {
                let a = x(lo + shift), c = x(center + shift), b = x(hi + shift)
                guard b > 0, a < size.width else { continue }
                var arc = Path()
                arc.move(to: CGPoint(x: a, y: 17))
                arc.addQuadCurve(to: CGPoint(x: b, y: 17), control: CGPoint(x: c, y: -6))
                ctx.stroke(arc, with: .color(.primary.opacity(0.8)), lineWidth: 1.2)
                var tri = Path()
                tri.move(to: CGPoint(x: c, y: 7)); tri.addLine(to: CGPoint(x: c - 4, y: 1)); tri.addLine(to: CGPoint(x: c + 4, y: 1))
                ctx.fill(tri, with: .color(.primary))
            }
        }
        .clipped()   // 端からはみ出す側の山は帯の外に描かない
        .accessibilityHidden(true)
    }
}

// MARK: - 拾った色

struct ColorPointsPanel: View {
    @EnvironmentObject private var model: EditorModel

    private var points: [ColorPointAdjust] { model.settings.colorAdjust?.points ?? [] }
    private var index: Int? { points.indices.contains(model.selectedPoint) ? model.selectedPoint : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        Button { model.selectedPoint = i } label: {
                            VStack(spacing: 4) {
                                Circle().fill(ColorAdjustColors.point(p)).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.2)))
                                Text(p.name.isEmpty ? "\(i + 1)" : p.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 56, height: 50)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary, lineWidth: i == index ? 2 : 0).padding(-2))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { model.colorPick = model.colorPick == .newPoint ? nil : .newPoint } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eyedropper")
                            Text(model.colorPick == .newPoint ? "写真を押す" : "色を拾う")
                        }
                        .frame(height: 50).padding(.horizontal, 12)
                        .foregroundStyle(Color.accentColor)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(model.colorPick == .newPoint ? 0.15 : 0))))
                    }
                    .buttonStyle(.plain)
                    .help("プレビューの色を押すと、その色を中心にした補正を足します")
                }
                .padding(2)
            }

            if let i = index {
                pointEditor(i)
            } else {
                Text("「色を拾う」を押して、プレビューの直したい色(桜の花びらなど)を押してください。拾った色に近い色だけが変わります")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func pointEditor(_ i: Int) -> some View {
        let p = points[i]
        TextField("名前", text: Binding(get: { points.indices.contains(i) ? points[i].name : "" },
                                       set: { v in update(i) { $0.name = v } }))
            .textFieldStyle(.roundedBorder)
        PointRangeChart(point: p).frame(height: 96)
        HStack {
            Text("← 色相 →").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Text("枠の外の色には効かない").font(.caption2).foregroundStyle(.tertiary)
        }

        Text("効く範囲").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ColorSlider("色相の幅", value: binding(i, \.hueWidth), range: ColorPointAdjust.hueWidthRange, neutral: 20,
                    format: "±%.0f°", onEditing: showMask)
        ColorRangeSlider("淡さ", low: binding(i, \.chromaMin), high: binding(i, \.chromaMax),
                         track: ColorAdjustColors.chromaTrack(p), onEditing: showMask)
        ColorSlider("なめらかさ", value: binding(i, \.softness), range: ColorPointAdjust.unitRange, neutral: 50,
                    format: "%.0f", onEditing: showMask)
        Divider()
        Text("補正").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ColorSlider("色を足す", value: binding(i, \.add), range: ColorPointAdjust.unitRange, neutral: 0, format: "%+.0f",
                    track: ColorAdjustColors.addTrack(p), onEditing: showMask)
        ColorSlider("彩度", value: binding(i, \.saturation), range: ColorPointAdjust.signedRange, neutral: 0, format: "%+.0f",
                    onEditing: showMask)
        ColorSlider("色相", value: binding(i, \.hueShift), range: ColorPointAdjust.signedRange, neutral: 0, format: "%+.0f",
                    onEditing: showMask)
        ColorSlider("輝度", value: binding(i, \.luminance), range: ColorPointAdjust.signedRange, neutral: 0, format: "%+.0f",
                    onEditing: showMask)
        Toggle("効く場所を表示(ドラッグ中だけ)", isOn: $model.showsColorMask)
        HStack {
            Button(model.colorPick == .repick(i) ? "写真を押す" : "スポイトで拾い直す") {
                model.colorPick = model.colorPick == .repick(i) ? nil : .repick(i)
            }
            Spacer()
            Button("この色の補正を消す") {
                model.updateColorAdjust { $0.points.remove(at: i) }
                model.selectedPoint = max(0, i - 1)
            }
        }
        .controlSize(.small)
    }

    private func update(_ i: Int, _ change: @escaping (inout ColorPointAdjust) -> Void) {
        model.updateColorAdjust { c in
            guard c.points.indices.contains(i) else { return }
            change(&c.points[i])
        }
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<ColorPointAdjust, Double>) -> Binding<Double> {
        Binding(get: { points.indices.contains(i) ? points[i][keyPath: key] : 0 },
                set: { v in update(i) { $0[keyPath: key] = v } })
    }

    private func showMask(_ editing: Bool) {
        model.colorMask = editing && model.showsColorMask ? .point(model.selectedPoint) : nil
    }
}

/// 拾った色の効く範囲の図。横が色相(拾った色を真ん中に)、縦が淡さ(上が淡い・下が濃い)
struct PointRangeChart: View {
    let point: ColorPointAdjust

    var body: some View {
        Canvas { ctx, size in
            let nx = 48, ny = 10
            for i in 0..<nx {
                for j in 0..<ny {
                    let h = point.hue - 180 + 360 * (Double(i) + 0.5) / Double(nx)
                    let level = 100 * (Double(j) + 0.5) / Double(ny)
                    let rect = CGRect(x: size.width * CGFloat(i) / CGFloat(nx), y: size.height * CGFloat(j) / CGFloat(ny),
                                      width: size.width / CGFloat(nx) + 0.5, height: size.height / CGFloat(ny) + 0.5)
                    ctx.fill(Path(rect), with: .color(ColorAdjustColors.oklch(l: 0.92 - 0.35 * level / 100, level: level, hue: h)))
                }
            }
            func x(_ dh: Double) -> CGFloat { size.width * CGFloat((dh + 180) / 360) }
            func y(_ level: Double) -> CGFloat { size.height * CGFloat(min(max(level, 0), 100) / 100) }
            let featherH = max(2, point.hueWidth * point.softness / 100), featherC = max(1, 20 * point.softness / 100)
            let outer = CGRect(x: x(-point.hueWidth - featherH), y: y(point.chromaMin - featherC),
                               width: x(point.hueWidth + featherH) - x(-point.hueWidth - featherH),
                               height: y(point.chromaMax + featherC) - y(point.chromaMin - featherC))
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 5), with: .color(.white.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let inner = CGRect(x: x(-point.hueWidth), y: y(point.chromaMin),
                               width: x(point.hueWidth) - x(-point.hueWidth), height: max(2, y(point.chromaMax) - y(point.chromaMin)))
            ctx.fill(Path(roundedRect: inner, cornerRadius: 3), with: .color(.white.opacity(0.15)))
            ctx.stroke(Path(roundedRect: inner, cornerRadius: 3), with: .color(.white), lineWidth: 1.6)
            let dot = CGRect(x: x(0) - 5, y: y(point.chroma) - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: dot), with: .color(ColorAdjustColors.point(point)))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.black), lineWidth: 1.2)
            ctx.draw(Text("淡い").font(.caption2).foregroundColor(.black.opacity(0.6)), at: CGPoint(x: 16, y: 9))
            ctx.draw(Text("濃い").font(.caption2).foregroundColor(.white), at: CGPoint(x: 16, y: size.height - 9))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("効く範囲の図")
    }
}

// MARK: - プレビューでのスポイト

/// スポイトを使っている間、プレビューに重ねて押した位置を拾う。Esc でやめる
struct ColorPickLayer: View {
    @EnvironmentObject private var model: EditorModel
    @State private var began = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside != hovering else { return }
                    hovering = inside
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !began {
                            began = true
                            model.colorPickBegan(at: CGPoint(x: g.startLocation.x / max(geo.size.width, 1),
                                                             y: g.startLocation.y / max(geo.size.height, 1)))
                        }
                        model.colorPickDragged(dy: g.translation.height)
                    }
                    .onEnded { _ in
                        began = false
                        model.colorPickEnded()
                    })
        }
        .onExitCommand { model.colorPick = nil }
        // 十字のポインタのまま消えると、ほかの所でも十字が残るので戻す
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .help("色を拾う所を押してください(Esc でやめる)")
    }
}

// MARK: - 部品

/// スポイトのボタン(押している間は色が付く)
struct EyedropperButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eyedropper")
                .frame(width: 22, height: 20)
                .foregroundStyle(isOn ? Color.white : Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("スポイト")
    }
}

/// 色別補正のスライダー。溝を、その値で変わる先の色で塗れる。AdjustSlider と同じ並び(見出し・値・↶)。
/// ドラッグの始まりと終わりを知らせる(効く場所の表示のため。標準の Slider を包むと取れないので自分で描く)
struct ColorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let format: String
    var track: [Color]? = nil
    var onEditing: (Bool) -> Void = { _ in }
    @State private var dragging = false

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double, format: String,
         track: [Color]? = nil, onEditing: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; self._value = value; self.range = range; self.neutral = neutral
        self.format = format; self.track = track; self.onEditing = onEditing
    }

    private var isAtNeutral: Bool { abs(value - neutral) < 1e-9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit()
                    .foregroundStyle(isAtNeutral ? Color.secondary : Color.primary)
            }
            .font(.callout)
            HStack(spacing: 6) {
                SliderTrack(range: range, track: track, values: [value], neutral: neutral) { _, v in
                    value = v
                } onEditing: { editing in
                    onEditing(editing)
                }
                .frame(height: 18)
                Button { value = neutral } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption).frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(isAtNeutral)
                .help("\(title)を初期値に戻す")
            }
        }
    }
}

/// つまみが 2 つのスライダー(淡さの範囲)
struct ColorRangeSlider: View {
    let title: String
    @Binding var low: Double
    @Binding var high: Double
    var track: [Color]? = nil
    var onEditing: (Bool) -> Void = { _ in }

    init(_ title: String, low: Binding<Double>, high: Binding<Double>, track: [Color]? = nil,
         onEditing: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; self._low = low; self._high = high; self.track = track; self.onEditing = onEditing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(low.rounded())) 〜 \(Int(high.rounded()))").monospacedDigit()
            }
            .font(.callout)
            HStack(spacing: 6) {
                SliderTrack(range: 0...100, track: track, values: [low, high], neutral: nil) { knob, v in
                    if knob == 0 { low = min(v, high - 1) } else { high = max(v, low + 1) }
                } onEditing: { onEditing($0) }
                .frame(height: 18)
                Button { low = 0; high = 100 } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption).frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(low <= 0 && high >= 100)
                .help("\(title)の範囲を全部に戻す")
            }
        }
    }
}

/// スライダーの溝とつまみ(1 つか 2 つ)。押した所に一番近いつまみを動かす
struct SliderTrack: View {
    let range: ClosedRange<Double>
    let track: [Color]?
    let values: [Double]
    let neutral: Double?
    let onChange: (Int, Double) -> Void
    let onEditing: (Bool) -> Void
    @State private var active: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 14
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) -> CGFloat in 7 + w * CGFloat((v - range.lowerBound) / span) }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) }
                          ?? AnyShapeStyle(Color.primary.opacity(0.15)))
                    .frame(height: 4)
                    .padding(.horizontal, 7)
                if track == nil, let n = neutral, values.count == 1 {
                    let a = x(min(n, values[0])), b = x(max(n, values[0]))
                    Capsule().fill(Color.accentColor).frame(width: max(0, b - a), height: 4).offset(x: a)
                }
                if values.count == 2 {
                    Capsule().stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: max(0, x(values[1]) - x(values[0])), height: 6).offset(x: x(values[0]))
                }
                ForEach(values.indices, id: \.self) { k in
                    Circle().fill(Color.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .offset(x: x(values[k]) - 7)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let v = range.lowerBound + Double((g.location.x - 7) / max(w, 1)) * span
                    let clamped = min(max(v, range.lowerBound), range.upperBound)
                    if active == nil {
                        active = values.indices.min { abs(x(values[$0]) - g.location.x) < abs(x(values[$1]) - g.location.x) } ?? 0
                        onEditing(true)
                    }
                    onChange(active ?? 0, clamped.rounded())
                }
                .onEnded { _ in
                    active = nil
                    onEditing(false)
                })
        }
    }
}

/// 色別補正の画面で使う色(OKLCH から作る)
enum ColorAdjustColors {
    static func color(_ rgb: SIMD3<Double>) -> Color {
        Color(.sRGB, red: min(max(rgb.x, 0), 1), green: min(max(rgb.y, 0), 1), blue: min(max(rgb.z, 0), 1))
    }

    static func band(_ b: ColorBand) -> Color { color(b.representativeSRGB) }

    /// 色相 h(OKLCH の度)の鮮やかな色
    static func hue(_ h: Double) -> Color { oklch(l: 0.72, level: 60, hue: h) }

    static func oklch(l: Double, level: Double, hue: Double) -> Color {
        let c = level / 100 * ColorAdjustMath.chromaReference
        let r = hue * .pi / 180
        return color(ColorAdjustMath.srgb([l, c * cos(r), c * sin(r)]))
    }

    /// 拾った色の見本(拾った色の明るさは持っていないので、淡い色は明るく、濃い色は中くらいの明るさで描く)
    static func point(_ p: ColorPointAdjust) -> Color {
        oklch(l: p.chroma < 30 ? 0.9 : 0.68, level: p.chroma, hue: p.hue)
    }

    /// 帯の中心と、隣の帯の中心(効く範囲)
    static func span(_ b: ColorBand) -> (lo: Double, center: Double, hi: Double) {
        let c = ColorAdjustMath.bandCenters
        let i = c.firstIndex { $0.band == b } ?? 0
        var lo = c[(i + c.count - 1) % c.count].hue, hi = c[(i + 1) % c.count].hue
        let center = c[i].hue
        if lo > center { lo -= 360 }
        if hi < center { hi += 360 }
        return (lo, center, hi)
    }

    static func halfSpan(_ b: ColorBand) -> Double { let s = span(b); return (s.hi - s.lo) / 2 }

    static func hueTrack(_ b: ColorBand) -> [Color] {
        let center = span(b).center
        return stride(from: -ColorAdjustMath.maxHueShift, through: ColorAdjustMath.maxHueShift, by: 6).map { hue(center + $0) }
    }

    static func saturationTrack(_ b: ColorBand) -> [Color] {
        let h = span(b).center
        return [oklch(l: 0.7, level: 0, hue: h), oklch(l: 0.7, level: 70, hue: h)]
    }

    static func luminanceTrack(_ b: ColorBand) -> [Color] {
        let h = span(b).center
        return [oklch(l: 0.3, level: 40, hue: h), oklch(l: 0.65, level: 60, hue: h), oklch(l: 0.92, level: 25, hue: h)]
    }

    static func chromaTrack(_ p: ColorPointAdjust) -> [Color] {
        [oklch(l: 0.92, level: 2, hue: p.hue), oklch(l: 0.6, level: 90, hue: p.hue)]
    }

    static func addTrack(_ p: ColorPointAdjust) -> [Color] {
        [oklch(l: 0.93, level: 3, hue: p.hue), oklch(l: 0.82, level: 45, hue: p.hue)]
    }
}
