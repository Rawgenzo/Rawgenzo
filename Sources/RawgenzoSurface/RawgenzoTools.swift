import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// Rawgenzo の領域定義: 写真・現像設定を、操作面(OperationSurface)の道具として公開する。
/// 道具の説明・入力の形は ParameterCatalog から作るので、スライダーの範囲や注意書きと食い違わない
public enum RawgenzoTools {
    public static let instructions = """
        Rawgenzo は SONY α7S III の RAW(ARW)を現像するソフトです。編集は非破壊で、元の RAW は書き換えず、
        設定は写真ごとのサイドカー(<RAW>.rawgenzo.json)に保存されます。adjust の変更は undo で取り消せます。

        進め方の目安:
        - 「この写真」「今開いている写真」と言われたら、そのたびに get_app_state でユーザがアプリで見ている写真を確かめる。
          会話の前のほうで写真を決めていても、ユーザはアプリで別の写真に切り替えているかもしれない。
          道具の結果に open_photo_warning が付いたら、対象がアプリで開いている写真と違う
        - list_photos で写真とメタデータ(ISO・レンズ・撮影日時など)を見る。条件で絞り込める。
          作業フォルダ以外のフォルダも folder(絶対パス)で見られ、その写真は絶対パスの ID で指す
        - get_photo で今の設定を見る
        - 明るさや色の判断は、まず get_stats(数値。安い)で行う。画像が要るときだけ get_preview を使う(画像はトークンを多く使う)
        - 明るさを目標に合わせる・揃える・白飛びを抑えるときは solve_exposure に目標を渡す(値を試し続けない)
        - それ以外は adjust で変える。写真ごとに違う変更も 1 回の呼び出しにまとめられる。結果に変更後の主な統計が付く
        - 切り抜き・傾き補正は set_crop。枠を決めるときは get_preview に ignore_crop を付けて、切り抜く前の全体を見る
        - 水平を直すときは、目測より estimate_tilt を使う。水平の基準(建物の線か人物か)を頼まれていなければ、
          どちらを基準にしたかを伝え、食い違いが大きければ人に聞く
        - 「シネマ調」「フィルムっぽく」「モノクロに」のような雰囲気の指示は、まず list_looks でルック(色の作りのひな形)を確かめ、
          合うものがあれば set_look で当てる。足りない分だけ adjust で整える。get_preview の look で、保存せずに試せる
        - レンズ補正は set_lens_correction、HDR ディスプレイ向けの出力は set_hdr_output、全部を初期値に戻すのは reset_settings
        - 値の範囲・効く条件は adjust の各項目の説明にある。例えばシャープネスは等倍で描くときだけ効き、
          縮小したプレビューや統計には表れない
        統計の値はすべて出力の sRGB(見た目に近い値)で 0〜1。
        """

    /// 道具を登録した操作面を作る
    public static func makeSurface(workspace: RawgenzoWorkspace, version: String = "0.1") -> Surface {
        let surface = Surface(name: "rawgenzo", version: version, instructions: instructions)
        register(on: surface, workspace: workspace)
        registerSolvers(on: surface, workspace: workspace)
        surface.registerStandardTools()
        return surface
    }

    // MARK: - 入力の形

    static let photoID = JSONSchema.string("写真の ID(list_photos・get_app_state が返す photo。作業フォルダの中ならファイル名 例 DSC03561.ARW、"
                                           + "それ以外は RAW ファイルの絶対パス 例 /Users/me/Photos/DSC03561.ARW)")

    /// adjust の changes。ParameterCatalog の全項目。null で基準値(撮影時の値・デコーダの既定値など)に戻す
    public static var changesSchema: JSONSchema { changesSchema(detailed: true) }

    /// - detailed: 各項目の説明を付けるか。説明は adjust にだけ付け、仮の変更を受け取る道具(get_stats など)は
    ///   範囲だけにする(道具の一覧は会話のたびに AI に送られるので、同じ説明を何度も載せない)
    public static func changesSchema(detailed: Bool) -> JSONSchema {
        .object(ParameterCatalog.all.map { p in
            guard detailed else {
                return .init(p.id, JSONSchema.number(minimum: p.range.lowerBound, maximum: p.range.upperBound).orNull())
            }
            let unit = p.unit.map { "単位 \($0)。" } ?? ""
            let baseline: String
            switch p.baseline {
            case .fixed(let v): baseline = "基準値 \(v)。"
            case .asShotTemperature, .asShotTint: baseline = "基準値は撮影時の値。"
            default: baseline = "基準値はデコーダの既定値。"
            }
            let schema = JSONSchema.number("\(p.label)。\(p.summary)。\(unit)\(baseline)",
                                           minimum: p.range.lowerBound, maximum: p.range.upperBound)
            return .init(p.id, schema.orNull())
        }, description: detailed
            ? "変える項目だけを書く。null を書いた項目は基準値に戻す"
            : "仮に当てる変更。adjust の changes と同じ形(各項目の意味は adjust の説明を参照)。保存はしない")
    }

    // MARK: - 道具

    static func register(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "get_app_state", title: "アプリの表示",
            description: "ユーザが Rawgenzo アプリで今見ているもの(開いている写真・表示倍率・クロップ中か)を返す。"
                + "「この写真」「今開いている写真」と言われたらまず使う。open_photo が写真の ID(作業フォルダの外なら絶対パス)。"
                + "app_connected が false なら、アプリが起動していないか、AI からの操作の受け付けがオフで、アプリの状態は分からない",
            effect: .read)) { _, _ in
            guard let live = ws.live else {
                return .json(["app_connected": false,
                              "note": "Rawgenzo アプリにつながっていない(起動していないか、設定で AI からの操作の受け付けがオフ)。どの写真のことか、ユーザに聞くこと"])
            }
            let v = live.viewState()
            var o: [String: JSONValue] = ["app_connected": true, "cropping": .bool(v.isCropping)]
            let inWorkspace = v.folder.map { $0.standardizedFileURL.path == ws.folder.path } ?? false
            o["folder_is_workspace"] = .bool(inWorkspace)
            // 作業フォルダの外のフォルダも、list_photos の folder にそのまま渡せる形で返す
            if let f = v.folder, !inWorkspace { o["app_folder"] = .string(f.standardizedFileURL.path) }
            o["open_photo"] = v.openPhoto.flatMap { try? ws.canonicalID(ws.id(for: $0)) }.map { .string($0) } ?? .null
            o["zoom"] = v.fitsWindow ? "ウインドウに合わせる" : v.zoom.map { .string("\(Int(($0 * 100).rounded()))%") } ?? .null
            return .json(.object(o))
        }
        surface.register(ToolDescriptor(
            name: "list_photos", title: "写真の一覧",
            description: "作業フォルダ(folder を渡すとそのフォルダ)の写真と撮影情報を名前順に返す。条件で絞り込める。"
                + "edited は Rawgenzo の設定(サイドカー)があるか",
            input: .object([
                .init("folder", .string("見るフォルダの絶対パス(省くと作業フォルダ。サブフォルダは含まない)")),
                .init("iso_min", .integer("ISO がこの値以上")),
                .init("iso_max", .integer("ISO がこの値以下")),
                .init("lens_contains", .string("レンズ名にこの文字列を含む(大文字小文字を区別しない)")),
                .init("edited", .boolean("true なら編集済みだけ、false なら未編集だけ")),
                .init("offset", .integer("先頭から飛ばす件数", minimum: 0)),
                .init("limit", .integer("返す最大件数(既定 100)", minimum: 1, maximum: 1000)),
            ]),
            effect: .read)) { args, _ in
            var rows: [JSONValue] = []
            for id in try ws.photoIDs(in: args["folder"]?.stringValue.map { try ws.resolveFolder(path: $0) }) {
                guard let m = try? ws.metadata(id) else { continue }
                if let v = args["iso_min"]?.intValue, (m.iso ?? 0) < v { continue }
                if let v = args["iso_max"]?.intValue, (m.iso ?? Int.max) > v { continue }
                if let s = args["lens_contains"]?.stringValue,
                   !(m.lensModel ?? "").localizedCaseInsensitiveContains(s) { continue }
                let edited = ws.hasSidecar(id)
                if let e = args["edited"]?.boolValue, e != edited { continue }
                var row = shootingInfo(m)
                row["photo"] = .string(id)
                row["edited"] = .bool(edited)
                rows.append(.object(row))
            }
            let offset = args["offset"]?.intValue ?? 0
            let limit = args["limit"]?.intValue ?? 100
            let page = Array(rows.dropFirst(offset).prefix(limit))
            var out: [String: JSONValue] = ["total": .number(Double(rows.count)), "offset": .number(Double(offset)),
                                            "photos": .array(page)]
            if let f = args["folder"]?.stringValue { out["folder"] = .string(try ws.resolveFolder(path: f).path) }
            return .json(.object(out))
        }

        surface.register(ToolDescriptor(
            name: "get_photo", title: "写真の設定",
            description: "写真の撮影情報と、今の現像設定を返す。adjustments は実際に使われる値。"
                + "follows_baseline に挙がった項目は未指定で、撮影時の値やデコーダの既定値に従っている",
            input: .object([.init("photo", photoID)], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            return warned(.json(.object(photoState(photo, id: ws.id(for: photo.url), ws: ws))), ws, [photo.url])
        }

        surface.register(ToolDescriptor(
            name: "get_stats", title: "現像結果の統計",
            description: "今の設定(changes を渡すと、それを仮に当てた設定。保存はしない)で現像した結果の統計を返す。"
                + "輝度の平均・中央値・1%/99% 点、白飛び・黒つぶれの割合、平均 RGB。"
                + "detail を full にすると 32 区間のヒストグラム(histogram、暗い側から)と、写真を 8×8 に区切った各区画の平均 RGB(grid_rgb、行は上から・列は左から)も返す(約 1.7KB)。"
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
            if region != nil, showFrame || guide != nil {
                return .error("region は show_crop_frame・guide と一緒には使えません")
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
                                                              longEdge: args["long_edge"]?.intValue ?? 768)
            let size = photo.source.nativeSize
            let shown = settings.crop ?? .full
            let scale = Double(image.extent.width) / (Double(size.width) * shown.width)
            if showFrame || guide != nil {
                let f = showFrame ? frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } : nil
                image = try PreviewOverlay.draw(on: image, frame: f, guides: guide.map { [$0] } ?? [])
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

        registerCrop(on: surface, workspace: ws)
        registerTilt(on: surface, workspace: ws)
        registerLook(on: surface, workspace: ws)
        registerOptions(on: surface, workspace: ws)
    }

    // MARK: レンズ補正・HDR 出力・初期値

    /// 今掛かるレンズ補正(follows_camera: 撮影時のカメラ設定に従っているか)。補正情報が無いレンズは available: false
    static func lensJSON(_ photo: Photo, _ s: DevelopSettings) -> JSONValue {
        guard let l = photo.effectiveLensSettings(s) else {
            return ["available": false, "note": "このレンズには補正情報がない"]
        }
        return ["available": true, "follows_camera": .bool(s.lens == nil), "vignetting": .bool(l.vignetting),
                "distortion": .bool(l.distortion), "chromatic_aberration": .bool(l.chromaticAberration)]
    }

    /// 写真の ID の並びを、結果で返す形にそろえて重複を除く
    static func uniqueIDs(_ ws: RawgenzoWorkspace, _ value: JSONValue?) throws -> [String] {
        var ids: [String] = []
        for raw in value?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let id = try ws.canonicalID(raw)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

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

    // MARK: ルック

    static let lookTrialSchema = JSONSchema.object([
        .init("id", JSONSchema.string("ルックの ID(list_looks)。null でルック無し").orNull()),
        .init("strength", .number("強さ(0〜1。省くと今の強さ、ルックが無かったなら 1)", minimum: 0, maximum: 1)),
    ], description: "仮に当てるルック(保存はしない)。set_look と同じ指定")

    static func lookJSON(_ ws: RawgenzoWorkspace, _ look: LookSelection?) -> JSONValue {
        guard let l = look else { return .null }
        var o: [String: JSONValue] = ["id": .string(l.id), "strength": .number(round4(l.strength))]
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
            var ids: [String] = []
            for raw in args["photos"]!.arrayValue!.compactMap(\.stringValue) {
                let id = try ws.canonicalID(raw)
                if !ids.contains(id) { ids.append(id) }
            }
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

    // MARK: 切り抜き

    static let aspectNames = AspectRatio.allCases.map(\.rawValue)

    static func registerCrop(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        let unit = JSONSchema.number(minimum: 0, maximum: 1)
        surface.register(ToolDescriptor(
            name: "set_crop", title: "切り抜き・傾き補正",
            description: "写真の切り抜き枠と傾き補正を設定してサイドカーに保存する(undo で取り消せる)。"
                + "枠の x・y・width・height は、傾き補正の後・切り抜く前の画像全体に対する比率(0〜1、左上が原点)で、4 つそろえて渡す。"
                + "get_preview に ignore_crop: true を付けた画像のピクセル座標を、その幅・高さで割った値になる。"
                + "aspect だけを渡すとその比率で中央に最大の枠、枠と aspect の両方なら枠の中心を保って比率に合わせて縮める。"
                + "angle だけを渡すと今の枠のまま傾ける。枠が傾けた画像からはみ出すときは、はみ出さない大きさに縮める(結果の notes)。"
                + "reset: true で切り抜きも傾きも無しに戻す。複数の写真に同じ指定を当てられる",
            input: .object([
                .init("photos", .array(of: photoID, description: "切り抜く写真の ID", minItems: 1, maxItems: 1000)),
                .init("x", unit), .init("y", unit),
                .init("width", .number(minimum: 0.05, maximum: 1)), .init("height", .number(minimum: 0.05, maximum: 1)),
                .init("angle", .number("傾き補正(度)。正 = 時計回り",
                                       minimum: CropSettings.angleRange.lowerBound, maximum: CropSettings.angleRange.upperBound)),
                .init("aspect", .string("縦横比。free(自由)・original(元の比率)・square(1:1)・r3x2・r4x3・r16x9・r2x3(縦)・r4x5(縦)",
                                        oneOf: aspectNames)),
                .init("reset", .boolean("true で切り抜きと傾き補正を無くす(ほかの項目と一緒には使えない)")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let rectKeys = ["x", "y", "width", "height"]
            let given = rectKeys.filter { args[$0] != nil }
            let reset = args["reset"]?.boolValue == true
            let angle = args["angle"]?.doubleValue
            let aspect = args["aspect"]?.stringValue.flatMap(AspectRatio.init(rawValue:))
            if reset, !given.isEmpty || angle != nil || aspect != nil {
                return .error("reset はほかの項目と一緒には使えません")
            }
            if !given.isEmpty, given.count < 4 { return .error("x・y・width・height は 4 つそろえて渡してください") }
            if !reset, given.isEmpty, angle == nil, aspect == nil {
                return .error("枠(x・y・width・height)・aspect・angle・reset のどれかを指定してください")
            }
            if given.count == 4, args["x"]!.doubleValue! + args["width"]!.doubleValue! > 1 + 1e-9
                || args["y"]!.doubleValue! + args["height"]!.doubleValue! > 1 + 1e-9 {
                return .error("枠が画像の外に出ています(x + width と y + height は 1 以下)")
            }
            var ids: [String] = []
            for raw in args["photos"]!.arrayValue!.compactMap(\.stringValue) {
                let id = try ws.canonicalID(raw)
                if !ids.contains(id) { ids.append(id) }
            }

            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = before
                var notes: [String] = []
                if reset {
                    after.crop = nil
                } else {
                    let imageAspect = photo.imageAspect
                    let tilt = angle ?? before.crop?.angle ?? 0
                    var c: CropSettings
                    if given.count == 4 {
                        c = CropSettings(x: args["x"]!.doubleValue!, y: args["y"]!.doubleValue!,
                                         width: args["width"]!.doubleValue!, height: args["height"]!.doubleValue!,
                                         angle: tilt, aspect: aspect ?? .free)
                        if let a = aspect, let ratio = a.value(imageAspect: imageAspect) {
                            let shrunk = c.shrunk(toAspect: ratio, imageAspect: imageAspect)
                            if differs(shrunk, c) { notes.append("枠の中心を保って \(a.label) に合わせて縮めた") }
                            c = shrunk
                        }
                    } else if let a = aspect {
                        c = .centered(aspect: a, imageAspect: imageAspect, angle: tilt)
                    } else {
                        c = before.crop ?? .full
                        c.angle = tilt
                    }
                    let requested = c
                    c = c.clamped()
                    if !c.isInsideImage(imageAspect: imageAspect) { c = c.fitted(imageAspect: imageAspect) }
                    // 等しいかではなく差の大きさで比べる。y 0.19・高さ 0.81 のように下端がちょうど 1 の枠は、
                    // clamped の 1 - 0.81 = 0.18999999999999995 で値がわずかに変わり、縮めていないのに注記が付いた(試験)
                    if differs(c, requested) {
                        notes.append("枠が傾けた画像からはみ出すので、はみ出さない大きさに縮めた")
                    }
                    after.crop = c == .full ? nil : c
                }
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id), "crop": ["from": cropJSON(before.crop), "to": cropJSON(after.crop)]]
                let size = photo.source.nativeSize
                let c = after.crop ?? .full
                row["cropped_size"] = [.number((Double(size.width) * c.width).rounded()),
                                       .number((Double(size.height) * c.height).rounded())]
                if after == before { notes.append("変更なし") }
                if !notes.isEmpty { row["notes"] = .array(notes.map { .string($0) }) }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }

    /// 枠が目に見えて違うか(小数の誤差は同じとみなす)
    static func differs(_ a: CropSettings, _ b: CropSettings) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height, a.angle - b.angle].contains { abs($0) > 1e-6 }
    }

    // MARK: 傾きの推定

    static func registerTilt(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "estimate_tilt", title: "傾きの手がかり",
            description: "写真の傾きを直すための手がかりを返す。長い直線(水平・垂直から 10° 以内)に番号を付けた画像と、"
                + "各線の角度、人物の目(E1…)・肩(S1…)を結ぶ線と、首と腰を結ぶ体の軸(T1…。垂直の手がかり)の角度。"
                + "角度はどれも set_crop の angle に入れるとその線が水平(垂直)になる値で、傾き補正の前からの値(今の angle に足すのではない)。"
                + "画像を見て、本当に水平・垂直なもの(建物や家具の縁・柱・水平線)の番号を segments に渡すと、長さで重みを付けた角度を返す。"
                + "奥へ伸びる線(遠近で斜めに見える)・ブラインドや斜めに置かれた物・カメラを上下に向けて撮ったときの縦の線は使わない。"
                + "人物写真では人物の線(subjects)も手がかりになる。目・肩は首をかしげたり肩を傾けたりすると大きく出るので、"
                + "「身体の傾き」には体の軸(T)を使い、1 本では決めない。体の軸はその人の姿勢(寄りかかる・前かがみ)も含む。"
                + "confidence が 0.3 未満の線(座っていて腰が隠れているときの体の軸など)は当てにしない。"
                + "線と人物で食い違うとき、どれを基準にするか決められないときは人に聞く。"
                + "そのとき、両方の値だけでなく間の角度(人物を立てつつ背景の傾きを抑える)も選択肢に入れる。2 秒ほどかかる",
            input: .object([
                .init("photo", photoID),
                .init("segments", .array(of: .integer(minimum: 1), description: "水平・垂直の基準にする直線の番号(前の結果の画像の番号)")),
                .init("subjects", .array(of: .string(), description: "基準にする人物の線(E1・S2・T1 など)")),
                .init("image", .boolean("番号を描いた画像を返すか(既定 true。番号が分かっていて角度だけ欲しいときは false)")),
                .init("long_edge", .integer("画像の長辺(既定 768)", minimum: 384, maximum: 1600)),
            ], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            let report = try TiltEstimator.estimate(photo, settings: photo.settings, pipeline: ws.engine.pipeline)
            let subjects = TiltEstimator.subjectIDs(report.subjects)
            func point(_ p: CGPoint) -> JSONValue { [.number(round4(Double(p.x))), .number(round4(Double(p.y)))] }
            func deg(_ v: Double) -> JSONValue { .number((v * 100).rounded() / 100) }
            var o: [String: JSONValue] = [
                "photo": .string(ws.id(for: photo.url)),
                "current_angle": deg(photo.settings.crop?.angle ?? 0),
                "segments": .array(report.segments.map {
                    ["id": .number(Double($0.id)), "axis": .string($0.axis.rawValue), "angle": deg($0.angle),
                     "length": .number(round4($0.length)), "from": point($0.from), "to": point($0.to)]
                }),
                "subjects": .array(subjects.map { id, m in
                    ["id": .string(id), "kind": .string(m.kind.rawValue), "angle": deg(m.angle), "center": point(m.center),
                     "confidence": .number((m.confidence * 100).rounded() / 100)]
                }),
            ]
            var notes: [String] = []
            var chosen: [String: JSONValue] = [:]
            if let ids = args["segments"]?.arrayValue?.compactMap(\.intValue), !ids.isEmpty {
                let picked = report.segments.filter { ids.contains($0.id) }
                let missing = ids.filter { id in !picked.contains { $0.id == id } }
                if !missing.isEmpty { notes.append("見つからない番号: \(missing.map(String.init).joined(separator: ", "))(番号は呼ぶたびに同じ。前の結果の番号を使う)") }
                if let c = TiltEstimator.combinedAngle(picked) {
                    chosen["segments"] = ["angle": deg(c.angle), "spread": deg(c.spread), "count": .number(Double(picked.count))]
                    if c.spread > 0.7 { notes.append("選んだ線の角度が ±\(String(format: "%.1f", c.spread))° ばらついている。遠近で斜めに見える線が混ざっていないか確かめる") }
                }
            }
            if let ids = args["subjects"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty {
                let picked = subjects.filter { ids.contains($0.0) }.map(\.1)
                if picked.count < ids.count { notes.append("見つからない人物の線がある") }
                if !picked.isEmpty {
                    let mean = picked.map(\.angle).reduce(0, +) / Double(picked.count)
                    let spread = (picked.map { ($0.angle - mean) * ($0.angle - mean) }.reduce(0, +) / Double(picked.count)).squareRoot()
                    chosen["subjects"] = ["angle": deg(mean), "spread": deg(spread), "count": .number(Double(picked.count))]
                }
            }
            if !chosen.isEmpty { o["chosen"] = .object(chosen) }
            if report.segments.isEmpty { notes.append("長い直線が見つからない(自然の風景など)。人物の線か、目で見て決める") }
            if photo.lensCorrection != nil, photo.effectiveLensSettings(photo.settings)?.distortion == false {
                notes.append("歪曲補正が切れているので、画面の端の直線は曲がって測りにくい(set_lens_correction で distortion をオンにすると正確になる)")
            }
            if !notes.isEmpty { o["notes"] = .array(notes.map { .string($0) }) }

            var content: [ToolContent] = [.json(.object(o))]
            if args["image"]?.boolValue ?? true {
                let image = try ws.engine.pipeline.processFitting(photo, settings: TiltEstimator.measuringSettings(photo.settings),
                                                                  longEdge: args["long_edge"]?.intValue ?? 768)
                let marked = try PreviewOverlay.draw(on: image, frame: nil, marks: TiltEstimator.marks(report))
                content.append(.image(data: try PreviewEncoder.jpeg(marked, quality: 0.75), mimeType: "image/jpeg"))
            }
            return warned(ToolResult(content), ws, [photo.url])
        }
    }

    static func cropJSON(_ crop: CropSettings?) -> JSONValue {
        guard let c = crop else { return .null }
        return ["x": .number(round4(c.x)), "y": .number(round4(c.y)),
                "width": .number(round4(c.width)), "height": .number(round4(c.height)),
                "angle": .number(round4(c.angle)), "aspect": .string(c.aspect.rawValue)]
    }

    // MARK: 目標で指示する

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
            var ids: [String] = []
            for raw in args["photos"]!.arrayValue!.compactMap(\.stringValue) {
                let id = try ws.canonicalID(raw)
                if !ids.contains(id) { ids.append(id) }
            }

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

    /// 1 枚の写真を指す呼び出しで、その写真がアプリで開いている写真と違えば、その知らせ(アプリにつながっていないときは nil)。
    /// 「この写真」を会話の前のほうで決めた写真と解釈し、アプリで切り替えた後の写真ではなく前の写真を変えた(2026-10-16 の試験)。
    /// 説明文の「get_app_state で確かめる」だけでは、AI が確かめを飛ばしたときに気づけないので、結果で知らせる。
    /// 複数の写真をまとめて扱う呼び出しには付けない(「全部揃えて」のたびに付くと知らせの意味が薄れる)
    static func openPhotoWarning(_ ws: RawgenzoWorkspace, _ targets: [URL]) -> String? {
        guard targets.count == 1, let live = ws.live, let open = live.viewState().openPhoto else { return nil }
        guard open.standardizedFileURL.path != targets[0].standardizedFileURL.path else { return nil }
        let id = (try? ws.canonicalID(ws.id(for: open))) ?? open.path
        return "アプリで今開いているのは \(id) で、この写真ではない。「この写真」「今開いている写真」の指示なら、対象を確かめること"
    }

    /// JSON の結果に open_photo_warning を足す
    static func warned(_ result: ToolResult, _ ws: RawgenzoWorkspace, _ targets: [URL]) -> ToolResult {
        guard let w = openPhotoWarning(ws, targets) else { return result }
        return ToolResult(result.content.map {
            guard case .json(.object(var o)) = $0 else { return $0 }
            o["open_photo_warning"] = .string(w)
            return .json(.object(o))
        }, isError: result.isError)
    }

    /// adjust の結果に統計を付ける写真の数の上限(1 枚 0.2 秒ほどかかり、約 180 バイト増える)
    static let observeLimit = 10

    /// 設定を保存し、取り消しの手順を登録する。
    ///
    /// 取り消しは「この取引が変えた項目だけを、変更前の値に戻す」。ほかの項目は取り消すときの値を残す。
    /// 取り消す前に、変えた項目が今もこの取引の直後の値のままかを確かめ、違えば断る(後から別の操作で変えられている)。
    /// 操作面の履歴ではなく今の状態(アプリで開いていれば編集中の値、そうでなければサイドカー)で確かめるので、
    /// アプリと rawdev の切り替えをまたいだ変更や、CLI・手作業の変更も見つけられる。
    /// 最初の版は変更前の設定を丸ごと書き戻していて、切り替えの後にアプリで行った変更を黙って消した(2026-10-16 の試験)
    static func commit(_ ws: RawgenzoWorkspace, _ ctx: ToolContext, _ photo: Photo,
                       from before: DevelopSettings, to after: DevelopSettings) throws {
        let id = ws.id(for: photo.url)
        let hadSidecar = ws.hasSidecar(id)
        try ws.save(photo, settings: after, origin: ChangeOrigin(caller: ctx.caller, task: ctx.task))
        let fields = SettingsFields.changed(before, after)
        let undoOrigin = ChangeOrigin(caller: ctx.caller, task: ctx.task, isUndo: true)
        ctx.registerUndo("\(id) の設定", resource: photo.url.path, check: {
            let now = try ws.photo(id).settings
            let altered = fields.filter { !SettingsFields.same($0, now, after) }
            if !altered.isEmpty {
                throw UndoWouldDiscardChanges(photo: id, fields: altered.map {
                    ($0, SettingsFields.describe($0, now), SettingsFields.describe($0, after))
                })
            }
        }) {
            let p = try ws.photo(id)
            var restored = p.settings
            for f in fields { SettingsFields.copy(f, from: before, to: &restored) }
            // サイドカーが無かった写真は、戻した結果が初期値と同じときだけ消す(後から他の項目が書かれていれば残す)
            if !hadSidecar, restored == p.profile.initialSettings(for: p.metadata) {
                try ws.removeSidecar(p, origin: undoOrigin)
            } else {
                try ws.save(p, settings: restored, origin: undoOrigin)
            }
        }
    }

    /// 2 つの設定の、数値パラメータの違い(項目ごとの {from, to}。実際に使われる値)
    static func difference(_ a: DevelopSettings, _ b: DevelopSettings, photo: Photo) -> [String: JSONValue] {
        let context = photo.parameterContext
        var diff: [String: JSONValue] = [:]
        for p in ParameterCatalog.all {
            let from = p.value(a, context: context), to = p.value(b, context: context)
            if from != to || p.storedValue(a) != p.storedValue(b) {
                diff[p.id] = ["from": .number(round4(from)), "to": .number(round4(to))]
            }
        }
        return diff
    }

    // MARK: - 下請け

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
            diff[key] = ["from": .number(round4(from)), "to": .number(round4(to))]
        }
        return diff
    }

    static func computeStats(_ ws: RawgenzoWorkspace, _ photo: Photo, _ settings: DevelopSettings) throws -> ImageStats {
        let image = try ws.engine.pipeline.processFitting(photo, settings: settings, longEdge: ImageStats.defaultLongEdge)
        return try ImageStats.compute(image)
    }

    /// 統計の要約(ヒストグラムと区画を除いたもの)
    static func summary(_ s: ImageStats) -> JSONValue {
        [
            "mean_luminance": .number(s.meanLuminance),
            "median_luminance": .number(s.medianLuminance),
            "p01_luminance": .number(s.p01Luminance),
            "p99_luminance": .number(s.p99Luminance),
            "highlight_clipping": .number(s.highlightClipping),
            "shadow_clipping": .number(s.shadowClipping),
            "mean_rgb": .array(s.meanRGB.map { .number($0) }),
        ]
    }

    /// 統計のすべて(要約 + ヒストグラム + 8×8 区画)。キーは要約と同じ書き方にそろえる
    static func full(_ s: ImageStats) -> JSONValue {
        var o = summary(s).objectValue ?? [:]
        o["histogram"] = .array(s.histogram.map { .number($0) })
        o["grid_rgb"] = .array(s.grid.map { row in .array(row.map { cell in .array(cell.map { .number($0) }) }) })
        o["computed_size"] = [.number(Double(s.width)), .number(Double(s.height))]
        return .object(o)
    }

    static func shootingInfo(_ m: RAWMetadata) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let v = m.iso { o["iso"] = .number(Double(v)) }
        if let t = m.exposureTime {
            o["shutter"] = .string(t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%.1f", t))
        }
        if let v = m.fNumber { o["aperture"] = .number(round4(v)) }
        if let v = m.focalLength { o["focal_length"] = .number(round4(v)) }
        if let v = m.lensModel { o["lens"] = .string(v) }
        if let v = m.captureDate { o["captured"] = .string(v) }
        return o
    }

    static func photoState(_ photo: Photo, id: String, ws: RawgenzoWorkspace) -> [String: JSONValue] {
        let s = photo.settings
        let context = photo.parameterContext
        var o = shootingInfo(photo.metadata)
        o["photo"] = .string(id)
        o["camera"] = .string(photo.profile.displayName)
        let size = photo.source.nativeSize
        o["size"] = [.number(Double(Int(size.width))), .number(Double(Int(size.height)))]
        o["as_shot"] = ["temperature": .number(round4(photo.source.asShot.temperature)),
                        "tint": .number(round4(photo.source.asShot.tint))]
        o["adjustments"] = .object(Dictionary(uniqueKeysWithValues: ParameterCatalog.all.map {
            ($0.id, JSONValue.number(round4($0.value(s, context: context))))
        }))
        o["follows_baseline"] = .array(ParameterCatalog.all.filter { $0.isOptional && $0.storedValue(s) == nil }
            .map { .string($0.id) })
        o["crop"] = cropJSON(s.crop)
        o["look"] = lookJSON(ws, s.look)
        o["lens_correction"] = lensJSON(photo, s)
        o["hdr_output"] = .bool(s.hdr.extendedOutput)
        return o
    }

    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
