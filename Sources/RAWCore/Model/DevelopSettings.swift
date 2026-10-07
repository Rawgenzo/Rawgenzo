import Foundation

/// 1枚の写真に対する現像パラメータ。サイドカーJSONにそのまま保存される。
/// 項目を後から増やしても古いサイドカーを読めるよう、デコードは欠けた項目を既定値で補う。
public struct DevelopSettings: Codable, Equatable, Sendable {
    /// 1: 最初の形式
    /// 2: レンズ補正を lensCorrection(Bool。実際には効いていなかった)から lens(3 種類の補正)に変えた
    /// 3: contrast を「デコーダのコントラスト(効いていなかった)」から自前のトーンカーブ(−1...1)に変えた
    public static let currentSchemaVersion = 3
    public var schemaVersion: Int = DevelopSettings.currentSchemaVersion

    // --- RAWデコード段 ---
    /// 露出補正 (EV)
    public var exposure: Double = 0
    /// ホワイトバランス。nil = 撮影時の値
    public var temperature: Double? = nil
    public var tint: Double? = nil
    /// コントラスト −1.2...1.2(0 = 変えない。ContrastCurve.range)。自前のトーンカーブ(ContrastStage)で掛ける。
    /// 以前はデコーダのコントラスト(nil = 既定値)だったが、CIRAWFilter.contrastAmount は ARW では効かず、
    /// UI・CLI にも出していなかったので、同じ項目を使い直した(schemaVersion 3)
    public var contrast: Double = 0
    /// シャープネス(DetailRanges.sharpness。nil = デコーダ既定値。α7S III では 1)。デコーダは等倍で描くときだけ掛ける
    /// (縮小して描くプレビューには効かない。2026-10-07 に確認)
    public var sharpness: Double? = nil
    /// 輝度ノイズ除去(DetailRanges.luminanceNoiseReduction。nil = デコーダ既定値。ISO に応じてデコーダが決める)
    public var luminanceNoiseReduction: Double? = nil
    /// 色ノイズ除去(DetailRanges.colorNoiseReduction。nil = デコーダ既定値。α7S III では 0.5)
    public var colorNoiseReduction: Double? = nil
    // --- レンズ補正(nil = 撮影時のカメラ設定に従う) ---
    // 旧形式の lensCorrection(Bool)は読まない。デコーダが非対応で実際には効いていなかったため
    public var lens: LensCorrectionSettings? = nil

    // --- HDR ---
    public var hdr = HDRSettings()

    // --- 色 ---
    /// 彩度 (1.0 = 変更なし, 0 = モノクロ, 2 = 2倍)
    public var saturation: Double = 1.0
    /// 自然な彩度 (0 = 変更なし, -1...1)
    public var vibrance: Double = 0

    // --- クロップ(nil = 切り抜きなし) ---
    public var crop: CropSettings? = nil

    // --- ルック(〜風フィルター。nil = なし) ---
    public var look: LookSelection? = nil

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exposure, temperature, tint, contrast, sharpness
        case luminanceNoiseReduction, colorNoiseReduction, lens
        case hdr, saturation, vibrance, crop, look
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DevelopSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? d.exposure
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        contrast = (try? c.decodeIfPresent(Double.self, forKey: .contrast)) ?? d.contrast
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness)
        luminanceNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .luminanceNoiseReduction)
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        lens = try? c.decodeIfPresent(LensCorrectionSettings.self, forKey: .lens)
        hdr = try c.decodeIfPresent(HDRSettings.self, forKey: .hdr) ?? d.hdr
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? d.vibrance
        crop = try c.decodeIfPresent(CropSettings.self, forKey: .crop)
        look = try c.decodeIfPresent(LookSelection.self, forKey: .look)
    }
}

/// HDR関連。2つの意味を扱う:
/// 1. 1枚のRAWの広いダイナミックレンジをSDRに収める「HDR風」トーン処理 (strength/highlights/shadows)
/// 2. HDRディスプレイ向けにハイライトを1.0超で出力する「HDR出力」 (extendedOutput)
public struct HDRSettings: Codable, Equatable, Sendable {
    /// ローカルトーンマッピングの強さ 0...1 (0 = オフ)
    public var strength: Double = 0
    /// ハイライト回復 0...1 (0 = 変更なし)
    public var highlights: Double = 0
    /// シャドウ持ち上げ 0...1 (0 = 変更なし)
    public var shadows: Double = 0
    /// HDR出力(EDR)。HEIF HDRで書き出すときに有効。SDR形式では1.0超がクリップされる。
    public var extendedOutput: Bool = false

    public init() {}

    public var isNeutral: Bool { strength == 0 && highlights == 0 && shadows == 0 && !extendedOutput }
}

/// クロップと傾き補正。座標は回転前の画像全体に対する比率 (0...1, 左上原点)。
public struct CropSettings: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// 傾き補正(度)。正 = 時計回り
    public var angle: Double = 0
    /// UIで比率を固定するための情報
    public var aspect: AspectRatio = .free

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1,
                angle: Double = 0, aspect: AspectRatio = .free) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.angle = angle; self.aspect = aspect
    }

    public static let full = CropSettings()

    /// 指定比率で画像中央に最大の枠を作る。傾き補正があるときは、回転後の画像に収まる最大の枠にする。
    /// 比率が「自由」のときは元画像の比率で作る。
    /// - imageAspect: 元画像の 幅/高さ
    public static func centered(aspect: AspectRatio, imageAspect: Double, angle: Double = 0) -> CropSettings {
        guard let ratio = aspect.value(imageAspect: imageAspect) else {
            return CropSettings(angle: angle, aspect: aspect).fitted(imageAspect: imageAspect)
        }
        // 正規化座標での高さ/幅 の比
        var w = 1.0
        var h = imageAspect / ratio
        if h > 1 { w = 1 / h; h = 1 }
        return CropSettings(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h,
                            angle: angle, aspect: aspect).fitted(imageAspect: imageAspect)
    }

    /// 範囲外にはみ出さないよう補正する
    public func clamped(minSize: Double = 0.05) -> CropSettings {
        var c = self
        c.width = min(max(c.width, minSize), 1)
        c.height = min(max(c.height, minSize), 1)
        c.x = min(max(c.x, 0), 1 - c.width)
        c.y = min(max(c.y, 0), 1 - c.height)
        return c
    }
}

public enum AspectRatio: String, Codable, CaseIterable, Sendable {
    case free, original, square, r3x2, r4x3, r16x9, r2x3, r4x5

    public var label: String {
        switch self {
        case .free: return "自由"
        case .original: return "元の比率"
        case .square: return "1:1"
        case .r3x2: return "3:2"
        case .r4x3: return "4:3"
        case .r16x9: return "16:9"
        case .r2x3: return "2:3 (縦)"
        case .r4x5: return "4:5 (縦)"
        }
    }

    /// 幅/高さ。free は nil
    public func value(imageAspect: Double) -> Double? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        case .r3x2: return 3.0 / 2
        case .r4x3: return 4.0 / 3
        case .r16x9: return 16.0 / 9
        case .r2x3: return 2.0 / 3
        case .r4x5: return 4.0 / 5
        }
    }
}

/// 選択中のルックとその効き具合
public struct LookSelection: Codable, Equatable, Sendable {
    public var id: String
    /// 0...1 (1 = ルックそのまま)
    public var strength: Double = 1

    public init(id: String, strength: Double = 1) {
        self.id = id; self.strength = strength
    }
}

/// デコーダが報告する撮影時の値(WBのリセット等に使う)
public struct AsShotValues: Equatable, Sendable {
    public var temperature: Double
    public var tint: Double
    public init(temperature: Double, tint: Double) {
        self.temperature = temperature; self.tint = tint
    }
}
