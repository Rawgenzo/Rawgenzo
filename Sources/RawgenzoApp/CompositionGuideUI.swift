import SwiftUI
import RAWCore

/// 構図ガイドの表示設定。1つのJSON文字列として UserDefaults に保存する。
struct GuideDisplay: Equatable, Codable, RawRepresentable {
    var isVisible = false
    /// 表示するガイドのID(複数可)
    var enabled: Set<String> = ["thirds"]
    var flipHorizontal = false
    var flipVertical = false
    var flipTriangle = false
    /// 不透明度 0.2...1
    var opacity = 0.75
    var lineWidth = 1.0

    static let storageKey = "compositionGuides"

    init() {}

    var options: GuideOptions {
        GuideOptions(flipHorizontal: flipHorizontal, flipVertical: flipVertical,
                     flipTriangle: flipTriangle)
    }

    var hasAnythingToDraw: Bool { isVisible && !enabled.isEmpty }

    func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    mutating func set(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
    }

    /// 螺旋の中心を 右下 → 左下 → 左上 → 右上 の順に回す
    mutating func rotateSpiral() {
        switch (flipHorizontal, flipVertical) {
        case (false, false): flipHorizontal = true
        case (true, false): flipVertical = true
        case (true, true): flipHorizontal = false
        case (false, true): flipVertical = false
        }
    }

    // MARK: RawRepresentable(@AppStorage 用)
    // Codable と RawRepresentable を両方持つと標準の実装が rawValue 経由になり無限再帰するため、
    // Codable は下で明示的に実装している。

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let value = try? JSONDecoder().decode(GuideDisplay.self, from: data) else { return nil }
        self = value
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible, enabled, flipHorizontal, flipVertical, flipTriangle, opacity, lineWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuideDisplay()
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? d.isVisible
        enabled = try c.decodeIfPresent(Set<String>.self, forKey: .enabled) ?? d.enabled
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? d.flipHorizontal
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? d.flipVertical
        flipTriangle = try c.decodeIfPresent(Bool.self, forKey: .flipTriangle) ?? d.flipTriangle
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? d.lineWidth
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(flipHorizontal, forKey: .flipHorizontal)
        try c.encode(flipVertical, forKey: .flipVertical)
        try c.encode(flipTriangle, forKey: .flipTriangle)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(lineWidth, forKey: .lineWidth)
    }
}

/// ガイドごとの色。重ねて表示しても見分けられるようにする。
enum GuidePalette {
    static func color(for id: String) -> Color {
        switch id {
        case "halves": return Color(red: 0.92, green: 0.92, blue: 0.92)
        case "thirds": return .white
        case "golden": return Color(red: 1.00, green: 0.80, blue: 0.30)
        case "silver": return Color(red: 0.62, green: 0.84, blue: 1.00)
        case "diagonal": return Color(red: 0.85, green: 0.65, blue: 1.00)
        case "triangle": return Color(red: 0.65, green: 0.94, blue: 0.48)
        case "spiral": return Color(red: 1.00, green: 0.55, blue: 0.38)
        default: return Color(red: 0.75, green: 1.00, blue: 0.70)   // 後から追加したガイド
        }
    }
}

/// ガイドの描画。タッチやドラッグは下のビューに通す。
struct GuideOverlay: View {
    let display: GuideDisplay
    /// 描画枠の 幅/高さ
    let aspect: Double
    /// ガイドを描く枠(このビューの座標)。nil = ビュー全体。
    /// 拡大表示ではビューより大きな枠になるが、Canvas はビューの大きさのまま枠の位置に描く
    /// (Canvas 自体を枠の大きさにすると、400% などで巨大な描画領域になるため)
    var imageFrame: CGRect? = nil

    var body: some View {
        Canvas { context, size in
            let r = imageFrame ?? CGRect(origin: .zero, size: size)
            for guide in CompositionGuides.all where display.isEnabled(guide.id) {
                let color = GuidePalette.color(for: guide.id)
                for p in guide.paths(aspect: aspect, options: display.options) {
                    var path = Path()
                    path.addLines(p.points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })

                    let fine = p.style == .fine
                    let width = display.lineWidth * (fine ? 0.6 : 1)
                    let dash: [CGFloat] = p.style == .dashed ? [6, 4] : []
                    let alpha = display.opacity * (fine ? 0.6 : 1)

                    // 明るい写真の上でも見えるよう、下に薄い影を敷く
                    context.stroke(path, with: .color(.black.opacity(0.35 * alpha)),
                                   style: StrokeStyle(lineWidth: width + 1.2, lineCap: .round,
                                                      lineJoin: .round, dash: dash))
                    context.stroke(path, with: .color(color.opacity(alpha)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                      lineJoin: .round, dash: dash))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// メニューバーとツールバーで共通の項目
struct GuideMenuItems: View {
    @Binding var display: GuideDisplay
    /// キーボードショートカットはメニューバー側だけに付ける(二重登録で打ち消し合わないように)
    var withShortcuts = false

    var body: some View {
        Toggle("構図ガイドを表示", isOn: $display.isVisible)
            .keyboardShortcut(withShortcuts ? KeyboardShortcut("g", modifiers: [.command, .option]) : nil)
        Divider()
        ForEach(CompositionGuides.all, id: \.id) { guide in
            Toggle(guide.displayName, isOn: Binding(
                get: { display.isEnabled(guide.id) },
                set: { on in
                    display.set(guide.id, on)
                    if on { display.isVisible = true }   // 選んだら表示もオンにする
                }))
        }
        Divider()
        Toggle("黄金三角形を反転", isOn: $display.flipTriangle)
        Divider()
        Toggle("螺旋を左右反転", isOn: $display.flipHorizontal)
        Toggle("螺旋を上下反転", isOn: $display.flipVertical)
        Button("螺旋の向きを回す") {
            display.rotateSpiral()
            display.set("spiral", true)
            display.isVisible = true
        }
        .keyboardShortcut(withShortcuts ? KeyboardShortcut("g", modifiers: [.command, .option, .shift]) : nil)
    }
}

/// 設定ウインドウの「構図ガイド」セクション
struct GuideSettingsSection: View {
    @Binding var display: GuideDisplay

    var body: some View {
        Section("構図ガイド") {
            Toggle("構図ガイドを表示", isOn: $display.isVisible)
            ForEach(CompositionGuides.all, id: \.id) { guide in
                Toggle(isOn: Binding(
                    get: { display.isEnabled(guide.id) },
                    set: { display.set(guide.id, $0) })) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(GuidePalette.color(for: guide.id))
                            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                            .frame(width: 10, height: 10)
                        Text(guide.displayName)
                    }
                }
            }
            Toggle("黄金三角形を反転", isOn: $display.flipTriangle)
                .disabled(!display.isEnabled("triangle"))
            Toggle("螺旋を左右反転", isOn: $display.flipHorizontal)
                .disabled(!display.isEnabled("spiral"))
            Toggle("螺旋を上下反転", isOn: $display.flipVertical)
                .disabled(!display.isEnabled("spiral"))
            HStack {
                Text("不透明度")
                Slider(value: $display.opacity, in: 0.2...1)
            }
            Picker("線の太さ", selection: $display.lineWidth) {
                Text("細い").tag(0.75)
                Text("標準").tag(1.0)
                Text("太い").tag(1.75)
            }
        }
    }
}
