import CoreImage
import Metal

/// コントラストのトーンカーブ(CPU での計算。GPU のカーネルと同じ式で、テストの基準に使う)。
///
/// 見た目の明るさに近い値(sRGB のガンマを掛けた値)の上で、中間グレー(リニアで 0.18)を軸にした S 字のカーブを掛ける。
/// - 黒(0)・白(1)・中間グレーは動かさない
/// - 軸より下は 2 次式で下げ、上は 2 次式で上げる。軸での傾きは 1 + k、両端での傾きは 1 − k(k = 強さ × 0.6)
/// - 強さは −1.2...1.2(スライダーの −120〜+120)。|k| ≤ 0.72 < 1 なのでカーブは常に右上がり
///   (明るさの順序が入れ替わらない)
/// - 0〜1 の外(HDR の 1 超え、負の値)はそのまま通す
public enum ContrastCurve {
    /// 強さ 1(スライダーの +100)のときの、軸での傾きの増分
    public static let maxSlopeChange = 0.6
    /// 強さの範囲。オーナーの希望で ±1 から 2 割広げた(1 目盛りあたりの効き方は変えていない)
    public static let range: ClosedRange<Double> = -1.2...1.2
    /// 中間グレー(リニア 0.18)の、見た目の明るさでの位置
    public static let pivot = encode(0.18)

    /// リニア → sRGB のガンマを掛けた値
    public static func encode(_ y: Double) -> Double {
        y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
    }

    /// sRGB のガンマを掛けた値 → リニア
    public static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// 見た目の明るさ x(0...1)にカーブを掛ける。amount は range の範囲(外れた値は端に丸める)
    public static func apply(_ x: Double, amount: Double) -> Double {
        guard x > 0, x < 1 else { return x }
        let k = min(max(amount, range.lowerBound), range.upperBound) * maxSlopeChange
        let p = pivot
        if x < p {
            let t = x / p
            return x - k * p * t * (1 - t)
        }
        let u = (x - p) / (1 - p)
        return x + k * (1 - p) * u * (1 - u)
    }

    /// リニアの RGB に掛ける。輝度にカーブを掛け、RGB を同じ比率で拡大縮小する(色相を変えないため)
    public static func applyLinear(_ rgb: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let y = (rgb * SIMD3(0.2126, 0.7152, 0.0722)).sum()
        guard y > 0 else { return rgb }
        let y2 = decode(apply(encode(y), amount: amount))
        return rgb * (y2 / y)
    }
}

/// コントラスト(DevelopSettings.contrast、ContrastCurve.range、0 = 変えない)
public struct ContrastStage: DevelopStage {
    public init() {}
    public let name = "contrast"
    public let phase = StagePhase.tone

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        let amount = min(max(settings.contrast, ContrastCurve.range.lowerBound), ContrastCurve.range.upperBound)
        guard abs(amount) > 1e-6, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        // カーネルを準備できない(GPU が使えない)ときは、コントラストを掛けずに続ける
        return (try? ContrastKernel.apply(withExtent: image.extent, inputs: [image],
                                          arguments: ["amount": amount])) ?? image
    }
}

final class ContrastKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    /// 画素ごとの処理なので、出力と同じ範囲だけ読めばよい
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let commandBuffer = output.metalCommandBuffer,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RAWError.renderFailed("コントラスト: GPU の画像を取得できません")
        }
        let pipeline = try MetalKernels.pipeline(name: "contrastCurve", source: source_, device: commandBuffer.device)
        // 入力の範囲が出力より広く渡されても同じ画素を読むよう、ずれを渡す
        // (テクスチャは 1 行目が上端なので、縦は上端どうしの差)
        var params = SIMD4<Float>(Float((arguments?["amount"] as? Double ?? 0) * ContrastCurve.maxSlopeChange),
                                  Float(ContrastCurve.pivot),
                                  Float(output.region.minX - input.region.minX),
                                  Float(input.region.maxY - output.region.maxY))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        MetalKernels.dispatch(encoder, over: destination)
        encoder.endEncoding()
    }

    /// ContrastCurve と同じ式
    private static let source_ = """
    #include <metal_stdlib>
    using namespace metal;

    static float encodeSRGB(float y) { return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1.0 / 2.4) - 0.055; }
    static float decodeSRGB(float v) { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }

    static float curve(float x, float k, float p) {
        if (x <= 0.0 || x >= 1.0) return x;
        if (x < p) { float t = x / p; return x - k * p * t * (1.0 - t); }
        float u = (x - p) / (1.0 - p);
        return x + k * (1.0 - p) * u * (1.0 - u);
    }

    // params: x = 強さ × 最大の傾きの増分(k)、y = 中間グレーの位置(見た目の明るさ)、zw = 入力と出力のずれ
    kernel void contrastCurve(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float4 &params [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(uint2(int2(gid) + int2(params.zw)));
        // α で割ってから掛け、戻す(Core Image の画像は α を掛けた形で持っている)
        float a = c.a;
        float3 rgb = a > 0.0 ? c.rgb / a : c.rgb;
        float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        if (y > 0.0) {
            float y2 = decodeSRGB(curve(encodeSRGB(y), params.x, params.y));
            rgb *= y2 / y;
        }
        dst.write(float4(rgb * (a > 0.0 ? a : 1.0), a), gid);
    }
    """
}
