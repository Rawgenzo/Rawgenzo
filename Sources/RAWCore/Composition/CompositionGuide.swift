import Foundation
import CoreGraphics

/// ガイドを構成する1本の線(折れ線)。座標は表示枠に対する比率 (0...1, 左上原点)。
public struct GuidePath: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case solid   // 実線
        case dashed  // 破線
        case fine    // 補助的な細線(黄金螺旋の分割線など)
    }
    public var points: [CGPoint]
    public var style: Style

    public init(points: [CGPoint], style: Style) {
        self.points = points
        self.style = style
    }

    static func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ style: Style) -> GuidePath {
        GuidePath(points: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)], style: style)
    }
}

/// 向きを変えられるガイド(黄金螺旋など)用のオプション
public struct GuideOptions: Equatable, Sendable {
    /// 黄金螺旋の左右反転
    public var flipHorizontal: Bool
    /// 黄金螺旋の上下反転
    public var flipVertical: Bool
    /// 黄金三角形の向き(false = 左上→右下の対角線, true = 右上→左下の対角線)
    public var flipTriangle: Bool

    public init(flipHorizontal: Bool = false, flipVertical: Bool = false, flipTriangle: Bool = false) {
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.flipTriangle = flipTriangle
    }
}

/// 構図ガイド1種類。新しいガイドはこれに準拠した型を作って CompositionGuides.all に足す。
public protocol CompositionGuide {
    /// 安定した識別子。表示設定に保存されるので変更しないこと。
    var id: String { get }
    var displayName: String { get }
    /// - aspect: 表示枠の 幅/高さ。比率によって形が変わるガイド(螺旋)が使う
    func paths(aspect: Double, options: GuideOptions) -> [GuidePath]
}

/// 縦横を同じ比率の位置で分割するガイド(二分割・三分割・黄金比・白銀比)
public struct RatioGridGuide: CompositionGuide {
    public let id: String
    public let displayName: String
    /// 分割位置 (0...1)
    public let positions: [Double]
    public let style: GuidePath.Style

    public init(id: String, displayName: String, positions: [Double], style: GuidePath.Style = .solid) {
        self.id = id
        self.displayName = displayName
        self.positions = positions
        self.style = style
    }

    public func paths(aspect: Double, options: GuideOptions) -> [GuidePath] {
        positions.flatMap { p in
            [GuidePath.line(p, 0, p, 1, style),   // 縦線
             GuidePath.line(0, p, 1, p, style)]   // 横線
        }
    }
}

/// 対角線(四隅を結ぶ2本)
public struct DiagonalGuide: CompositionGuide {
    public let id = "diagonal"
    public let displayName = "対角線"
    public init() {}

    public func paths(aspect: Double, options: GuideOptions) -> [GuidePath] {
        [GuidePath.line(0, 0, 1, 1, .solid),
         GuidePath.line(1, 0, 0, 1, .solid)]
    }
}

/// 黄金三角形。1本の対角線と、残り2つの角からその対角線へ下ろした垂線。
/// 垂直かどうかは実際の画面上で決まるので、枠の比率(aspect)を使ってピクセル空間で計算する。
public struct GoldenTriangleGuide: CompositionGuide {
    public let id = "triangle"
    public let displayName = "黄金三角形"
    public init() {}

    public func paths(aspect: Double, options: GuideOptions) -> [GuidePath] {
        let a = max(aspect, 1e-6)
        // 枠を 幅 a × 高さ 1 として計算し、最後に x を a で割って比率座標に戻す
        let start = (0.0, 0.0), end = (a, 1.0)               // 対角線: 左上 → 右下
        let corners = [(a, 0.0), (0.0, 1.0)]                 // 右上と左下から垂線を下ろす
        let dx = end.0 - start.0, dy = end.1 - start.1
        let len2 = dx * dx + dy * dy

        func foot(_ p: (Double, Double)) -> (Double, Double) {
            let t = ((p.0 - start.0) * dx + (p.1 - start.1) * dy) / len2
            return (start.0 + t * dx, start.1 + t * dy)
        }

        let map: ((Double, Double)) -> CGPoint = { p in
            var nx = p.0 / a
            if options.flipTriangle { nx = 1 - nx }          // 左右反転で逆向きの対角線になる
            return CGPoint(x: nx, y: p.1)
        }

        var result = [GuidePath(points: [map(start), map(end)], style: .solid)]
        for c in corners {
            result.append(GuidePath(points: [map(c), map(foot(c))], style: .solid))
        }
        return result
    }
}

/// 黄金螺旋(フィボナッチ螺旋)。黄金長方形から正方形を切り出していく分割線と、その中を通る螺旋。
/// 枠が黄金比でない場合は枠に合わせて引き伸ばす(Lightroomなどと同じ考え方)。
/// 縦長の枠では90°回転した形にする。
public struct GoldenSpiralGuide: CompositionGuide {
    public let id = "spiral"
    public let displayName = "黄金螺旋"
    /// 正方形を切り出す回数(多いほど螺旋の中心まで描く)
    public var steps = 10
    /// 1つの四分円を何点で近似するか
    public var pointsPerArc = 24

    public init() {}

    public static let phi = (1 + 5.0.squareRoot()) / 2

    public func paths(aspect: Double, options: GuideOptions) -> [GuidePath] {
        let phi = Self.phi
        // 黄金長方形 [0, φ] × [0, 1] 上で計算する(y は下向き)
        var x = 0.0, y = 0.0, w = phi, h = 1.0
        var spiral: [(Double, Double)] = []
        var divisions: [[(Double, Double)]] = []

        for i in 0..<steps {
            let s: Double
            let center: (Double, Double)
            let startAngle: Double
            switch i % 4 {
            case 0: // 左に正方形
                s = h
                center = (x + s, y + s); startAngle = .pi
                divisions.append([(x + s, y), (x + s, y + h)])
                x += s; w -= s
            case 1: // 上に正方形
                s = w
                center = (x, y + s); startAngle = 1.5 * .pi
                divisions.append([(x, y + s), (x + w, y + s)])
                y += s; h -= s
            case 2: // 右に正方形
                s = h
                center = (x + w - s, y); startAngle = 0
                divisions.append([(x + w - s, y), (x + w - s, y + h)])
                w -= s
            default: // 下に正方形
                s = w
                center = (x + w, y + h - s); startAngle = 0.5 * .pi
                divisions.append([(x, y + h - s), (x + w, y + h - s)])
                h -= s
            }
            for k in 0...pointsPerArc {
                if k == 0 && i > 0 { continue }  // 前の弧の終点と同じ点
                let a = startAngle + Double(k) / Double(pointsPerArc) * (.pi / 2)
                spiral.append((center.0 + s * cos(a), center.1 + s * sin(a)))
            }
        }

        let map: ((Double, Double)) -> CGPoint = { p in
            var nx = p.0 / phi
            var ny = p.1
            if aspect < 1 { swap(&nx, &ny) }           // 縦長の枠では90°回して当てはめる
            if options.flipHorizontal { nx = 1 - nx }
            if options.flipVertical { ny = 1 - ny }
            return CGPoint(x: nx, y: ny)
        }

        return divisions.map { GuidePath(points: $0.map(map), style: .fine) }
            + [GuidePath(points: spiral.map(map), style: .solid)]
    }

    /// 螺旋の中心(収束点)の位置。テストやUIのヒント表示用
    public func eye(aspect: Double, options: GuideOptions) -> CGPoint {
        paths(aspect: aspect, options: options).last?.points.last ?? CGPoint(x: 0.5, y: 0.5)
    }
}

/// 組み込みの構図ガイド一覧
public enum CompositionGuides {
    public static let halves = RatioGridGuide(id: "halves", displayName: "二分割線",
                                              positions: [0.5], style: .dashed)
    public static let thirds = RatioGridGuide(id: "thirds", displayName: "三分割線",
                                              positions: [1.0 / 3, 2.0 / 3])
    /// 1 : φ で分割 (約 0.382 / 0.618)
    public static let golden = RatioGridGuide(id: "golden", displayName: "黄金比",
                                              positions: [1 - 1 / GoldenSpiralGuide.phi,
                                                          1 / GoldenSpiralGuide.phi])
    /// 1 : √2 で分割 (約 0.414 / 0.586)
    public static let silver = RatioGridGuide(id: "silver", displayName: "白銀比",
                                              positions: [1 / (1 + 2.0.squareRoot()),
                                                          2.0.squareRoot() / (1 + 2.0.squareRoot())])
    public static let diagonal = DiagonalGuide()
    public static let triangle = GoldenTriangleGuide()
    public static let spiral = GoldenSpiralGuide()

    public static var all: [CompositionGuide] {
        [halves, thirds, golden, silver, diagonal, triangle, spiral]
    }

    public static func guide(id: String) -> CompositionGuide? {
        all.first { $0.id == id }
    }
}
