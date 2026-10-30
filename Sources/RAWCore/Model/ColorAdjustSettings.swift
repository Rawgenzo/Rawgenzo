import Foundation

/// 色別補正(docs/color-grading-design.md の A)。8 色の帯の補正と、スポイトで拾った色の補正。
/// 値はどれも人の目に近い色の空間(OKLCH)で扱う。
public struct ColorAdjustSettings: Codable, Equatable, Sendable {
    /// 8 色の帯ごとの補正。変えていない帯は持たない(保存もしない)
    public var bands: [ColorBand: ColorBandAdjust] = [:]
    /// 拾った色の補正。並びの順に当てる。数の制限はない(オーナーの決定、2026-10-30)
    public var points: [ColorPointAdjust] = []

    public init(bands: [ColorBand: ColorBandAdjust] = [:], points: [ColorPointAdjust] = []) {
        self.bands = bands; self.points = points
    }

    /// 何も変えない設定か(このときは処理の段を通さない)
    public var isNeutral: Bool {
        bands.values.allSatisfy(\.isNeutral) && points.allSatisfy(\.isNeutral)
    }

    private enum CodingKeys: String, CodingKey { case bands, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 帯は ID の文字列をキーにした表で保存する。知らない ID は読み飛ばす(後で帯を増やしても古い版で開けるように)
        let raw = (try? c.decodeIfPresent([String: ColorBandAdjust].self, forKey: .bands)) ?? [:]
        var bands: [ColorBand: ColorBandAdjust] = [:]
        for (key, value) in raw {
            if let band = ColorBand(rawValue: key) { bands[band] = value }
        }
        self.bands = bands
        points = (try? c.decodeIfPresent([ColorPointAdjust].self, forKey: .points)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let stored = bands.filter { !$0.value.isNeutral }
        if !stored.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: stored.map { ($0.key.rawValue, $0.value) }), forKey: .bands)
        }
        if !points.isEmpty { try c.encode(points, forKey: .points) }
    }
}

/// 8 色の帯。rawValue はサイドカーに書かれるので変えないこと
public enum ColorBand: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var label: String {
        switch self {
        case .red: return "赤"
        case .orange: return "オレンジ"
        case .yellow: return "黄"
        case .green: return "緑"
        case .aqua: return "水色"
        case .blue: return "青"
        case .purple: return "紫"
        case .magenta: return "マゼンタ"
        }
    }

    /// 帯の代表の色(sRGB)。帯の中心の色相は、この色を OKLCH に直して決める(数値を手で書かない)
    public var representativeSRGB: SIMD3<Double> {
        switch self {
        case .red: return [1, 0, 0]
        case .orange: return [1, 0.5, 0]
        case .yellow: return [1, 1, 0]
        case .green: return [0, 1, 0]
        case .aqua: return [0, 1, 1]
        case .blue: return [0, 0, 1]
        case .purple: return [0.5, 0, 1]
        case .magenta: return [1, 0, 1]
        }
    }
}

/// 1 つの帯の補正。どれも −100...100(0 = 変えない)
public struct ColorBandAdjust: Codable, Equatable, Sendable {
    /// 色相。+ で次の帯の方(赤 → オレンジ → 黄 …)へ、最大 ColorAdjustMath.maxHueShift 度ずらす
    public var hue: Double = 0
    /// 彩度。−100 でその帯だけ灰色、+100 で 2 倍
    public var saturation: Double = 0
    /// 輝度
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    public var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    public static let range: ClosedRange<Double> = -100...100

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = (try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? 0
        saturation = (try? c.decodeIfPresent(Double.self, forKey: .saturation)) ?? 0
        luminance = (try? c.decodeIfPresent(Double.self, forKey: .luminance)) ?? 0
    }
}

/// スポイトで拾った色の補正 1 つ。拾った色を中心に、色相の幅と淡さ(色の濃さ)の範囲で効く場所を決める
public struct ColorPointAdjust: Codable, Equatable, Sendable {
    /// 表示用の名前(「花びら」など)
    public var name: String = ""
    /// 拾った色の色相(OKLCH の色相、度 0..<360)
    public var hue: Double = 0
    /// 拾った色の濃さ(0 = 白・灰色、100 = とても鮮やか。ColorAdjustMath.chromaLevel)
    public var chroma: Double = 0
    /// 効く色相の幅(片側の度。拾った色相 ± この値)
    public var hueWidth: Double = 20
    /// 効く濃さの範囲(0...100)。淡い色だけを狙うなら上限を下げる
    public var chromaMin: Double = 0
    public var chromaMax: Double = 100
    /// 拾った色の明るさ(OKLab の L × 100。0 = 黒、100 = 白)
    public var lightness: Double = 50
    /// 効く明るさの範囲(0...100)。桜の花びら(明るい)を狙うとき、同じ色相・淡さの暗い枝を外す
    /// (2026-10-30、DSC01032 で枝が紫がかった)
    public var lightnessMin: Double = 0
    public var lightnessMax: Double = 100
    /// 範囲の端で効き方を弱める幅(0...100)
    public var softness: Double = 50
    /// 色を足す(0...100)。足す色の色相の方へ一定量だけ色を足す。ほとんど白の画素にも色が付く
    public var add: Double = 0
    /// 足す色の色相(OKLCH の度)。nil = 拾った色の色相。暖かい光で花びらが黄色みを帯びた写真(DSC01275)で、
    /// 花びらを拾ってピンクを足すため
    public var addHue: Double? = nil
    /// 彩度・色相・輝度(−100...100)。帯の補正と同じ意味
    public var saturation: Double = 0
    public var hueShift: Double = 0
    public var luminance: Double = 0

    public init(name: String = "", hue: Double, chroma: Double, hueWidth: Double = 20,
                chromaMin: Double = 0, chromaMax: Double = 100,
                lightness: Double = 50, lightnessMin: Double = 0, lightnessMax: Double = 100, softness: Double = 50,
                add: Double = 0, addHue: Double? = nil, saturation: Double = 0, hueShift: Double = 0, luminance: Double = 0) {
        self.name = name; self.hue = hue; self.chroma = chroma; self.hueWidth = hueWidth
        self.chromaMin = chromaMin; self.chromaMax = chromaMax
        self.lightness = lightness; self.lightnessMin = lightnessMin; self.lightnessMax = lightnessMax
        self.softness = softness; self.add = add; self.addHue = addHue
        self.saturation = saturation; self.hueShift = hueShift; self.luminance = luminance
    }

    /// 拾った色から作る。効く濃さの範囲は拾った濃さの ±20、明るさの範囲は拾った明るさの ±25
    /// (淡い色を拾えば淡い色だけに、明るい花びらを拾えば暗い枝には効かない)。
    /// 明るさに既定値を付けない(渡し忘れると、明るい淡い色を拾っても範囲が 25〜75 になり、その色自体に効かなくなった)
    public static func picked(hue: Double, chroma: Double, lightness: Double, name: String = "") -> ColorPointAdjust {
        ColorPointAdjust(name: name, hue: hue, chroma: chroma,
                         chromaMin: max(0, chroma - 20), chromaMax: min(100, chroma + 20),
                         lightness: lightness, lightnessMin: max(0, lightness - 25), lightnessMax: min(100, lightness + 25))
    }

    /// 実際に足す色の色相
    public var effectiveAddHue: Double { addHue ?? hue }

    public var isNeutral: Bool { add == 0 && saturation == 0 && hueShift == 0 && luminance == 0 }

    public static let hueWidthRange: ClosedRange<Double> = 5...60
    public static let unitRange: ClosedRange<Double> = 0...100
    public static let signedRange: ClosedRange<Double> = -100...100

    private enum CodingKeys: String, CodingKey {
        case name, hue, chroma, hueWidth, chromaMin, chromaMax, lightness, lightnessMin, lightnessMax
        case softness, add, addHue, saturation, hueShift, luminance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorPointAdjust(hue: 0, chroma: 0)
        func value(_ key: CodingKeys, _ fallback: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        hue = value(.hue, d.hue); chroma = value(.chroma, d.chroma); hueWidth = value(.hueWidth, d.hueWidth)
        chromaMin = value(.chromaMin, d.chromaMin); chromaMax = value(.chromaMax, d.chromaMax)
        lightness = value(.lightness, d.lightness)
        lightnessMin = value(.lightnessMin, d.lightnessMin); lightnessMax = value(.lightnessMax, d.lightnessMax)
        addHue = try? c.decodeIfPresent(Double.self, forKey: .addHue)
        softness = value(.softness, d.softness); add = value(.add, d.add); saturation = value(.saturation, d.saturation)
        hueShift = value(.hueShift, d.hueShift); luminance = value(.luminance, d.luminance)
    }
}
