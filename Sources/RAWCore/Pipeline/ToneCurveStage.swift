import CoreImage
import Metal

/// トーンカーブの計算(CPU。GPU のカーネルと同じ式で、テストの基準に使う)。
///
/// カーブは見た目の明るさ(sRGB のガンマを掛けた値)の上で掛ける。画像の値はリニア。
/// 1. 輝度のカーブ: 2 つの結果を「彩度の連動」で混ぜる
///    - 比: 輝度(Rec.709 の重み)にカーブを掛け、RGB を同じ比率で拡大縮小する(色合いと彩度を保つ。ContrastStage と同じ)
///    - チャンネルごと: R・G・B それぞれにカーブを掛ける(S 字なら彩度も上がる)
///    ほぼ黒の所(見た目の明るさ 0.05 未満)は、黒に近いほどチャンネルごとの側へ寄せる。カーブで黒を持ち上げたとき、
///    比で掛けると輝度の小さい色の画素が何倍にもなり(暗い青が鮮やかな青になる)、真っ黒(輝度 0)の画素だけが黒く残るため
/// 2. R・G・B のカーブ: そのチャンネルにだけ掛ける
/// 0〜1 の外は ToneCurveFunction が端の接線で伸ばす(HDR の 1 超えを切らない)
public enum ToneCurveMath {
    /// これより暗い所(見た目の明るさ)は、チャンネルごとの側へ寄せる
    public static let blackBlend = 0.05
    static let weights = SIMD3(0.2126, 0.7152, 0.0722)

    public struct Functions: Sendable {
        public var luma: ToneCurveFunction?
        public var red: ToneCurveFunction?
        public var green: ToneCurveFunction?
        public var blue: ToneCurveFunction?
        public var saturationLink: Double

        /// 変えていないチャンネルは nil(掛けない)
        public init(_ s: ToneCurveSettings) {
            func f(_ c: ToneCurveChannel) -> ToneCurveFunction? {
                ToneCurveSettings.isIdentity(s[c]) ? nil : ToneCurveFunction(s[c])
            }
            luma = f(.luma); red = f(.red); green = f(.green); blue = f(.blue)
            saturationLink = min(max(s.saturationLink, 0), 1)
        }
    }

    static func through(_ f: ToneCurveFunction, _ v: Double) -> Double {
        ContrastCurve.decode(f(ContrastCurve.encode(v)))
    }

    public static func apply(_ rgb: SIMD3<Double>, _ fs: Functions) -> SIMD3<Double> {
        var c = rgb
        if let f = fs.luma {
            let perChannel = SIMD3(through(f, c.x), through(f, c.y), through(f, c.z))
            let y = (c * weights).sum()
            let e = ContrastCurve.encode(max(y, 0))
            let link = max(fs.saturationLink, min(max(1 - e / blackBlend, 0), 1))
            if link >= 1 || y <= 0 {
                c = perChannel
            } else {
                let ratio = c * (through(f, y) / y)
                c = ratio + (perChannel - ratio) * link
            }
        }
        if let f = fs.red { c.x = through(f, c.x) }
        if let f = fs.green { c.y = through(f, c.y) }
        if let f = fs.blue { c.z = through(f, c.z) }
        return c
    }
}

/// トーンカーブ(DevelopSettings.toneCurve)。コントラストの後(tone の段の最後)
public struct ToneCurveStage: DevelopStage {
    public init() {}
    public let name = "toneCurve"
    public let phase = StagePhase.tone

    /// GPU に渡す表の大きさ(1 チャンネルあたり)
    static let tableSize = 1024

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        guard let s = settings.toneCurve, !s.isNeutral, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        let fs = ToneCurveMath.Functions(s)
        // 4 本の表を続けて並べる(変えていないチャンネルは使わないが、場所は取る)
        var table: [Float] = []
        for f in [fs.luma, fs.red, fs.green, fs.blue] {
            table += f?.table(Self.tableSize) ?? [Float](repeating: 0, count: Self.tableSize)
        }
        var slopes: [Double] = []
        for f in [fs.luma, fs.red, fs.green, fs.blue] { slopes += [f?.lowSlope ?? 1, f?.highSlope ?? 1] }
        let flags = SIMD4<Float>(fs.luma == nil ? 0 : 1, fs.red == nil ? 0 : 1, fs.green == nil ? 0 : 1, fs.blue == nil ? 0 : 1)
        // カーネルを準備できない(GPU が使えない)ときは、カーブを掛けずに続ける
        return (try? ToneCurveKernel.apply(withExtent: image.extent, inputs: [image], arguments: [
            "table": table.withUnsafeBufferPointer { Data(buffer: $0) },
            "flags": [flags.x, flags.y, flags.z, flags.w].map(Double.init),
            "link": fs.saturationLink,
            "slopes": slopes,
        ])) ?? image
    }
}

final class ToneCurveKernel: CIImageProcessorKernel {
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
              let table = arguments?["table"] as? Data,
              let buffer = table.withUnsafeBytes({ commandBuffer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RAWError.renderFailed("トーンカーブ: GPU の画像を取得できません")
        }
        let pipeline = try MetalKernels.pipeline(name: "toneCurve", source: source_, device: commandBuffer.device)
        let f = (arguments?["flags"] as? [Double] ?? [0, 0, 0, 0]).map(Float.init)
        let sl = (arguments?["slopes"] as? [Double] ?? [Double](repeating: 1, count: 8)).map(Float.init)
        var params = Params(
            flags: SIMD4(f[0], f[1], f[2], f[3]),
            lowSlopes: SIMD4(sl[0], sl[2], sl[4], sl[6]),
            highSlopes: SIMD4(sl[1], sl[3], sl[5], sl[7]),
            // 入力の範囲が出力より広く渡されても同じ画素を読むよう、ずれを渡す
            // (テクスチャは 1 行目が上端なので、縦は上端どうしの差)
            offsetLink: SIMD4(Float(output.region.minX - input.region.minX), Float(input.region.maxY - output.region.maxY),
                              Float(arguments?["link"] as? Double ?? 0), Float(ToneCurveStage.tableSize)))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 1)
        MetalKernels.dispatch(encoder, over: destination)
        encoder.endEncoding()
    }

    struct Params {
        /// 輝度・R・G・B のカーブを掛けるか(1 = 掛ける)
        var flags: SIMD4<Float>
        /// 0 の外・1 の外へ伸ばすときの傾き(輝度・R・G・B)
        var lowSlopes: SIMD4<Float>
        var highSlopes: SIMD4<Float>
        /// xy = 入力と出力のずれ、z = 彩度の連動、w = 表の大きさ
        var offsetLink: SIMD4<Float>
    }

    /// ToneCurveMath と同じ式(カーブは表を線形に補間する)
    private static let source_ = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float4 flags; float4 lowSlopes; float4 highSlopes; float4 offsetLink; };

    static float encodeSRGB(float y) { return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1.0 / 2.4) - 0.055; }
    static float decodeSRGB(float v) { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }

    // 表 ch 番目のカーブ。0〜1 の外は端の接線で伸ばす
    static float curve(device const float *table, constant Params &pr, int ch, int n, float x) {
        device const float *t = table + ch * n;
        if (x <= 0.0) return t[0] + x * pr.lowSlopes[ch];
        if (x >= 1.0) return t[n - 1] + (x - 1.0) * pr.highSlopes[ch];
        float p = x * float(n - 1);
        int i = min(int(p), n - 2);
        return mix(t[i], t[i + 1], p - float(i));
    }

    static float through(device const float *table, constant Params &pr, int ch, int n, float v) {
        return decodeSRGB(curve(table, pr, ch, n, encodeSRGB(v)));
    }

    kernel void toneCurve(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant Params &params [[buffer(0)]],
                          device const float *table [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(uint2(int2(gid) + int2(params.offsetLink.xy)));
        // α で割ってから掛け、戻す(Core Image の画像は α を掛けた形で持っている)
        float a = c.a;
        float3 rgb = a > 0.0 ? c.rgb / a : c.rgb;
        int n = int(params.offsetLink.w);
        if (params.flags.x > 0.5) {
            float3 per = float3(through(table, params, 0, n, rgb.r), through(table, params, 0, n, rgb.g), through(table, params, 0, n, rgb.b));
            float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float e = encodeSRGB(max(y, 0.0));
            float link = max(params.offsetLink.z, clamp(1.0 - e / \(ToneCurveMath.blackBlend), 0.0, 1.0));
            if (link >= 1.0 || y <= 0.0) {
                rgb = per;
            } else {
                float3 ratio = rgb * (through(table, params, 0, n, y) / y);
                rgb = ratio + (per - ratio) * link;
            }
        }
        if (params.flags.y > 0.5) rgb.r = through(table, params, 1, n, rgb.r);
        if (params.flags.z > 0.5) rgb.g = through(table, params, 2, n, rgb.g);
        if (params.flags.w > 0.5) rgb.b = through(table, params, 3, n, rgb.b);
        dst.write(float4(rgb * (a > 0.0 ? a : 1.0), a), gid);
    }
    """
}
