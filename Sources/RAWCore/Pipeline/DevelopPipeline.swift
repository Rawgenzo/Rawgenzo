import CoreImage

/// デコード → 各ステージ(phase順) の処理を組み立てる。
public struct DevelopPipeline {
    public var stages: [DevelopStage]

    public init(stages: [DevelopStage]) {
        self.stages = stages
    }

    public static func makeDefault(looks: LookRegistry) -> DevelopPipeline {
        DevelopPipeline(stages: [
            HDRToneStage(),
            ContrastStage(),   // HDR トーン(ハイライト/シャドウ)の後、色の前
            ColorStage(),
            CropStage(),
            LookStage(registry: looks),
        ])
    }

    /// - settings: 指定しなければ photo.settings を使う(UIから編集中の値を渡す用)
    public func process(_ photo: Photo, settings: DevelopSettings? = nil,
                        options: RenderOptions = RenderOptions()) throws -> CIImage {
        let s = settings ?? photo.settings
        var image = try photo.source.render(settings: s, scale: options.scale, draft: options.draft)

        // レンズ補正はデコード直後(リニアな値のうち、明るさやクロップより前)に掛ける。
        // 写真ごとの補正データが要るので、ステージ(設定だけを受け取る)ではなくここで行う
        if let lens = photo.lensCorrection, let lensSettings = photo.effectiveLensSettings(s) {
            image = try LensCorrector.apply(image, data: lens, settings: lensSettings)
        }

        // phaseが同じものは登録順を保つ
        let ordered = (stages + photo.profile.extraStages)
            .enumerated()
            .sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }
            .map(\.element)

        for stage in ordered {
            image = stage.apply(image, settings: s, options: options)
        }
        return image
    }
}
