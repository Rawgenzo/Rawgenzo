import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// レンズ補正・HDR 出力・初期値に戻す道具
extension RawgenzoTools {
    static func registerOptions(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "set_lens_correction", title: "レンズ補正",
            description: "レンズ補正(周辺減光・歪曲・倍率色収差)のオン/オフを変えて、サイドカーに保存する(undo で取り消せる)。"
                + "渡した項目だけを変え、ほかは今の状態のまま。follow_camera: true で撮影時のカメラ設定に従う状態に戻す。"
                + "補正情報が無いレンズの写真は変えずに、結果の notes で知らせる。今の状態は get_photo の lens_correction",
            input: .object([
                .init("photos", .array(of: photoID, description: "変える写真の ID", minItems: 1, maxItems: 1000)),
                .init("vignetting", .boolean("周辺減光(四隅が暗くなるのを明るくする)")),
                .init("distortion", .boolean("歪曲(樽型・糸巻き型の歪みを直す)")),
                .init("chromatic_aberration", .boolean("倍率色収差(画面の端の赤・青の色ずれを直す)")),
                .init("follow_camera", .boolean("true で撮影時のカメラ設定に従う(ほかの項目と一緒には使えない)")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let keys: [(String, WritableKeyPath<LensCorrectionSettings, Bool>)] =
                [("vignetting", \.vignetting), ("distortion", \.distortion), ("chromatic_aberration", \.chromaticAberration)]
            let given = keys.filter { args[$0.0] != nil }
            let follow = args["follow_camera"]?.boolValue == true
            if follow, !given.isEmpty { return .error("follow_camera はほかの項目と一緒には使えません") }
            if !follow, given.isEmpty { return .error("vignetting・distortion・chromatic_aberration・follow_camera のどれかを指定してください") }
            let ids = try uniqueIDs(ws, args["photos"])
            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                guard photo.lensCorrection != nil else {
                    results.append(["photo": .string(id), "notes": ["このレンズには補正情報が無いので変えなかった"]])
                    continue
                }
                var after = before
                if follow {
                    after.lens = nil
                } else {
                    // アプリと同じく、今掛かっている補正から始めて、渡した項目だけを変える
                    var l = photo.effectiveLensSettings(before) ?? .all
                    for (key, path) in given { l[keyPath: path] = args[key]!.boolValue! }
                    after.lens = l
                }
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id),
                                                "lens_correction": ["from": lensJSON(photo, before), "to": lensJSON(photo, after)]]
                if after == before { row["notes"] = ["変更なし"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }

        surface.register(ToolDescriptor(
            name: "set_hdr_output", title: "HDR ディスプレイ向けの出力",
            description: "HDR ディスプレイ向けの出力(書き出しが 10bit の HDR HEIF になる)のオン/オフを変えて、サイドカーに保存する(undo で取り消せる)。"
                + "効くのは書き出しだけで、プレビュー・get_preview・get_stats は通常の明るさ(SDR)のまま変わらない。"
                + "明暗差の大きい場面を HDR 対応の画面で見せたいときに使う",
            input: .object([
                .init("photos", .array(of: photoID, description: "変える写真の ID", minItems: 1, maxItems: 1000)),
                .init("enabled", .boolean("true でオン、false でオフ")),
            ], required: ["photos", "enabled"]),
            effect: .modify)) { args, ctx in
            let enabled = args["enabled"]!.boolValue!
            let ids = try uniqueIDs(ws, args["photos"])
            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = before
                after.hdr.extendedOutput = enabled
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id),
                                                "hdr_output": ["from": .bool(before.hdr.extendedOutput), "to": .bool(enabled)]]
                if after == before { row["notes"] = ["変更なし"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }

        surface.register(ToolDescriptor(
            name: "reset_settings", title: "初期値に戻す",
            description: "写真の現像設定を初期値(撮影時の値・デコーダの既定値。切り抜き・ルック無し、レンズ補正はカメラ設定に従う)に戻して、"
                + "サイドカーに保存する(アプリの「すべて初期値に戻す」と同じ。undo で取り消せる)。"
                + "keep に挙げたもの(crop: 切り抜きと傾き、look: ルック)は今のまま残す。"
                + "一部の数値だけを戻すときは、これではなく adjust の changes に null を書く",
            input: .object([
                .init("photos", .array(of: photoID, description: "戻す写真の ID", minItems: 1, maxItems: 1000)),
                .init("keep", .array(of: .string(oneOf: ["crop", "look"]), description: "戻さずに残すもの")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let keep = Set(args["keep"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let ids = try uniqueIDs(ws, args["photos"])
            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = photo.profile.initialSettings(for: photo.metadata)
                if keep.contains("crop") { after.crop = before.crop }
                if keep.contains("look") { after.look = before.look }
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                let fields = SettingsFields.changed(before, after)
                var row: [String: JSONValue] = ["photo": .string(id), "reset": .array(fields.map { .string($0) })]
                if fields.isEmpty { row["notes"] = ["もともと初期値"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }
}
