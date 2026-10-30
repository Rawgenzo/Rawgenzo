import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// 色別補正の計算。入出力は sRGB ガンマの 0...1(ColorCubeLook と同じ空間)で、中では OKLab / OKLCH を使う
/// (HSL のままだと、黄と青で同じ「輝度 +10」の見え方が大きく違うため)。
public enum ColorAdjustMath {
    /// 色相の補正 ±100 で動かす角度(度)
    public static let maxHueShift = 30.0
    /// 輝度の補正 ±100 で動かす OKLab の L(0...1)
    public static let maxLuminanceShift = 0.15
    /// 色を足す 100 で足す OKLab の色の量(a・b の長さ)
    public static let maxAdd = 0.08
    /// 濃さ 100 に当たる OKLCH の C。sRGB の原色(赤 0.26、青 0.31 など)がおよそ 100 になる
    public static let chromaReference = 0.25

    // MARK: 色の空間

    public static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    public static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// sRGB ガンマ → OKLab(L, a, b)。式は Björn Ottosson の OKLab
    public static func oklab(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        let r = linear(srgb.x), g = linear(srgb.y), b = linear(srgb.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s]
    }

    /// OKLab → sRGB ガンマ(範囲の外は切らない。切るのは呼ぶ側)
    public static func srgb(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func gm(_ v: Double) -> Double { v < 0 ? -gamma(-v) : gamma(v) }
        return [gm(r), gm(g), gm(b)]
    }

    /// OKLab → (C, h 度 0..<360)
    public static func lch(_ lab: SIMD3<Double>) -> (c: Double, h: Double) {
        let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h = atan2(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        return (c, h)
    }

    /// OKLCH の C → 濃さ(0...100)
    public static func chromaLevel(_ c: Double) -> Double { min(100, c / chromaReference * 100) }

    /// 2 つの色相の差(−180...180)
    public static func hueDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x >= e1 ? 1 : 0 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: 8 色の帯

    /// 帯の中心の色相(代表の色を OKLCH に直した値)。色相の小さい順
    public static let bandCenters: [(band: ColorBand, hue: Double)] = ColorBand.allCases
        .map { ($0, lch(oklab($0.representativeSRGB)).h) }
        .sorted { $0.hue < $1.hue }

    /// 色相 h での各帯の重み。隣り合う 2 つの帯の中心の間を cos² でなだらかに分け、合計は 1
    public static func bandWeights(hue h: Double) -> [(ColorBand, Double)] {
        let centers = bandCenters
        for i in centers.indices {
            let a = centers[i], b = centers[(i + 1) % centers.count]
            let span = (b.hue - a.hue + 360).truncatingRemainder(dividingBy: 360)
            let offset = (h - a.hue + 360).truncatingRemainder(dividingBy: 360)
            if offset < span {
                let t = offset / span
                let wa = pow(cos(t * .pi / 2), 2)
                return [(a.band, wa), (b.band, 1 - wa)]
            }
        }
        return [(centers[0].band, 1)]
    }

    /// 灰色に近い色(色相が定まらない)には帯の補正を効かせない(設計の 8 色の 4)
    static func bandGate(_ c: Double) -> Double { smoothstep(0.015, 0.05, c) }

    // MARK: 拾った色

    /// 拾った色の補正が、色 (L, C, h) にどれだけ効くか(0...1)。L は OKLab の明るさ(0...1)
    public static func pointWeight(_ p: ColorPointAdjust, l: Double, c: Double, h: Double) -> Double {
        // 色がほとんど無い画素(真っ白・灰色)は色相が定まらないので効かせない。淡い色を狙うときも白い雲は変えない
        let defined = smoothstep(0.004, 0.012, c)
        let d = abs(hueDifference(h, p.hue))
        let featherH = max(2, p.hueWidth * p.softness / 100)
        let wh = 1 - smoothstep(p.hueWidth, p.hueWidth + featherH, d)
        let level = chromaLevel(c)
        let featherC = max(1, 20 * p.softness / 100)
        let lower = p.chromaMin <= 0 ? 1 : smoothstep(p.chromaMin - featherC, p.chromaMin, level)
        let upper = p.chromaMax >= 100 ? 1 : 1 - smoothstep(p.chromaMax, p.chromaMax + featherC, level)
        let light = l * 100
        let featherL = max(1, 15 * p.softness / 100)
        let dark = p.lightnessMin <= 0 ? 1 : smoothstep(p.lightnessMin - featherL, p.lightnessMin, light)
        let bright = p.lightnessMax >= 100 ? 1 : 1 - smoothstep(p.lightnessMax, p.lightnessMax + featherL, light)
        return defined * wh * lower * upper * dark * bright
    }

    // MARK: 補正

    /// 色別補正を 1 色に当てる(sRGB ガンマ 0...1 → 同じ。範囲の外は切る)。
    /// 効き方の重みはどれも補正前の色で決める(前の補正の結果で次の補正の範囲が動かないように)
    public static func apply(_ s: ColorAdjustSettings, to rgb: SIMD3<Double>) -> SIMD3<Double> {
        var lab = oklab(rgb)
        let (c0, h0) = lch(lab)
        let l0 = lab.x

        // 8 色の帯
        if !s.bands.isEmpty {
            let gate = bandGate(c0)
            var dh = 0.0, sat = 0.0, dl = 0.0
            for (band, w) in bandWeights(hue: h0) {
                guard let a = s.bands[band] else { continue }
                dh += w * a.hue; sat += w * a.saturation; dl += w * a.luminance
            }
            lab = adjusted(lab, weight: gate, hue: dh, saturation: sat, luminance: dl)
        }
        // 拾った色(並びの順)
        for p in s.points where !p.isNeutral {
            let w = pointWeight(p, l: l0, c: c0, h: h0)
            guard w > 0 else { continue }
            if p.add > 0 {
                let rad = p.effectiveAddHue * .pi / 180
                let amount = w * p.add / 100 * maxAdd
                lab.y += amount * cos(rad); lab.z += amount * sin(rad)
            }
            lab = adjusted(lab, weight: w, hue: p.hueShift, saturation: p.saturation, luminance: p.luminance)
        }
        let out = srgb(lab)
        return [min(max(out.x, 0), 1), min(max(out.y, 0), 1), min(max(out.z, 0), 1)]
    }

    /// 色相・彩度・輝度(どれも −100...100)を重み weight で当てる
    static func adjusted(_ lab: SIMD3<Double>, weight: Double, hue: Double, saturation: Double, luminance: Double) -> SIMD3<Double> {
        guard weight > 0 else { return lab }
        var (c, h) = lch(lab)
        h += weight * hue / 100 * maxHueShift
        c *= max(0, 1 + weight * saturation / 100)
        let l = lab.x + weight * luminance / 100 * maxLuminanceShift
        let rad = h * .pi / 180
        return [l, c * cos(rad), c * sin(rad)]
    }

    /// 効く場所を見せる: 効く色はそのまま、効かない色は灰色(同じ明るさ)にする
    public static func mask(_ target: ColorAdjustMask, _ s: ColorAdjustSettings, rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lab = oklab(rgb)
        let (c, h) = lch(lab)
        let w: Double
        switch target {
        case .band(let band):
            w = bandGate(c) * (bandWeights(hue: h).first { $0.0 == band }?.1 ?? 0)
        case .point(let i):
            w = s.points.indices.contains(i) ? pointWeight(s.points[i], l: lab.x, c: c, h: h) : 0
        }
        let gray = srgb([lab.x, 0, 0])
        let out = gray + (rgb - gray) * w
        return [min(max(out.x, 0), 1), min(max(out.y, 0), 1), min(max(out.z, 0), 1)]
    }
}

/// 「効く場所を表示」で見せる対象
public enum ColorAdjustMask: Equatable, Hashable, Sendable {
    case band(ColorBand)
    case point(Int)
}

/// 色別補正の段。今の色の段(彩度・自然な彩度)の後、クロップ・ルックの前に置く。
/// 設定から 3D LUT を作り、Core Image の色キューブで当てる。LUT は設定が変わったときだけ作り直す。
///
/// 色キューブは 0...1 の外の値を切る(2026-10-30 に確認: 入力 2.0・4.0 がどちらも 1.0 になった)。
/// HDR 出力のとき、色別補正を使っている写真だけ明るい所が 1 で切れる(ルックと同じ)。
/// 使っていない写真はこの段を通さないので、変わらない。
public struct ColorAdjustStage: DevelopStage {
    public init() {}
    public let name = "colorAdjust"
    public let phase = StagePhase.color

    /// LUT の大きさ(一辺)。CubeCacheTests で作る時間を測って決めた
    public static let cubeSize = 33

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        let adjust = settings.colorAdjust ?? ColorAdjustSettings()
        let data: Data
        if let target = options.colorAdjustMask {
            data = Self.cache.cube(for: .mask(target, adjust)) {
                ColorCubeLook.makeCube(size: Self.cubeSize) { c in
                    let o = ColorAdjustMath.mask(target, adjust, rgb: SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)))
                    return SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
                }
            }
        } else {
            guard !adjust.isNeutral else { return image }
            data = Self.cache.cube(for: .adjust(adjust)) {
                ColorCubeLook.makeCube(size: Self.cubeSize) { c in
                    let o = ColorAdjustMath.apply(adjust, to: SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)))
                    return SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
                }
            }
        }
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(Self.cubeSize)
        f.cubeData = data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    /// 作った LUT の置き場。プレビューの描画キューと AI の操作面のキューの両方から呼ばれるので鍵をかける
    static let cache = CubeCache()

    final class CubeCache: @unchecked Sendable {
        enum Key: Equatable {
            case adjust(ColorAdjustSettings)
            case mask(ColorAdjustMask, ColorAdjustSettings)
        }
        private let lock = NSLock()
        private var entries: [(key: Key, data: Data)] = []
        private let limit = 4

        func cube(for key: Key, make: () -> Data) -> Data {
            lock.lock()
            if let hit = entries.first(where: { $0.key == key }) { lock.unlock(); return hit.data }
            lock.unlock()
            let data = make()
            lock.lock()
            entries.removeAll { $0.key == key }
            entries.insert((key, data), at: 0)
            if entries.count > limit { entries.removeLast() }
            lock.unlock()
            return data
        }
    }
}

extension ColorPointAdjust {
    /// 範囲を決めた結果
    public struct FitResult: Sendable {
        public var point: ColorPointAdjust
        /// 外せなかった「変えたくない色」の番号(excludes の並び)と、残った効き方(0...1)
        public var unresolved: [(index: Int, weight: Double)]
        /// 効き方が半分に届かない「変えたい色」の番号(includes の並び)。色がほとんど無い(真っ白に近い)色など
        public var weakIncludes: [(index: Int, weight: Double)]
    }

    /// 変えたい色(includes)が全部入り、変えたくない色(excludes)が外れるように、範囲を決める。
    /// AI が範囲の値を試し続けないための、目標で指示する計算(solve_exposure と同じ考え方)。
    /// 中心は変えたい色の平均。範囲は変えたい色が全部入る大きさにゆとりを足して始め、変えたくない色が入っていれば、
    /// その色と変えたい色がいちばん離れている軸(色相・淡さ・明るさ)で範囲を狭める。
    /// 補正の値(色を足すなど)は base から引き継ぐ
    public static func fitted(includes: [ColorSampler.Picked], excludes: [ColorSampler.Picked] = [],
                              base: ColorPointAdjust? = nil) -> FitResult? {
        guard !includes.isEmpty else { return nil }
        // 色相は円の上の平均
        let sx = includes.map { cos($0.hue * .pi / 180) * max($0.chroma, 1) }.reduce(0, +)
        let sy = includes.map { sin($0.hue * .pi / 180) * max($0.chroma, 1) }.reduce(0, +)
        var center = atan2(sy, sx) * 180 / .pi
        if center < 0 { center += 360 }
        let hueSpread = includes.map { abs(ColorAdjustMath.hueDifference($0.hue, center)) }.max() ?? 0
        let chromas = includes.map(\.chroma), lights = includes.map(\.lightness)

        var p = base ?? ColorPointAdjust(hue: center, chroma: 0)
        p.hue = center
        p.chroma = chromas.reduce(0, +) / Double(chromas.count)
        p.lightness = lights.reduce(0, +) / Double(lights.count)
        p.hueWidth = min(max(hueSpread + 5, ColorPointAdjust.hueWidthRange.lowerBound), ColorPointAdjust.hueWidthRange.upperBound)
        p.chromaMin = max(0, (chromas.min() ?? 0) - 4)
        p.chromaMax = min(100, (chromas.max() ?? 100) + 4)
        p.lightnessMin = max(0, (lights.min() ?? 0) - 6)
        p.lightnessMax = min(100, (lights.max() ?? 100) + 6)
        p.softness = base?.softness ?? 30
        p.samples = includes.map(\.sample)

        func weight(_ c: ColorSampler.Picked, _ q: ColorPointAdjust) -> Double {
            ColorAdjustMath.pointWeight(q, l: c.lightness / 100, c: c.chroma / 100 * ColorAdjustMath.chromaReference, h: c.hue)
        }
        // 変えたくない色を 1 つずつ外す。狭めるのは、変えたい色が全部入ったままでいられる範囲まで
        for _ in 0..<3 {
            var changed = false
            for e in excludes where weight(e, p) > 0.05 {
                let s = p.softness / 100
                // 軸ごとに「どこまで狭めれば外れるか」と、そのとき変えたい色が入ったままか
                var options: [(gap: Double, apply: (inout ColorPointAdjust) -> Void)] = []
                let dh = abs(ColorAdjustMath.hueDifference(e.hue, center))
                let width = dh / (1 + s)
                if width >= hueSpread + 1, max(2, width * s) <= dh - width {
                    options.append(((dh - hueSpread) / 60, { $0.hueWidth = max(ColorPointAdjust.hueWidthRange.lowerBound, width) }))
                }
                let featherC = max(1, 20 * s)
                if e.chroma > (chromas.max() ?? 0) + featherC {
                    options.append(((e.chroma - (chromas.max() ?? 0)) / 100, { $0.chromaMax = e.chroma - featherC }))
                } else if e.chroma < (chromas.min() ?? 0) - featherC {
                    options.append((((chromas.min() ?? 0) - e.chroma) / 100, { $0.chromaMin = e.chroma + featherC }))
                }
                let featherL = max(1, 15 * s)
                if e.lightness > (lights.max() ?? 0) + featherL {
                    options.append(((e.lightness - (lights.max() ?? 0)) / 100, { $0.lightnessMax = e.lightness - featherL }))
                } else if e.lightness < (lights.min() ?? 0) - featherL {
                    options.append((((lights.min() ?? 0) - e.lightness) / 100, { $0.lightnessMin = e.lightness + featherL }))
                }
                if let best = options.max(by: { $0.gap < $1.gap }) {
                    best.apply(&p)
                    changed = true
                }
            }
            if !changed {
                // どの軸でも外せないときは、端のなめらかさを小さくしてもう一度だけ試す
                if p.softness > 10, excludes.contains(where: { weight($0, p) > 0.05 }) { p.softness = 10; continue }
                break
            }
        }
        let unresolved = excludes.enumerated().compactMap { i, e -> (Int, Double)? in
            let w = weight(e, p)
            return w > 0.05 ? (i, w) : nil
        }
        let weak = includes.enumerated().compactMap { i, c -> (Int, Double)? in
            let w = weight(c, p)
            return w < 0.5 ? (i, w) : nil
        }
        return FitResult(point: p, unresolved: unresolved, weakIncludes: weak)
    }
}

extension ColorPointAdjust {
    /// 変えたい色の濃さの平均が target(0...100)になる「色を足す」の強さを探す(二分法)。
    /// 届かないときは 100(足せる最大)にして、届いた濃さを返す。画像は描かず、拾った色の計算だけで探す
    public func solvedAdd(includes: [ColorSampler.Picked], targetChroma target: Double)
        -> (point: ColorPointAdjust, achieved: Double, met: Bool) {
        func meanChroma(_ add: Double) -> Double {
            var q = self
            q.add = add
            let s = ColorAdjustSettings(points: [q])
            let values = includes.map { ColorSampler.Picked(rgb: ColorAdjustMath.apply(s, to: $0.rgb)).chroma }
            return values.reduce(0, +) / Double(max(values.count, 1))
        }
        var q = self
        let start = meanChroma(0)
        if target <= start { q.add = 0; return (q, start, abs(start - target) < 1) }
        let top = meanChroma(100)
        if target >= top { q.add = 100; return (q, top, abs(top - target) < 1) }
        var lo = 0.0, hi = 100.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if meanChroma(mid) < target { lo = mid } else { hi = mid }
        }
        q.add = ((lo + hi) / 2).rounded()
        return (q, meanChroma(q.add), true)
    }
}
