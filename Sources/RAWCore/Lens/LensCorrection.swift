import Foundation

/// どのレンズ補正を掛けるか。サイドカーに保存される(DevelopSettings.lens)。
public struct LensCorrectionSettings: Codable, Hashable, Sendable {
    /// 周辺減光(四隅が暗くなるのを明るくする)
    public var vignetting: Bool
    /// 歪曲(樽型・糸巻き型の歪みを直す)
    public var distortion: Bool
    /// 倍率色収差(画面の端で赤・青がずれて色の縁が出るのを直す)
    public var chromaticAberration: Bool

    public init(vignetting: Bool = true, distortion: Bool = true, chromaticAberration: Bool = true) {
        self.vignetting = vignetting
        self.distortion = distortion
        self.chromaticAberration = chromaticAberration
    }

    public static let all = LensCorrectionSettings()
    /// 全部切る。`.none` という名前にしないこと: `DevelopSettings.lens` は Optional なので、
    /// `s.lens = .none` が「全部切る」ではなく「未指定(nil)= カメラ設定に従う」になってしまう
    public static let off = LensCorrectionSettings(vignetting: false, distortion: false, chromaticAberration: false)

    public var isNone: Bool { !vignetting && !distortion && !chromaticAberration }

    private enum CodingKeys: String, CodingKey { case vignetting, distortion, chromaticAberration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vignetting = try c.decodeIfPresent(Bool.self, forKey: .vignetting) ?? true
        distortion = try c.decodeIfPresent(Bool.self, forKey: .distortion) ?? true
        chromaticAberration = try c.decodeIfPresent(Bool.self, forKey: .chromaticAberration) ?? true
    }
}

/// 1 枚の写真のレンズ補正データ(撮影条件ごとにカメラが記録した値を、補正量に換算したもの)。
///
/// 半径は「画像の中心から隅までの距離(半対角)」を 1 とする。点と点の間は直線で補間し、
/// 最初の点より内側は最初の値、最後の点より外側は最後の値を使う。
/// 出力の画素(中心からの位置 p)は、入力の「倍率 × p」の位置から色を取る(色ごとに倍率が違う = 倍率色収差)。
/// 明るさは、色を取った位置の半径での周辺減光の係数 k で割る。
public struct LensCorrectionData: Hashable, Sendable {
    /// 点の半径
    public let knots: [Double]
    /// 歪曲の倍率(G の倍率でもある)
    public let distortion: [Double]
    /// R・B の倍率に掛ける係数(倍率色収差)
    public let chromaticRed: [Double]
    public let chromaticBlue: [Double]
    /// 周辺減光の係数 k(明るさを k で割る。1 = 補正なし)
    public let vignetting: [Double]
    /// 撮影時のカメラの補正設定。サイドカーで指定が無い写真はこれに従う
    public let cameraSettings: LensCorrectionSettings

    public init(knots: [Double], distortion: [Double], chromaticRed: [Double], chromaticBlue: [Double],
                vignetting: [Double], cameraSettings: LensCorrectionSettings) {
        self.knots = knots
        self.distortion = distortion
        self.chromaticRed = chromaticRed
        self.chromaticBlue = chromaticBlue
        self.vignetting = vignetting
        self.cameraSettings = cameraSettings
    }

    public enum Channel: Int, CaseIterable, Sendable { case red, green, blue }

    /// 半径 r での値(直線補間)
    static func interpolate(_ knots: [Double], _ values: [Double], at r: Double) -> Double {
        guard let first = knots.first, !values.isEmpty else { return 1 }
        if r < first { return values[0] }
        for i in 1..<knots.count where r <= knots[i] {
            let t = (r - knots[i - 1]) / (knots[i] - knots[i - 1])
            return values[i - 1] + (values[i] - values[i - 1]) * t
        }
        return values[values.count - 1]
    }

    /// 色 channel の、半径 r での倍率(設定で切った補正は 1 として扱う)
    public func magnification(_ channel: Channel, at r: Double, settings: LensCorrectionSettings) -> Double {
        var m = settings.distortion ? Self.interpolate(knots, distortion, at: r) : 1
        if settings.chromaticAberration {
            switch channel {
            case .red: m *= Self.interpolate(knots, chromaticRed, at: r)
            case .blue: m *= Self.interpolate(knots, chromaticBlue, at: r)
            case .green: break
            }
        }
        return m
    }

    /// 半径 r での周辺減光の係数 k(明るさを k で割る)
    public func vignettingFactor(at r: Double, settings: LensCorrectionSettings) -> Double {
        settings.vignetting ? Self.interpolate(knots, vignetting, at: r) : 1
    }

    /// 出力の位置 p(画像中心が原点、半対角 = 1)に対して、色 channel を取る入力の位置。scale は全体の拡大率
    public func sourcePoint(_ p: SIMD2<Double>, channel: Channel, settings: LensCorrectionSettings,
                            scale: Double) -> SIMD2<Double> {
        let q = p / scale
        let r = (q * q).sum().squareRoot()
        return q * magnification(channel, at: r, settings: settings)
    }

    /// 歪曲で画像の外を参照する所が出ないよう、全体を拡大する率(1 以上)。
    /// 糸巻き型(外側ほど倍率が 1 より大きい)だと、縁の画素が画像の外から色を取ろうとする。
    /// 縁の上の点を全部調べ、どの色も画像の内側から取れる最小の拡大率を求める。
    /// - imageAspect: 画像の 幅/高さ
    public func autoScale(settings: LensCorrectionSettings, imageAspect: Double) -> Double {
        guard settings.distortion || settings.chromaticAberration else { return 1 }
        let d = (imageAspect * imageAspect + 1).squareRoot()
        let halfW = imageAspect / d, halfH = 1 / d   // 半対角 = 1 のときの、幅・高さの半分
        // 上下左右対称なので、右上の 4 分の 1 の縁(右の辺と上の辺)だけ調べればよい
        let n = 400
        var edge: [SIMD2<Double>] = []
        for i in 0...n {
            let t = Double(i) / Double(n)
            edge.append(SIMD2(halfW, halfH * t))
            edge.append(SIMD2(halfW * t, halfH))
        }
        func fits(_ s: Double) -> Bool {
            for p in edge {
                for c in Channel.allCases {
                    let src = sourcePoint(p, channel: c, settings: settings, scale: s)
                    if abs(src.x) > halfW * (1 + 1e-9) || abs(src.y) > halfH * (1 + 1e-9) { return false }
                }
            }
            return true
        }
        if fits(1) { return 1 }
        var lo = 1.0, hi = 1.0
        repeat { hi *= 1.05 } while !fits(hi) && hi < 2
        guard fits(hi) else { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }
}

extension LensCorrectionData {
    /// Sony の ARW に記録された補正値から作る。値の意味は docs/sony-lens-correction.md
    /// (darktable のリバースエンジニアリングによる式。コードは写さず式だけを参考にした)。
    /// - distortion / vignetting: 先頭が点の数 n、続いて n 個
    /// - chromatic: 先頭が 2n、続いて R の n 個、B の n 個
    /// 形が合わなければ nil
    static func sony(distortion d: [Int], chromatic ca: [Int], vignetting v: [Int],
                     cameraSettings: LensCorrectionSettings) -> LensCorrectionData? {
        guard let n = d.first, n >= 2, n <= 16,
              d.count >= n + 1, v.first == n, v.count >= n + 1,
              ca.first == 2 * n, ca.count >= 2 * n + 1 else { return nil }
        let knots = (0..<n).map { (Double($0) + 0.5) / Double(n - 1) }
        return LensCorrectionData(
            knots: knots,
            distortion: (1...n).map { 1 + Double(d[$0]) / 16384 },             // 2^-14
            chromaticRed: (1...n).map { 1 + Double(ca[$0]) / 2_097_152 },      // 2^-21
            chromaticBlue: (1...n).map { 1 + Double(ca[n + $0]) / 2_097_152 },
            vignetting: (1...n).map { pow(2, 0.5 - pow(2, Double(v[$0]) / 8192 - 1)) },   // 2^-13
            cameraSettings: cameraSettings)
    }
}
