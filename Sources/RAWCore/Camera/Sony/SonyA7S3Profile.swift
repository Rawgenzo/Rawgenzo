import Foundation

/// SONY α7S III (ILCE-7SM3)
/// 約1210万画素 / ARW(非圧縮・ロスレス圧縮・圧縮)
public struct SonyA7S3Profile: CameraProfile {
    public init() {}

    public let id = "sony.ilce-7sm3"
    public let displayName = "SONY α7S III"
    public let fileExtensions: Set<String> = ["arw"]

    public func matches(_ metadata: RAWMetadata) -> Bool {
        guard let make = metadata.make?.uppercased(),
              let model = metadata.model?.uppercased() else { return false }
        return make.hasPrefix("SONY") && model == "ILCE-7SM3"
    }

    public func makeSource(url: URL, metadata: RAWMetadata) throws -> RAWSource {
        // macOS標準のRAWデコーダ(Core Image)を使う
        try CoreImageRAWSource(url: url, metadata: metadata)
    }

    /// ARW に記録されたレンズ補正値(周辺減光・歪曲・倍率色収差)
    public func lensCorrection(url: URL, metadata: RAWMetadata) -> LensCorrectionData? {
        SonyLensCorrection.read(from: url)
    }

    // 高感度での輝度ノイズ除去の初期値は、デコーダが ISO に応じて決める値を使う(DetailDefaults)。
    // 以前はここで ISO 3200 以上に 0.4〜0.8 を入れていたが、デコーダ自身がより細かく決めていて
    // (ISO 8000 で 0.302、12800 で 0.605)、↶ で戻る先とずれるのでやめた(2026-10-07)
}
