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

        return RAWMetadata(
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
    }

    /// EXIF文字列の末尾スペースやNULを除去する
    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
