import CoreImage
import CoreImage.CIFilterBuiltins

/// Adobe/Resolve形式の .cube (3D LUT) を読み込むルック。
/// 一般的な写真用LUTは sRGB(Rec.709)ガンマの入力を想定しているので、その色空間で適用する。
public final class CubeFileLook: Look {
    public enum ParseError: Error, CustomStringConvertible {
        case missingSize, only3DSupported, wrongValueCount(expected: Int, actual: Int), badLine(Int)
        public var description: String {
            switch self {
            case .missingSize: return "LUT_3D_SIZE がありません"
            case .only3DSupported: return "1D LUTには未対応です"
            case .wrongValueCount(let e, let a): return "値の数が合いません (期待 \(e), 実際 \(a))"
            case .badLine(let n): return "\(n)行目を読めません"
            }
        }
    }

    public let id: String
    public let displayName: String
    public let size: Int
    private let cubeData: Data

    public convenience init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(text: text, id: "cube:" + url.lastPathComponent,
                      fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    public init(text: String, id: String, fallbackName: String) throws {
        var title: String?
        var size: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []

        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                size = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE":
                throw ParseError.only3DSupported
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3 else { throw ParseError.badLine(index + 1) }
                if parts[0] == "DOMAIN_MIN" { domainMin = SIMD3(v[0], v[1], v[2]) }
                else { domainMax = SIMD3(v[0], v[1], v[2]) }
            default:
                let v = parts.compactMap { Float($0) }
                guard v.count == 3 else {
                    // 未知のキーワード行は無視、数値行の崩れはエラー
                    if Float(parts[0]) != nil { throw ParseError.badLine(index + 1) }
                    continue
                }
                let n = (SIMD3(v[0], v[1], v[2]) - domainMin) / (domainMax - domainMin)
                values.append(contentsOf: [n.x, n.y, n.z, 1])
            }
        }

        guard let n = size else { throw ParseError.missingSize }
        let expected = n * n * n * 4
        guard values.count == expected else {
            throw ParseError.wrongValueCount(expected: n * n * n, actual: values.count / 4)
        }

        self.id = id
        self.displayName = title?.isEmpty == false ? title! : fallbackName
        self.size = n
        // .cube も Core Image と同じく R が最速で変化する順なので並べ替え不要
        self.cubeData = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func apply(to image: CIImage) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(size)
        f.cubeData = cubeData
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return f.outputImage ?? image
    }
}
