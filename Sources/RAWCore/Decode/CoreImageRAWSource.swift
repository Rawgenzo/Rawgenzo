import CoreImage

/// macOS標準のCIRAWFilterによるデコーダ。デモザイクからNR・シャープネスまでGPUで処理される。
/// レンズ補正は機種によって非対応(α7S III の ARW は isLensCorrectionSupported == false で補正されない)。
public final class CoreImageRAWSource: RAWSource {
    public let url: URL
    public let metadata: RAWMetadata
    public let asShot: AsShotValues
    /// 開いた時点で読んでおく。描画中の CIRAWFilter に別スレッドから問い合わせないため(RAWSource の約束)
    public let nativeSize: CGSize
    public let detailDefaults: DetailDefaults
    private let filter: CIRAWFilter

    // デコーダ既定値(設定がnilのときに戻すため最初に控えておく)
    private let defaults: (contrast: Float, sharpness: Float, lumaNR: Float, colorNR: Float)

    public init(url: URL, metadata: RAWMetadata) throws {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RAWError.decoderUnavailable(url)
        }
        self.url = url
        self.metadata = metadata
        self.filter = filter
        self.asShot = AsShotValues(temperature: Double(filter.neutralTemperature),
                                   tint: Double(filter.neutralTint))
        self.nativeSize = filter.nativeSize
        self.detailDefaults = DetailDefaults(sharpness: Double(filter.sharpnessAmount),
                                             luminanceNoiseReduction: Double(filter.luminanceNoiseReductionAmount),
                                             colorNoiseReduction: Double(filter.colorNoiseReductionAmount))
        self.defaults = (filter.contrastAmount, filter.sharpnessAmount,
                         filter.luminanceNoiseReductionAmount, filter.colorNoiseReductionAmount)
    }

    /// デコーダが各機能に対応していると申告しているか(rawdev info で確認用)。
    /// 申告どおり効くとは限らない(コントラストは対応と申告するが ARW では効かない)
    public var capabilityReport: [(String, Bool)] {
        [("ローカルトーンマップ", filter.isLocalToneMapSupported),
         ("レンズ補正", filter.isLensCorrectionSupported),
         ("輝度NR", filter.isLuminanceNoiseReductionSupported),
         ("色NR", filter.isColorNoiseReductionSupported),
         ("シャープネス", filter.isSharpnessSupported),
         ("コントラスト", filter.isContrastSupported)]
    }

    /// このMacのCore Imageが対応しているカメラ名一覧
    public static var supportedCameraModels: [String] { CIRAWFilter.supportedCameraModels }

    public func render(settings s: DevelopSettings, scale: Double, draft: Bool) throws -> CIImage {
        filter.exposure = Float(s.exposure)
        filter.neutralTemperature = Float(s.temperature ?? asShot.temperature)
        filter.neutralTint = Float(s.tint ?? asShot.tint)
        // コントラストは ARW では効かない(isContrastSupported は true なのに出力が変わらない)ので、自前で掛ける(ContrastStage)
        filter.contrastAmount = defaults.contrast
        // 範囲の外は端に丸める(輝度ノイズ除去は 1 を超えると効き方が逆になる)
        func clamp(_ v: Double?, _ r: ClosedRange<Double>) -> Float? { v.map { Float(min(max($0, r.lowerBound), r.upperBound)) } }
        filter.sharpnessAmount = clamp(s.sharpness, DetailRanges.sharpness) ?? defaults.sharpness
        filter.luminanceNoiseReductionAmount = clamp(s.luminanceNoiseReduction, DetailRanges.luminanceNoiseReduction) ?? defaults.lumaNR
        filter.colorNoiseReductionAmount = clamp(s.colorNoiseReduction, DetailRanges.colorNoiseReduction) ?? defaults.colorNR
        // レンズ補正は RAW に記録された値で自前で行う(LensCorrector)。二重に掛けないよう、デコーダ側は切る。
        // CIRAWFilter がレンズ補正に対応している機種を追加するときは、どちらを使うか見直すこと
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = false
        }

        // HDRトーンは HDRToneStage で自前処理する。デコーダ側のローカルトーンマップは
        // 機種によって非対応で効き方も揃わないので、二重掛けを避けるため常にオフにする。
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = 0
        }
        filter.extendedDynamicRangeAmount = s.hdr.extendedOutput ? 1 : 0

        filter.scaleFactor = Float(min(max(scale, 0.01), 1.0))
        filter.isDraftModeEnabled = draft

        guard let image = filter.outputImage else {
            throw RAWError.renderFailed("CIRAWFilterの出力が空です")
        }
        return image
    }
}
