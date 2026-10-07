import Foundation

/// Sony の ARW に記録されたレンズ補正値を読む。
/// IFD0 の SubIFDs(0x014a)が指す SubIFD に、補正値と撮影時のカメラ設定が平文で入っている
/// (同じ値が暗号化された SR2SubIFD にもあるが、そちらは読まない)。詳しくは docs/sony-lens-correction.md
public enum SonyLensCorrection {
    /// 読み出したままの値(換算前)。確認・テスト用
    public struct Tags: Equatable, Sendable {
        public var vignettingParams: [Int]     // 0x7032
        public var chromaticParams: [Int]      // 0x7035
        public var distortionParams: [Int]     // 0x7037
        public var vignettingSetting: Int?     // 0x7031: 256 = 切, 257 = オート, 511 = 補正値なし
        public var chromaticSetting: Int?      // 0x7034: 0 = 切, 1 = オート, 255 = 補正値なし
        public var distortionSetting: Int?     // 0x7036: 0 = 切, 1 = オート, 17 = オート(レンズで固定), 255 = 補正値なし
    }

    public static func readTags(from url: URL) -> Tags? {
        guard let tiff = TIFFReader(url: url), let ifd0 = tiff.firstIFDOffset,
              let entries0 = tiff.entries(atIFD: ifd0) else { return nil }
        var candidates = [entries0]
        if let sub = entries0.first(where: { $0.tag == 0x014a }), let offsets = tiff.integers(sub) {
            candidates += offsets.compactMap { tiff.entries(atIFD: $0) }
        }
        // タグ番号順に並んでいないので、二分探索せず全部見る
        for entries in candidates {
            func ints(_ tag: UInt16) -> [Int]? {
                entries.first(where: { $0.tag == tag }).flatMap { tiff.integers($0) }
            }
            guard let v = ints(0x7032), let c = ints(0x7035), let d = ints(0x7037) else { continue }
            return Tags(vignettingParams: v, chromaticParams: c, distortionParams: d,
                        vignettingSetting: ints(0x7031)?.first,
                        chromaticSetting: ints(0x7034)?.first,
                        distortionSetting: ints(0x7036)?.first)
        }
        return nil
    }

    /// 撮影時のカメラ設定。分からない値は「切」とみなす(カメラが補正しなかったものとして扱う)
    static func cameraSettings(_ t: Tags) -> LensCorrectionSettings {
        LensCorrectionSettings(vignetting: t.vignettingSetting == 257,
                               distortion: t.distortionSetting == 1 || t.distortionSetting == 17,
                               chromaticAberration: t.chromaticSetting == 1)
    }

    public static func read(from url: URL) -> LensCorrectionData? {
        guard let t = readTags(from: url) else { return nil }
        // 「補正値なし」と記録されていれば使わない(電子接点の無いレンズなど)
        if t.vignettingSetting == 511 || t.chromaticSetting == 255 || t.distortionSetting == 255 { return nil }
        return LensCorrectionData.sony(distortion: t.distortionParams, chromatic: t.chromaticParams,
                                       vignetting: t.vignettingParams, cameraSettings: cameraSettings(t))
    }
}
