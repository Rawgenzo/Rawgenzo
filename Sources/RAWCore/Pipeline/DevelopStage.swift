import CoreImage

/// 処理の順番。数値の小さい順に適用される。
/// 例: クロップ(geometry)をルック(look)より先に行うので、周辺減光はクロップ後の枠に掛かる。
public enum StagePhase: Int, Comparable, Sendable {
    case tone = 100      // ハイライト/シャドウなど明るさ
    case color = 200     // 彩度など
    case camera = 300    // 機種固有の補正
    case geometry = 400  // 傾き補正・クロップ
    case look = 500      // 〜風フィルター

    public static func < (a: StagePhase, b: StagePhase) -> Bool { a.rawValue < b.rawValue }
}

/// プレビューと書き出しで変えたい描画条件
public struct RenderOptions: Sendable {
    public enum CropMode: Sendable {
        case apply       // 通常: 傾き補正 + 切り抜き
        case rotateOnly  // クロップ編集中: 傾きだけ反映し、全体を表示
    }
    public var scale: Double
    public var draft: Bool
    public var cropMode: CropMode

    public init(scale: Double = 1, draft: Bool = false, cropMode: CropMode = .apply) {
        self.scale = scale; self.draft = draft; self.cropMode = cropMode
    }
}

/// デコード後の画像に適用する処理の単位。
public protocol DevelopStage {
    var name: String { get }
    var phase: StagePhase { get }
    func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage
}
