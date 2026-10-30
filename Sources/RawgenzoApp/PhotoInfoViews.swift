import SwiftUI
import RAWCore

// MARK: - ヒストグラム

/// 調整パネルの一番上のヒストグラム。R・G・B を重ねて描き、明るさを線で描く。左右の端に黒つぶれ・白飛びの割合
struct HistogramSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection("ヒストグラム", id: .histogram) {
            if let h = model.histogram {
                HistogramChart(histogram: h).frame(height: 80)
                HStack {
                    clipping("黒つぶれ", h.shadowClipping)
                    Spacer()
                    clipping("白飛び", h.highlightClipping)
                }
                .font(.caption2)
            } else {
                Color.clear.frame(height: 80)
            }
        }
    }

    private func clipping(_ title: String, _ v: Double) -> some View {
        Text("\(title) \(String(format: v < 0.001 ? "%.0f%%" : "%.1f%%", v * 100))")
            .monospacedDigit()
            .foregroundStyle(v >= 0.01 ? Color.orange : Color.secondary)
    }
}

struct HistogramChart: View {
    let histogram: Histogram

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.black.opacity(0.25)))
            // 縦は、端(0 と 255)を除いた区間の最大で合わせる(端に溜まった白飛び・黒つぶれで全体が潰れないように)
            let inner = { (a: [Double]) in a.dropFirst().dropLast().max() ?? 0 }
            let top = max(inner(histogram.red), inner(histogram.green), inner(histogram.blue), inner(histogram.luminance), 1e-9)
            func path(_ values: [Double], closed: Bool) -> Path {
                // 4 区間ずつまとめて、64 本の折れ線にする(細かすぎると線がざらつく)
                let group = 4, n = values.count / group
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<n {
                    let v = values[(i * group)..<(i * group + group)].reduce(0, +) / Double(group)
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(min(v / top, 1)))))
                }
                if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath() }
                return p
            }
            ctx.blendMode = .plusLighter
            for (values, color) in [(histogram.red, Color.red), (histogram.green, Color.green), (histogram.blue, Color.blue)] {
                ctx.fill(path(values, closed: true), with: .color(color.opacity(0.45)))
            }
            ctx.blendMode = .normal
            ctx.stroke(path(histogram.luminance, closed: false), with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("ヒストグラム")
    }
}

// MARK: - 撮影情報

/// 撮影情報(EXIF)。フォーカス位置の表示の切り替えもここに置く
struct ShootingInfoSection: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var prefs: AppConfigStore
    let photo: Photo

    var body: some View {
        let m = photo.metadata
        InspectorSection("撮影情報", id: .info) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("撮影日時", m.captureDate)
                row("カメラ", [m.make, m.model].compactMap { $0 }.joined(separator: " "))
                row("レンズ", m.lensModel)
                row("焦点距離", m.focalLength.map { f in
                    String(format: "%.0f mm", f) + (m.focalLength35mm.map { String(format: "(35mm 換算 %.0f mm)", $0) } ?? "")
                })
                row("露出", [ExifLabels.shutter(m.exposureTime).map { "\($0) 秒" }, m.fNumber.map { String(format: "F%.1f", $0) },
                            m.iso.map { "ISO \($0)" }].compactMap { $0 }.joined(separator: "  "))
                row("露出補正", m.exposureBias.map { String(format: "%+.1f EV", $0) })
                row("露出モード", ExifLabels.exposureProgram(m.exposureProgram))
                row("測光", ExifLabels.meteringMode(m.meteringMode))
                row("WB", ExifLabels.whiteBalance(m.whiteBalance).map {
                    "\($0)(撮影時 \(Int(photo.source.asShot.temperature.rounded())) K)"
                })
                row("フラッシュ", ExifLabels.flash(m.flash))
                row("画像", "\(Int(photo.source.nativeSize.width)) × \(Int(photo.source.nativeSize.height))")
            }
            .font(.callout)
            Toggle("フォーカス位置を表示", isOn: $prefs.config.showsFocusPoint)
                .disabled(m.focusPoint == nil)
                .help(m.focusPoint == nil ? "この写真にはフォーカス位置の記録がありません" : "撮影時にピントを合わせた位置をプレビューに出します(⌥⌘F)")
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - フォーカス位置の印

/// 撮影時のフォーカス位置に出す印(AF の枠のような四隅のかぎと、真ん中の点)。frame は写真が描かれている範囲
struct FocusMarker: View {
    let point: CGPoint
    let frame: CGRect

    var body: some View {
        Canvas { ctx, _ in
            let c = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
            let half: CGFloat = 18, arm: CGFloat = 8
            var corners = Path()
            for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let corner = CGPoint(x: c.x + sx * half, y: c.y + sy * half)
                corners.move(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
                corners.addLine(to: corner)
                corners.addLine(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
            }
            let dot = Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
            // 明るい所でも見えるよう、暗い縁取りの上に色の線を描く
            ctx.stroke(corners, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(corners, with: .color(Color(red: 0.4, green: 1, blue: 0.4)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ctx.fill(dot.strokedPath(StrokeStyle(lineWidth: 2)), with: .color(.black.opacity(0.55)))
            ctx.fill(dot, with: .color(Color(red: 0.4, green: 1, blue: 0.4)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 写真全体に重ねる(写真が描かれている範囲 = 重ねたビューの全体のとき。クロップ枠の調整中・スポイト中の表示)
struct FocusMarkerFill: View {
    let point: CGPoint

    var body: some View {
        GeometryReader { geo in
            FocusMarker(point: point, frame: CGRect(origin: .zero, size: geo.size))
        }
        .allowsHitTesting(false)
    }
}
