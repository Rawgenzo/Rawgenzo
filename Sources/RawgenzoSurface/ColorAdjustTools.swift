import CoreGraphics
import Foundation
import OperationSurface
import RAWCore

/// 色別補正の道具(docs/color-grading-design.md の A)。
///
/// 目指すのは「人は操作のしかたを知らなくても、AI に頼めば思った絵になる」こと(オーナー、2026-10-30)。
/// 拾った色の補正は、範囲の 3 つの軸(色相・淡さ・明るさ)となめらかさを詰める込み入った操作なので、
/// AI に値を試させず、目標で指示させる: 変えたい所と変えたくない所の位置から範囲を決め(ColorPointAdjust.fitted)、
/// 目標の濃さから「色を足す」の強さを探す(solvedAdd)。外せない所があれば、そう返す。
extension RawgenzoTools {
    static let bandIDs = ColorBand.allCases.map(\.rawValue)

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// 結果の JSON は短くする(道具の結果は会話に残り、毎回のトークンになる)。0 の値・空の項目は書かない
    static func colorAdjustJSON(_ c: ColorAdjustSettings?) -> JSONValue {
        guard let c, !c.isNeutral || !c.points.isEmpty else { return .null }
        var o: [String: JSONValue] = [:]
        var bands: [String: JSONValue] = [:]
        for (band, a) in c.bands where !a.isNeutral { bands[band.rawValue] = bandJSON(a) }
        if !bands.isEmpty { o["bands"] = .object(bands) }
        if !c.points.isEmpty { o["points"] = .array(c.points.enumerated().map { pointJSON($0.offset, $0.element) }) }
        return .object(o)
    }

    static func bandJSON(_ a: ColorBandAdjust) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if a.hue != 0 { o["hue"] = .number(a.hue) }
        if a.saturation != 0 { o["saturation"] = .number(a.saturation) }
        if a.luminance != 0 { o["luminance"] = .number(a.luminance) }
        return .object(o)
    }

    static func pointJSON(_ i: Int, _ p: ColorPointAdjust) -> JSONValue {
        var o: [String: JSONValue] = [
            "index": .number(Double(i)), "hue": .number(round1(p.hue)), "chroma": .number(round1(p.chroma)),
            "lightness": .number(round1(p.lightness)), "hue_width": .number(round1(p.hueWidth)),
            "chroma_range": [.number(round1(p.chromaMin)), .number(round1(p.chromaMax))],
            "lightness_range": [.number(round1(p.lightnessMin)), .number(round1(p.lightnessMax))],
            "softness": .number(round1(p.softness)),
        ]
        if !p.name.isEmpty { o["name"] = .string(p.name) }
        if p.add != 0 { o["add_color"] = .number(p.add) }
        if p.addHue != nil { o["add_hue"] = .number(round1(p.effectiveAddHue)) }
        if p.saturation != 0 { o["saturation"] = .number(p.saturation) }
        if p.hueShift != 0 { o["hue_shift"] = .number(p.hueShift) }
        if p.luminance != 0 { o["luminance"] = .number(p.luminance) }
        return .object(o)
    }

    /// 色を [色相, 濃さ, 明るさ] の 3 つの数で返す(キーを繰り返さない)
    static func pickedJSON(_ c: ColorSampler.Picked) -> JSONValue {
        [.number(round1(c.hue)), .number(round1(c.chroma)), .number(round1(c.lightness))]
    }

    static func registerColorAdjust(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        // MARK: 8 色の帯
        surface.register(ToolDescriptor(
            name: "adjust_colors", title: "色別補正(8 色)",
            description: "8 色の帯ごとの色相・彩度・輝度(−100〜+100)。空を深い青に・肌の赤みを抑える、など帯全体の調子に使う。"
                + "色相 + は次の帯の方(red→orange→yellow…)へ最大 30°。彩度 −100 でその帯だけ灰色。白・灰色に近い色には効かない"
                + "(淡い色は set_color_point)。書いた値だけ変える。relative: true は今の値に足す",
            input: .object([
                .init("photos", .array(of: photoID, minItems: 1, maxItems: 1000)),
                .init("edits", .array(of: .object([
                    .init("band", .string(oneOf: ColorBand.allCases.map(\.rawValue))),
                    .init("hue", .number(minimum: -200, maximum: 200)),
                    .init("saturation", .number(minimum: -200, maximum: 200)),
                    .init("luminance", .number(minimum: -200, maximum: 200)),
                    .init("relative", .boolean()),
                ], required: ["band"]), maxItems: 16)),
                .init("reset", .boolean("全部の帯を 0 に戻す(拾った色は残す)")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let edits = args["edits"]?.arrayValue ?? []
            let reset = args["reset"]?.boolValue == true
            if edits.isEmpty, !reset { return .error("edits か reset を指定してください") }
            let keys: [(String, WritableKeyPath<ColorBandAdjust, Double>)] =
                [("hue", \.hue), ("saturation", \.saturation), ("luminance", \.luminance)]
            let ids = try uniqueIDs(ws, args["photos"])
            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var c = before.colorAdjust ?? ColorAdjustSettings()
                if reset { c.bands = [:] }
                for edit in edits {
                    guard let band = edit["band"]?.stringValue.flatMap(ColorBand.init(rawValue:)) else { continue }
                    let relative = edit["relative"]?.boolValue == true
                    var a = c.bands[band] ?? ColorBandAdjust()
                    for (key, path) in keys {
                        guard let v = edit[key]?.doubleValue else { continue }
                        a[keyPath: path] = min(max(relative ? a[keyPath: path] + v : v, ColorBandAdjust.range.lowerBound),
                                               ColorBandAdjust.range.upperBound)
                    }
                    c.bands[band] = a.isNeutral ? nil : a
                }
                var after = before
                after.colorAdjust = c.isNeutral && c.points.isEmpty ? nil : c
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id), "color_adjust": colorAdjustJSON(after.colorAdjust)]
                if after == before { row["notes"] = ["変更なし"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }

        // MARK: 拾った色
        let position = JSONSchema.object([.init("x", .number(minimum: 0, maximum: 1)), .init("y", .number(minimum: 0, maximum: 1))],
                                         required: ["x", "y"])
        surface.register(ToolDescriptor(
            name: "set_color_point", title: "色別補正(拾った色)",
            description: "写真の中の特定の色だけを補正する(淡い桜の花びらだけピンクに、など)。位置は get_preview の画像に対する比率"
                + "(grid: true の目盛りで読む)。add: at に変えたい所(同じ物の 2〜5 か所)、exclude_at に変えたくない所(空・背景など)を渡すと、"
                + "範囲は Rawgenzo が決める(値を試し続けない)。外せない所は unresolved(色が近すぎる。人に伝える)。"
                + "強さは target_chroma(変えたい所の濃さの目標 0〜100。淡い桜なら 12〜20)か add_color(色を足す 0〜100)。"
                + "add_hue は足す色の色相(既定は拾った色。黄色みの白い花をピンクにするなら 350 前後)。"
                + "update は index の補正を変える(at を渡すと範囲を決め直す)。色は [色相, 濃さ, 明るさ] で返す。"
                + "当てた後は get_preview の color_mask で効く場所を確かめる",
            input: .object([
                .init("photo", photoID),
                .init("action", .string("add・update・remove・clear", oneOf: ["add", "update", "remove", "clear"])),
                .init("index", .integer(minimum: 0)),
                .init("at", .array(of: position, minItems: 1, maxItems: 20)),
                .init("exclude_at", .array(of: position, maxItems: 20)),
                .init("name", .string()),
                .init("add_color", .number(minimum: 0, maximum: 100)),
                .init("add_hue", JSONSchema.number(minimum: 0, maximum: 360).orNull()),
                .init("target_chroma", .number(minimum: 0, maximum: 100)),
                .init("saturation", .number(minimum: -100, maximum: 100)),
                .init("hue_shift", .number(minimum: -100, maximum: 100)),
                .init("luminance", .number(minimum: -100, maximum: 100)),
                .init("softness", .number(minimum: 0, maximum: 100)),
            ], required: ["photo", "action"]),
            effect: .modify)) { args, ctx in
            let action = args["action"]!.stringValue!
            let photo = try ws.photo(args["photo"]!.stringValue!)
            let id = ws.id(for: photo.url)
            let before = photo.settings
            var c = before.colorAdjust ?? ColorAdjustSettings()
            var out: [String: JSONValue] = ["photo": .string(id)]
            var notes: [String] = []

            func positions(_ key: String) -> [CGPoint] {
                (args[key]?.arrayValue ?? []).compactMap { p in
                    guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { return nil }
                    return CGPoint(x: x, y: y)
                }
            }
            func pick(_ points: [CGPoint]) throws -> [ColorSampler.Picked] {
                try points.map { try ColorSampler.pick(photo, settings: before, pipeline: ws.engine.pipeline, at: $0) }
            }

            switch action {
            case "clear":
                c.points = []
            case "remove":
                guard let i = args["index"]?.intValue, c.points.indices.contains(i) else {
                    return .error("index が無いか、その番号の補正がありません(get_photo の color_adjust.points を見てください)")
                }
                c.points.remove(at: i)
            case "add", "update":
                let index: Int
                var point: ColorPointAdjust
                let includes = try pick(positions("at"))
                let excludes = try pick(positions("exclude_at"))
                if action == "add" {
                    guard !includes.isEmpty else { return .error("add には at(変えたい所の位置)が要ります") }
                    if includes.allSatisfy(\.isNearlyGray) {
                        return .error("at の所は色がほとんど無い(白・灰色)ので、範囲が決まりません。少しでも色のある所を選んでください: "
                            + includes.map { pickedJSON($0).jsonString() }.joined(separator: ", "))
                    }
                    guard let fit = ColorPointAdjust.fitted(includes: includes, excludes: excludes) else { return .error("範囲を決められません") }
                    point = fit.point
                    index = c.points.count
                    c.points.append(point)
                    // 外せなかった所・効きの弱い所は、渡された並びの番号と色だけ返す(位置は AI が渡したもの)
                    if !fit.unresolved.isEmpty {
                        out["unresolved"] = .array(fit.unresolved.map { ["exclude_at": .number(Double($0.index)),
                                                                          "color": pickedJSON(excludes[$0.index]),
                                                                          "weight": .number(round1($0.weight * 100) / 100)] })
                    }
                    if !fit.weakIncludes.isEmpty {
                        out["weak_includes"] = .array(fit.weakIncludes.map { ["at": .number(Double($0.index)),
                                                                              "color": pickedJSON(includes[$0.index])] })
                    }
                    if !fit.unresolved.isEmpty {
                        notes.append("変えたくない所のうち \(fit.unresolved.count) か所は、変えたい所と色(色相・淡さ・明るさ)が近すぎて外せなかった。"
                            + "色で選ぶ補正では分けられない(場所で選ぶ補正は無い)ので、人に伝える")
                    }
                } else {
                    guard let i = args["index"]?.intValue, c.points.indices.contains(i) else {
                        return .error("index が無いか、その番号の補正がありません(get_photo の color_adjust.points を見てください)")
                    }
                    index = i
                    point = c.points[i]
                    if !includes.isEmpty, let fit = ColorPointAdjust.fitted(includes: includes, excludes: excludes, base: point) {
                        point = fit.point
                        if !fit.unresolved.isEmpty { notes.append("変えたくない所のうち \(fit.unresolved.count) か所は外せなかった") }
                    }
                }
                if let v = args["name"]?.stringValue { point.name = v }
                if args.objectValue?.keys.contains("add_hue") == true { point.addHue = args["add_hue"]?.doubleValue }
                if let v = args["add_color"]?.doubleValue { point.add = v }
                if let v = args["saturation"]?.doubleValue { point.saturation = v }
                if let v = args["hue_shift"]?.doubleValue { point.hueShift = v }
                if let v = args["luminance"]?.doubleValue { point.luminance = v }
                if let v = args["softness"]?.doubleValue { point.softness = v }
                if let target = args["target_chroma"]?.doubleValue {
                    let sample = includes.isEmpty
                        ? [ColorSampler.Picked(rgb: ColorAdjustMath.srgb([point.lightness / 100,
                                                                         point.chroma / 100 * ColorAdjustMath.chromaReference * cos(point.hue * .pi / 180),
                                                                         point.chroma / 100 * ColorAdjustMath.chromaReference * sin(point.hue * .pi / 180)]))]
                        : includes
                    let r = point.solvedAdd(includes: sample, targetChroma: target)
                    point = r.point
                    out["target"] = ["achieved": .number(round1(r.achieved)), "met": .bool(r.met)]
                    if !r.met { notes.append(String(format: "目標の濃さに届かなかった(色を足す 100 で %.1f)", r.achieved)) }
                }
                if !includes.isEmpty {
                    // 変えたい所の濃さの前後(平均)。1 か所ずつは返さない
                    let s = ColorAdjustSettings(points: [point])
                    let beforeC = includes.map(\.chroma).reduce(0, +) / Double(includes.count)
                    let afterC = includes.map { ColorSampler.Picked(rgb: ColorAdjustMath.apply(s, to: $0.rgb)).chroma }.reduce(0, +)
                        / Double(includes.count)
                    out["chroma_of_at"] = [.number(round1(beforeC)), .number(round1(afterC))]
                }
                c.points[index] = point
                out["point"] = pointJSON(index, point)
                out["coverage"] = .number(round1(try ColorSampler.coverage(of: point, photo, settings: before, pipeline: ws.engine.pipeline) * 1000) / 1000)
                if point.isNeutral { notes.append("補正の値(add_color・target_chroma など)がまだ無いので、見た目は変わらない") }
            default:
                return .error("action は add・update・remove・clear のどれかです")
            }
            var after = before
            after.colorAdjust = c.isNeutral && c.points.isEmpty ? nil : c
            if after != before { try commit(ws, ctx, photo, from: before, to: after) }
            // 全部の補正の詳細は返さない(get_photo で見られる)。数だけ
            out["point_count"] = .number(Double(after.colorAdjust?.points.count ?? 0))
            if !notes.isEmpty { out["notes"] = .array(notes.map { .string($0) }) }
            return warned(.json(.object(out)), ws, [photo.url])
        }
    }
}
