import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// RGB→RGB の関数から3D LUTを生成して適用するルック。
/// 新しい「〜風」は、色の変換を関数で書くだけで作れる。
/// 関数の入出力は sRGBガンマの 0...1 (人の見た目に近い空間)。
public final class ColorCubeLook: Look {
    public typealias Transform = (SIMD3<Float>) -> SIMD3<Float>

    public let id: String
    public let displayName: String
    private let cubeSize: Int
    private let transform: Transform
    /// LUT適用後に追加で掛ける処理(周辺減光など)
    private let finish: ((CIImage) -> CIImage)?
    private lazy var cubeData: Data = ColorCubeLook.makeCube(size: cubeSize, transform)

    public init(id: String, displayName: String, cubeSize: Int = 32,
                transform: @escaping Transform, finish: ((CIImage) -> CIImage)? = nil) {
        self.id = id
        self.displayName = displayName
        self.cubeSize = cubeSize
        self.transform = transform
        self.finish = finish
    }

    public func apply(to image: CIImage) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(cubeSize)
        f.cubeData = cubeData
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let out = f.outputImage ?? image
        return finish?(out) ?? out
    }

    /// Core Imageのキューブは R が最速で変化する順、RGBA Float32
    static func makeCube(size n: Int, _ transform: Transform) -> Data {
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        let scale = 1 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let input = SIMD3<Float>(Float(r), Float(g), Float(b)) * scale
                    let o = transform(input).clamped(lowerBound: .zero, upperBound: .one)
                    values.append(contentsOf: [o.x, o.y, o.z, 1])
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// ルックを書くための小さな色計算ヘルパー
public enum ColorMath {
    public static let rec709 = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    public static func luminance(_ c: SIMD3<Float>) -> Float { simd_dot(c, rec709) }

    public static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    /// 彩度の変更 (1 = そのまま)
    public static func saturate(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        mix(SIMD3(repeating: luminance(c)), c, amount)
    }

    /// なめらかなS字カーブ (amount 0 = 直線, 1 = 強いS字)
    public static func sCurve(_ x: Float, _ amount: Float) -> Float {
        let s = x * x * (3 - 2 * x)
        return x + (s - x) * amount
    }

    public static func sCurve(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        SIMD3(sCurve(c.x, amount), sCurve(c.y, amount), sCurve(c.z, amount))
    }

    /// 黒を持ち上げ、白を抑える(フィルムっぽい眠さ)
    public static func fade(_ c: SIMD3<Float>, black: Float, white: Float = 1) -> SIMD3<Float> {
        SIMD3(repeating: black) + c * (white - black)
    }
}
