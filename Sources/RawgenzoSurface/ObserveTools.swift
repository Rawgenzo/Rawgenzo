import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// 現像結果を見る道具(get_stats・get_preview)と、統計の整形
extension RawgenzoTools {
    // MARK: 現像結果を見る
    static func registerObserve(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "get_stats", title: "現像結果の統計",
            description: "今の設定(changes を渡すと、それを仮に当てた設定。保存はしない)で現像した結果の統計を返す。"
                + "輝度の平均・中央値・1%/99% 点、白飛び・黒つぶれの割合、平均 RGB。白飛びがあれば channel_clipping(R・G・B 別の割合。どの色が飽和しているか)。"
                + "detail を full にすると 32 区間のヒストグラム(histogram は輝度、rgb_histograms は R・G・B。暗い側から)と、"
                + "写真を 8×8 に区切った各区画の平均 RGB(grid_rgb、行は上から・列は左から)も返す(約 2.5KB)。"
                + "長辺 1024 に縮小して計算するので、点光源のようなごく小さな白飛びは数え漏れることがある",
            input: .object([
                .init("photo", photoID),
                .init("changes", changesSchema(detailed: false)),
                .init("detail", .string("summary(既定)か full", oneOf: ["summary", "full"])),
            ], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            var settings = photo.settings
            if let changes = args["changes"] { _ = apply(changes, to: &settings, photo: photo) }
            let stats = try computeStats(ws, photo, settings)
            return warned(.json(args["detail"]?.stringValue == "full" ? full(stats) : summary(stats)), ws, [photo.url])
        }

        surface.register(ToolDescriptor(
            name: "get_preview", title: "縮小画像",
            description: "現像結果の縮小画像(JPEG)を返す。changes を渡すと仮に当てた結果(保存はしない)。"
                + "画像はトークンを多く使うので、数値(get_stats)で判断できないときだけ使う。"
                + "縮小して描くのでシャープネスの効果は見えない。"
                + "ignore_crop を true にすると切り抜く前の全体を返す(傾き補正は当てたまま)。"
                + "その画像のピクセル座標を幅・高さで割った値が、set_crop の座標になる。"
                + "region を渡すと、その範囲だけを高い解像度で返す(縁の傾き・ピントの確認に。全体を大きく出すよりトークンが少ない)。"
                + "show_crop_frame は切り抜く前の全体に今の枠を描き(枠の外は暗く)、guide は構図ガイドを枠の中(枠を描かないときは画像全体)に描く。"
                + "grid は 10% ごとの目盛り、color_mask は色別補正の効く所だけを色で描く(ほかは灰色。長辺 512 程度で足りる)。"
                + "結果の文字に、等倍に対する倍率が付く",
            input: .object([
                .init("photo", photoID),
                .init("long_edge", .integer("長辺のピクセル数(既定 768)", minimum: 128, maximum: 1600)),
                .init("changes", changesSchema(detailed: false)),
                .init("ignore_crop", .boolean("切り抜く前の全体を返すか(既定 false)")),
                .init("look", lookTrialSchema),
                .init("region", .object([
                    .init("x", .number(minimum: 0, maximum: 1)), .init("y", .number(minimum: 0, maximum: 1)),
                    // 切り抜きの処理が枠を 5% 以上に広げるので、それより小さい範囲は受け付けない(黙って広がると倍率を誤る)
                    .init("width", .number(minimum: 0.05, maximum: 1)), .init("height", .number(minimum: 0.05, maximum: 1)),
                ], required: ["x", "y", "width", "height"],
                   description: "返す範囲。set_crop と同じ座標(傾き補正の後・切り抜く前の画像に対する比率、左上が原点)。幅・高さは 0.05 以上。等倍より大きくはしない")),
                .init("show_crop_frame", .boolean("切り抜く前の全体に今の切り抜き枠を描くか(既定 false。true なら ignore_crop も true として扱う)")),
                .init("guide", .string("重ねる構図ガイド: " + CompositionGuides.all.map { "\($0.id)(\($0.displayName))" }.joined(separator: "・"),
                                       oneOf: CompositionGuides.all.map(\.id))),
                .init("grid", .boolean()),
                .init("color_mask", .object([
                    .init("band", .string(oneOf: ColorBand.allCases.map(\.rawValue))),
                    .init("point", .integer(minimum: 0)),
                ], description: "band か point(色別補正の index)")),
            ], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            var settings = photo.settings
            if let changes = args["changes"] { _ = apply(changes, to: &settings, photo: photo) }
            if let look = args["look"] {
                if let error = applyTrialLook(look, to: &settings, ws: ws) { return .error(error) }
            }
            let region = args["region"]
            let showFrame = args["show_crop_frame"]?.boolValue == true
            let guide = args["guide"]?.stringValue.flatMap(CompositionGuides.guide(id:))
            let grid = args["grid"]?.boolValue == true
            if region != nil, showFrame || guide != nil || grid {
                return .error("region は show_crop_frame・guide・grid と一緒には使えません")
            }
            // 目盛りは set_color_point の位置(切り抜いた後の画像の比率)を読むためのもの。切り抜く前の全体に描くと、
            // 読んだ位置が切り抜いた写真では別の画素を指し、黙って違う色を拾う
            if grid, showFrame || args["ignore_crop"]?.boolValue == true {
                return .error("grid は ignore_crop・show_crop_frame と一緒には使えません(目盛りは切り抜いた後の画像の座標)")
            }
            var mask: ColorAdjustMask?
            if let m = args["color_mask"] {
                if let b = m["band"]?.stringValue.flatMap(ColorBand.init(rawValue:)) {
                    mask = .band(b)
                } else if let i = m["point"]?.intValue {
                    guard (settings.colorAdjust?.points.indices ?? 0..<0).contains(i) else {
                        return .error("拾った色の \(i) 番はありません(get_photo の color_adjust.points を見てください)")
                    }
                    mask = .point(i)
                } else {
                    return .error("color_mask には band か point を書いてください")
                }
            }
            let frame = settings.crop
            var notes: [String] = []
            if let r = region {
                let rect = CropSettings(x: r["x"]!.doubleValue!, y: r["y"]!.doubleValue!,
                                        width: r["width"]!.doubleValue!, height: r["height"]!.doubleValue!,
                                        angle: settings.crop?.angle ?? 0)
                guard rect.x + rect.width <= 1 + 1e-9, rect.y + rect.height <= 1 + 1e-9 else {
                    return .error("region が画像の外に出ています(x + width と y + height は 1 以下)")
                }
                // 範囲を切り抜き枠として現像すると、processFitting がその範囲の大きさで解像度を決める
                settings.crop = rect
            } else if showFrame || args["ignore_crop"]?.boolValue == true {
                // 枠の座標は傾けた後の画像に対するものなので、傾きは残して枠だけ全体にする
                settings.crop = settings.crop.flatMap { $0.angle == 0 ? nil : CropSettings(angle: $0.angle) }
                if showFrame, frame == nil || frame.map({ $0.width >= 1 && $0.height >= 1 }) == true {
                    notes.append("切り抜き枠が無い(全体)ので、枠は描いていない")
                }
            }
            var image = try ws.engine.pipeline.processFitting(photo, settings: settings,
                                                              longEdge: args["long_edge"]?.intValue ?? 768, colorAdjustMask: mask)
            let size = photo.source.nativeSize
            let shown = settings.crop ?? .full
            let scale = Double(image.extent.width) / (Double(size.width) * shown.width)
            if showFrame || guide != nil || grid {
                let f = showFrame ? frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } : nil
                image = try PreviewOverlay.draw(on: image, frame: f, guides: guide.map { [$0] } ?? [], grid: grid)
            }
            let jpeg = try PreviewEncoder.jpeg(image, quality: 0.75)
            var content: [ToolContent] = [
                .image(data: jpeg, mimeType: "image/jpeg"),
                .text("\(Int(image.extent.width))×\(Int(image.extent.height))"),
                .text(String(format: "等倍の %.2f 倍", scale)),
            ]
            if !notes.isEmpty { content.append(.text(notes.joined(separator: "。"))) }
            if let w = openPhotoWarning(ws, [photo.url]) { content.append(.text("open_photo_warning: \(w)")) }
            return ToolResult(content)
        }
    }

    static func computeStats(_ ws: RawgenzoWorkspace, _ photo: Photo, _ settings: DevelopSettings) throws -> ImageStats {
        let image = try ws.engine.pipeline.processFitting(photo, settings: settings, longEdge: ImageStats.defaultLongEdge)
        return try ImageStats.compute(image)
    }

    /// 統計の要約(ヒストグラムと区画を除いたもの)
    static func summary(_ s: ImageStats) -> JSONValue {
        var o: [String: JSONValue] = [
            "mean_luminance": .number(s.meanLuminance),
            "median_luminance": .number(s.medianLuminance),
            "p01_luminance": .number(s.p01Luminance),
            "p99_luminance": .number(s.p99Luminance),
            "highlight_clipping": .number(s.highlightClipping),
            "shadow_clipping": .number(s.shadowClipping),
            "mean_rgb": .array(s.meanRGB.map { .number($0) }),
        ]
        // どの色が飽和しているか。白飛びが無いときの [0, 0, 0] は何も伝えないので書かない(トークンの節約)
        if s.highlightClipping > 0 { o["channel_clipping"] = .array(s.channelClipping.map { .number($0) }) }
        return .object(o)
    }

    /// 統計のすべて(要約 + ヒストグラム + 8×8 区画)。キーは要約と同じ書き方にそろえる
    static func full(_ s: ImageStats) -> JSONValue {
        var o = summary(s).objectValue ?? [:]
        o["histogram"] = .array(s.histogram.map { .number($0) })
        o["rgb_histograms"] = .array(s.rgbHistograms.map { .array($0.map { .number($0) }) })
        o["grid_rgb"] = .array(s.grid.map { row in .array(row.map { cell in .array(cell.map { .number($0) }) }) })
        o["computed_size"] = [.number(Double(s.width)), .number(Double(s.height))]
        return .object(o)
    }
}
