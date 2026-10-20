import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 写真の傾きを推定する。返す角度はどれも「CropSettings.angle に入れると直る値」(度。正 = 時計回りに回す)。
///
/// 水平の基準は 1 つではない。2026-10-20 の試験では、同じ写真で棚の線を基準にすると −0.8°、
/// 二人の並びや体の傾きを基準にすると +1.2° になり、オーナーは人物写真として +1.2° を選んだ。
/// どちらが正しいかは写真の意図で決まるので、基準ごとの値を両方返し、選ぶのは AI と人に任せる。
public enum TiltEstimator {
    /// 線を基準にした推定。水平に近い線と垂直に近い線を別々に数える
    /// (カメラを上下に向けて撮ると縦の線が平行でなくなるので、食い違いを見分けられるように)
    public struct LineEstimate: Equatable, Sendable {
        public struct Axis: Equatable, Sendable {
            /// 直すための角度
            public var angle: Double
            /// 推定に使ったエッジのうち、推定値の ±0.75° に入る重みの割合(0...1。高いほど 1 本の向きにそろっている)
            public var support: Double
            /// 推定値のまわり(±2°)のばらつき(度)
            public var spread: Double
            /// 推定に使ったエッジの量(ピクセル数)
            public var pixels: Int
        }
        public var horizontal: Axis?
        public var vertical: Axis?
    }

    /// 人物を基準にした推定。目を結ぶ線・肩を結ぶ線の 1 本ずつ
    public struct SubjectMark: Equatable, Sendable {
        public enum Kind: String, Sendable { case eyes, shoulders }
        public var kind: Kind
        /// 直すための角度(その線が水平になる角度)
        public var angle: Double
        /// 線の中点(画像に対する比率、左上原点)
        public var center: CGPoint
    }

    /// 探す範囲(度)。これより大きく傾いた写真は、意図した傾きとみなして数えない
    public static let searchRange = 10.0

    // MARK: - 線

    public static func lines(in image: CIImage, context: CIContext = CIContext()) -> LineEstimate {
        guard let gray = Gray(image, context: context) else { return LineEstimate() }
        let (w, h) = (gray.width, gray.height)
        let n = w * h
        // Sobel(y は上向きを正にする。画素の行は上から下なので符号を反転)
        var jxx = [Float](repeating: 0, count: n), jxy = jxx, jyy = jxx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let p = { (dx: Int, dy: Int) in gray.v[(y + dy) * w + x + dx] }
                let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                let gyDown = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                let gy = -gyDown
                let i = y * w + x
                jxx[i] = gx * gx; jxy[i] = gx * gy; jyy[i] = gy * gy
            }
        }
        // 構造テンソル(5×5 で平均)。1 画素ごとの勾配の向きより、線の向きを精度よく出せる
        jxx = boxBlur(jxx, w, h, radius: 2); jxy = boxBlur(jxy, w, h, radius: 2); jyy = boxBlur(jyy, w, h, radius: 2)

        // 強いエッジ(上位 15%)だけを使う
        let border = 4
        var energies: [Float] = []
        energies.reserveCapacity(n / 4)
        for y in border..<(h - border) { for x in border..<(w - border) { energies.append(jxx[y * w + x] + jyy[y * w + x]) } }
        guard !energies.isEmpty else { return LineEstimate() }
        energies.sort()
        let threshold = max(energies[Int(Double(energies.count) * 0.85)], 1e-4)

        let bins = Int(searchRange * 2 / binWidth)
        var histH = [Double](repeating: 0, count: bins), histV = histH
        var countH = 0, countV = 0
        // 2 段目(投影で詰める)に使うエッジの点。座標は上向き y
        var pointsH: [(x: Double, y: Double, w: Double)] = [], pointsV = pointsH
        for y in border..<(h - border) {
            for x in border..<(w - border) {
                let i = y * w + x
                let a = Double(jxx[i]), b = Double(jxy[i]), c = Double(jyy[i])
                let energy = a + c
                guard energy >= Double(threshold) else { continue }
                let coherence = ((a - c) * (a - c) + 4 * b * b).squareRoot() / energy
                guard coherence > 0.6 else { continue }
                // 勾配の主な向き → 線の向き(勾配に直角)。上向き y の数学の向き(反時計回りが正)
                let gradient = 0.5 * atan2(2 * b, a - c) * 180 / .pi
                let line = normalize(gradient + 90)
                let weight = coherence * coherence * energy.squareRoot()
                let point = (x: Double(x), y: Double(h - 1 - y), w: weight)
                if abs(line) < searchRange {
                    add(line, weight, to: &histH); countH += 1; pointsH.append(point)
                } else {
                    let v = normalize(line - 90)
                    if abs(v) < searchRange { add(v, weight, to: &histV); countV += 1; pointsV.append(point) }
                }
            }
        }
        // 1 段目: 向きのヒストグラムの山。画素の格子に沿った階段状のエッジに引っぱられ、大きい角度ほど 0 寄りに出る
        // (3° を 2.78° と出した)。2 段目: 山のまわりで、エッジの点を投影したときに線がいちばん鋭くそろう角度を探す
        var horizontal = peak(histH, pixels: countH), vertical = peak(histV, pixels: countV)
        if let a = horizontal { horizontal?.angle = refine(pointsH, around: a.angle, vertical: false) }
        if let a = vertical { vertical?.angle = refine(pointsV, around: a.angle, vertical: true) }
        return LineEstimate(horizontal: horizontal, vertical: vertical)
    }

    /// 角度 deg の線に直角な向きへ点を投影し、1 ピクセル幅のヒストグラムの鋭さ(二乗和)がいちばん大きい角度を探す。
    /// 線が本当にその角度なら、同じ線の点が同じ区間に集まって鋭くなる(文書の傾き補正で使われるやり方)
    static func refine(_ points: [(x: Double, y: Double, w: Double)], around start: Double, vertical: Bool) -> Double {
        guard points.count >= 200 else { return start }
        func score(_ deg: Double) -> Double {
            let t = deg * .pi / 180, c = cos(t), s = sin(t)
            var hist: [Int: Double] = [:]
            hist.reserveCapacity(points.count / 4)
            for p in points {
                // 水平に近い線: 法線は (−sin, cos)。垂直に近い線: 法線は (cos, sin)
                let u = vertical ? p.x * c + p.y * s : p.y * c - p.x * s
                hist[Int(u.rounded(.down)), default: 0] += p.w
            }
            return hist.values.reduce(0) { $0 + $1 * $1 }
        }
        let step = 0.02, span = 1.0
        let candidates = stride(from: start - span, through: start + span, by: step).map { $0 }
        let scores = candidates.map(score)
        guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return start }
        var best = candidates[i]
        if i > 0, i < scores.count - 1 {
            let (l, c, r) = (scores[i - 1], scores[i], scores[i + 1])
            let denom = l - 2 * c + r
            if denom != 0 { best += 0.5 * (l - r) / denom * step }
        }
        return best
    }

    static let binWidth = 0.05

    /// (−90, 90] に収める
    static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 180)
        if d > 90 { d -= 180 }
        if d <= -90 { d += 180 }
        return d
    }

    static func add(_ deg: Double, _ weight: Double, to hist: inout [Double]) {
        let i = Int((deg + searchRange) / binWidth)
        if hist.indices.contains(i) { hist[i] += weight }
    }

    /// ヒストグラムのいちばん高い山。線の向きの「反時計回りのずれ」がそのまま直す角度(時計回りに回す量)になる
    static func peak(_ hist: [Double], pixels: Int) -> LineEstimate.Axis? {
        let total = hist.reduce(0, +)
        guard pixels >= 200, total > 0 else { return nil }
        // ガウスでならす(σ 0.25°)
        let sigma = 0.25 / binWidth, r = Int(sigma * 3)
        let kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        var smooth = [Double](repeating: 0, count: hist.count)
        for i in hist.indices {
            var s = 0.0
            for (k, wgt) in kernel.enumerated() {
                let j = i + k - r
                if hist.indices.contains(j) { s += hist[j] * wgt }
            }
            smooth[i] = s
        }
        guard let top = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
        // 放物線で山の頂を細かく求める
        var offset = 0.0
        if top > 0, top < smooth.count - 1 {
            let (l, c, rr) = (smooth[top - 1], smooth[top], smooth[top + 1])
            let denom = l - 2 * c + rr
            if denom != 0 { offset = 0.5 * (l - rr) / denom }
        }
        let deg = (Double(top) + 0.5 + offset) * binWidth - searchRange
        func weight(within d: Double) -> (sum: Double, sq: Double) {
            var sum = 0.0, sq = 0.0
            for i in hist.indices {
                let x = (Double(i) + 0.5) * binWidth - searchRange
                if abs(x - deg) <= d { sum += hist[i]; sq += hist[i] * (x - deg) * (x - deg) }
            }
            return (sum, sq)
        }
        let near = weight(within: 0.75).sum
        let around = weight(within: 2)
        return LineEstimate.Axis(angle: deg, support: near / total,
                                 spread: around.sum > 0 ? (around.sq / around.sum).squareRoot() : 0, pixels: pixels)
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
        return marks
    }

    /// 2 点(Vision の座標: 左下原点のピクセル)を結ぶ線が水平になる角度
    static func mark(_ kind: SubjectMark.Kind, _ p: CGPoint, _ q: CGPoint, _ size: CGSize) -> SubjectMark? {
        let (a, b) = p.x <= q.x ? (p, q) : (q, p)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        guard dx * dx + dy * dy > 4 else { return nil }   // 近すぎる点は向きが定まらない
        let deg = atan2(dy, dx) * 180 / .pi
        guard abs(deg) < 30 else { return nil }   // 寝ている人など、水平の手がかりにならないもの
        let mid = CGPoint(x: (a.x + b.x) / 2 / size.width, y: 1 - (a.y + b.y) / 2 / size.height)
        return SubjectMark(kind: kind, angle: deg, center: mid)
    }
}

extension TiltEstimator {
    /// 写真 1 枚の推定結果
    public struct Report: Sendable {
        public var lines: LineEstimate
        public var subjects: [SubjectMark]
        /// 測った画像の大きさ(線・人物)
        public var lineImageSize: CGSize
        public var subjectImageSize: CGSize
    }

    /// 線は長辺 1024、人物は長辺 1600(顔が小さいと目の位置が取れないため)で測る。
    /// 測るのは、今の設定(レンズ補正を含む)で、切り抜きと傾き補正を外した画像。返す角度は傾き 0 からの値
    public static func estimate(_ photo: Photo, settings: DevelopSettings, pipeline: DevelopPipeline,
                                lines measureLines: Bool = true, subjects measureSubjects: Bool = true) throws -> Report {
        var s = settings
        s.crop = nil
        s.look = nil   // 周辺減光などのルックが線や顔の手がかりを変えないように
        let context = CIContext(options: [.cacheIntermediates: false])
        var report = Report(lines: LineEstimate(), subjects: [], lineImageSize: .zero, subjectImageSize: .zero)
        if measureLines {
            let image = try pipeline.processFitting(photo, settings: s, longEdge: 1024)
            report.lines = lines(in: image, context: context)
            report.lineImageSize = image.extent.size
        }
        if measureSubjects {
            let image = try pipeline.processFitting(photo, settings: s, longEdge: 1600)
            report.subjects = try subjects(in: image, context: context)
            report.subjectImageSize = image.extent.size
        }
        return report
    }
}
