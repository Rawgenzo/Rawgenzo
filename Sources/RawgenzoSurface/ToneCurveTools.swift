import Foundation
import OperationSurface
import RAWCore

/// トーンカーブの道具(docs/tone-curve-design.md)。点の値は画面と同じ 0〜255
extension RawgenzoTools {
    /// 結果の JSON は短くする。変えていないチャンネルは書かない
    static func toneCurveJSON(_ c: ToneCurveSettings?) -> JSONValue {
        guard let c, !c.isNeutral || c.saturationLink != 0 else { return .null }
        var o: [String: JSONValue] = [:]
        for channel in ToneCurveChannel.allCases where !ToneCurveSettings.isIdentity(c[channel]) {
            o[channel.rawValue] = .array(c[channel].map { [.number(round1($0.x * 255)), .number(round1($0.y * 255))] })
        }
        if let preset = ToneCurvePreset.matching(c.luma), preset != .linear { o["preset"] = .string(preset.rawValue) }
        if c.saturationLink != 0 { o["saturation_link"] = .number(round1(c.saturationLink * 100)) }
        return .object(o)
    }

    static func registerToneCurve(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        let point = JSONSchema.array(of: .number(minimum: 0, maximum: 255), minItems: 2, maxItems: 2)
        surface.register(ToolDescriptor(
            name: "set_tone_curve", title: "トーンカーブ",
            description: "トーンカーブ。点は [入力, 出力](0〜255、見た目の明るさ)、1 本に 16 点まで、端を省くと 0→0・255→255。"
                + "luma: S 字で中間のコントラスト、[0, 20] のように黒を上げるとフェード調。red・green・blue は色を直接変える"
                + "(上げると赤・緑・青、下げるとシアン・マゼンタ・黄)。preset は luma の形。"
                + "saturation_link 0〜100: luma で彩度も変えるか(0 = 明るさだけ、既定)。書いたチャンネルだけ変える",
            input: .object([
                .init("photos", .array(of: photoID, minItems: 1, maxItems: 1000)),
                .init("preset", .string(oneOf: ToneCurvePreset.allCases.map(\.rawValue))),
                .init("curves", .array(of: .object([
                    .init("channel", .string(oneOf: ToneCurveChannel.allCases.map(\.rawValue))),
                    .init("points", .array(of: point, maxItems: ToneCurveSettings.maxPoints)),
                ], required: ["channel", "points"]), maxItems: 4)),
                .init("saturation_link", .number(minimum: 0, maximum: 100)),
                .init("reset", .boolean("全部のチャンネルを戻す")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let preset = args["preset"]?.stringValue.flatMap(ToneCurvePreset.init(rawValue:))
            let curves = args["curves"]?.arrayValue ?? []
            let link = args["saturation_link"]?.doubleValue
            let reset = args["reset"]?.boolValue == true
            if preset == nil, curves.isEmpty, link == nil, !reset {
                return .error("preset・curves・saturation_link・reset のどれかを指定してください")
            }
            if preset != nil, curves.contains(where: { $0["channel"]?.stringValue == "luma" }) {
                return .error("preset と curves の luma は一緒に指定できません")
            }
            let ids = try uniqueIDs(ws, args["photos"])
            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var c = reset ? ToneCurveSettings() : (before.toneCurve ?? ToneCurveSettings())
                if let preset { c.luma = preset.points }
                for curve in curves {
                    guard let channel = curve["channel"]?.stringValue.flatMap(ToneCurveChannel.init(rawValue:)) else { continue }
                    c[channel] = (curve["points"]?.arrayValue ?? []).compactMap { p in
                        guard let a = p.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
                        return CurvePoint(x / 255, y / 255)
                    }
                }
                if let link { c.saturationLink = min(max(link / 100, 0), 1) }
                var after = before
                after.toneCurve = c.isNeutral && c.saturationLink == 0 ? nil : c
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id), "tone_curve": toneCurveJSON(after.toneCurve)]
                if after == before { row["notes"] = ["変更なし"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }
}
