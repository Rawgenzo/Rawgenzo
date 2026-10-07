import CoreImage

/// 開いた1枚のRAW。デコーダの実装差(Core Image / LibRaw など)をここで吸収する。
///
/// スレッドについての約束:
/// - render は内部状態を書き換えるので、同時に複数スレッドから呼ばないこと(アプリでは描画キューだけが呼ぶ)
/// - url / metadata / asShot / nativeSize / detailDefaults は、開いた時点で決まる**変わらない値**として実装すること。
///   UI(メインスレッド)が描画中にも読むので、プロパティの中でデコーダに問い合わせてはいけない
///   (CIRAWFilter.nativeSize を毎回読む実装にしていて、描画と重なると出力が空になる不具合が出た)
/// シャープネス・ノイズ除去の範囲(CIRAWFilter で 2026-10-07 に測って決めた)
public enum DetailRanges {
    /// 値に比例して効く(8 まで頭打ちなし)。既定は 1。オーナーの希望で 0...3 から広げた
    public static let sharpness: ClosedRange<Double> = 0...6
    /// 1 を超えると効き方が逆になる(細部が戻り、3 では補正なしより粗くなる)ので 1 まで
    public static let luminanceNoiseReduction: ClosedRange<Double> = 0...1
    /// 1 を超えても少しずつ効く。既定は 0.5。オーナーの希望で 0...1 から広げた
    public static let colorNoiseReduction: ClosedRange<Double> = 0...2
}

/// デコーダのシャープネス・ノイズ除去の既定値。輝度ノイズ除去は ISO に応じてデコーダが決める
/// (α7S III: ISO 100 以下で 0、ISO 8000 で 0.302、ISO 12800 で 0.605)
public struct DetailDefaults: Equatable, Sendable {
    public var sharpness: Double
    public var luminanceNoiseReduction: Double
    public var colorNoiseReduction: Double

    public init(sharpness: Double, luminanceNoiseReduction: Double, colorNoiseReduction: Double) {
        self.sharpness = sharpness
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.colorNoiseReduction = colorNoiseReduction
    }
}

public protocol RAWSource: AnyObject {
    var url: URL { get }
    var metadata: RAWMetadata { get }
    var asShot: AsShotValues { get }
    /// 回転適用後の出力サイズ(等倍)
    var nativeSize: CGSize { get }
    /// シャープネス・ノイズ除去のデコーダ既定値(DevelopSettings で nil のときに使う値)
    var detailDefaults: DetailDefaults { get }

    /// デコード段の設定を適用した画像を返す。
    /// - scale: 1.0 = 等倍。プレビュー時は縮小して高速化する。
    /// - draft: 品質より速度を優先する(スライダー操作中など)
    func render(settings: DevelopSettings, scale: Double, draft: Bool) throws -> CIImage
}
