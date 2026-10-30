import CoreGraphics
import Foundation

/// 調整パネルに出すヒストグラム(R・G・B・明るさ、256 区間)。表示している現像結果(sRGB の 8 bit)から数える
public struct Histogram: Equatable, Sendable {
    public static let bins = 256
    /// 区間ごとの画素の割合(合計 1)
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    public var luminance: [Double]
    /// どれかの色が 255(白飛び)/ 0(黒つぶれ)の画素の割合
    public var highlightClipping: Double
    public var shadowClipping: Double

    /// 画像の画素を数える。大きい画像は step 画素おきに数える(プレビューは長辺 2400 なので 2 おきで約 100 万画素)。
    /// - colorSpace: 数える色空間。アプリのプレビューは Display P3 で描くので、P3 のまま数える
    ///   (sRGB に直すと、sRGB の外の鮮やかな色が 255 / 0 に切られ、白飛び・黒つぶれを多く数える)
    public static func compute(_ image: CGImage, step: Int = 2, colorSpace: CGColorSpace? = nil) -> Histogram? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let cs = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var r = [Int](repeating: 0, count: bins), g = r, b = r, l = r
        var hi = 0, lo = 0, n = 0
        let s = max(1, step)
        for y in stride(from: 0, to: h, by: s) {
            let row = data + y * w * 4
            for x in stride(from: 0, to: w, by: s) {
                let p = row + x * 4
                let (rv, gv, bv) = (Int(p[0]), Int(p[1]), Int(p[2]))
                r[rv] += 1; g[gv] += 1; b[bv] += 1
                // 明るさは Rec.709 の重み(整数で計算)
                l[(rv * 54 + gv * 183 + bv * 19) >> 8] += 1
                if rv == 255 || gv == 255 || bv == 255 { hi += 1 }
                if rv == 0 || gv == 0 || bv == 0 { lo += 1 }
                n += 1
            }
        }
        let total = Double(max(n, 1))
        func norm(_ a: [Int]) -> [Double] { a.map { Double($0) / total } }
        return Histogram(red: norm(r), green: norm(g), blue: norm(b), luminance: norm(l),
                         highlightClipping: Double(hi) / total, shadowClipping: Double(lo) / total)
    }
}
