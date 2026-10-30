import Foundation
import ImageIO

/// カメラ判定や初期値決定に使う撮影メタデータ。
/// デコーダに依存しないよう、ImageIOで独立して読む。
public struct RAWMetadata: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    public var lensModel: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var captureDate: String?
    // --- 撮影情報の表示用(調整パネルの「撮影情報」) ---
    /// 露出補正(EV)
    public var exposureBias: Double?
    /// 露出プログラム(EXIF の ExposureProgram の値。ExifLabels.exposureProgram で名前に)
    public var exposureProgram: Int?
    /// 測光方式(EXIF の MeteringMode)
    public var meteringMode: Int?
    /// フラッシュ(EXIF の Flash。下位ビットが発光したか)
    public var flash: Int?
    /// ホワイトバランス(EXIF の WhiteBalance。0 = オート、1 = マニュアル)
    public var whiteBalance: Int?
    /// 35mm 換算の焦点距離
    public var focalLength35mm: Double?
    /// 写真の向き(EXIF の Orientation。1 = そのまま、6 = 90° 時計回り、8 = 90° 反時計回り、3 = 180°)
    public var orientation: Int?
    /// 撮影時にピントを合わせた位置(カメラの記録の向き = 横長の画像に対する比率、左上原点)。ソニーの MakerNote から読む。無ければ nil
    public var focusPoint: CGPoint?

    public init(make: String? = nil, model: String? = nil, iso: Int? = nil,
                exposureTime: Double? = nil, fNumber: Double? = nil,
                focalLength: Double? = nil, lensModel: String? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                captureDate: String? = nil) {
        self.make = make; self.model = model; self.iso = iso
        self.exposureTime = exposureTime; self.fNumber = fNumber
        self.focalLength = focalLength; self.lensModel = lensModel
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.captureDate = captureDate
    }

    public static func read(from url: URL) throws -> RAWMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw RAWError.unreadable(url) }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        var m = RAWMetadata(
            make: clean(tiff[kCGImagePropertyTIFFMake]),
            model: clean(tiff[kCGImagePropertyTIFFModel]),
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            lensModel: clean(exif[kCGImagePropertyExifLensModel]),
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int,
            captureDate: clean(exif[kCGImagePropertyExifDateTimeOriginal])
        )
        m.exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
        m.exposureProgram = exif[kCGImagePropertyExifExposureProgram] as? Int
        m.meteringMode = exif[kCGImagePropertyExifMeteringMode] as? Int
        m.flash = exif[kCGImagePropertyExifFlash] as? Int
        m.whiteBalance = exif[kCGImagePropertyExifWhiteBalance] as? Int
        m.focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double
        m.orientation = props[kCGImagePropertyOrientation] as? Int
        if m.make?.uppercased().hasPrefix("SONY") == true { m.focusPoint = SonyMakerNote.focusPoint(url: url) }
        return m
    }

    /// EXIF文字列の末尾スペースやNULを除去する
    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
