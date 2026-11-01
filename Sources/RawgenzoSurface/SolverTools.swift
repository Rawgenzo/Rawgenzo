import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// 目標で指示する道具(solve_exposure)
extension RawgenzoTools {
    static func registerSolvers(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "solve_exposure", title: "明るさを目標に合わせる",
            description: "明るさの目標(平均輝度か中央値)と白飛びの上限を渡すと、Rawgenzo が露出とハイライト回復を探して合わせ、"
                + "サイドカーに保存する。明るさを合わせる・揃える・白飛びを抑えるときは、get_stats で値を試し続けずにこれを使う。"
                + "写真ごとに必要な値は Rawgenzo が求めるので、複数の写真を同じ目標に揃えるときも 1 回で済む(undo 1 回で戻せる)。"
                + "白飛びの上限は明るさの目標より優先する。目標に届かないときは結果の met と notes で知らせる。"
                + "明るさの目標を渡さず白飛びの上限だけを渡したときは、今の平均輝度を保つ(keep_brightness を false にすると保たない)。"
                + "1 枚あたり数秒かかる。結果の統計は get_stats と同じ解像度(長辺 1024)",
            input: .object([
                .init("photos", .array(of: photoID, description: "合わせる写真の ID", minItems: 1, maxItems: 200)),
                .init("target_mean_luminance", .number("目標の平均輝度(sRGB の 0〜1。普通の明るさは 0.4〜0.5 前後)",
                                                       minimum: 0.02, maximum: 0.98)),
                .init("target_median_luminance", .number("目標の輝度の中央値(平均の代わりに使う。空や光源など一部の明るい所に引っぱられにくい)",
                                                         minimum: 0.02, maximum: 0.98)),
                .init("max_highlight_clipping", .number("白飛びの割合の上限(0.01 = 1%)", minimum: 0, maximum: 0.5)),
                .init("allow_highlight_recovery", .boolean("白飛びを抑えるのにハイライト回復を使ってよいか(既定 true。false なら露出だけで合わせる)")),
                .init("keep_brightness", .boolean("明るさの目標が無いとき、今の平均輝度を保つか(既定 true)")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let mean = args["target_mean_luminance"]?.doubleValue
            let median = args["target_median_luminance"]?.doubleValue
            let maxClip = args["max_highlight_clipping"]?.doubleValue
            if mean != nil, median != nil { return .error("target_mean_luminance と target_median_luminance はどちらか一方にしてください") }
            if mean == nil, median == nil, maxClip == nil { return .error("目標(明るさか白飛びの上限)を 1 つ以上指定してください") }
            let target = ExposureSolver.Target(meanLuminance: mean, medianLuminance: median, maxHighlightClipping: maxClip,
                                               allowHighlightRecovery: args["allow_highlight_recovery"]?.boolValue ?? true)
            // 「白飛びを抑えて」と頼まれたとき、人はふつう明るさまで変わることを期待しない。
            // 試験では AI によって明るさを保つ目標を付けたり付けなかったりしたので、既定で保つ
            let keepBrightness = mean == nil && median == nil && (args["keep_brightness"]?.boolValue ?? true)
            let ids = try uniqueIDs(ws, args["photos"])

            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                func eval(_ edge: Int) -> (DevelopSettings) throws -> ImageStats {
                    { try ImageStats.compute(ws.engine.pipeline.processFitting(photo, settings: $0, longEdge: edge)) }
                }
                var photoTarget = target
                if keepBrightness {
                    photoTarget.meanLuminance = try eval(ImageStats.defaultLongEdge)(before).meanLuminance
                }
                let r = try ExposureSolver.solve(from: before, target: photoTarget,
                                                 coarse: eval(512), fine: eval(ImageStats.defaultLongEdge))
                if r.settings != before { try commit(ws, ctx, photo, from: before, to: r.settings) }
                var row: [String: JSONValue] = [
                    "photo": .string(id),
                    "changed": .object(difference(before, r.settings, photo: photo)),
                    "stats": summary(r.stats),
                    "met": ["luminance": .bool(r.luminanceMet), "clipping": .bool(r.clippingMet)],
                ]
                if keepBrightness, let kept = photoTarget.meanLuminance { row["kept_mean_luminance"] = .number(kept) }
                if !r.notes.isEmpty { row["notes"] = .array(r.notes.map { .string($0) }) }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }
}
