import CoreImage
import Foundation

/// 現像結果の「数値の観測」。画像そのものを見なくても、明るさ・白飛び・色の偏り・明暗の配置が分かる。
/// AI に毎回画像を送らずに済ませるためのもの(docs/ai-agent-architecture.md の 8.2)。
///
/// 値はすべて出力の sRGB(ガンマを掛けた、見た目に近い値)で 0...1。
/// 縮小した画像で計算するので、ごく小さな白飛び(点光源など)は数え漏れることがある。
public struct ImageStats: Codable, Equatable, Sendable {
    /// 計算に使った画像の大きさ(ピクセル)
    public var width: Int
    public var height: Int
    /// 輝度(Rec.709 の係数で sRGB の値から求めたもの)の平均・中央値・1% 点・99% 点
    public var meanLuminance: Double
    public var medianLuminance: Double
    public var p01Luminance: Double
    public var p99Luminance: Double
    /// 白飛びの割合: どれかのチャンネルが highlightThreshold 以上の画素
    public var highlightClipping: Double
    /// 黒つぶれの割合: すべてのチャンネルが shadowThreshold 以下の画素
    public var shadowClipping: Double
    /// RGB それぞれの平均。R と B の差で暖色・寒色への偏り、G の高低で緑・マゼンタへの偏りの目安になる
    public var meanRGB: [Double]
    /// 輝度のヒストグラム(histogramBins 区間、割合。合計 1)
    public var histogram: [Double]
    /// 写真を gridSize × gridSize に区切った各区画の平均 RGB。行は上から、列は左から
    public var grid: [[[Double]]]

    public static let histogramBins = 32
    public static let gridSize = 8
    public static let highlightThreshold = 0.995
    public static let shadowThreshold = 0.005

    /// 計算に使う画像の長辺(既定)。1024 で α7S III なら 1 回 0.1 秒前後
    public static let defaultLongEdge = 1024

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 画像の画素から計算する。画像が大きいときは maxLongEdge まで縮小してから数える
    public static func compute(_ image: CIImage, maxLongEdge: Int = defaultLongEdge) throws -> ImageStats {
        var img = image
        let longEdge = max(img.extent.width, img.extent.height)
        guard img.extent.width >= 1, img.extent.height >= 1, longEdge.isFinite else {
            throw RAWError.renderFailed("統計を計算する画像が空です")
        }
        if longEdge > CGFloat(maxLongEdge) {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: CGFloat(maxLongEdge) / longEdge,
                                                  kCIInputAspectRatioKey: 1])
        }
        let e = img.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(img, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return fromPixels(px, width: w, height: h)
    }

    /// RGBA(float)の画素の並びから計算する。1 行目が画像の上端
    static func fromPixels(_ px: [Float], width w: Int, height h: Int) -> ImageStats {
        let n = w * h
        let bins = histogramBins, g = gridSize
        var hist = [Int](repeating: 0, count: bins)
        // 中央値などはヒストグラムより細かく取りたいので 1024 段の累積で求める
        let fine = 1024
        var fineHist = [Int](repeating: 0, count: fine)
        var sumY = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0
        var hi = 0, lo = 0
        var cellSum = [[Double]](repeating: [0, 0, 0], count: g * g)
        var cellCount = [Int](repeating: 0, count: g * g)

        for y in 0..<h {
            let row = min(y * g / h, g - 1)
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(px[i]), gg = Double(px[i + 1]), b = Double(px[i + 2])
                let lum = 0.2126 * r + 0.7152 * gg + 0.0722 * b
                let c = min(max(lum, 0), 1)
                hist[min(Int(c * Double(bins)), bins - 1)] += 1
                fineHist[min(Int(c * Double(fine)), fine - 1)] += 1
                sumY += c; sumR += r; sumG += gg; sumB += b
                if max(r, gg, b) >= highlightThreshold { hi += 1 }
                if max(r, gg, b) <= shadowThreshold { lo += 1 }
                let cell = row * g + min(x * g / w, g - 1)
                cellSum[cell][0] += r; cellSum[cell][1] += gg; cellSum[cell][2] += b
                cellCount[cell] += 1
            }
        }

        func percentile(_ p: Double) -> Double {
            let target = Double(n) * p
            var acc = 0
            for (k, count) in fineHist.enumerated() {
                acc += count
                if Double(acc) >= target { return (Double(k) + 0.5) / Double(fine) }
            }
            return 1
        }
        let total = Double(max(n, 1))
        let grid: [[[Double]]] = (0..<g).map { row in
            (0..<g).map { col in
                let k = row * g + col
                let c = Double(max(cellCount[k], 1))
                return cellSum[k].map { round3($0 / c) }
            }
        }
        return ImageStats(
            width: w, height: h,
            meanLuminance: round3(sumY / total),
            medianLuminance: round3(percentile(0.5)),
            p01Luminance: round3(percentile(0.01)),
            p99Luminance: round3(percentile(0.99)),
            highlightClipping: round4(Double(hi) / total),
            shadowClipping: round4(Double(lo) / total),
            meanRGB: [sumR, sumG, sumB].map { round3($0 / total) },
            histogram: hist.map { round4(Double($0) / total) },
            grid: grid)
    }

    // AI に渡す JSON を短くするため、意味のない桁は落とす
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}

extension DevelopPipeline {
    /// 長辺が longEdge ピクセル(以下)になるよう、縮小して現像する。クロップ後の大きさで合わせる。
    /// 縮小して描くのでシャープネスは効かない(等倍のときだけ効くデコーダの性質)。
    /// RAWSource に触るので、アプリでは描画キューから呼ぶこと
    /// - colorAdjustMask: 色別補正の「効く場所を表示」(AI の get_preview の color_mask)
    public func processFitting(_ photo: Photo, settings: DevelopSettings, longEdge: Int,
                               colorAdjustMask: ColorAdjustMask? = nil) throws -> CIImage {
        // まず等倍の大きさを求める(CIImage は描くまで計算しないので、大きさを知るだけなら軽い)
        let full = try process(photo, settings: settings, options: RenderOptions(scale: 1, colorAdjustMask: colorAdjustMask))
        let fullLong = max(full.extent.width, full.extent.height)
        guard fullLong > 0 else { throw RAWError.renderFailed("現像結果が空です") }
        let scale = min(1, Double(longEdge) / Double(fullLong))
        if scale >= 1 { return full }
        var image = try process(photo, settings: settings, options: RenderOptions(scale: scale, colorAdjustMask: colorAdjustMask))
        // デコーダの縮小は端数で 1〜2 ピクセルずれることがあるので、超えた分だけ縮める
        let long = max(image.extent.width, image.extent.height)
        if long > CGFloat(longEdge) {
            image = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: CGFloat(longEdge) / long,
                                                      kCIInputAspectRatioKey: 1])
        }
        return image
    }
}

/// AI に見せる縮小画像(JPEG)を作る
public enum PreviewEncoder {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func jpeg(_ image: CIImage, quality: Double = 0.8) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let data = context.jpegRepresentation(of: image, colorSpace: cs, options: opts) else {
            throw RAWError.renderFailed("JPEG を作れません")
        }
        return data
    }
}
