import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// ルックの道具
extension RawgenzoTools {
    static let lookTrialSchema = JSONSchema.object([
        .init("id", JSONSchema.string("ルックの ID(list_looks)。null でルック無し").orNull()),
        .init("strength", .number("強さ(0〜1。省くと今の強さ、ルックが無かったなら 1)", minimum: 0, maximum: 1)),
    ], description: "仮に当てるルック(保存はしない)。set_look と同じ指定")

    static func lookJSON(_ ws: RawgenzoWorkspace, _ look: LookSelection?) -> JSONValue {
        guard let l = look else { return .null }
        var o: [String: JSONValue] = ["id": .string(l.id), "strength": .number(l.strength.rounded(toPlaces: 4))]
        if let name = ws.engine.looks.look(id: l.id)?.displayName { o["name"] = .string(name) }
        return .object(o)
    }

    /// ルックの指定(id と強さ)を設定に当てる。誤りなら理由を返す
    static func applyLook(id: JSONValue?, strength: Double?, delta: Double?, to settings: inout DevelopSettings,
                          ws: RawgenzoWorkspace) -> String? {
        if let id {
            if id == .null {
                settings.look = nil
                return strength == nil && delta == nil ? nil : "ルックを無しにするときは強さを指定できません"
            }
            guard let raw = id.stringValue, ws.engine.looks.look(id: raw) != nil else {
                return "ルックが見つかりません: \(id.stringValue ?? "?")(list_looks の id を使ってください)"
            }
            settings.look = LookSelection(id: raw, strength: settings.look?.strength ?? 1)
        }
        guard strength != nil || delta != nil else { return nil }
        guard settings.look != nil else { return "ルックが当たっていない写真の強さは変えられません(look で選んでください)" }
        if let v = strength { settings.look!.strength = v }
        if let d = delta { settings.look!.strength = min(max(settings.look!.strength + d, 0), 1) }
        return nil
    }

    static func applyTrialLook(_ look: JSONValue, to settings: inout DevelopSettings, ws: RawgenzoWorkspace) -> String? {
        let id: JSONValue? = look.objectValue?.keys.contains("id") == true ? (look["id"] ?? .null) : .none
        return applyLook(id: id,
                  strength: look["strength"]?.doubleValue, delta: nil, to: &settings, ws: ws)
    }

    static func registerLook(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "list_looks", title: "ルックの一覧",
            description: "使えるルック(色の作りのひな形。シネマ風・フィルム風・モノクロなど)の ID・名前・説明を返す。"
                + "user はユーザが置いた .cube のルックで、説明が無いことがある",
            effect: .read)) { _, _ in
            let rows: [JSONValue] = ws.engine.looks.all.map { l in
                var o: [String: JSONValue] = ["id": .string(l.id), "name": .string(l.displayName),
                                              "kind": .string(l.id.hasPrefix("builtin.") ? "builtin" : "user")]
                if let s = l.summary { o["summary"] = .string(s) }
                return .object(o)
            }
            return .json(["looks": .array(rows)])
        }
        surface.register(ToolDescriptor(
            name: "set_look", title: "ルックを当てる",
            description: "写真にルックを当てる・外す・強さを変えて、サイドカーに保存する(undo で取り消せる)。"
                + "look に list_looks の id(null で外す)、strength に強さ(0〜1。1 でルックそのまま)。"
                + "「少し弱めて」のような指示は strength_delta を使う。ルックは露出・色などの調整の後に掛かる。"
                + "複数の写真に同じ指定を当てられる",
            input: .object([
                .init("photos", .array(of: photoID, description: "当てる写真の ID", minItems: 1, maxItems: 1000)),
                .init("look", JSONSchema.string("ルックの ID(list_looks)。null で外す。省くと今のルックのまま").orNull()),
                .init("strength", .number("強さ(0〜1)。省くと今の強さ(ルックが無かった写真は 1)", minimum: 0, maximum: 1)),
                .init("strength_delta", .number("今の強さに足す量(結果は 0〜1 に丸める)", minimum: -1, maximum: 1)),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let strength = args["strength"]?.doubleValue
            let delta = args["strength_delta"]?.doubleValue
            let lookGiven = args.objectValue?.keys.contains("look") == true
            if !lookGiven, strength == nil, delta == nil { return .error("look・strength・strength_delta のどれかを指定してください") }
            if strength != nil, delta != nil { return .error("strength と strength_delta はどちらか一方にしてください") }
            let ids = try uniqueIDs(ws, args["photos"])
            // 先に全部の写真で確かめる(途中で断って半分だけ変わる、を避ける)
            var planned: [(Photo, DevelopSettings, DevelopSettings)] = []
            for id in ids {
                let photo = try ws.photo(id)
                var after = photo.settings
                // JSONValue は nil リテラルで .null になるので、「指定なし」は Optional の .none で明示する
                let lookID: JSONValue? = lookGiven ? (args["look"] ?? .null) : .none
                if let error = applyLook(id: lookID, strength: strength, delta: delta, to: &after, ws: ws) {
                    return .error("\(id): \(error)")
                }
                planned.append((photo, photo.settings, after))
            }
            var results: [JSONValue] = []
            for (photo, before, after) in planned {
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(ws.id(for: photo.url)),
                                                "look": ["from": lookJSON(ws, before.look), "to": lookJSON(ws, after.look)]]
                if after == before { row["notes"] = ["変更なし"] }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }
}
