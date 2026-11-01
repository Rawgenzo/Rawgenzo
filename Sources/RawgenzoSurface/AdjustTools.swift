import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// 数値の現像設定を変える道具(adjust)と、changes・deltas の当て方
extension RawgenzoTools {
    // MARK: 数値を変える
    static func registerAdjust(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "adjust", title: "現像設定を変える",
            description: "写真の現像設定を変えてサイドカーに保存する。edits の各要素は「photos に changes(値を指定)と deltas(今の値に足す量)を当てる」。"
                + "「0.3 上げる」のような指示は deltas を使い、今の値を読んで足し算しないこと。"
                + "写真ごとに違う値にしたいときは edits を複数並べる(同じ写真が複数の要素に出てきたら順に当てる)。"
                + "1 回の呼び出しは 1 つの取引で、undo 1 回でまとめて取り消せる。関連する変更は 1 回の呼び出しにまとめること。"
                + "結果には写真ごとの変更前後の値と、変更した写真が \(observeLimit) 枚以下なら変更後の主な統計(get_stats の summary)が付く",
            input: .object([
                .init("edits", .array(of: .object([
                    .init("photos", .array(of: photoID, description: "変える写真の ID", minItems: 1, maxItems: 1000)),
                    .init("changes", changesSchema),
                    .init("deltas", deltasSchema),
                ], required: ["photos"]), description: "当てる変更の並び(changes と deltas の少なくとも一方が要る)",
                   minItems: 1, maxItems: 1000)),
                .init("observe", .boolean("変更後の統計を付けるか(既定 true。変更した写真が \(observeLimit) 枚以下のとき)")),
            ], required: ["edits"]),
            effect: .modify)) { args, ctx in
            let edits = args["edits"]!.arrayValue!
            // 写真ごとに、当てる changes を順に集める(登場順を保つ)
            var order: [String] = []
            var perPhoto: [String: [JSONValue]] = [:]
            for edit in edits {
                let changes = edit["changes"] ?? .object([:])
                let deltas = edit["deltas"] ?? .object([:])
                guard !(changes.objectValue ?? [:]).isEmpty || !(deltas.objectValue ?? [:]).isEmpty else {
                    return .error("changes か deltas に変える項目を書いてください")
                }
                // 先に全部の ID を確かめる(途中で見つからない写真があって半分だけ変わる、を避ける)。
                // 同じ写真をファイル名と絶対パスの両方で指していても 1 枚として扱う
                var inThisEdit: Set<String> = []
                for raw in edit["photos"]!.arrayValue!.compactMap(\.stringValue) {
                    let id = try ws.canonicalID(raw)
                    guard inThisEdit.insert(id).inserted else { continue }   // 1 つの要素の中の重複は 1 回だけ当てる
                    if perPhoto[id] == nil { order.append(id) }
                    perPhoto[id, default: []].append(edit)
                }
            }

            let observe = (args["observe"]?.boolValue ?? true) && order.count <= observeLimit
            var results: [JSONValue] = []
            var observed: [String: JSONValue] = [:]
            for id in order {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = before
                for edit in perPhoto[id]! {
                    if let changes = edit["changes"] { _ = apply(changes, to: &after, photo: photo) }
                    if let deltas = edit["deltas"] { applyDeltas(deltas, to: &after, photo: photo) }
                }
                try commit(ws, ctx, photo, from: before, to: after)
                results.append(["photo": .string(id), "changed": .object(difference(before, after, photo: photo))])
                if observe { observed[id] = summary(try computeStats(ws, photo, after)) }
            }
            var out: [String: JSONValue] = ["results": .array(results)]
            if !observed.isEmpty { out["stats"] = .object(observed) }
            return warned(.json(.object(out)), ws, try order.map { try ws.url(for: $0) })
        }
    }

    /// adjust の結果に統計を付ける写真の数の上限(1 枚 0.2 秒ほどかかり、約 180 バイト増える)
    static let observeLimit = 10

    /// 2 つの設定の、数値パラメータの違い(項目ごとの {from, to}。実際に使われる値)
    static func difference(_ a: DevelopSettings, _ b: DevelopSettings, photo: Photo) -> [String: JSONValue] {
        let context = photo.parameterContext
        var diff: [String: JSONValue] = [:]
        for p in ParameterCatalog.all {
            let from = p.value(a, context: context), to = p.value(b, context: context)
            if from != to || p.storedValue(a) != p.storedValue(b) {
                diff[p.id] = ["from": .number(from.rounded(toPlaces: 4)), "to": .number(to.rounded(toPlaces: 4))]
            }
        }
        return diff
    }

    /// adjust の deltas。今の値に足す量。結果が範囲を超えたら端に丸める
    public static var deltasSchema: JSONSchema {
        .object(ParameterCatalog.all.map { p in
            let span = p.range.upperBound - p.range.lowerBound
            return .init(p.id, .number(minimum: -span, maximum: span))
        }, description: "今の値に足す量(例: 露出を 0.3 上げるなら {\"exposure\": 0.3})。各項目の意味は changes と同じ。"
            + "結果が範囲を超えたら端に丸める。changes と両方あるときは changes を先に当てる")
    }

    static func applyDeltas(_ deltas: JSONValue, to settings: inout DevelopSettings, photo: Photo) {
        let context = photo.parameterContext
        for (key, value) in (deltas.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let p = ParameterCatalog.descriptor(key), let d = value.doubleValue else { continue }
            p.set(p.value(settings, context: context) + d, in: &settings)
        }
    }

    /// changes を設定に当てる。戻り値は項目ごとの {from, to}(実際に使われる値)
    static func apply(_ changes: JSONValue, to settings: inout DevelopSettings, photo: Photo) -> [String: JSONValue] {
        let context = photo.parameterContext
        var diff: [String: JSONValue] = [:]
        for (key, value) in (changes.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let p = ParameterCatalog.descriptor(key) else { continue }   // スキーマで検証済み
            let from = p.value(settings, context: context)
            if let v = value.doubleValue { p.set(v, in: &settings) } else { p.reset(&settings) }
            let to = p.value(settings, context: context)
            diff[key] = ["from": .number(from.rounded(toPlaces: 4)), "to": .number(to.rounded(toPlaces: 4))]
        }
        return diff
    }
}
