import CoreImage
import CoreImage.CIFilterBuiltins

/// HDR風トーン
/// - strength: 自前のローカルトーンマッピング(暗部を持ち上げ、明部を抑え、中域のコントラストを戻す)
/// - highlights / shadows: Core Image標準のハイライト・シャドウ調整
public struct HDRToneStage: DevelopStage {
    public init() {}
    public let name = "hdr-tone"
    public let phase = StagePhase.tone

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        let hdr = settings.hdr
        var out = image

        let strength = min(max(hdr.strength, 0), 1)
        if strength > 0 {
            out = Self.localToneMap(out, strength: strength)
        }

        if hdr.highlights > 0 || hdr.shadows > 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = out
            // 半径は画像サイズに比例させ、プレビュー縮小時も見た目が変わらないようにする
            f.radius = Float(max(out.extent.width, out.extent.height) * 0.01)
            f.highlightAmount = Float(1 - min(max(hdr.highlights, 0), 1))   // 1 = 変更なし
            f.shadowAmount = Float(min(max(hdr.shadows, 0), 1))             // 0 = 変更なし
            out = f.outputImage?.cropped(to: image.extent) ?? out
        }
        return out
    }

    /// ローカルトーンマッピング。Core Imageの標準フィルタだけで組んでいる。
    /// 1. 輝度を見た目の明るさに近いガンマにして大きくぼかし、「領域ごとの明るさ」マスクを作る
    /// 2. 暗い領域ほど露出を上げ、明るい領域ほど露出を下げる(中間の明るさは変えない)
    /// 3. ぼかしで失われた立体感を、半径の大きいアンシャープマスク(クラリティ)で戻す
    static func localToneMap(_ image: CIImage, strength s: Double) -> CIImage {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)

        // 1. 明るさマスク
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = clamp01(luma.outputImage ?? image)
        gamma.power = 1 / 2.2

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = (gamma.outputImage ?? image).clampedToExtent()
        blur.radius = Float(longEdge * 0.025)
        let mask = (blur.outputImage ?? image).cropped(to: extent)

        // 暗部マスク: 明るさ0で1、中間(0.5)以上で0
        let shadowMask = ramp(mask, scale: -2, bias: 1)
        // 明部マスク: 中間(0.5)以下で0、明るさ1で1
        let highlightMask = ramp(mask, scale: 2, bias: -1)

        // 2. 領域ごとの露出
        let lifted = exposure(image, ev: 2.0 * s)
        let lowered = exposure(image, ev: -1.5 * s)

        let liftShadows = CIFilter.blendWithMask()
        liftShadows.inputImage = lifted
        liftShadows.backgroundImage = image
        liftShadows.maskImage = shadowMask
        let step1 = (liftShadows.outputImage ?? image).cropped(to: extent)

        let lowerHighlights = CIFilter.blendWithMask()
        lowerHighlights.inputImage = lowered
        lowerHighlights.backgroundImage = step1
        lowerHighlights.maskImage = highlightMask
        let step2 = (lowerHighlights.outputImage ?? step1).cropped(to: extent)

        // 3. クラリティ
        let clarity = CIFilter.unsharpMask()
        clarity.inputImage = step2.clampedToExtent()
        clarity.radius = Float(longEdge * 0.008)
        clarity.intensity = Float(0.6 * s)
        return (clarity.outputImage ?? step2).cropped(to: extent)
    }

    private static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    /// グレー画像に v * scale + bias を掛けて 0...1 に収める
    private static func ramp(_ gray: CIImage, scale: CGFloat, bias: CGFloat) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = gray
        m.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return clamp01(m.outputImage ?? gray)
    }

    private static func clamp01(_ image: CIImage) -> CIImage {
        let c = CIFilter.colorClamp()
        c.inputImage = image
        c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return c.outputImage ?? image
    }
}

/// 彩度・自然な彩度
public struct ColorStage: DevelopStage {
    public init() {}
    public let name = "color"
    public let phase = StagePhase.color

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        var out = image
        if settings.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = out
            f.amount = Float(settings.vibrance)
            out = f.outputImage ?? out
        }
        if settings.saturation != 1.0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.saturation = Float(max(settings.saturation, 0))
            f.brightness = 0
            f.contrast = 1
            out = f.outputImage ?? out
        }
        return out
    }
}

/// 傾き補正とクロップ
public struct CropStage: DevelopStage {
    public init() {}
    public let name = "crop"
    public let phase = StagePhase.geometry

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        guard let crop = settings.crop else { return image }
        let frame = image.extent
        var out = image

        if crop.angle != 0 {
            // 画像中心で回転し、元の枠で切る(四隅は透明になるので、枠を内側に寄せて使う)
            let c = CGPoint(x: frame.midX, y: frame.midY)
            let t = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: -crop.angle * .pi / 180)   // Core Imageは反時計回りが正
                .translatedBy(x: -c.x, y: -c.y)
            out = out.transformed(by: t).cropped(to: frame)
        }

        if options.cropMode == .rotateOnly { return out }

        let r = Self.pixelRect(for: crop, in: frame)
        return out.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// 正規化座標(左上原点)→ Core Imageのピクセル座標(左下原点)
    ///
    /// 傾き補正があるときは、整数ピクセルへの丸めを内側に向け、さらに1ピクセル内側に寄せる。
    /// 回転した画像の縁のピクセルは補間で半透明になるので、枠がちょうど縁に接していると
    /// 外向きの丸めで半透明の線が残るため。
    public static func pixelRect(for crop: CropSettings, in frame: CGRect) -> CGRect {
        let c = crop.clamped()
        let r = CGRect(x: frame.minX + c.x * frame.width,
                       y: frame.minY + (1 - c.y - c.height) * frame.height,
                       width: c.width * frame.width,
                       height: c.height * frame.height)
        guard crop.angle != 0 else { return r.integral }
        let inner = r.insetBy(dx: 1, dy: 1)
        let minX = inner.minX.rounded(.up), minY = inner.minY.rounded(.up)
        let maxX = inner.maxX.rounded(.down), maxY = inner.maxY.rounded(.down)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}

/// ルック(〜風フィルター)を強さ付きで適用する
public struct LookStage: DevelopStage {
    public let registry: LookRegistry
    public init(registry: LookRegistry) { self.registry = registry }
    public let name = "look"
    public let phase = StagePhase.look

    public func apply(_ image: CIImage, settings: DevelopSettings, options: RenderOptions) -> CIImage {
        guard let selection = settings.look,
              selection.strength > 0,
              let look = registry.look(id: selection.id) else { return image }

        let styled = look.apply(to: image).cropped(to: image.extent)
        if selection.strength >= 0.999 { return styled }

        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = styled
        mix.time = Float(selection.strength)
        return mix.outputImage?.cropped(to: image.extent) ?? styled
    }
}
