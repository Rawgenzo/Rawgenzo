import Foundation

/// 対応カメラ1機種(または1系統)を表す。
/// 新しいカメラに対応するときは、このプロトコルに準拠した型を作って
/// CameraRegistry.makeDefault() に登録するだけで済む。
public protocol CameraProfile {
    /// 安定した識別子。サイドカーに保存されるので変更しないこと。
    var id: String { get }
    var displayName: String { get }
    /// 小文字の拡張子 (例: "arw")
    var fileExtensions: Set<String> { get }

    /// メタデータがこのカメラのものか判定する
    func matches(_ metadata: RAWMetadata) -> Bool

    /// このカメラ用のデコーダを生成する。
    /// Core Imageが未対応の機種は、LibRaw等の別実装を返せばよい。
    func makeSource(url: URL, metadata: RAWMetadata) throws -> RAWSource

    /// 新規に開いた写真の初期現像パラメータ(ISO別ノイズ処理など機種固有の調整)
    func initialSettings(for metadata: RAWMetadata) -> DevelopSettings

    /// 機種固有の後処理。phase は .camera を推奨。既定は空。
    var extraStages: [DevelopStage] { get }

    /// RAW に記録されたレンズ補正データ。無ければ nil(既定は nil)。
    /// 写真を開いたときに一度だけ呼ばれる(RAWSource の約束と同じく、開いた時点で決まる値として持つ)
    func lensCorrection(url: URL, metadata: RAWMetadata) -> LensCorrectionData?
}

public extension CameraProfile {
    func initialSettings(for metadata: RAWMetadata) -> DevelopSettings { DevelopSettings() }
    var extraStages: [DevelopStage] { [] }
    func lensCorrection(url: URL, metadata: RAWMetadata) -> LensCorrectionData? { nil }
}
