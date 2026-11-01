import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// Rawgenzo の領域定義: 写真・現像設定を、操作面(OperationSurface)の道具として公開する。
/// 道具の説明・入力の形は ParameterCatalog から作るので、スライダーの範囲や注意書きと食い違わない
public enum RawgenzoTools {
    /// AI への説明。対応機種は登録された機種から作る(機種を足したときに書き直さなくて済むように)
    public static func instructions(cameras registry: CameraRegistry) -> String {
        let names = registry.profiles.map(\.displayName).joined(separator: "・")
        let extensions = registry.supportedExtensions.sorted().map { $0.uppercased() }.joined(separator: "・")
        return """
        Rawgenzo は \(names) の RAW(\(extensions))を現像するソフトです。編集は非破壊で、元の RAW は書き換えず、
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
        - 特定の色だけを変えるのは、色の帯全体なら adjust_colors、写真の中の特定の物(淡い花びらなど)なら set_color_point。
          set_color_point は位置で頼む: get_preview(grid: true)で変えたい所と変えたくない所の位置を読み、強さは target_chroma で渡す
        - 値の範囲・効く条件は adjust の各項目の説明にある。例えばシャープネスは等倍で描くときだけ効き、
          縮小したプレビューや統計には表れない
        統計の値はすべて出力の sRGB(見た目に近い値)で 0〜1。
        """
    }

    /// 道具を登録した操作面を作る
    public static func makeSurface(workspace: RawgenzoWorkspace, version: String = "0.1") -> Surface {
        let surface = Surface(name: "rawgenzo", version: version, instructions: instructions(cameras: workspace.engine.registry))
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
        // 登録の順が tools/list の順になる
        registerPhotoInfo(on: surface, workspace: ws)
        registerObserve(on: surface, workspace: ws)
        registerAdjust(on: surface, workspace: ws)
        registerCrop(on: surface, workspace: ws)
        registerTilt(on: surface, workspace: ws)
        registerLook(on: surface, workspace: ws)
        registerColorAdjust(on: surface, workspace: ws)
        registerToneCurve(on: surface, workspace: ws)
        registerOptions(on: surface, workspace: ws)
    }

    // MARK: - 道具に共通の下請け

    /// 写真の ID の並びを、結果で返す形にそろえて重複を除く
    static func uniqueIDs(_ ws: RawgenzoWorkspace, _ value: JSONValue?) throws -> [String] {
        var ids: [String] = []
        for raw in value?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let id = try ws.canonicalID(raw)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
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
}
