import Foundation

/// 写真ごとに決まる、パラメータの基準値の材料(撮影時の WB、デコーダの既定値)
public struct ParameterContext: Equatable, Sendable {
    public var asShot: AsShotValues
    public var detailDefaults: DetailDefaults

    public init(asShot: AsShotValues, detailDefaults: DetailDefaults) {
        self.asShot = asShot
        self.detailDefaults = detailDefaults
    }
}

extension Photo {
    public var parameterContext: ParameterContext {
        ParameterContext(asShot: source.asShot, detailDefaults: source.detailDefaults)
    }
}

/// 調整パネルのまとまり。並び順は調整パネルと同じ
public enum ParameterGroup: String, CaseIterable, Sendable {
    case basic, hdr, color, detail

    public var label: String {
        switch self {
        case .basic: return "基本"
        case .hdr: return "HDR"
        case .color: return "色"
        case .detail: return "ディテール"
        }
    }
}

/// 数値で調整する現像パラメータ 1 つの記述。
/// 調整パネルのスライダー・CLI の範囲チェック・AI に渡す道具の説明を、すべてこの記述から作る。
///
/// - id はサイドカーの JSON のキー(入れ子は "hdr.strength" のように . でつなぐ)と同じにしてある。
///   AI の道具の引数名にも使うので、変えるときは呼び出し側(MCP の利用者)への影響に注意
/// - 「基準値」は ↶ で戻る先。写真によって決まるもの(撮影時の WB、デコーダの既定値)は context から求める
public struct ParameterDescriptor: Sendable {
    public enum Baseline: Sendable, Equatable {
        /// 決まった値
        case fixed(Double)
        case asShotTemperature, asShotTint
        case decoderSharpness, decoderLuminanceNoiseReduction, decoderColorNoiseReduction
    }

    public let id: String
    public let label: String
    public let group: ParameterGroup
    public let range: ClosedRange<Double>
    public let baseline: Baseline
    /// 単位(無ければ nil)。表示用と AI への説明用
    public let unit: String?
    /// 表示するときに掛ける倍率(内部 0...1 を 0〜100 と見せる、など)と書式
    public let displayScale: Double
    public let displayFormat: String
    /// 何をする値か。AI への説明にも使うので、画面を見ても分からない注意(効く条件など)はここに書く
    public let summary: String
    /// 値を「未指定」(nil)にできるか。未指定のときは基準値(撮影時の値・デコーダの既定値)が使われる
    public let isOptional: Bool

    private let read: @Sendable (DevelopSettings) -> Double?
    private let write: @Sendable (inout DevelopSettings, Double?) -> Void

    init(id: String, label: String, group: ParameterGroup, range: ClosedRange<Double>,
         baseline: Baseline, unit: String? = nil, displayScale: Double = 1, displayFormat: String,
         summary: String, isOptional: Bool = false,
         read: @escaping @Sendable (DevelopSettings) -> Double?,
         write: @escaping @Sendable (inout DevelopSettings, Double?) -> Void) {
        self.id = id; self.label = label; self.group = group; self.range = range
        self.baseline = baseline; self.unit = unit
        self.displayScale = displayScale; self.displayFormat = displayFormat
        self.summary = summary; self.isOptional = isOptional
        self.read = read; self.write = write
    }

    /// ↶ で戻る先の値
    public func baselineValue(in context: ParameterContext) -> Double {
        switch baseline {
        case .fixed(let v): return v
        case .asShotTemperature: return context.asShot.temperature
        case .asShotTint: return context.asShot.tint
        case .decoderSharpness: return context.detailDefaults.sharpness
        case .decoderLuminanceNoiseReduction: return context.detailDefaults.luminanceNoiseReduction
        case .decoderColorNoiseReduction: return context.detailDefaults.colorNoiseReduction
        }
    }

    /// 設定に書かれている値(未指定なら nil)
    public func storedValue(_ settings: DevelopSettings) -> Double? {
        read(settings)
    }

    /// 実際に使われる値(未指定なら基準値)
    public func value(_ settings: DevelopSettings, context: ParameterContext) -> Double {
        read(settings) ?? baselineValue(in: context)
    }

    /// 値を書く。範囲外は端に丸める。戻り値は実際に書いた値
    @discardableResult
    public func set(_ value: Double, in settings: inout DevelopSettings) -> Double {
        let v = clamp(value)
        write(&settings, v)
        return v
    }

    /// 基準値に戻す(未指定にできるものは nil にする。撮影時の値・デコーダの既定値に従う)
    public func reset(_ settings: inout DevelopSettings) {
        if isOptional {
            write(&settings, nil)
        } else if case .fixed(let v) = baseline {
            write(&settings, v)
        }
    }

    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 表示用の文字列(例: "+0.30 EV"、"5200 K")
    public func formatted(_ value: Double) -> String {
        String(format: displayFormat, value * displayScale)
    }
}

/// 数値で調整する現像パラメータの一覧。
/// クロップ(枠を画像に収める規則がある)、ルックの選択、レンズ補正(オン/オフ)、HDR 出力(オン/オフ)は
/// 1 つの数値では表せないので含めない
public enum ParameterCatalog {
    public static let all: [ParameterDescriptor] = [
        // --- 基本 ---
        ParameterDescriptor(
            id: "exposure", label: "露出", group: .basic, range: -3...3, baseline: .fixed(0),
            unit: "EV", displayFormat: "%+.2f EV",
            summary: "露出補正。RAW のデコード段で掛ける(+1 で 2 倍の明るさ)",
            read: { $0.exposure }, write: { $0.exposure = $1 ?? 0 }),
        ParameterDescriptor(
            id: "contrast", label: "コントラスト", group: .basic, range: ContrastCurve.range, baseline: .fixed(0),
            displayScale: 100, displayFormat: "%+.0f",
            summary: "中間グレーを軸にした S 字のトーンカーブ。正で硬く、負で柔らかくなる。黒・白・中間グレーは動かない",
            read: { $0.contrast }, write: { $0.contrast = $1 ?? 0 }),
        ParameterDescriptor(
            id: "temperature", label: "色温度", group: .basic, range: 2000...12000, baseline: .asShotTemperature,
            unit: "K", displayFormat: "%.0f K",
            summary: "ホワイトバランスの色温度。値を上げると暖色(黄色寄り)になる。未指定なら撮影時の値",
            isOptional: true,
            read: { $0.temperature }, write: { $0.temperature = $1 }),
        ParameterDescriptor(
            id: "tint", label: "色かぶり", group: .basic, range: -150...150, baseline: .asShotTint,
            displayFormat: "%+.0f",
            summary: "ホワイトバランスの色かぶり補正。正でマゼンタ寄り、負でグリーン寄り。未指定なら撮影時の値",
            isOptional: true,
            read: { $0.tint }, write: { $0.tint = $1 }),
        // --- HDR ---
        ParameterDescriptor(
            id: "hdr.strength", label: "HDRの強さ", group: .hdr, range: 0...1, baseline: .fixed(0),
            displayFormat: "%.2f",
            summary: "ローカルトーンマッピングの強さ。明暗差の大きい場面を見やすくする。強いと明暗の境にハローが出ることがある",
            read: { $0.hdr.strength }, write: { $0.hdr.strength = $1 ?? 0 }),
        ParameterDescriptor(
            id: "hdr.highlights", label: "ハイライト回復", group: .hdr, range: 0...1, baseline: .fixed(0),
            displayFormat: "%.2f",
            summary: "明るい部分を抑えて白飛びしかけた階調を戻す",
            read: { $0.hdr.highlights }, write: { $0.hdr.highlights = $1 ?? 0 }),
        ParameterDescriptor(
            id: "hdr.shadows", label: "シャドウ持ち上げ", group: .hdr, range: 0...1, baseline: .fixed(0),
            displayFormat: "%.2f",
            summary: "暗い部分を持ち上げる",
            read: { $0.hdr.shadows }, write: { $0.hdr.shadows = $1 ?? 0 }),
        // --- 色 ---
        ParameterDescriptor(
            id: "saturation", label: "彩度", group: .color, range: 0...2, baseline: .fixed(1),
            displayFormat: "%.2f",
            summary: "彩度の倍率。1 で変更なし、0 でモノクロ、2 で 2 倍",
            read: { $0.saturation }, write: { $0.saturation = $1 ?? 1 }),
        ParameterDescriptor(
            id: "vibrance", label: "自然な彩度", group: .color, range: -1...1, baseline: .fixed(0),
            displayFormat: "%+.2f",
            summary: "彩度の低い色ほど強く効く彩度調整。肌色が飽和しにくい",
            read: { $0.vibrance }, write: { $0.vibrance = $1 ?? 0 }),
        // --- ディテール(デコーダの機能) ---
        ParameterDescriptor(
            id: "sharpness", label: "シャープネス", group: .detail, range: DetailRanges.sharpness,
            baseline: .decoderSharpness, displayScale: 100, displayFormat: "%.0f",
            summary: "RAW デコーダのシャープネス。等倍で描くときだけ効き、縮小したプレビューや縮小書き出しでは変化が見えない。未指定ならデコーダの既定値",
            isOptional: true,
            read: { $0.sharpness }, write: { $0.sharpness = $1 }),
        ParameterDescriptor(
            id: "luminanceNoiseReduction", label: "輝度ノイズ除去", group: .detail,
            range: DetailRanges.luminanceNoiseReduction, baseline: .decoderLuminanceNoiseReduction,
            displayScale: 100, displayFormat: "%.0f",
            summary: "RAW デコーダの輝度ノイズ除去。未指定なら ISO に応じたデコーダの既定値(低感度では 0)。1 を超えると逆に粗くなるので 1 までに制限している",
            isOptional: true,
            read: { $0.luminanceNoiseReduction }, write: { $0.luminanceNoiseReduction = $1 }),
        ParameterDescriptor(
            id: "colorNoiseReduction", label: "色ノイズ除去", group: .detail,
            range: DetailRanges.colorNoiseReduction, baseline: .decoderColorNoiseReduction,
            displayScale: 100, displayFormat: "%.0f",
            summary: "RAW デコーダの色ノイズ除去。未指定ならデコーダの既定値",
            isOptional: true,
            read: { $0.colorNoiseReduction }, write: { $0.colorNoiseReduction = $1 }),
    ]

    private static let byID: [String: ParameterDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(_ id: String) -> ParameterDescriptor? { byID[id] }

    /// 登録済みの id で引く(コード中で決め打ちする用。無い id はプログラムの誤りなので止める)
    public static subscript(_ id: String) -> ParameterDescriptor {
        guard let d = byID[id] else { preconditionFailure("未登録のパラメータ: \(id)") }
        return d
    }

    public static func parameters(in group: ParameterGroup) -> [ParameterDescriptor] {
        all.filter { $0.group == group }
    }
}

extension CropSettings {
    /// 傾き補正の範囲(度)
    public static let angleRange: ClosedRange<Double> = -15...15
}
