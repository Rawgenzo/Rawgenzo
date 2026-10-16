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
        - list_photos で写真とメタデータ(ISO・レンズ・撮影日時など)を見る。条件で絞り込める
        - get_photo で今の設定を見る
        - 明るさや色の判断は、まず get_stats(数値。安い)で行う。画像が要るときだけ get_preview を使う(画像はトークンを多く使う)
        - adjust で変える。同じ変更を複数の写真にまとめて当てられる。結果に変更後の主な統計が付く
        - 値の範囲・効く条件は adjust の各項目の説明にある。例えばシャープネスは等倍で描くときだけ効き、
          縮小したプレビューや統計には表れない
        統計の値はすべて出力の sRGB(見た目に近い値)で 0〜1。
        """

    /// 道具を登録した操作面を作る
    public static func makeSurface(workspace: RawgenzoWorkspace, version: String = "0.1") -> Surface {
        let surface = Surface(name: "rawgenzo", version: version, instructions: instructions)
        register(on: surface, workspace: workspace)
        surface.registerStandardTools()
        return surface
    }

    // MARK: - 入力の形

    static let photoID = JSONSchema.string("写真の ID(list_photos が返す photo。フォルダ内のファイル名。例 DSC03561.ARW)")

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
            name: "list_photos", title: "写真の一覧",
            description: "作業フォルダの写真と撮影情報を名前順に返す。条件で絞り込める。"
                + "edited は Rawgenzo の設定(サイドカー)があるか",
            input: .object([
                .init("iso_min", .integer("ISO がこの値以上")),
                .init("iso_max", .integer("ISO がこの値以下")),
                .init("lens_contains", .string("レンズ名にこの文字列を含む(大文字小文字を区別しない)")),
                .init("edited", .boolean("true なら編集済みだけ、false なら未編集だけ")),
                .init("offset", .integer("先頭から飛ばす件数", minimum: 0)),
                .init("limit", .integer("返す最大件数(既定 100)", minimum: 1, maximum: 1000)),
            ]),
            effect: .read)) { args, _ in
            var rows: [JSONValue] = []
            for id in try ws.photoIDs() {
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
            return .json(["total": .number(Double(rows.count)), "offset": .number(Double(offset)),
                          "photos": .array(page)])
        }

        surface.register(ToolDescriptor(
            name: "get_photo", title: "写真の設定",
            description: "写真の撮影情報と、今の現像設定を返す。adjustments は実際に使われる値。"
                + "follows_baseline に挙がった項目は未指定で、撮影時の値やデコーダの既定値に従っている",
            input: .object([.init("photo", photoID)], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            return .json(.object(photoState(photo)))
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
            return .json(args["detail"]?.stringValue == "full" ? full(stats) : summary(stats))
        }

        surface.register(ToolDescriptor(
            name: "get_preview", title: "縮小画像",
            description: "現像結果の縮小画像(JPEG)を返す。changes を渡すと仮に当てた結果(保存はしない)。"
                + "画像はトークンを多く使うので、数値(get_stats)で判断できないときだけ使う。"
                + "縮小して描くのでシャープネスの効果は見えない",
            input: .object([
                .init("photo", photoID),
                .init("long_edge", .integer("長辺のピクセル数(既定 768)", minimum: 128, maximum: 1600)),
                .init("changes", changesSchema(detailed: false)),
            ], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            var settings = photo.settings
            if let changes = args["changes"] { _ = apply(changes, to: &settings, photo: photo) }
            let image = try ws.engine.pipeline.processFitting(photo, settings: settings,
                                                              longEdge: args["long_edge"]?.intValue ?? 768)
            let jpeg = try PreviewEncoder.jpeg(image, quality: 0.75)
            return ToolResult([
                .image(data: jpeg, mimeType: "image/jpeg"),
                .text("\(Int(image.extent.width))×\(Int(image.extent.height))"),
            ])
        }

        surface.register(ToolDescriptor(
            name: "adjust", title: "現像設定を変える",
            description: "写真の現像設定を変えてサイドカーに保存する。edits の各要素は「photos に changes を当てる」。"
                + "写真ごとに違う値にしたいときは edits を複数並べる(同じ写真が複数の要素に出てきたら順に当てる)。"
                + "1 回の呼び出しは 1 つの取引で、undo 1 回でまとめて取り消せる。関連する変更は 1 回の呼び出しにまとめること。"
                + "結果には写真ごとの変更前後の値と、変更した写真が \(observeLimit) 枚以下なら変更後の主な統計(get_stats の summary)が付く",
            input: .object([
                .init("edits", .array(of: .object([
                    .init("photos", .array(of: photoID, description: "変える写真の ID", minItems: 1, maxItems: 1000)),
                    .init("changes", changesSchema),
                ], required: ["photos", "changes"]), description: "当てる変更の並び", minItems: 1, maxItems: 1000)),
                .init("observe", .boolean("変更後の統計を付けるか(既定 true。変更した写真が \(observeLimit) 枚以下のとき)")),
            ], required: ["edits"]),
            effect: .modify)) { args, ctx in
            let edits = args["edits"]!.arrayValue!
            // 写真ごとに、当てる changes を順に集める(登場順を保つ)
            var order: [String] = []
            var perPhoto: [String: [JSONValue]] = [:]
            for edit in edits {
                let changes = edit["changes"]!
                guard !(changes.objectValue ?? [:]).isEmpty else { return .error("changes に変える項目がありません") }
                for id in edit["photos"]!.arrayValue!.compactMap(\.stringValue) {
                    if perPhoto[id] == nil { order.append(id) }
                    perPhoto[id, default: []].append(changes)
                }
            }
            // 先に全部の ID を確かめる(途中で見つからない写真があって半分だけ変わる、を避ける)
            for id in order { _ = try ws.url(for: id) }

            let observe = (args["observe"]?.boolValue ?? true) && order.count <= observeLimit
            var results: [JSONValue] = []
            var observed: [String: JSONValue] = [:]
            for id in order {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = before
                for changes in perPhoto[id]! { _ = apply(changes, to: &after, photo: photo) }
                try commit(ws, ctx, photo, from: before, to: after)
                results.append(["photo": .string(id), "changed": .object(difference(before, after, photo: photo))])
                if observe { observed[id] = summary(try computeStats(ws, photo, after)) }
            }
            var out: [String: JSONValue] = ["results": .array(results)]
            if !observed.isEmpty { out["stats"] = .object(observed) }
            return .json(.object(out))
        }
    }

    /// adjust の結果に統計を付ける写真の数の上限(1 枚 0.2 秒ほどかかり、約 180 バイト増える)
    static let observeLimit = 10

    /// 設定を保存し、取り消しの手順を登録する。サイドカーが無かった写真の取り消しはサイドカーを消して「未編集」に戻す
    static func commit(_ ws: RawgenzoWorkspace, _ ctx: ToolContext, _ photo: Photo,
                       from before: DevelopSettings, to after: DevelopSettings) throws {
        let id = photo.url.lastPathComponent
        let hadSidecar = ws.hasSidecar(id)
        try ws.save(photo, settings: after)
        ctx.registerUndo("\(id) の設定", resource: photo.url.path) {
            let p = try ws.photo(id)
            if hadSidecar { try ws.save(p, settings: before) } else { try ws.removeSidecar(p) }
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

    static func photoState(_ photo: Photo) -> [String: JSONValue] {
        let s = photo.settings
        let context = photo.parameterContext
        var o = shootingInfo(photo.metadata)
        o["photo"] = .string(photo.url.lastPathComponent)
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
        if let c = s.crop {
            o["crop"] = ["x": .number(round4(c.x)), "y": .number(round4(c.y)),
                         "width": .number(round4(c.width)), "height": .number(round4(c.height)),
                         "angle": .number(round4(c.angle)), "aspect": .string(c.aspect.rawValue)]
        } else {
            o["crop"] = .null
        }
        o["look"] = s.look.map { ["id": .string($0.id), "strength": .number(round4($0.strength))] } ?? .null
        if photo.lensCorrection == nil {
            o["lens_correction"] = "このレンズには補正情報がない"
        } else if let l = s.lens {
            o["lens_correction"] = ["vignetting": .bool(l.vignetting), "distortion": .bool(l.distortion),
                                    "chromatic_aberration": .bool(l.chromaticAberration)]
        } else {
            o["lens_correction"] = "撮影時のカメラ設定に従う"
        }
        o["hdr_output"] = .bool(s.hdr.extendedOutput)
        return o
    }

    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
