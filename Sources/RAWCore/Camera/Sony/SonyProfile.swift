import CoreGraphics
import Foundation

/// SONY の機種(ARW)。デコーダ・レンズ補正・フォーカス位置の読み方は機種によらず同じなので、
/// 機種ごとの違い(EXIF の機種名・表示名・id)は Model に書く
public struct SonyProfile: CameraProfile {
    public struct Model: Sendable {
        /// EXIF の Model(例: ILCE-7SM3)
        public let exifModel: String
        public let displayName: String
        /// サイドカーに保存される。変えないこと
        public let id: String
        /// Core Image の対応機種一覧での名前(rawdev check で確かめる)
        public let coreImageName: String
    }

    /// 対応機種。機種を足すときは Model に定義を足し、ここに並べる(先に rawdev check で Core Image の対応を確かめる)
    public static let models: [Model] = [.a7S3]

    public static var all: [CameraProfile] { models.map(SonyProfile.init) }

    public let model: Model

    public init(_ model: Model) {
        self.model = model
    }

    public var id: String { model.id }
    public var displayName: String { model.displayName }
    public var coreImageModelName: String? { model.coreImageName }
    public let fileExtensions: Set<String> = ["arw"]

    public func matches(_ metadata: RAWMetadata) -> Bool {
        guard let make = metadata.make?.uppercased(),
              let exifModel = metadata.model?.uppercased() else { return false }
        return make.hasPrefix("SONY") && exifModel == model.exifModel
    }

    public func makeSource(url: URL, metadata: RAWMetadata) throws -> RAWSource {
        // macOS標準のRAWデコーダ(Core Image)を使う
        try CoreImageRAWSource(url: url, metadata: metadata)
    }

    /// ARW に記録されたレンズ補正値(周辺減光・歪曲・倍率色収差)
    public func lensCorrection(url: URL, metadata: RAWMetadata) -> LensCorrectionData? {
        SonyLensCorrection.read(from: url)
    }

    public func focusPoint(url: URL, metadata: RAWMetadata) -> CGPoint? {
        SonyMakerNote.focusPoint(url: url)
    }

    // 高感度での輝度ノイズ除去の初期値は、デコーダが ISO に応じて決める値を使う(DetailDefaults)。
    // 以前はここで ISO 3200 以上に 0.4〜0.8 を入れていたが、デコーダ自身がより細かく決めていて
    // (ISO 8000 で 0.302、12800 で 0.605)、↶ で戻る先とずれるのでやめた(2026-10-07)
}

extension SonyProfile.Model {
    /// α7S III。約1210万画素 / ARW(非圧縮・ロスレス圧縮・圧縮)
    public static let a7S3 = Self(exifModel: "ILCE-7SM3", displayName: "SONY α7S III",
                                  id: "sony.ilce-7sm3", coreImageName: "Sony Alpha ILCE-7S III")
}
