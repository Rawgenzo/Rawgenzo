import CoreImage
import Foundation

public struct Exporter {
    public enum Format: String, CaseIterable, Sendable {
        case jpeg, heif, tiff16
        /// 10bit HEIF (HLG)。HDR出力をオンにした写真を、HDRディスプレイで明るく見せる用
        case heifHDR = "heif-hdr"

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heif, .heifHDR: return "heic"
            case .tiff16: return "tif"
            }
        }
    }

    public enum OutputColorSpace: String, CaseIterable, Sendable {
        case sRGB, displayP3, adobeRGB
        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            }
        }
    }

    public let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public func write(_ image: CIImage, to url: URL, format: Format,
                      colorSpace: OutputColorSpace = .sRGB, quality: Double = 0.92) throws {
        let cs = colorSpace.cgColorSpace
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        switch format {
        case .jpeg:
            try context.writeJPEGRepresentation(of: image, to: url, colorSpace: cs, options: opts)
        case .heif:
            try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8,
                                                colorSpace: cs, options: opts)
        case .heifHDR:
            let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
            try context.writeHEIF10Representation(of: image, to: url, colorSpace: hlg, options: opts)
        case .tiff16:
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16,
                                                colorSpace: cs, options: [:])
        }
    }
}
