import CoreImage
import Foundation

/// 色別補正の「色を拾う」(アプリのスポイトと AI の道具で共通)。
/// 拾うのは色別補正の段に入る前の色(補正は補正前の色で効く場所を決めるため)なので、色別補正とルックを外して描いた画像から拾う。
public enum ColorSampler {
    public struct Picked: Equatable, Sendable {
        /// OKLCH の色相(度)
        public var hue: Double
        /// 濃さ(0...100。ColorAdjustMath.chromaLevel)
        public var chroma: Double
        /// 明るさ(OKLab の L × 100)
        public var lightness: Double
        /// 拾った色(sRGB ガンマ 0...1。表示用)
        public var rgb: SIMD3<Double>
        /// 色がほとんど無い(白・灰色)。色相が定まらないので、拾っても効く場所が決まらない
        public var isNearlyGray: Bool { ColorAdjustMath.chromaLevel(0.012) > chroma }
    }

    /// 拾うときの設定: 色別補正とルックを外す(切り抜き・傾きは残す。見えている画像の位置で拾うため)
    public static func samplingSettings(_ settings: DevelopSettings) -> DevelopSettings {
        var s = settings
        s.colorAdjust = nil
        s.look = nil
        return s
    }

    /// 写真の、見えている画像(切り抜き・傾き補正の後)の位置 point(比率、左上原点)の色を拾う。
    /// 長辺 512 で描き、まわり 5×5 画素の平均を取る(1 画素だとノイズで色相がぶれる)
    public static func pick(_ photo: Photo, settings: DevelopSettings, pipeline: DevelopPipeline,
                            at point: CGPoint) throws -> Picked {
        let image = try pipeline.processFitting(photo, settings: samplingSettings(settings), longEdge: 512)
        return sample(image, at: point)
    }

    /// 画像の位置 point(比率、左上原点)のまわりの平均の色
    public static func sample(_ image: CIImage, at point: CGPoint, radius: Int = 2,
                              context: CIContext = CIContext(options: [.cacheIntermediates: false])) -> Picked {
        let e = image.extent
        let px = Int((e.minX + min(max(point.x, 0), 1) * e.width).rounded(.down))
        // 左上原点の比率 → Core Image の座標(左下原点)
        let py = Int((e.minY + (1 - min(max(point.y, 0), 1)) * e.height).rounded(.down))
        let size = radius * 2 + 1
        let box = CGRect(x: px - radius, y: py - radius, width: size, height: size).intersection(e.integral)
        var buffer = [Float](repeating: 0, count: max(1, Int(box.width * box.height)) * 4)
        context.render(image, toBitmap: &buffer, rowBytes: Int(box.width) * 16, bounds: box,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // 明るさの平均はリニアで取る
        var sum = SIMD3<Double>(0, 0, 0)
        let count = buffer.count / 4
        for i in 0..<count {
            sum += SIMD3(ColorAdjustMath.linear(Double(buffer[i * 4])), ColorAdjustMath.linear(Double(buffer[i * 4 + 1])),
                         ColorAdjustMath.linear(Double(buffer[i * 4 + 2])))
        }
        let mean = sum / Double(max(count, 1))
        let rgb = SIMD3(ColorAdjustMath.gamma(mean.x), ColorAdjustMath.gamma(mean.y), ColorAdjustMath.gamma(mean.z))
        let lab = ColorAdjustMath.oklab(rgb)
        let (c, h) = ColorAdjustMath.lch(lab)
        return Picked(hue: h, chroma: ColorAdjustMath.chromaLevel(c), lightness: lab.x * 100, rgb: rgb)
    }
}
