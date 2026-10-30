import SwiftUI
import AppKit
import RAWCore

/// トーンカーブの欄(docs/tone-curve-design.md の 1 段目)。輝度・R・G・B のカーブを点で作る
struct ToneCurveSection: View {
    @EnvironmentObject private var model: EditorModel
    @State private var channel: ToneCurveChannel = .luma
    /// 選んでいる点(入力・出力の欄と矢印キーの対象)
    @State private var selected: Int? = nil
    /// グラフの矢印キーの受け口(数値欄の return でも受け付けを戻すので、欄とグラフで共有する)
    @State private var keys = CurveKeyHandler()

    private var curve: ToneCurveSettings { model.settings.toneCurve ?? ToneCurveSettings() }
    private var points: [CurvePoint] { curve[channel] }

    var body: some View {
        InspectorSection("トーンカーブ", id: .curve) {
            Picker("", selection: $channel) {
                ForEach(ToneCurveChannel.allCases, id: \.self) { c in
                    // 変えたチャンネルには印
                    Text(ToneCurveSettings.isDefault(curve[c]) ? c.label : "\(c.label)•").tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .modifier(AgentHighlight(isOn: model.agentHighlights.contains("toneCurve")))
            .onChange(of: channel) { _ in selected = nil }
            // 写真を替えたら選択を外す(前の写真の番号が、次の写真の別の点を指さないように)
            .onChange(of: model.photo?.url) { _ in selected = nil }
            // AI の変更や取り消しで点が減り、選んでいた番号が無くなったら選択を外す
            .onChange(of: points) { p in if let i = selected, !p.indices.contains(i) { selected = nil } }

            if channel == .luma {
                Picker("", selection: presetBinding) {
                    ForEach(ToneCurvePreset.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    if ToneCurvePreset.matching(points) == nil {
                        Text("カスタム").tag(ToneCurvePreset?.none)
                    }
                }
                .labelsHidden()
            }

            ToneCurveGraph(channel: channel, curve: curve, selected: $selected,
                           histogram: model.curveInputHistogram, keys: keys) { new in
                // 変わらないドラッグでは書かない(書くたびに描き直しと保存の予約が走る)
                if ToneCurveSettings.normalized(new) != points { update { $0[channel] = new } }
            }
            .aspectRatio(1, contentMode: .fit)

            pointFields

            if channel == .luma {
                AdjustSlider("彩度の連動", value: Binding(
                    get: { curve.saturationLink },
                    set: { v in update { $0.saturationLink = v } }),
                    range: 0...1, neutral: 0, format: "%.0f", displayScale: 100)
                Text("0 は明るさだけを変え、色合いと彩度を保ちます。100 は R・G・B それぞれに同じカーブを掛け、S 字なら彩度も上がります")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(channel.label) のカーブは色を直接変えます。上げると\(raiseColor)、下げると\(lowerColor)寄りになります")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("クリックで点を足す・ドラッグで動かす・グラフの外へドラッグで消す")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("このチャンネルを戻す") {
                    selected = nil
                    update { $0[channel] = ToneCurveSettings.identity }
                }
                .disabled(ToneCurveSettings.isDefault(points))
                Spacer()
                Button("全部を戻す") {
                    selected = nil
                    model.settings.toneCurve = nil
                }
                .disabled(model.settings.toneCurve == nil)
            }
            .controlSize(.small)
        }
    }

    private var raiseColor: String {
        switch channel { case .red: return "赤"; case .green: return "緑"; case .blue: return "青"; case .luma: return "" }
    }

    private var lowerColor: String {
        switch channel { case .red: return "シアン"; case .green: return "マゼンタ"; case .blue: return "黄"; case .luma: return "" }
    }

    /// 選んだ点の入力・出力(0〜255)と点の数
    private var pointFields: some View {
        HStack(spacing: 6) {
            Text("入力").foregroundStyle(.secondary)
            CurveValueField(value: selectedValue(\.x), target: editTarget, enabled: selectedIsInner,
                            commit: { setPoint($1, x: $0) }, onReturn: { keys.isActive = true })
            Text("出力").foregroundStyle(.secondary)
            CurveValueField(value: selectedValue(\.y), target: editTarget, enabled: selected != nil,
                            commit: { setPoint($1, y: $0) }, onReturn: { keys.isActive = true })
            Spacer()
            Text("\(points.count) / \(ToneCurveSettings.maxPoints) 点")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }

    private var selectedIsInner: Bool {
        guard let i = selected else { return false }
        return i > 0 && i < points.count - 1
    }

    private func selectedValue(_ key: KeyPath<CurvePoint, Double>) -> Int? {
        selected.flatMap { value(points, at: $0, key) }
    }

    private func value(_ points: [CurvePoint], at i: Int, _ key: KeyPath<CurvePoint, Double>) -> Int? {
        guard points.indices.contains(i) else { return nil }
        return Int((points[i][keyPath: key] * 255).rounded())
    }

    /// 数値欄に打ち始めたときの、写真・チャンネル・点
    private var editTarget: CurveEditTarget? {
        selected.map { CurveEditTarget(photo: model.photo?.url, channel: channel, index: $0) }
    }

    /// 数値欄で確定した値を、打ち始めたときの点に当てる(確定する前に別の点・チャンネルを選んでも、そちらに当てない)。
    /// 写真が替わっていたら捨てる
    private func setPoint(_ t: CurveEditTarget, x: Int? = nil, y: Int? = nil) {
        guard t.photo == model.photo?.url else { return }
        var p = curve[t.channel]
        let i = t.index
        guard p.indices.contains(i) else { return }
        // 表示と同じ値なら書かない(0〜255 に丸めた値で書き直すと、プリセットの点がずれて「カスタム」になる)
        let x = x == value(p, at: i, \.x) ? nil : x
        let y = y == value(p, at: i, \.y) ? nil : y
        guard x != nil || y != nil else { return }
        if let x, i > 0, i < p.count - 1 {
            let lo = p[i - 1].x + ToneCurveSettings.minGap, hi = p[i + 1].x - ToneCurveSettings.minGap
            p[i].x = min(max(Double(x) / 255, lo), hi)
        }
        if let y { p[i].y = min(max(Double(y) / 255, 0), 1) }
        update { $0[t.channel] = p }
    }

    private var presetBinding: Binding<ToneCurvePreset?> {
        Binding(
            get: { ToneCurvePreset.matching(points) },
            set: { preset in
                guard let preset else { return }
                selected = nil
                update { $0.luma = preset.points }
            })
    }

    /// カーブを変える(無ければ作る)。何も設定していなければ nil に戻す(サイドカーに空の項目を残さない)。
    /// 判断は isEmpty(点を足していない)で、isNeutral(画像を変えない)ではない。斜めの線の上に足した点を消さないため
    private func update(_ change: (inout ToneCurveSettings) -> Void) {
        var c = curve
        change(&c)
        model.settings.toneCurve = c.isEmpty ? nil : c
    }
}

/// 数値欄に打ち始めたときの、写真・チャンネル・点
struct CurveEditTarget: Equatable {
    var photo: URL?
    var channel: ToneCurveChannel
    var index: Int
}

/// 0〜255 の数の欄。
/// - 表示は写しを持たずにその場で決める: 打っている間(フォーカスがある間)は打ちかけの文字、それ以外は今の点の値。
///   最初の版は表示の文字を写しとして持ち、点の値と同期させていたが、フォーカス・打ちかけの印・欄が送り返す文字の扱いを
///   継ぎ足すたびに同期が壊れ、古い値が残る・空のままになる、が続いた(2026-10-30)
/// - 打ち始めたとき(フォーカスを得たとき)に、写真・チャンネル・点を覚える。確定はその点に当てる
/// - 確定は return か、欄を離れたとき。return で欄を離れ、矢印キーをグラフに戻す(onReturn)。Esc は打ちかけを捨てる
private struct CurveValueField: View {
    let value: Int?
    let target: CurveEditTarget?
    let enabled: Bool
    let commit: (Int, CurveEditTarget) -> Void
    let onReturn: () -> Void
    @State private var draft = ""
    /// 打ち始めたときの点と、そのときの表示(変えずに離れたら当てない)
    @State private var editing: (target: CurveEditTarget, original: String)?
    @FocusState private var focused: Bool

    private var shown: String { value.map(String.init) ?? "" }

    var body: some View {
        // 打った文字を受け取るのはフォーカスがある間だけ。フォーカスが外れると表示が今の点の値に替わり、欄がそれを送り返してくる。
        // 受け取ると、打ちかけが別の点の値で上書きされ、確定でそれが当たった(50 と打ってほかの点をクリックしたら、
        // 新しく選んだ点の出力 0 が元の点に当たった。2026-10-30、オーナーの確認)
        TextField("", text: Binding(get: { focused ? draft : shown }, set: { if focused { draft = $0 } }))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 48)
            .disabled(!enabled || value == nil)
            .focused($focused)
            .onChange(of: focused) { f in
                if f {
                    draft = shown
                    editing = target.map { ($0, shown) }
                } else {
                    finish()
                }
            }
            .onSubmit {
                finish()
                // FocusState だけで欄の編集が終わるかは確かめていないので、AppKit にも外させる
                // (残ると矢印キーが欄のカーソルに取られる)
                focused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
                onReturn()
            }
            .onExitCommand {
                editing = nil
                focused = false
            }
    }

    /// 打ちかけを当てる(変えていなければ何もしない)。一度当てたら、続けて呼ばれても当てない
    private func finish() {
        guard let e = editing else { return }
        editing = nil
        let typed = draft.trimmingCharacters(in: .whitespaces)
        guard typed != e.original, let v = Int(typed) else { return }
        commit(min(max(v, 0), 255), e.target)
    }
}

/// カーブのグラフ。後ろにカーブを掛ける前のヒストグラム、ほかのチャンネルのカーブを薄く描く
struct ToneCurveGraph: View {
    let channel: ToneCurveChannel
    let curve: ToneCurveSettings
    @Binding var selected: Int?
    let histogram: Histogram?
    let keys: CurveKeyHandler
    let onChange: ([CurvePoint]) -> Void

    /// ドラッグ中の点(ドラッグを始めたときの点の並びと、動かしている点)
    @State private var drag: (start: [CurvePoint], index: Int)?

    /// 点をつかめる距離(pt)と、外へ出すと点が消える距離(pt)
    private let hitRadius: CGFloat = 8
    private let removeDistance: CGFloat = 24

    private var points: [CurvePoint] { curve[channel] }

    var body: some View {
        // キーの受け口は、今のカーブ・選んだ点で動くよう描くたびに差し替える
        let _ = keys.nudge = nudge
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in draw(&ctx, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in dragChanged(g, size) }
                    .onEnded { _ in drag = nil })
        }
        .onAppear { keys.install() }
        .onDisappear { keys.remove() }
        .accessibilityLabel("トーンカーブ(\(channel.label))")
    }

    // MARK: 座標

    private func toView(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func toCurve(_ v: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(min(max(v.x / size.width, 0), 1), min(max(1 - v.y / size.height, 0), 1))
    }

    // MARK: 操作

    private func dragChanged(_ g: DragGesture.Value, _ size: CGSize) {
        if drag == nil {
            // 数値欄の入力を確定してフォーカスを外し、矢印キーをグラフで受ける
            NSApp.keyWindow?.makeFirstResponder(nil)
            keys.isActive = true
            // つかむ点を決める。近くに点が無ければ、クリックした所に点を足す(オーナーの選択。カーブの上に足す案もあった)
            let p = points
            let near = p.indices.min { distance(toView(p[$0], size), g.startLocation) < distance(toView(p[$1], size), g.startLocation) }
            if let near, distance(toView(p[near], size), g.startLocation) <= hitRadius {
                drag = (p, near)
                selected = near
            } else if p.count < ToneCurveSettings.maxPoints {
                let c = toCurve(g.startLocation, size)
                let x = c.x
                guard let i = p.firstIndex(where: { $0.x > x }), i > 0,
                      x - p[i - 1].x >= ToneCurveSettings.minGap, p[i].x - x >= ToneCurveSettings.minGap else { return }
                var q = p
                q.insert(CurvePoint(x, c.y), at: i)
                drag = (q, i)
                selected = i
                onChange(q)
            } else {
                return
            }
        }
        guard let (start, i) = drag else { return }
        let loc = g.location
        let isEnd = i == 0 || i == start.count - 1
        let outside = loc.x < -removeDistance || loc.x > size.width + removeDistance
            || loc.y < -removeDistance || loc.y > size.height + removeDistance
        if outside, !isEnd {
            // グラフの外へ出したら消す(戻せば元に戻る)
            var q = start
            q.remove(at: i)
            selected = nil
            onChange(q)
            return
        }
        // つかんだ所からの移動量だけ動かす(クリックした位置へ点を移さない。クリックだけなら点は動かない)
        var q = start
        let dx = Double(g.translation.width / size.width), dy = Double(-g.translation.height / size.height)
        if !isEnd {
            q[i].x = min(max(start[i].x + dx, start[i - 1].x + ToneCurveSettings.minGap), start[i + 1].x - ToneCurveSettings.minGap)
        }
        q[i].y = min(max(start[i].y + dy, 0), 1)
        selected = i
        onChange(q)
    }

    /// 矢印キーで選んだ点を 1 動かす(⇧ で 10)。端の点は上下だけ。動かす点が無ければ false(キーを渡す)
    private func nudge(_ direction: MoveCommandDirection, _ shift: Bool) -> Bool {
        guard let i = selected, points.indices.contains(i) else { return false }
        let step = (shift ? 10.0 : 1.0) / 255
        var q = points
        switch direction {
        case .up: q[i].y = min(q[i].y + step, 1)
        case .down: q[i].y = max(q[i].y - step, 0)
        case .left, .right:
            guard i > 0, i < q.count - 1 else { return true }
            let x = q[i].x + (direction == .left ? -step : step)
            q[i].x = min(max(x, q[i - 1].x + ToneCurveSettings.minGap), q[i + 1].x - ToneCurveSettings.minGap)
        @unknown default: return false
        }
        onChange(q)
        return true
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: 描画

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.25)))

        // ヒストグラム(4 区間ずつまとめて 64 本。端の区間は白飛び・黒つぶれで高くなるので、縦の最大から外す)
        if let h = histogram {
            let values: [Double]
            switch channel {
            case .luma: values = h.luminance
            case .red: values = h.red
            case .green: values = h.green
            case .blue: values = h.blue
            }
            let group = 4, n = values.count / group
            let grouped = (0..<n).map { i in values[(i * group)..<(i * group + group)].reduce(0, +) / Double(group) }
            let top = max(grouped.dropFirst().dropLast().max() ?? 0, 1e-9)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in grouped.enumerated() {
                p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1),
                                      y: size.height * (1 - 0.9 * CGFloat(min(v / top, 1)))))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            ctx.fill(p, with: .color(color(channel).opacity(0.22)))
        }

        // 4 分割の目盛りと、変えていない線
        var grid = Path()
        for q in [0.25, 0.5, 0.75] {
            grid.move(to: CGPoint(x: size.width * q, y: 0)); grid.addLine(to: CGPoint(x: size.width * q, y: size.height))
            grid.move(to: CGPoint(x: 0, y: size.height * q)); grid.addLine(to: CGPoint(x: size.width, y: size.height * q))
        }
        ctx.stroke(grid, with: .color(.primary.opacity(0.1)), lineWidth: 0.5)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        ctx.stroke(diagonal, with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))

        // ほかのチャンネルのカーブ(変えたものだけ、薄く)
        for c in ToneCurveChannel.allCases where c != channel && !ToneCurveSettings.isIdentity(curve[c]) {
            ctx.stroke(curvePath(curve[c], size), with: .color(color(c).opacity(0.35)), lineWidth: 1)
        }
        ctx.stroke(curvePath(points, size), with: .color(color(channel)), lineWidth: 1.6)

        for (i, p) in points.enumerated() {
            let v = toView(p, size)
            if i == selected {
                ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 6.5, y: v.y - 6.5, width: 13, height: 13)),
                           with: .color(.primary), lineWidth: 1.4)
            }
            let dot = Path(ellipseIn: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7))
            ctx.fill(dot, with: .color(.white))
            ctx.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 0.8)
        }
    }

    private func curvePath(_ points: [CurvePoint], _ size: CGSize) -> Path {
        let f = ToneCurveFunction(points)
        let n = max(Int(size.width / 2), 32)
        var p = Path()
        for j in 0...n {
            let x = Double(j) / Double(n)
            let pt = toView(CurvePoint(x, min(max(f(x), 0), 1)), size)
            if j == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func color(_ c: ToneCurveChannel) -> Color {
        switch c {
        case .luma: return .primary
        case .red: return Color(red: 1, green: 0.33, blue: 0.33)
        case .green: return Color(red: 0.33, green: 0.85, blue: 0.4)
        case .blue: return Color(red: 0.35, green: 0.55, blue: 1)
        }
    }
}

/// グラフの矢印キー。グラフをクリック(または数値欄で return)してから、ほかの場所をクリックするまでの間だけ受ける
/// (サムネイル一覧などの矢印キーを取らないため。文字の入力中も受けない)。
/// SwiftUI のフォーカス(focusable・onMoveCommand)では、数値欄がフォーカスを持ったままになり、
/// 矢印キーが数値欄のカーソルを動かした(2026-10-30、オーナーの確認)ので、キーを直接受ける
final class CurveKeyHandler {
    var isActive = false
    var nudge: (MoveCommandDirection, Bool) -> Bool = { _, _ in false }
    private var monitors: [Any] = []

    func install() {
        guard monitors.isEmpty else { return }
        // クリックのたびにいったん外す(グラフのクリックなら、この後のドラッグの処理でまた受ける)
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            self?.isActive = false
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.isActive, !(e.window?.firstResponder is NSText) else { return e }
            let direction: MoveCommandDirection
            switch e.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: return e
            }
            return self.nudge(direction, e.modifierFlags.contains(.shift)) ? nil : e
        }) { monitors.append(m) }
    }

    func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isActive = false
    }
}
