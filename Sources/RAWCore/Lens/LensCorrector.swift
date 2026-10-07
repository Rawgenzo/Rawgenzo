import CoreImage
import Metal

/// レンズ補正(周辺減光・歪曲・倍率色収差)を GPU で掛ける。
///
/// Core Image の組み込みフィルターには任意の放射状の変形が無いので、Metal の計算カーネルを
/// CIImageProcessorKernel で Core Image の処理に組み込む。カーネルは最初に使うときに実行時にコンパイルする
/// (SwiftPM のコマンドラインビルドでは Core Image 用の Metal ライブラリを作れないため)。
///
/// 1 回の処理で、出力の画素ごとに「色ごとにどこから色を取るか(歪曲・倍率色収差)」と
/// 「どれだけ明るくするか(周辺減光)」を計算する。デコード直後のリニアな画像に掛ける。
public enum LensCorrector {
    /// 補正を掛けた画像。設定で全部切ってあれば元の画像をそのまま返す
    public static func apply(_ image: CIImage, data: LensCorrectionData,
                             settings: LensCorrectionSettings) throws -> CIImage {
        guard !settings.isNone else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return image }

        let scale = autoScale(data: data, settings: settings, imageAspect: Double(extent.width / extent.height))
        let n = data.knots.count
        // knots, R の倍率, G の倍率, B の倍率, 周辺減光の係数(各 n 個)
        var table: [Float] = data.knots.map(Float.init)
        for c in LensCorrectionData.Channel.allCases {
            table += data.knots.map { Float(data.magnification(c, at: $0, settings: settings)) }
        }
        table += data.knots.map { Float(data.vignettingFactor(at: $0, settings: settings)) }

        let arguments: [String: Any] = [
            "table": table.withUnsafeBufferPointer { Data(buffer: $0) },
            "count": n,
            "extent": CIVector(cgRect: extent),
            "scale": scale,
        ]
        return try LensCorrectionKernel.apply(withExtent: extent, inputs: [image], arguments: arguments)
    }

    // MARK: 拡大率のキャッシュ(縁を全部調べるので、描画のたびに計算し直さない)

    private struct ScaleKey: Hashable {
        let data: LensCorrectionData
        let settings: LensCorrectionSettings
        let aspect: Int
    }
    private static let scaleCache = LockedCache<ScaleKey, Double>()

    static func autoScale(data: LensCorrectionData, settings: LensCorrectionSettings, imageAspect: Double) -> Double {
        // 縮小して描いた画像は丸めで比率が僅かに変わるので、1/10000 で丸めて同じものとして扱う
        let key = ScaleKey(data: data, settings: settings, aspect: Int((imageAspect * 10000).rounded()))
        return scaleCache.value(for: key) { data.autoScale(settings: settings, imageAspect: imageAspect) }
    }
}

/// 中心が (cx, cy)、半対角 = radius ピクセルの画像での座標変換(ROI の計算用。カーネルと同じ式)
private struct LensWarp {
    let table: [Float]
    let n: Int
    let center: SIMD2<Double>
    let radius: Double
    let scale: Double

    init(arguments: [String: Any]?) {
        let data = arguments?["table"] as? Data ?? Data()
        table = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        n = arguments?["count"] as? Int ?? 0
        let e = (arguments?["extent"] as? CIVector)?.cgRectValue ?? .zero
        center = SIMD2(Double(e.midX), Double(e.midY))
        radius = max(1, (Double(e.width) * Double(e.width) + Double(e.height) * Double(e.height)).squareRoot() / 2)
        scale = arguments?["scale"] as? Double ?? 1
    }

    private func interpolate(_ offset: Int, at r: Double) -> Double {
        guard n > 0, table.count >= 5 * n else { return 1 }
        let k = { Double(self.table[$0]) }
        if r < k(0) { return k(offset) }
        for i in 1..<n where r <= k(i) {
            let t = (r - k(i - 1)) / (k(i) - k(i - 1))
            return k(offset + i - 1) + (k(offset + i) - k(offset + i - 1)) * t
        }
        return k(offset + n - 1)
    }

    /// 出力の点(ピクセル座標)に対して、色 c(0...2)を取る入力の点
    func source(of p: SIMD2<Double>, channel c: Int) -> SIMD2<Double> {
        let q = (p - center) / scale
        let r = (q * q).sum().squareRoot() / radius
        return center + q * interpolate((1 + c) * n, at: r)
    }
}

final class LensCorrectionKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    /// 出力の範囲を描くのに要る入力の範囲。範囲の縁の点を変換した先を全部囲む
    /// (倍率は半径に対してなめらかなので、縁の点だけ調べれば内側も収まる)
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let warp = LensWarp(arguments: arguments)
        let steps = 16
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = Double(outputRect.minX) + Double(outputRect.width) * t
            let y = Double(outputRect.minY) + Double(outputRect.height) * t
            for p in [SIMD2(x, Double(outputRect.minY)), SIMD2(x, Double(outputRect.maxY)),
                      SIMD2(Double(outputRect.minX), y), SIMD2(Double(outputRect.maxX), y)] {
                for c in 0..<3 {
                    let s = warp.source(of: p, channel: c)
                    minX = min(minX, s.x); maxX = max(maxX, s.x)
                    minY = min(minY, s.y); maxY = max(maxY, s.y)
                }
            }
        }
        // 補間で隣の画素も読むので少し広げる
        return CGRect(x: minX - 2, y: minY - 2, width: maxX - minX + 4, height: maxY - minY + 4).integral
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let commandBuffer = output.metalCommandBuffer else {
            throw RAWError.renderFailed("レンズ補正: GPU の画像を取得できません")
        }
        let pipeline = try MetalKernels.pipeline(name: "lensCorrect", source: LensKernelLibrary.source,
                                                 device: commandBuffer.device)
        let warp = LensWarp(arguments: arguments)
        guard warp.n > 0, let tableData = arguments?["table"] as? Data,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RAWError.renderFailed("レンズ補正: 補正データが不正です")
        }
        // テクスチャは 1 行目が上端(Core Image の座標で y が大きい側)なので、上端の y を渡す
        var params = LensKernelParams(
            center: SIMD2(Float(warp.center.x), Float(warp.center.y)),
            invRadius: Float(1 / warp.radius),
            invScale: Float(1 / warp.scale),
            outOrigin: SIMD2(Float(output.region.minX), Float(output.region.maxY)),
            inOrigin: SIMD2(Float(input.region.minX), Float(input.region.maxY)),
            count: Int32(warp.n))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<LensKernelParams>.stride, index: 0)
        tableData.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: tableData.count, index: 1) }
        MetalKernels.dispatch(encoder, over: destination)
        encoder.endEncoding()
    }
}

/// カーネルに渡す値。Metal 側の Params と並びを合わせる
private struct LensKernelParams {
    var center: SIMD2<Float>
    var invRadius: Float
    var invScale: Float
    var outOrigin: SIMD2<Float>
    var inOrigin: SIMD2<Float>
    var count: Int32
}

/// Metal のカーネルのソース(MetalKernels で GPU ごとに 1 回だけコンパイルする)
private enum LensKernelLibrary {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float2 center;      // 画像の中心(Core Image の座標)
        float invRadius;    // 1 / 半対角
        float invScale;     // 1 / 全体の拡大率
        float2 outOrigin;   // 出力テクスチャの左端の x と上端の y
        float2 inOrigin;    // 入力テクスチャの左端の x と上端の y
        int count;          // 点の数
    };

    static float interpolate(constant float *knots, constant float *v, int n, float r) {
        if (r < knots[0]) return v[0];
        for (int i = 1; i < n; i++) {
            if (r <= knots[i]) {
                float t = (r - knots[i - 1]) / (knots[i] - knots[i - 1]);
                return mix(v[i - 1], v[i], t);
            }
        }
        return v[n - 1];
    }

    // table: knots, R の倍率, G の倍率, B の倍率, 周辺減光の係数(各 count 個)
    kernel void lensCorrect(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant Params &p [[buffer(0)]],
                            constant float *table [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
        int n = p.count;
        // 出力の画素の中心(Core Image の座標。テクスチャは 1 行目が上端)
        float2 pos = float2(p.outOrigin.x + float(gid.x) + 0.5, p.outOrigin.y - float(gid.y) - 0.5);
        float2 q = (pos - p.center) * p.invScale;
        float r = length(q) * p.invRadius;
        float4 result = float4(0.0, 0.0, 0.0, 1.0);
        for (int c = 0; c < 3; c++) {
            float m = interpolate(table, table + (1 + c) * n, n, r);
            float2 sp = p.center + q * m;
            float k = interpolate(table, table + 4 * n, n, length(sp - p.center) * p.invRadius);
            float4 v = src.sample(smp, float2(sp.x - p.inOrigin.x, p.inOrigin.y - sp.y));
            result[c] = v[c] / max(k, 1e-4);
            if (c == 1) result.a = v.a;
        }
        dst.write(result, gid);
    }
    """
}
