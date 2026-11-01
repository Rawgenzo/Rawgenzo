import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// 写真とアプリの状態を読む道具(get_app_state・list_photos・get_photo)と、その結果の整形
extension RawgenzoTools {
    // MARK: 写真とアプリの状態
    static func registerPhotoInfo(on surface: Surface, workspace ws: RawgenzoWorkspace) {
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
                + "follows_baseline に挙がった項目は未指定で、撮影時の値やデコーダの既定値に従っている。"
                + "focus_point は撮影時にピントを合わせた位置(get_preview の画像の比率)で、主な被写体の手がかり",
            input: .object([.init("photo", photoID)], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            return warned(.json(.object(photoState(photo, id: ws.id(for: photo.url), ws: ws))), ws, [photo.url])
        }
    }

    /// 今掛かるレンズ補正(follows_camera: 撮影時のカメラ設定に従っているか)。補正情報が無いレンズは available: false
    static func lensJSON(_ photo: Photo, _ s: DevelopSettings) -> JSONValue {
        guard let l = photo.effectiveLensSettings(s) else {
            return ["available": false, "note": "このレンズには補正情報がない"]
        }
        return ["available": true, "follows_camera": .bool(s.lens == nil), "vignetting": .bool(l.vignetting),
                "distortion": .bool(l.distortion), "chromatic_aberration": .bool(l.chromaticAberration)]
    }

    static func shootingInfo(_ m: RAWMetadata) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let v = m.iso { o["iso"] = .number(Double(v)) }
        if let t = m.exposureTime {
            o["shutter"] = .string(t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%.1f", t))
        }
        if let v = m.fNumber { o["aperture"] = .number(v.rounded(toPlaces: 4)) }
        if let v = m.focalLength { o["focal_length"] = .number(v.rounded(toPlaces: 4)) }
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
        o["as_shot"] = ["temperature": .number(photo.source.asShot.temperature.rounded(toPlaces: 4)),
                        "tint": .number(photo.source.asShot.tint.rounded(toPlaces: 4))]
        o["adjustments"] = .object(Dictionary(uniqueKeysWithValues: ParameterCatalog.all.map {
            ($0.id, JSONValue.number(($0.value(s, context: context)).rounded(toPlaces: 4)))
        }))
        o["follows_baseline"] = .array(ParameterCatalog.all.filter { $0.isOptional && $0.storedValue(s) == nil }
            .map { .string($0.id) })
        o["crop"] = cropJSON(s.crop)
        o["look"] = lookJSON(ws, s.look)
        // 撮影情報の残り(get_photo だけ。list_photos は写真の数だけ長くなるので足さない)。値の無い項目は書かない
        let m = photo.metadata
        if let v = m.exposureBias { o["exposure_bias"] = .number(v.rounded(toPlaces: 4)) }
        if let v = ExifLabels.exposureProgram(m.exposureProgram) { o["exposure_mode"] = .string(v) }
        if let v = ExifLabels.meteringMode(m.meteringMode) { o["metering"] = .string(v) }
        if let v = ExifLabels.whiteBalance(m.whiteBalance) { o["white_balance_mode"] = .string(v) }
        if let v = ExifLabels.flash(m.flash) { o["flash"] = .string(v) }
        if let v = m.focalLength35mm, v > 0 { o["focal_length_35mm"] = .number(v) }
        // 撮影時にピントを合わせた位置(get_preview の画像 = 切り抜いた後の比率)。主な被写体の手がかり。切り抜きの外なら書かない
        if let f = photo.metadata.focusPoint,
           let p = FocusPointMapping.displayed(FocusPointMapping.upright(f, orientation: photo.metadata.orientation),
                                               crop: s.crop, imageAspect: photo.imageAspect) {
            o["focus_point"] = [.number(Double(p.x).rounded(toPlaces: 3)), .number(Double(p.y).rounded(toPlaces: 3))]
        }
        o["color_adjust"] = colorAdjustJSON(s.colorAdjust)
        o["tone_curve"] = toneCurveJSON(s.toneCurve)
        o["lens_correction"] = lensJSON(photo, s)
        o["hdr_output"] = .bool(s.hdr.extendedOutput)
        return o
    }
}
