import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 写真の傾きを推定するための手がかり(長い直線と、人物の目・肩の線)を見つける。
/// 返す角度はどれも「CropSettings.angle に入れると、その線が水平(または垂直)になる値」(度。正 = 時計回りに回す)。
///
/// どの線を基準にするかは決めない。2026-10-20 の試験で分かったこと:
/// - 水平の基準は 1 つではない。同じ写真で棚の線を基準にすると −0.8°、二人の並びや体の傾きを基準にすると +1.2° で、
///   オーナーは人物写真として +1.2° を選んだ
/// - 画素ごとのエッジの向きを数える最初の試作は、合成画像では ±0.15° で当てたが、本物の写真では雲・水面・葉や、
///   奥へ伸びる手すり(遠近で斜めに見える線)に引っぱられ、水平と垂直の推定が最大 11° 食い違った
/// そこで、長い直線を番号付きの候補として返し、本当に水平・垂直な線(建物の縁・柱・水平線)を選ぶのは
/// 画像を見た AI に任せる。角度の精密な計算だけをここで行う。
public enum TiltEstimator {
    /// 見つけた直線 1 本
    public struct Segment: Equatable, Sendable {
        public enum Axis: String, Sendable { case horizontal, vertical }
        /// 長い順の番号(1 から)
        public var id: Int
        public var axis: Axis
        /// この線が水平(垂直)になる傾き補正の角度
        public var angle: Double
        /// 長さ(画像の長辺に対する比率)
        public var length: Double
        /// 端の点(画像に対する比率、左上原点)
        public var from: CGPoint
        public var to: CGPoint
    }

    /// 人物の目を結ぶ線・肩を結ぶ線の 1 本
    public struct SubjectMark: Equatable, Sendable {
        public enum Kind: String, Sendable { case eyes, shoulders }
        public var kind: Kind
        /// その線が水平になる傾き補正の角度
        public var angle: Double
        /// 線の端(画像に対する比率、左上原点)
        public var from: CGPoint
        public var to: CGPoint
        public var center: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
    }

    /// 探す範囲(度)。水平・垂直からこれより大きく傾いた線は、手がかりにしない
    public static let searchRange = 10.0
    /// 線分として数える最短の長さ(画像の長辺に対する比率)
    public static let minLength = 0.04
    /// 返す線分の数の上限(水平・垂直それぞれ。片方の向きだけで埋まらないように)
    public static let maxSegmentsPerAxis = 10

    /// 複数の線分の角度を、長さで重みを付けて平均する(AI が選んだ線から角度を出す)
    public static func combinedAngle(_ segments: [Segment]) -> (angle: Double, spread: Double)? {
        let total = segments.map(\.length).reduce(0, +)
        guard total > 0 else { return nil }
        let mean = segments.map { $0.angle * $0.length }.reduce(0, +) / total
        let variance = segments.map { $0.length * ($0.angle - mean) * ($0.angle - mean) }.reduce(0, +) / total
        return (mean, variance.squareRoot())
    }

    // MARK: - 直線

    /// 長い直線を見つける。水平・垂直から ±searchRange 以内のものだけを、向きごとに長い順で maxSegmentsPerAxis 本まで
    public static func segments(in image: CIImage, context: CIContext = CIContext()) -> [Segment] {
        guard let gray = Gray(image, context: context) else { return [] }
        let (w, h) = (gray.width, gray.height)
        let n = w * h
        var jxx = [Float](repeating: 0, count: n), jxy = jxx, jyy = jxx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let p = { (dx: Int, dy: Int) in gray.v[(y + dy) * w + x + dx] }
                let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                // 画素の行は上から下なので、上向きを正にするため符号を反転
                let gy = -((p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1)))
                let i = y * w + x
                jxx[i] = gx * gx; jxy[i] = gx * gy; jyy[i] = gy * gy
            }
        }
        // 構造テンソルを 3×3 で平均(線の向きを安定させる。広げすぎると近くの線がにじんで混ざる)
        jxx = boxBlur(jxx, w, h, radius: 1); jxy = boxBlur(jxy, w, h, radius: 1); jyy = boxBlur(jyy, w, h, radius: 1)

        // 画素ごとの線の向き(上向き y の数学の向き。反時計回りが正。−90...90)と強さ
        let border = 3
        var orientation = [Float](repeating: 0, count: n)
        var strength = [Float](repeating: 0, count: n)
        var energies: [Float] = []
        energies.reserveCapacity(n / 2)
        for y in border..<(h - border) {
            for x in border..<(w - border) {
                let i = y * w + x
                let a = Double(jxx[i]), b = Double(jxy[i]), c = Double(jyy[i])
                let energy = a + c
                guard energy > 1e-6 else { continue }
                let coherence = ((a - c) * (a - c) + 4 * b * b).squareRoot() / energy
                guard coherence > 0.5 else { continue }
                orientation[i] = Float(normalize(0.5 * atan2(2 * b, a - c) * 180 / .pi + 90))
                strength[i] = Float(energy)
                energies.append(Float(energy))
            }
        }
        guard energies.count > 100 else { return [] }
        energies.sort()
        let threshold = max(energies[Int(Double(energies.count) * 0.7)], 0.02)

        // 強い画素から順に、向きのそろった隣の画素をつなげて線分の候補にする(LSD の領域成長を簡単にしたもの)
        var seeds: [Int] = []
        for i in 0..<n where strength[i] >= threshold { seeds.append(i) }
        seeds.sort { strength[$0] > strength[$1] }
        var used = [Bool](repeating: false, count: n)
        let tolerance = 6.0
        let longEdge = Double(max(w, h))
        var regions: [[Int]] = []
        for seed in seeds where !used[seed] {
            used[seed] = true
            var region = [seed]
            var queue = [seed], head = 0
            // 領域の向きは倍角のベクトルの和で持つ(180° 回ると同じ向き)
            var sx = cos(2 * Double(orientation[seed]) * .pi / 180), sy = sin(2 * Double(orientation[seed]) * .pi / 180)
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                let mean = 0.5 * atan2(sy, sx) * 180 / .pi
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= border, ny >= border, nx < w - border, ny < h - border else { continue }
                        let j = ny * w + nx
                        guard !used[j], strength[j] >= threshold * 0.5 else { continue }
                        guard abs(normalize(Double(orientation[j]) - mean)) < tolerance else { continue }
                        used[j] = true
                        region.append(j); queue.append(j)
                        sx += cos(2 * Double(orientation[j]) * .pi / 180); sy += sin(2 * Double(orientation[j]) * .pi / 180)
                    }
                }
            }
            // 交わる線のところで向きが変わって途切れるので、ここでは短いものも残し、後でつなぐ
            if Double(region.count) >= longEdge * minLength / 2 { regions.append(region) }
        }
        typealias Fitted = (axis: Segment.Axis, angle: Double, length: Double, from: CGPoint, to: CGPoint)
        var pieces: [(fit: Fitted, region: [Int])] = regions.compactMap { r in
            fit(r, width: w, height: h, longEdge: longEdge, minLength: minLength / 2).map { ($0, r) }
        }
        // 同じ直線のかけら(向きがほぼ同じで、同じ線の上にあり、間が近い)をつないで当てはめ直す
        var merged = true
        while merged {
            merged = false
            outer: for i in pieces.indices {
                for j in pieces.indices where j > i && sameLine(pieces[i].fit, pieces[j].fit, width: w, height: h) {
                    let union = pieces[i].region + pieces[j].region
                    if let f = fit(union, width: w, height: h, longEdge: longEdge, minLength: minLength / 2) {
                        pieces[i] = (f, union)
                        pieces.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        // 向きごとに長い順。同じ長さなら位置で並べて、呼ぶたびに番号が変わらないようにする
        func order(_ a: Fitted, _ b: Fitted) -> Bool { (a.length, a.from.y, a.from.x) > (b.length, b.from.y, b.from.x) }
        let long = pieces.map(\.fit).filter { $0.length >= minLength }
        let kept = (long.filter { $0.axis == .horizontal }.sorted(by: order).prefix(maxSegmentsPerAxis)
            + long.filter { $0.axis == .vertical }.sorted(by: order).prefix(maxSegmentsPerAxis)).sorted(by: order)
        return kept.enumerated().map { k, s in
            Segment(id: k + 1, axis: s.axis, angle: s.angle, length: s.length, from: s.from, to: s.to)
        }
    }

    /// 2 本が同じ直線のかけらか: 向きが 1° 以内、互いの端が相手の直線から 1.5 ピクセル以内、間が画像の長辺の 5% 以内
    static func sameLine(_ a: (axis: Segment.Axis, angle: Double, length: Double, from: CGPoint, to: CGPoint),
                         _ b: (axis: Segment.Axis, angle: Double, length: Double, from: CGPoint, to: CGPoint),
                         width w: Int, height h: Int) -> Bool {
        guard a.axis == b.axis, abs(a.angle - b.angle) < 1 else { return false }
        func px(_ p: CGPoint) -> (Double, Double) { (Double(p.x) * Double(w), Double(p.y) * Double(h)) }
        let (a0, a1, b0, b1) = (px(a.from), px(a.to), px(b.from), px(b.to))
        let len = hypot(a1.0 - a0.0, a1.1 - a0.1)
        guard len > 0 else { return false }
        let (ux, uy) = ((a1.0 - a0.0) / len, (a1.1 - a0.1) / len)
        func distance(_ p: (Double, Double)) -> Double { abs(-(p.0 - a0.0) * uy + (p.1 - a0.1) * ux) }
        guard distance(b0) < 1.5, distance(b1) < 1.5 else { return false }
        // 方向に沿った位置で、間のすき間を測る
        func t(_ p: (Double, Double)) -> Double { (p.0 - a0.0) * ux + (p.1 - a0.1) * uy }
        let (bl, bh) = (min(t(b0), t(b1)), max(t(b0), t(b1)))
        let gap = max(0, max(bl - len, -bh))
        return gap < 0.05 * Double(max(w, h))
    }

    /// 画素の集まりに直線を当てはめる(主成分分析)。細長くないもの・短いもの・水平垂直から遠いものは nil
    static func fit(_ region: [Int], width w: Int, height h: Int, longEdge: Double, minLength: Double)
        -> (axis: Segment.Axis, angle: Double, length: Double, from: CGPoint, to: CGPoint)? {
        var mx = 0.0, my = 0.0
        for i in region { mx += Double(i % w); my += Double(h - 1 - i / w) }
        let count = Double(region.count)
        mx /= count; my /= count
        var cxx = 0.0, cxy = 0.0, cyy = 0.0
        for i in region {
            let dx = Double(i % w) - mx, dy = Double(h - 1 - i / w) - my
            cxx += dx * dx; cxy += dx * dy; cyy += dy * dy
        }
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)   // 主な向き(上向き y。反時計回りが正)
        let (ux, uy) = (cos(theta), sin(theta))
        var lo = Double.infinity, hi = -Double.infinity, across = 0.0
        for i in region {
            let dx = Double(i % w) - mx, dy = Double(h - 1 - i / w) - my
            let t = dx * ux + dy * uy
            lo = min(lo, t); hi = max(hi, t)
            let d = -dx * uy + dy * ux
            across += d * d
        }
        let length = hi - lo
        let thickness = (across / count).squareRoot()
        guard length >= longEdge * minLength, length > 8 * max(thickness, 0.5) else { return nil }
        let deg = normalize(theta * 180 / .pi)
        let axis: Segment.Axis
        let angle: Double
        if abs(deg) < searchRange {
            // 右上がりの線(反時計回りにずれている)は、時計回りに回すと水平になる
            axis = .horizontal; angle = deg
        } else if abs(normalize(deg - 90)) < searchRange {
            axis = .vertical; angle = normalize(deg - 90)
        } else {
            return nil
        }
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: (mx + t * ux) / Double(w), y: 1 - (my + t * uy) / Double(h))
        }
        return (axis, angle, length / longEdge, point(lo), point(hi))
    }

    /// (−90, 90] に収める
    static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 180)
        if d > 90 { d -= 180 }
        if d <= -90 { d += 180 }
        return d
    }

    static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count), out = tmp
        let norm = Float(2 * r + 1)
        for y in 0..<h {
            var s: Float = 0
            for x in -r...r { s += src[y * w + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                tmp[y * w + x] = s / norm
                s += src[y * w + min(x + r + 1, w - 1)] - src[y * w + max(x - r, 0)]
            }
        }
        for x in 0..<w {
            var s: Float = 0
            for y in -r...r { s += tmp[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = s / norm
                s += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x]
            }
        }
        return out
    }

    /// 輝度の画素(行は上から下)
    struct Gray {
        let width: Int, height: Int
        let v: [Float]

        init?(_ image: CIImage, context: CIContext) {
            let e = image.extent.integral
            width = Int(e.width); height = Int(e.height)
            guard width > 16, height > 16 else { return nil }
            var px = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &px, rowBytes: width * 4, bounds: e,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            var g = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                g[i] = (0.2126 * Float(px[i * 4]) + 0.7152 * Float(px[i * 4 + 1]) + 0.0722 * Float(px[i * 4 + 2])) / 255
            }
            v = g
        }
    }

    // MARK: - 人物

    /// 目(瞳)を結ぶ線と、肩を結ぶ線を Vision で見つける。人がいなければ空
    public static func subjects(in image: CIImage, context: CIContext = CIContext()) throws -> [SubjectMark] {
        let e = image.extent.integral
        guard let cg = context.createCGImage(image, from: e) else { return [] }
        let size = CGSize(width: e.width, height: e.height)
        let faces = VNDetectFaceLandmarksRequest()
        let bodies = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([faces, bodies])

        var marks: [SubjectMark] = []
        for face in faces.results ?? [] {
            guard let lm = face.landmarks else { continue }
            func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let pts = region?.pointsInImage(imageSize: size), !pts.isEmpty else { return nil }
                return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                               y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
            }
            // 瞳が取れなければ目の輪郭の中心
            if let a = center(lm.leftPupil) ?? center(lm.leftEye), let b = center(lm.rightPupil) ?? center(lm.rightEye),
               let m = mark(.eyes, a, b, size) {
                marks.append(m)
            }
        }
        for body in bodies.results ?? [] {
            guard let l = try? body.recognizedPoint(.leftShoulder), let r = try? body.recognizedPoint(.rightShoulder),
                  l.confidence > 0.3, r.confidence > 0.3 else { continue }
            let a = CGPoint(x: l.location.x * size.width, y: l.location.y * size.height)
            let b = CGPoint(x: r.location.x * size.width, y: r.location.y * size.height)
            if let m = mark(.shoulders, a, b, size) { marks.append(m) }
        }
        // 左から順に並べる(呼ぶたびに番号が変わらないように)
        return marks.sorted { ($0.center.x, $0.kind.rawValue) < ($1.center.x, $1.kind.rawValue) }
    }

    /// 2 点(Vision の座標: 左下原点のピクセル)を結ぶ線が水平になる角度
    static func mark(_ kind: SubjectMark.Kind, _ p: CGPoint, _ q: CGPoint, _ size: CGSize) -> SubjectMark? {
        let (a, b) = p.x <= q.x ? (p, q) : (q, p)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        guard dx * dx + dy * dy > 4 else { return nil }   // 近すぎる点は向きが定まらない
        let deg = atan2(dy, dx) * 180 / .pi
        guard abs(deg) < 30 else { return nil }   // 寝ている人など、水平の手がかりにならないもの
        func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: 1 - p.y / size.height) }
        return SubjectMark(kind: kind, angle: deg, from: normalized(a), to: normalized(b))
    }
}

extension TiltEstimator {
    /// 写真 1 枚の手がかり
    public struct Report: Sendable {
        public var segments: [Segment]
        public var subjects: [SubjectMark]
    }

    /// 線は長辺 1024、人物は長辺 1600(顔が小さいと目の位置が取れないため)で測る。
    /// 測るのは、今の設定(レンズ補正を含む)で、切り抜きと傾き補正を外した画像。返す角度は傾き 0 からの値
    public static func estimate(_ photo: Photo, settings: DevelopSettings, pipeline: DevelopPipeline) throws -> Report {
        let context = CIContext(options: [.cacheIntermediates: false])
        let s = measuringSettings(settings)
        let lineImage = try pipeline.processFitting(photo, settings: s, longEdge: 1024)
        let subjectImage = try pipeline.processFitting(photo, settings: s, longEdge: 1600)
        return Report(segments: segments(in: lineImage, context: context),
                      subjects: try subjects(in: subjectImage, context: context))
    }

    /// 測るときの設定: 切り抜き・傾き補正・ルックを外す(ルックの周辺減光などが手がかりを変えないように)
    public static func measuringSettings(_ settings: DevelopSettings) -> DevelopSettings {
        var s = settings
        s.crop = nil
        s.look = nil
        return s
    }
}

extension TiltEstimator {
    /// 画像に描く番号付きの線(直線は番号、人物は E1・S1 のように目・肩の頭文字と番号)
    public static func marks(_ r: Report) -> [PreviewOverlay.Mark] {
        r.segments.map { PreviewOverlay.Mark(label: "\($0.id)", from: $0.from, to: $0.to,
                                             color: $0.axis == .horizontal ? .horizontal : .vertical) }
            + subjectIDs(r.subjects).map { id, m in PreviewOverlay.Mark(label: id, from: m.from, to: m.to, color: .subject) }
    }

    /// 人物の線の番号(目は E1, E2…、肩は S1, S2…。左から順)
    public static func subjectIDs(_ marks: [SubjectMark]) -> [(String, SubjectMark)] {
        var eyes = 0, shoulders = 0
        return marks.map { m in
            switch m.kind {
            case .eyes: eyes += 1; return ("E\(eyes)", m)
            case .shoulders: shoulders += 1; return ("S\(shoulders)", m)
            }
        }
    }
}
