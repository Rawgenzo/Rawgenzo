import XCTest
import OperationSurface
import RAWCore
@testable import RawgenzoSurface

final class RawgenzoToolsSchemaTests: XCTestCase {
    /// adjust の入力の形は ParameterCatalog の全項目を、同じ範囲で持つ
    func testChangesSchemaFollowsCatalog() {
        let schema = RawgenzoTools.changesSchema
        XCTAssertEqual(schema.properties.map(\.name), ParameterCatalog.all.map(\.id))
        for p in ParameterCatalog.all {
            let s = schema.properties.first { $0.name == p.id }!.schema
            XCTAssertEqual(s.minimum, p.range.lowerBound, p.id)
            XCTAssertEqual(s.maximum, p.range.upperBound, p.id)
            XCTAssertTrue(s.nullable, "null で基準値に戻せる: \(p.id)")
            XCTAssertTrue(s.description?.contains(p.summary) == true, p.id)
        }
    }

    /// AI への説明の対応機種は、登録された機種から作る(機種を足しても書き直さなくて済む)
    func testInstructionsListRegisteredCameras() {
        struct OtherCamera: CameraProfile {
            let id = "other.x1"
            let displayName = "OTHER X1"
            let fileExtensions: Set<String> = ["orf"]
            func matches(_ metadata: RAWMetadata) -> Bool { false }
            func makeSource(url: URL, metadata: RAWMetadata) throws -> RAWSource {
                throw RAWError.unsupportedCamera(make: nil, model: nil)
            }
        }
        XCTAssertTrue(RawgenzoTools.instructions(cameras: .makeDefault())
            .hasPrefix("Rawgenzo は SONY α7S III の RAW(ARW)を現像するソフトです。"))
        let two = RawgenzoTools.instructions(cameras: CameraRegistry(profiles: SonyProfile.all + [OtherCamera()]))
        XCTAssertTrue(two.hasPrefix("Rawgenzo は SONY α7S III・OTHER X1 の RAW(ARW・ORF)を現像するソフトです。"))
    }

    func testToolsAreRegisteredInStableOrder() {
        let ws = RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory)
        let surface = RawgenzoTools.makeSurface(workspace: ws)
        XCTAssertEqual(surface.descriptors.map(\.name),
                       ["get_app_state", "list_photos", "get_photo", "get_stats", "get_preview", "adjust", "set_crop", "estimate_tilt", "list_looks", "set_look", "adjust_colors", "set_color_point", "set_tone_curve", "set_lens_correction", "set_hdr_output", "reset_settings", "solve_exposure", "undo", "recent_operations"])
        XCTAssertEqual(surface.descriptors.first { $0.name == "adjust" }?.effect, .modify)
    }

    /// 相対パス・隠しファイル・RAW でないファイルは受け付けない(作業フォルダの外は絶対パスでだけ指せる)
    func testIDsOutsideFolderAreRejected() {
        let ws = RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory)
        for bad in ["../x.ARW", "a/b.ARW", "/etc/passwd", "/tmp/.hidden.ARW", ".hidden.ARW", "..", "x.txt", "", "/no/such/x.ARW"] {
            XCTAssertThrowsError(try ws.url(for: bad), bad)
        }
        let surface = RawgenzoTools.makeSurface(workspace: ws)
        let r = surface.call("get_photo", arguments: ["photo": "../secret.ARW"], as: .agent("t"))
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.summary.contains("ID が正しくありません"), r.summary)
    }
}

/// 実際の ARW を一時フォルダに写して、道具を順に呼ぶ(RAW_SAMPLE_DIR のときだけ)。
/// サンプルのフォルダにサイドカーを書かないよう、写したものを使う
final class RawgenzoToolsSampleTests: XCTestCase {
    private var folder: URL!
    private var surface: Surface!
    private var workspace: RawgenzoWorkspace!
    private var id = ""
    private var id2 = ""
    private let ai = Caller.agent("test")

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        // 値を確かめている写真(DSC03356。露出補正 +0.3、真ん中に花)を先に使う。サンプルを足して名前順の先頭が変わっても同じ写真で試す
        let all = try RAWEngine().listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let samples = all.filter { $0.lastPathComponent == "DSC03356.ARW" } + all.filter { $0.lastPathComponent != "DSC03356.ARW" }
        guard samples.count >= 2 else { throw XCTSkip("サンプルが 2 枚以上必要") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rawgenzo-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // コピーせずシンボリックリンクにする(AItrial と同じ形。サイドカーはリンクの隣に書かれる)
        for source in samples.prefix(2) {
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(source.lastPathComponent),
                                                       withDestinationURL: source)
        }
        id = samples[0].lastPathComponent
        id2 = samples[1].lastPathComponent
        workspace = RawgenzoWorkspace(folder: folder)
        surface = RawgenzoTools.makeSurface(workspace: workspace)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func json(_ r: ToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        XCTAssertFalse(r.isError, r.summary, file: file, line: line)
        for c in r.content { if case .json(let v) = c { return v } }
        throw XCTSkip("JSON が返らない")
    }

    private var sidecar: URL { folder.appendingPathComponent(id).appendingPathExtension("rawgenzo.json") }

    func testListAndGetPhoto() throws {
        let list = try json(surface.call("list_photos", as: ai))
        XCTAssertEqual(list["total"], 2)
        let listed = list["photos"]?.arrayValue?.first { $0["photo"] == .string(id) }
        XCTAssertNotNil(listed)
        XCTAssertEqual(listed?["edited"], false)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["iso_min": 10_000_000], as: ai))["total"], 0)

        let state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["exposure"], 0)
        XCTAssertEqual(state["adjustments"]?["temperature"], state["as_shot"]?["temperature"])
        XCTAssertTrue(state["follows_baseline"]?.arrayValue?.contains("temperature") == true)
        XCTAssertEqual(state["crop"], .null)
        // 撮影情報の残り(DSC03356 は ExifTool で 露出補正 +0.3・絞り優先)
        XCTAssertEqual(state["exposure_mode"], "絞り優先")
        XCTAssertEqual(try XCTUnwrap(state["exposure_bias"]?.doubleValue), 0.3, accuracy: 0.01)
        let full = try json(surface.call("get_stats", arguments: ["photo": .string(id), "detail": "full"], as: ai))
        XCTAssertEqual(full["rgb_histograms"]?.arrayValue?.count, 3)
        XCTAssertEqual(full["rgb_histograms"]?.arrayValue?.first?.arrayValue?.count, ImageStats.histogramBins)
        // サンプル(DSC03356)は撮影時のフォーカス位置が真ん中(ExifTool で 4240 2832 2120 1416)
        if let f = state["focus_point"]?.arrayValue?.compactMap(\.doubleValue), f.count == 2 {
            XCTAssertEqual(f[0], 0.5, accuracy: 0.01); XCTAssertEqual(f[1], 0.5, accuracy: 0.01)
        }
    }

    /// adjust → サイドカーに保存、統計が付く → undo でサイドカーが無い状態に戻る
    func testAdjustSavesAndUndoRestores() throws {
        let before = try json(surface.call("get_stats", arguments: ["photo": .string(id)], as: ai))
        let r = try json(surface.call("adjust", arguments: [
            "edits": [["photos": [.string(id)], "changes": ["exposure": 1, "saturation": 1.2]]],
        ], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["changed"]?["exposure"]?["to"], 1)
        XCTAssertEqual(r["results"]?.arrayValue?.first?["changed"]?["exposure"]?["from"], 0)
        let after = try XCTUnwrap(r["stats"]?[id]?["mean_luminance"]?.doubleValue)
        XCTAssertGreaterThan(after, try XCTUnwrap(before["mean_luminance"]?.doubleValue))

        let saved = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id)))
        XCTAssertEqual(saved.settings.exposure, 1)
        XCTAssertEqual(saved.settings.saturation, 1.2)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["edited": true], as: ai))["total"], 1)
        XCTAssertEqual(r["results"]?.arrayValue?.count, 1, "変えていない写真は結果に出ない")

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "サイドカーが無かった写真は無い状態に戻る")
        let state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["exposure"], 0)
    }

    /// サイドカーがあった写真の undo は、前の設定を書き戻す。null は基準値に戻す
    func testUndoRestoresPreviousSidecarAndNullResets() throws {
        _ = try json(surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["temperature": 4000]]],
                                                        "observe": false], as: ai))
        _ = try json(surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["temperature": nil]]],
                                                        "observe": false], as: ai))
        var state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["temperature"], state["as_shot"]?["temperature"])
        XCTAssertFalse(surface.call("undo", as: ai).isError)
        state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["temperature"], 4000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// 範囲外・未知の項目は実行前に拒否され、何も書かない
    func testInvalidChangesAreRejected() throws {
        let r1 = surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["exposure": 9]]]], as: ai)
        XCTAssertTrue(r1.isError)
        XCTAssertTrue(r1.summary.contains("$.edits[0].changes.exposure"), r1.summary)
        let r2 = surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["brightness": 1]]]], as: ai)
        XCTAssertTrue(r2.isError)
        let r3 = surface.call("adjust", arguments: ["edits": [["photos": [.string(id), "nope.ARW"], "changes": ["exposure": 1]]]], as: ai)
        XCTAssertTrue(r3.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "1 枚でも見つからなければ何も変えない")
    }

    /// 仮の変更での統計・縮小画像は保存しない
    func testTrialChangesAreNotSaved() throws {
        let base = try json(surface.call("get_stats", arguments: ["photo": .string(id)], as: ai))
        let trial = try json(surface.call("get_stats", arguments: ["photo": .string(id), "changes": ["exposure": -1],
                                                                   "detail": "full"], as: ai))
        XCTAssertLessThan(try XCTUnwrap(trial["mean_luminance"]?.doubleValue), try XCTUnwrap(base["mean_luminance"]?.doubleValue))
        XCTAssertEqual(trial["grid_rgb"]?.arrayValue?.count, ImageStats.gridSize)
        XCTAssertEqual(trial["histogram"]?.arrayValue?.count, ImageStats.histogramBins)

        let preview = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 256], as: ai)
        XCTAssertFalse(preview.isError, preview.summary)
        guard case .image(let data, let mime)? = preview.content.first else { return XCTFail("画像が返らない") }
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let size = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        XCTAssertLessThanOrEqual(max(size[kCGImagePropertyPixelWidth] as! Int, size[kCGImagePropertyPixelHeight] as! Int), 256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// 写真ごとに違う変更を 1 回の呼び出しで当て、undo 1 回でまとめて戻る(試験で undo が 4 回要った問題の対策)
    func testPerPhotoEditsAreOneTransaction() throws {
        let r = try json(surface.call("adjust", arguments: ["edits": [
            ["photos": [.string(id)], "changes": ["exposure": 0.5]],
            ["photos": [.string(id2)], "changes": ["exposure": -0.5]],
            ["photos": [.string(id), .string(id2)], "changes": ["saturation": 1.1]],
        ]], as: ai))
        let results = try XCTUnwrap(r["results"]?.arrayValue)
        XCTAssertEqual(results.map { $0["photo"] }, [.string(id), .string(id2)])
        XCTAssertEqual(results[0]["changed"]?["exposure"]?["to"], 0.5)
        XCTAssertEqual(results[1]["changed"]?["exposure"]?["to"], -0.5)
        XCTAssertEqual(results[1]["changed"]?["saturation"]?["to"], 1.1)
        XCTAssertEqual(r["stats"]?.objectValue?.count, 2)

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["edited": true], as: ai))["total"], 0)
        XCTAssertTrue(surface.call("undo", as: ai).isError, "取引は 1 つだけ")
    }

    /// 目標だけ渡せば、写真ごとに違う露出で合わせ、1 つの取引で保存する
    func testSolveExposure() throws {
        let r = try json(surface.call("solve_exposure", arguments: [
            "photos": [.string(id), .string(id2)], "target_mean_luminance": 0.45, "max_highlight_clipping": 0.01,
        ], as: ai))
        let results = try XCTUnwrap(r["results"]?.arrayValue)
        XCTAssertEqual(results.count, 2)
        for row in results {
            XCTAssertEqual(row["met"]?["clipping"], true)
            XCTAssertLessThanOrEqual(try XCTUnwrap(row["stats"]?["highlight_clipping"]?.doubleValue), 0.01)
            if row["met"]?["luminance"] == true {
                XCTAssertEqual(try XCTUnwrap(row["stats"]?["mean_luminance"]?.doubleValue), 0.45, accuracy: 0.011)
            }
            // 結果の統計は get_stats と一致する(AI が後から確かめても同じ数字になる)
            let check = try json(surface.call("get_stats", arguments: ["photo": row["photo"]!], as: ai))
            XCTAssertEqual(check["mean_luminance"], row["stats"]?["mean_luminance"])
        }
        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["edited": true], as: ai))["total"], 0)
        XCTAssertTrue(surface.call("solve_exposure", arguments: ["photos": [.string(id)]], as: ai).isError, "目標が無い")
    }

    /// 白飛びの上限だけを渡したときは、今の平均輝度を保つ(試験で AI により明るさが変わったりしたため)
    func testClippingOnlyKeepsBrightness() throws {
        let before = try json(surface.call("get_stats", arguments: ["photo": .string(id2)], as: ai))
        let mean = try XCTUnwrap(before["mean_luminance"]?.doubleValue)
        let clip = try XCTUnwrap(before["highlight_clipping"]?.doubleValue)
        let limit = clip / 3
        let r = try json(surface.call("solve_exposure", arguments: [
            "photos": [.string(id2)], "max_highlight_clipping": .number(limit),
        ], as: ai))
        let row = try XCTUnwrap(r["results"]?.arrayValue?.first)
        XCTAssertEqual(row["kept_mean_luminance"]?.doubleValue, mean)
        XCTAssertEqual(row["met"]?["clipping"], true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(row["stats"]?["highlight_clipping"]?.doubleValue), limit)
        if row["met"]?["luminance"] == true {
            XCTAssertEqual(try XCTUnwrap(row["stats"]?["mean_luminance"]?.doubleValue), mean, accuracy: 0.011)
        }
    }

    /// deltas は今の値に足す。範囲を超えたら端に丸める。changes と一緒なら changes を先に当てる
    func testDeltas() throws {
        _ = try json(surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["exposure": 0.4]]],
                                                        "observe": false], as: ai))
        let r = try json(surface.call("adjust", arguments: ["edits": [
            ["photos": [.string(id)], "deltas": ["exposure": 0.3, "saturation": 1.5]],
            ["photos": [.string(id2)], "changes": ["exposure": 1], "deltas": ["exposure": -0.25]],
        ], "observe": false], as: ai))
        let rows = try XCTUnwrap(r["results"]?.arrayValue)
        XCTAssertEqual(rows[0]["changed"]?["exposure"]?["to"], 0.7)
        XCTAssertEqual(rows[0]["changed"]?["saturation"]?["to"], 2, "範囲の端(2)に丸める")
        XCTAssertEqual(rows[1]["changed"]?["exposure"]?["to"], 0.75)
        XCTAssertTrue(surface.call("adjust", arguments: ["edits": [["photos": [.string(id)]]]], as: ai).isError,
                      "changes も deltas も無い")
    }

    /// 作業フォルダの外の写真は絶対パスで指せる。サイドカーはその写真の隣に書き、undo で戻る
    func testPhotoInAnotherFolderByAbsolutePath() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("rawgenzo-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let source = try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(id).path)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent(id), withDestinationURL: URL(fileURLWithPath: source))
        let path = other.appendingPathComponent(id).standardizedFileURL.path

        let list = try json(surface.call("list_photos", arguments: ["folder": .string(other.path)], as: ai))
        XCTAssertEqual(list["total"], 1)
        XCTAssertEqual(list["photos"]?.arrayValue?.first?["photo"], .string(path), "作業フォルダの外は絶対パスの ID")
        XCTAssertTrue(surface.call("list_photos", arguments: ["folder": "/no/such/folder"], as: ai).isError)

        let r = try json(surface.call("adjust", arguments: ["edits": [["photos": [.string(path)], "changes": ["exposure": 0.5]]],
                                                            "observe": false], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["photo"], .string(path))
        XCTAssertEqual(SidecarStore().load(for: other.appendingPathComponent(id))?.settings.exposure, 0.5)
        XCTAssertNil(SidecarStore().load(for: folder.appendingPathComponent(id)), "作業フォルダの同名の写真には書かない")
        XCTAssertEqual(try json(surface.call("get_photo", arguments: ["photo": .string(path)], as: ai))["photo"], .string(path))

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertNil(SidecarStore().load(for: other.appendingPathComponent(id)))
    }

    /// 作業フォルダの写真は、絶対パスで指してもファイル名の ID にそろえる(同じ写真を 2 枚と数えない)
    func testAbsolutePathInsideWorkspaceIsCanonicalized() throws {
        let path = folder.appendingPathComponent(id).path
        let r = try json(surface.call("adjust", arguments: ["edits": [
            ["photos": [.string(id), .string(path)], "deltas": ["exposure": 0.25]],
        ], "observe": false], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.count, 1)
        XCTAssertEqual(r["results"]?.arrayValue?.first?["photo"], .string(id))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["changed"]?["exposure"]?["to"], 0.25, "1 回だけ足す")
    }

    /// set_crop: 枠を保存し、切り抜く前の全体を get_preview で見られ、undo で無しに戻る
    func testSetCrop() throws {
        let r = try json(surface.call("set_crop", arguments: [
            "photos": [.string(id)], "x": 0.1, "y": 0.2, "width": 0.6, "height": 0.7,
        ], as: ai))
        let row = try XCTUnwrap(r["results"]?.arrayValue?.first)
        XCTAssertEqual(row["crop"]?["from"], .null)
        XCTAssertEqual(row["crop"]?["to"]?["width"], 0.6)
        let saved = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)
        XCTAssertEqual(saved.x, 0.1); XCTAssertEqual(saved.height, 0.7)

        func previewSize(_ args: JSONValue) throws -> (Double, Double) {
            let p = surface.call("get_preview", arguments: args, as: ai)
            XCTAssertFalse(p.isError, p.summary)
            for c in p.content {
                if case .text(let t) = c {
                    let n = t.split(separator: "×").compactMap { Double($0) }
                    if n.count == 2 { return (n[0], n[1]) }
                }
            }
            throw XCTSkip("大きさが返らない")
        }
        let photoState = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        let size = try XCTUnwrap(photoState["size"]?.arrayValue?.compactMap(\.doubleValue))
        let cropped = try previewSize(["photo": .string(id), "long_edge": 600])
        XCTAssertEqual(cropped.0 / cropped.1, size[0] * 0.6 / (size[1] * 0.7), accuracy: 0.02)
        let whole = try previewSize(["photo": .string(id), "long_edge": 600, "ignore_crop": true])
        XCTAssertEqual(whole.0 / whole.1, size[0] / size[1], accuracy: 0.02, "切り抜く前の全体")

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        // 下端がちょうど 1 の枠: 小数の誤差で「縮めた」と注記しない(試験で付いた)
        let edge = try json(surface.call("set_crop", arguments: [
            "photos": [.string(id)], "x": 0.054, "y": 0.19, "width": 0.728, "height": 0.81,
        ], as: ai))
        XCTAssertNil(edge["results"]?.arrayValue?.first?["notes"], "\(edge)")
    }

    /// set_look: 当てる → 強さを足す → 外す。undo で戻る。誤りは何も変えずに断る
    func testSetLook() throws {
        let looks = try json(surface.call("list_looks", as: ai))["looks"]?.arrayValue ?? []
        XCTAssertTrue(looks.contains { $0["id"] == "builtin.cinema" && $0["summary"]?.stringValue != nil })

        var r = try json(surface.call("set_look", arguments: ["photos": [.string(id)], "look": "builtin.cinema",
                                                              "strength": 0.6], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["look"]?["to"]?["name"], "シネマ風")
        XCTAssertEqual(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.look,
                       LookSelection(id: "builtin.cinema", strength: 0.6))

        r = try json(surface.call("set_look", arguments: ["photos": [.string(id)], "strength_delta": -0.2], as: ai))
        XCTAssertEqual(try XCTUnwrap(r["results"]?.arrayValue?.first?["look"]?["to"]?["strength"]?.doubleValue), 0.4, accuracy: 1e-9)
        // ルックを替えても強さは保つ
        _ = try json(surface.call("set_look", arguments: ["photos": [.string(id)], "look": "builtin.film"], as: ai))
        XCTAssertEqual(try workspace.photo(id).settings.look?.strength ?? 0, 0.4, accuracy: 1e-9)

        _ = try json(surface.call("set_look", arguments: ["photos": [.string(id)], "look": nil], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.look)

        for bad: JSONValue in [
            ["photos": [.string(id)]],
            ["photos": [.string(id)], "look": "builtin.nothing"],
            ["photos": [.string(id)], "strength": 0.5],                              // ルックが無い写真の強さ
            ["photos": [.string(id)], "look": nil, "strength": 0.5],
            ["photos": [.string(id)], "look": "builtin.mono", "strength": 0.5, "strength_delta": 0.1],
        ] {
            XCTAssertTrue(surface.call("set_look", arguments: bad, as: ai).isError, "\(bad)")
        }
        // 1 枚でも断れば、ほかの写真も変えない
        _ = try json(surface.call("set_look", arguments: ["photos": [.string(id2)], "look": "builtin.mono"], as: ai))
        XCTAssertTrue(surface.call("set_look", arguments: ["photos": [.string(id2), .string(id)], "strength": 0.3], as: ai).isError)
        XCTAssertEqual(try workspace.photo(id2).settings.look?.strength, 1)

        // 取り消し: 外す → 付け直す…と順に戻る(作業名が無いので 1 回ずつ)
        for _ in 0..<5 { XCTAssertFalse(surface.call("undo", as: ai).isError) }
        XCTAssertNil(try workspace.photo(id).settings.look)
        XCTAssertNil(try workspace.photo(id2).settings.look)
    }

    /// set_lens_correction: 渡した項目だけを変え(ほかは今掛かっている補正のまま)、follow_camera でカメラ設定に戻す
    func testSetLensCorrection() throws {
        let start = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))["lens_correction"]
        guard start?["available"] == true else { throw XCTSkip("サンプルのレンズに補正情報が無い") }
        XCTAssertEqual(start?["follows_camera"], true)
        let camera = try XCTUnwrap(workspace.photo(id).effectiveLensSettings(DevelopSettings()))

        let r = try json(surface.call("set_lens_correction", arguments: ["photos": [.string(id)],
                                                                        "distortion": .bool(!camera.distortion)], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["lens_correction"]?["to"]?["follows_camera"], false)
        var expected = camera
        expected.distortion.toggle()
        XCTAssertEqual(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.lens, expected, "ほかの項目はカメラ設定のまま")

        _ = try json(surface.call("set_lens_correction", arguments: ["photos": [.string(id)], "follow_camera": true], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.lens)
        XCTAssertTrue(surface.call("set_lens_correction", arguments: ["photos": [.string(id)]], as: ai).isError)
        XCTAssertTrue(surface.call("set_lens_correction", arguments: ["photos": [.string(id)], "follow_camera": true,
                                                                     "vignetting": false], as: ai).isError)
        for _ in 0..<2 { XCTAssertFalse(surface.call("undo", as: ai).isError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testSetHDROutput() throws {
        let r = try json(surface.call("set_hdr_output", arguments: ["photos": [.string(id)], "enabled": true], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["hdr_output"]?["to"], true)
        XCTAssertEqual(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.hdr.extendedOutput, true)
        XCTAssertEqual(try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))["hdr_output"], true)
        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// 色別補正も取り消しの対象(SettingsFields に入っていないと、初期値に戻した後の undo で戻らない)
    func testUndoRestoresColorAdjust() throws {
        let photo = try workspace.photo(id)
        var s = photo.settings
        s.colorAdjust = ColorAdjustSettings(bands: [.blue: ColorBandAdjust(saturation: 30)])
        try workspace.save(photo, settings: s)
        _ = try json(surface.call("reset_settings", arguments: ["photos": [.string(id)]], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.colorAdjust)
        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.bands[.blue]?.saturation, 30)
    }

    /// reset_settings: 全部を初期値に戻す。keep に挙げたものは残す。undo で戻る
    func testResetSettings() throws {
        _ = try json(surface.call("adjust", arguments: ["edits": [["photos": [.string(id)], "changes": ["exposure": 1, "temperature": 4000]]],
                                                        "observe": false], as: ai))
        _ = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "aspect": "square"], as: ai))
        _ = try json(surface.call("set_look", arguments: ["photos": [.string(id)], "look": "builtin.film"], as: ai))
        let edited = try workspace.photo(id).settings

        let r = try json(surface.call("reset_settings", arguments: ["photos": [.string(id)], "keep": ["crop"]], as: ai))
        let reset = r["results"]?.arrayValue?.first?["reset"]?.arrayValue ?? []
        XCTAssertTrue(reset.contains("exposure") && reset.contains("look") && !reset.contains("crop"), "\(reset)")
        var s = try workspace.photo(id).settings
        XCTAssertEqual(s.exposure, 0)
        XCTAssertNil(s.temperature)
        XCTAssertNil(s.look)
        XCTAssertEqual(s.crop, edited.crop)

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        s = try workspace.photo(id).settings
        XCTAssertEqual(s, edited)
        let again = try json(surface.call("reset_settings", arguments: ["photos": [.string(id2)]], as: ai))
        XCTAssertNotNil(again["results"]?.arrayValue?.first?["notes"], "もともと初期値")
    }

    /// estimate_tilt: 番号付きの線と画像を返し、選んだ番号から角度を出す。読むだけで保存しない
    func testEstimateTilt() throws {
        let r = surface.call("estimate_tilt", arguments: ["photo": .string(id), "long_edge": 512], as: ai)
        let o = try json(r)
        XCTAssertTrue(r.content.contains { if case .image = $0 { return true } else { return false } }, "番号を描いた画像が付く")
        let segments = try XCTUnwrap(o["segments"]?.arrayValue)
        guard let first = segments.first, let angle = first["angle"]?.doubleValue else { throw XCTSkip("このサンプルに長い直線が無い") }
        XCTAssertEqual(first["id"], 1)
        XCTAssertLessThanOrEqual(abs(angle), TiltEstimator.searchRange)

        let picked = try json(surface.call("estimate_tilt", arguments: ["photo": .string(id), "segments": [1, 99], "image": false], as: ai))
        XCTAssertEqual(try XCTUnwrap(picked["chosen"]?["segments"]?["angle"]?.doubleValue), angle, accuracy: 0.01, "1 本だけならその線の角度")
        XCTAssertTrue(picked["notes"]?.arrayValue?.contains { $0.stringValue?.contains("99") == true } == true, "\(picked)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "読むだけ")
    }

    /// get_preview の region・show_crop_frame・guide
    func testPreviewRegionFrameAndGuide() throws {
        func texts(_ r: ToolResult) -> [String] { r.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }
        func size(_ r: ToolResult) throws -> (Double, Double) {
            XCTAssertFalse(r.isError, r.summary)
            let n = try XCTUnwrap(texts(r).first).split(separator: "×").compactMap { Double($0) }
            return (n[0], n[1])
        }
        let photoSize = try XCTUnwrap(try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))["size"]?
            .arrayValue?.compactMap(\.doubleValue))
        // 5% 四方の小さな範囲は、等倍を上限にする(拡大しない)
        let tiny = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 1600,
                                                           "region": ["x": 0.4, "y": 0.4, "width": 0.05, "height": 0.05]], as: ai)
        let t = try size(tiny)
        XCTAssertEqual(t.0, (photoSize[0] * 0.05).rounded(), accuracy: 2)
        XCTAssertTrue(texts(tiny).contains("等倍の 1.00 倍"), "\(texts(tiny))")
        // 範囲の縦横比で返る
        let half = try size(surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 400,
                                                                    "region": ["x": 0, "y": 0, "width": 0.5, "height": 0.25]], as: ai))
        XCTAssertEqual(half.0 / half.1, photoSize[0] * 0.5 / (photoSize[1] * 0.25), accuracy: 0.02)

        // 枠を描く: 切り抜く前の全体の大きさで返り、枠を描かない全体とは画像が違う
        _ = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "x": 0.2, "y": 0.2, "width": 0.5, "height": 0.5], as: ai))
        let framed = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 300, "show_crop_frame": true,
                                                             "guide": "thirds"], as: ai)
        let whole = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 300, "ignore_crop": true], as: ai)
        XCTAssertEqual(try size(framed).0 / size(framed).1, photoSize[0] / photoSize[1], accuracy: 0.02)
        XCTAssertNotEqual(framed.content.first, whole.content.first)

        for bad: JSONValue in [
            ["photo": .string(id), "region": ["x": 0.6, "y": 0, "width": 0.5, "height": 0.5]],
            ["photo": .string(id), "region": ["x": 0.4, "y": 0.4, "width": 0.01, "height": 0.01]],   // 5% 未満
            ["photo": .string(id), "region": ["x": 0, "y": 0, "width": 0.5, "height": 0.5], "guide": "thirds"],
            ["photo": .string(id), "guide": "nothing"],
        ] {
            XCTAssertTrue(surface.call("get_preview", arguments: bad, as: ai).isError, "\(bad)")
        }
    }

    /// adjust_colors: 帯の値を指定・足す・戻す。undo で戻る
    func testAdjustColors() throws {
        var r = try json(surface.call("adjust_colors", arguments: ["photos": [.string(id)], "edits": [
            ["band": "blue", "saturation": 30], ["band": "red", "hue": 10, "luminance": -5],
        ]], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["color_adjust"]?["bands"]?["blue"]?["saturation"], 30)
        r = try json(surface.call("adjust_colors", arguments: ["photos": [.string(id)], "edits": [
            ["band": "blue", "saturation": 90, "relative": true],
        ]], as: ai))
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.bands[.blue]?.saturation, 100, "足して上限で丸める")
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.bands[.red]?.hue, 10, "書いていない帯は変えない")
        _ = try json(surface.call("adjust_colors", arguments: ["photos": [.string(id)], "reset": true], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.colorAdjust, "全部 0 なら項目ごと消す")
        XCTAssertTrue(surface.call("adjust_colors", arguments: ["photos": [.string(id)]], as: ai).isError)
        for _ in 0..<3 { XCTAssertFalse(surface.call("undo", as: ai).isError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// set_tone_curve: 形・点・彩度の連動を指定し、書いていないチャンネルは保つ。undo で戻る
    func testSetToneCurve() throws {
        var r = try json(surface.call("set_tone_curve", arguments: ["photos": [.string(id)], "preset": "medium"], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["tone_curve"]?["preset"], "medium")
        r = try json(surface.call("set_tone_curve", arguments: ["photos": [.string(id)], "curves": [
            ["channel": "blue", "points": [[0, 20], [128, 120]]],
        ], "saturation_link": 40], as: ai))
        let c = try XCTUnwrap(workspace.photo(id).settings.toneCurve)
        XCTAssertEqual(c.luma, ToneCurvePreset.medium.points, "書いていないチャンネルは保つ")
        XCTAssertEqual(c.blue.count, 3, "255 の端を補う")
        XCTAssertEqual(c.blue[0].y, 20.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.saturationLink, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r["results"]?.arrayValue?.first?["tone_curve"]?["blue"]?.arrayValue?.count, 3)
        XCTAssertTrue(surface.call("set_tone_curve", arguments: ["photos": [.string(id)]], as: ai).isError)
        XCTAssertTrue(surface.call("set_tone_curve", arguments: ["photos": [.string(id)], "preset": "weak",
                                                                  "curves": [["channel": "luma", "points": [[0, 0], [255, 255]]]]],
                                   as: ai).isError)
        _ = try json(surface.call("set_tone_curve", arguments: ["photos": [.string(id)], "reset": true], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.toneCurve, "全部戻したら項目ごと消す")
        for _ in 0..<3 { XCTAssertFalse(surface.call("undo", as: ai).isError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// set_color_point: 位置で拾い、範囲を決め、目標の濃さに合わせる。効く場所を get_preview で見られる
    func testSetColorPoint() throws {
        // DSC03356(ランタナの花)の真ん中の花を変え、左の葉は変えない
        let r = surface.call("set_color_point", arguments: [
            "photo": .string(id), "action": "add", "name": "花",
            "at": [["x": 0.48, "y": 0.52], ["x": 0.52, "y": 0.56]], "exclude_at": [["x": 0.08, "y": 0.45]],
            "target_chroma": 60,
        ], as: ai)
        if r.isError, r.summary.contains("色がほとんど無い") { throw XCTSkip("このサンプルの真ん中に色が無い: \(r.summary)") }
        let o = try json(r)
        XCTAssertEqual(o["point"]?["index"], 0)
        XCTAssertEqual(o["point_count"], 1)
        let coverage = try XCTUnwrap(o["coverage"]?.doubleValue)
        XCTAssertGreaterThan(coverage, 0); XCTAssertLessThan(coverage, 1)
        let chroma = try XCTUnwrap(o["chroma_of_at"]?.arrayValue?.compactMap(\.doubleValue))
        XCTAssertEqual(chroma.count, 2)
        if o["target"]?["met"] == true { XCTAssertEqual(chroma[1], 60, accuracy: 1.5) }
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.points.first?.name, "花")
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.points.first?.samples.count, 2, "拾った色を保存する")

        // 「もう少し濃く」: 位置を渡さずに目標の濃さだけを上げても、最初と同じ色で測るので強さは下がらない
        // (2026-10-30 の試験で、範囲の中心の色で測って 59 → 56 に下がった)
        let firstAdd = try XCTUnwrap(o["point"]?["add_color"]?.doubleValue)
        let stronger = try json(surface.call("set_color_point", arguments: ["photo": .string(id), "action": "update", "index": 0,
                                                                            "target_chroma": .number(min(100, chroma[1] + 8))], as: ai))
        let secondAdd = try XCTUnwrap(stronger["point"]?["add_color"]?.doubleValue)
        XCTAssertGreaterThanOrEqual(secondAdd, firstAdd, "\(stronger)")
        let after = try XCTUnwrap(stronger["chroma_of_at"]?.arrayValue?.compactMap(\.doubleValue))
        XCTAssertGreaterThan(after[1], chroma[1], "濃くなる")
        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertNotNil(try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))["color_adjust"]?["points"])

        let mask = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 256, "color_mask": ["point": 0], "grid": true], as: ai)
        XCTAssertFalse(mask.isError, mask.summary)
        XCTAssertTrue(surface.call("get_preview", arguments: ["photo": .string(id), "color_mask": ["point": 5]], as: ai).isError)
        // 目盛りは切り抜いた後の画像の座標なので、切り抜く前の全体には描かない(読んだ位置が別の画素を指すため)
        XCTAssertTrue(surface.call("get_preview", arguments: ["photo": .string(id), "grid": true, "ignore_crop": true], as: ai).isError)

        let u = try json(surface.call("set_color_point", arguments: ["photo": .string(id), "action": "update", "index": 0,
                                                                     "add_color": 10, "add_hue": 350], as: ai))
        XCTAssertEqual(u["point"]?["add_color"], 10)
        XCTAssertEqual(try workspace.photo(id).settings.colorAdjust?.points.first?.addHue, 350)
        _ = try json(surface.call("set_color_point", arguments: ["photo": .string(id), "action": "update", "index": 0,
                                                                 "add_hue": nil], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.colorAdjust?.points.first?.addHue, "null で拾った色に戻す")
        XCTAssertTrue(surface.call("set_color_point", arguments: ["photo": .string(id), "action": "remove", "index": 3], as: ai).isError)
        _ = try json(surface.call("set_color_point", arguments: ["photo": .string(id), "action": "remove", "index": 0], as: ai))
        XCTAssertNil(try workspace.photo(id).settings.colorAdjust)
        for _ in 0..<4 { XCTAssertFalse(surface.call("undo", as: ai).isError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// get_preview の look は仮に当てるだけで、保存しない
    func testTrialLookIsNotSaved() throws {
        let plain = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 256], as: ai)
        let mono = surface.call("get_preview", arguments: ["photo": .string(id), "long_edge": 256,
                                                           "look": ["id": "builtin.mono"]], as: ai)
        XCTAssertFalse(mono.isError, mono.summary)
        XCTAssertNotEqual(plain.content.first, mono.content.first, "ルックが当たった画像になる")
        XCTAssertNil(try workspace.photo(id).settings.look)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(surface.call("get_preview", arguments: ["photo": .string(id), "look": ["id": "x"]], as: ai).isError)
    }

    /// set_crop の比率・傾き・解除と、入力の誤り
    func testSetCropAspectAngleAndReset() throws {
        // 枠と比率: 中心を保って縮める
        var r = try json(surface.call("set_crop", arguments: [
            "photos": [.string(id)], "x": 0, "y": 0, "width": 1, "height": 1, "aspect": "square",
        ], as: ai))
        var c = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)
        let aspect = try workspace.photo(id).imageAspect
        XCTAssertEqual(c.width * aspect / c.height, 1, accuracy: 1e-6)
        XCTAssertEqual(c.x + c.width / 2, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.aspect, .square)
        XCTAssertNotNil(r["results"]?.arrayValue?.first?["notes"])

        // 傾きだけ: 今の枠のまま傾け、はみ出すなら縮める
        r = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "angle": 10], as: ai))
        c = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)
        XCTAssertEqual(c.angle, 10)
        XCTAssertTrue(c.isInsideImage(imageAspect: aspect))

        // 傾きを小さくしても枠は広がらない。maximize で、収まる最大まで戻す(アプリのボタンと同じ計算)
        let shrunkAt10 = c
        r = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "angle": 2], as: ai))
        c = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)
        XCTAssertEqual(c.width, shrunkAt10.width, accuracy: 1e-9, "自動では広げない")
        r = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "maximize": true], as: ai))
        c = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)
        let expected = CropSettings(x: shrunkAt10.x, y: shrunkAt10.y, width: shrunkAt10.width, height: shrunkAt10.height,
                                    angle: 2, aspect: shrunkAt10.aspect).maximized(imageAspect: aspect)
        XCTAssertEqual(c.width, expected.width, accuracy: 1e-9)
        XCTAssertGreaterThan(c.width, shrunkAt10.width)
        XCTAssertTrue(c.isInsideImage(imageAspect: aspect))
        XCTAssertEqual(c.width * aspect / c.height, 1, accuracy: 1e-6, "比率(1:1)を保つ")
        XCTAssertTrue(surface.call("set_crop", arguments: ["photos": [.string(id)], "maximize": true,
                                                           "x": 0, "y": 0, "width": 0.5, "height": 0.5], as: ai).isError)

        // 解除
        r = try json(surface.call("set_crop", arguments: ["photos": [.string(id)], "reset": true], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["crop"]?["to"], .null)
        XCTAssertNil(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.crop)

        for bad: JSONValue in [
            ["photos": [.string(id)]],
            ["photos": [.string(id)], "x": 0.1, "y": 0.1],
            ["photos": [.string(id)], "x": 0.5, "y": 0, "width": 0.6, "height": 0.5],
            ["photos": [.string(id)], "reset": true, "angle": 1],
            ["photos": [.string(id)], "aspect": "5:4"],
        ] {
            XCTAssertTrue(surface.call("set_crop", arguments: bad, as: ai).isError, "\(bad)")
        }
    }
}

final class RawgenzoToolsSizeTests: XCTestCase {
    /// 項目の説明は adjust にだけ載せる(道具の一覧は会話のたびに送られるので重複させない)
    func testParameterSummariesAppearOnlyOnce() {
        let ws = RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory)
        let list = JSONValue.array(RawgenzoTools.makeSurface(workspace: ws).descriptors.map { $0.input.toJSON() }).jsonString()
        for p in ParameterCatalog.all {
            XCTAssertEqual(list.components(separatedBy: p.summary).count - 1, 1, p.id)
        }
    }
}

/// アプリとの橋渡し: ソケット経由で操作し、アプリで開いている写真には編集中の設定として反映する(RAW_SAMPLE_DIR のときだけ)
final class RawgenzoAgentHostTests: XCTestCase {
    /// アプリの編集画面の代わり。1 枚だけ開いている
    final class FakeEditor: LiveEditing {
        var openURL: URL?
        var settings = DevelopSettings()
        var applied: [(DevelopSettings, ChangeOrigin?)] = []
        func liveSettings(for url: URL) -> DevelopSettings? { url == openURL ? settings : nil }
        var folderShown: URL?
        func viewState() -> AppViewState {
            AppViewState(folder: folderShown, openPhoto: openURL, zoom: 1, fitsWindow: false, isCropping: false)
        }
        func applyLive(_ s: DevelopSettings, for url: URL, origin: ChangeOrigin?) -> Bool {
            guard url == openURL else { return false }
            settings = s
            applied.append((s, origin))
            return true
        }
    }

    private var folder: URL!
    private var host: RawgenzoAgentHost!
    private let editor = FakeEditor()
    private var ids: [String] = []

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let samples = try RAWEngine().listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        guard samples.count >= 2 else { throw XCTSkip("サンプルが 2 枚以上必要") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rg-host-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for s in samples.prefix(2) {
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(s.lastPathComponent), withDestinationURL: s)
        }
        ids = samples.prefix(2).map(\.lastPathComponent)
        editor.openURL = folder.appendingPathComponent(ids[0]).standardizedFileURL
        // ソケットのパスは 104 バイトまでなので短くする
        host = RawgenzoAgentHost(socketPath: "/tmp/rg-\(UUID().uuidString.prefix(8)).sock")
        host.live = editor
        try host.start()
    }

    override func tearDownWithError() throws {
        host?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// 行を送り、返事を count 行受け取る
    private func exchange(_ lines: [String], replies count: Int) throws -> [JSONValue] {
        let fd = try XCTUnwrap(UnixSocketBridge.connect(path: host.socketPath))
        defer { close(fd) }
        for l in lines { UnixSocketBridge.write(fd, l + "\n") }
        var out: [JSONValue] = []
        if count > 0 {
            UnixSocketBridge.readLines(fd) { line in
                if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) { out.append(v) }
                return out.count < count
            }
        }
        return out
    }

    private func call(_ id: Int, _ tool: String, _ args: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
                          "params": ["name": .string(tool), "arguments": args]]).jsonString()
    }

    /// 実際の rawdev mcp を起動し、標準入出力 → ソケット → アプリ(ここでは同じプロセスの host)と中継されること
    func testRawdevRelaysToHost() throws {
        let rawdev = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("rawdev")
        guard FileManager.default.isExecutableFile(atPath: rawdev.path) else { throw XCTSkip("rawdev が見つからない: \(rawdev.path)") }
        let p = Process()
        p.executableURL = rawdev
        p.arguments = ["mcp", folder.path]
        p.environment = ["RAWGENZO_AGENT_SOCKET": host.socketPath]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
        try p.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"relay"}}}"#,
            call(2, "adjust", ["edits": [["photos": [.string(ids[0])], "changes": ["vibrance": 0.3]]], "observe": false]),
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(err.contains("中継"), err)
        let replies = out.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(replies.count, 2, out)
        XCTAssertEqual(replies.last?["result"]?["isError"], false, out)
        XCTAssertEqual(editor.settings.vibrance, 0.3, "アプリ(host)の編集中の設定に届いた")
        XCTAssertEqual(editor.applied.last?.1?.caller, .agent("mcp:relay"))
    }

    /// アプリで開いている写真を ID で返す。作業フォルダの外の写真なら操作できないと知らせる
    func testAppStateReportsOpenPhoto() throws {
        editor.folderShown = folder
        func state() throws -> JSONValue {
            let r = try exchange([RawgenzoBridge.handshake(folder: folder),
                                  #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
                                  call(2, "get_app_state", [:])], replies: 2)
            let text = try XCTUnwrap(r[1]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        var s = try state()
        XCTAssertEqual(s["app_connected"], true)
        XCTAssertEqual(s["open_photo"], .string(ids[0]))
        XCTAssertEqual(s["folder_is_workspace"], true)
        XCTAssertEqual(s["zoom"], "100%")

        // 作業フォルダの外: 絶対パスの ID で返し、そのまま道具に渡せる
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("rg-other-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let source = try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(ids[1]).path)
        let outside = other.appendingPathComponent(ids[1]).standardizedFileURL
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: URL(fileURLWithPath: source))
        editor.folderShown = other
        editor.openURL = outside
        s = try state()
        XCTAssertEqual(s["open_photo"], .string(outside.path))
        XCTAssertEqual(s["folder_is_workspace"], false)
        XCTAssertEqual(s["app_folder"], .string(other.standardizedFileURL.path))

        let r = try exchange([RawgenzoBridge.handshake(folder: folder),
                              #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
                              call(2, "set_crop", ["photos": [.string(outside.path)], "x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5])],
                             replies: 2)
        XCTAssertEqual(r[1]["result"]?["isError"], false, "\(r)")
        XCTAssertEqual(editor.settings.crop?.width, 0.5, "アプリで開いている作業フォルダ外の写真に、その場で届く")
        XCTAssertEqual(SidecarStore().load(for: outside)?.settings.crop?.x, 0.1)
    }

    /// 1 枚の写真を指す呼び出しで、アプリで開いている写真と違えば結果で知らせる(「この写真」の取り違えに気づけるように)
    func testWarnsWhenTargetIsNotTheOpenPhoto() throws {
        func result(_ tool: String, _ args: JSONValue) throws -> JSONValue {
            let r = try exchange([RawgenzoBridge.handshake(folder: folder),
                                  #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
                                  call(2, tool, args)], replies: 2)
            let text = try XCTUnwrap(r[1]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        let other = try result("get_stats", ["photo": .string(ids[1])])
        XCTAssertTrue(other["open_photo_warning"]?.stringValue?.contains(ids[0]) == true, "\(other)")
        XCTAssertNil(try result("get_stats", ["photo": .string(ids[0])])["open_photo_warning"])
        let changed = try result("adjust", ["edits": [["photos": [.string(ids[1])], "changes": ["vibrance": 0.1]]], "observe": false])
        XCTAssertNotNil(changed["open_photo_warning"])
        let both = try result("adjust", ["edits": [["photos": [.string(ids[0]), .string(ids[1])], "changes": ["vibrance": 0.2]]],
                                         "observe": false])
        XCTAssertNil(both["open_photo_warning"], "複数の写真をまとめて扱うときは付けない")
    }

    func testRequiresHandshake() throws {
        let r = try exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], replies: 1)
        XCTAssertNotNil(r.first?["error"])
    }

    /// 開いている写真は編集中の設定にも反映し、開いていない写真はサイドカーだけ。人がアプリで変えた後は AI の取り消しを断る
    func testLiveApplyAndHumanConflict() throws {
        let hello = RawgenzoBridge.handshake(folder: folder)
        let r = try exchange([
            hello,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
            call(2, "adjust", ["edits": [["photos": [.string(ids[0]), .string(ids[1])], "changes": ["exposure": 0.5]]],
                               "observe": false, "task": "試し"]),
        ], replies: 2)
        XCTAssertEqual(r[1]["result"]?["isError"], false, r[1].jsonString())
        XCTAssertEqual(editor.settings.exposure, 0.5, "開いている写真の編集中の設定が変わる")
        XCTAssertEqual(editor.applied.count, 1, "開いていない写真には触らない")
        XCTAssertEqual(editor.applied.first?.1?.task, "試し")
        XCTAssertEqual(editor.applied.first?.1?.caller, .agent("mcp:t"))
        for id in ids {
            XCTAssertEqual(SidecarStore().load(for: folder.appendingPathComponent(id))?.settings.exposure, 0.5)
        }

        // 人がアプリで開いている写真を変えて保存した(と記録する)。AI の取り消しは断られる
        editor.settings.exposure = 1.0
        host.noteHumanChange(editor.openURL!)
        let undo = try exchange([hello, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
                                 call(3, "undo", [:])], replies: 2)
        XCTAssertEqual(undo[1]["result"]?["isError"], true)
        XCTAssertTrue(undo[1].jsonString().contains("rawgenzo-app"), undo[1].jsonString())
        XCTAssertTrue(undo[1].jsonString().contains("\(ids[0]) の設定"), "対象は写真の ID で示す")
        XCTAssertFalse(undo[1].jsonString().contains(folder.path), "パスは見せない")
        XCTAssertEqual(editor.settings.exposure, 1.0, "人の変更は消えない")
    }

    /// AI の読む設定は、まだ保存していない編集中の値(サイドカーではなく)
    func testReadsUnsavedLiveSettings() throws {
        editor.settings.saturation = 1.7
        let r = try exchange([
            RawgenzoBridge.handshake(folder: folder),
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"t"}}}"#,
            call(2, "get_photo", ["photo": .string(ids[0])]),
        ], replies: 2)
        let text = try XCTUnwrap(r[1]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let state = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(state["adjustments"]?["saturation"], 1.7)
    }
}

/// 取り消しが、操作面の履歴に載らない変更(別のプロセスの操作面、CLI、手作業)を消さないこと。
/// 同じフォルダに 2 つの作業場所・操作面を作り、アプリと rawdev の切り替えをまたいだ状況を再現する(RAW_SAMPLE_DIR のときだけ)
final class CrossProcessUndoTests: XCTestCase {
    private var folder: URL!
    private var rawdev: Surface!   // rawdev mcp が自分で処理するときの操作面
    private var app: Surface!      // アプリの中の操作面
    private var ids: [String] = []
    private let ai = Caller.agent("mcp:claude-code")

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let samples = try RAWEngine().listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        guard samples.count >= 2 else { throw XCTSkip("サンプルが 2 枚以上必要") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rg-cross-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for s in samples.prefix(2) {
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(s.lastPathComponent), withDestinationURL: s)
        }
        ids = samples.prefix(2).map(\.lastPathComponent)
        rawdev = RawgenzoTools.makeSurface(workspace: RawgenzoWorkspace(folder: folder))
        app = RawgenzoTools.makeSurface(workspace: RawgenzoWorkspace(folder: folder))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func adjust(_ s: Surface, _ photos: [String], _ changes: JSONValue, deltas: Bool = false) {
        let r = s.call("adjust", arguments: ["edits": [["photos": .array(photos.map { .string($0) }),
                                                        deltas ? "deltas" : "changes": changes]], "observe": false], as: ai)
        XCTAssertFalse(r.isError, r.summary)
    }

    private func saved(_ id: String) -> DevelopSettings? {
        SidecarStore().load(for: folder.appendingPathComponent(id))?.settings
    }

    /// バグレポートの再現手順: rawdev で露出 → アプリで彩度 → rawdev で undo。露出だけ戻り、彩度は残る
    func testUndoKeepsOtherProcessChangeToAnotherField() throws {
        adjust(rawdev, [ids[0]], ["exposure": 0.738])
        adjust(rawdev, [ids[0]], ["exposure": 0.5], deltas: true)           // 0.738 → 1.238
        adjust(app, [ids[0]], ["saturation": 0])
        let r = rawdev.call("undo", as: ai)
        XCTAssertFalse(r.isError, r.summary)
        let s = try XCTUnwrap(saved(ids[0]))
        XCTAssertEqual(s.exposure, 0.738, accuracy: 1e-9, "露出だけ戻る")
        XCTAssertEqual(s.saturation, 0, "アプリでの彩度の変更は残る")
    }

    /// 同じ項目を後から別の操作で変えていたら、取り消しを断り、何も変えない
    func testUndoRefusesWhenTheSameFieldWasChangedElsewhere() throws {
        adjust(rawdev, [ids[0]], ["exposure": 1])
        adjust(app, [ids[0]], ["exposure": -1])
        let r = rawdev.call("undo", as: ai)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.summary.contains("露出"), r.summary)
        XCTAssertTrue(r.summary.contains("\(ids[0])"), r.summary)
        XCTAssertEqual(saved(ids[0])?.exposure, -1, "アプリでの変更が残る")
        XCTAssertEqual(rawdev.undoCount(for: ai), 1, "取引は残る(状況が変われば取り消せる)")
    }

    /// 手作業でサイドカーを書き換えた場合も同じ(操作面をまったく通らない変更)
    func testUndoRefusesAfterManualSidecarEdit() throws {
        adjust(rawdev, [ids[0]], ["contrast": 0.5])
        let raw = folder.appendingPathComponent(ids[0])
        var record = try XCTUnwrap(SidecarStore().load(for: raw))
        record.settings.contrast = 0.2
        try SidecarStore().save(record, for: raw)
        XCTAssertTrue(rawdev.call("undo", as: ai).isError)
        XCTAssertEqual(saved(ids[0])?.contrast, 0.2)
    }

    /// サイドカーが無かった写真: 後から別の項目が書かれていれば、サイドカーは消さずに変えた項目だけ戻す
    func testUndoOfNewSidecarKeepsFileWhenOthersWrote() throws {
        let sidecar = folder.appendingPathComponent(ids[0]).appendingPathExtension("rawgenzo.json")
        adjust(rawdev, [ids[0]], ["exposure": 1])
        adjust(app, [ids[0]], ["vibrance": 0.4])
        XCTAssertFalse(rawdev.call("undo", as: ai).isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "アプリの変更が入ったサイドカーは消さない")
        XCTAssertEqual(saved(ids[0])?.exposure, 0)
        XCTAssertEqual(saved(ids[0])?.vibrance, 0.4)

        // 誰も他に書いていなければ、これまでどおりサイドカーを消して未編集に戻す
        adjust(rawdev, [ids[1]], ["exposure": 1])
        XCTAssertFalse(rawdev.call("undo", as: ai).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ids[1]).appendingPathExtension("rawgenzo.json").path))
    }

    /// 複数の写真をまとめて取り消すとき、1 枚でも断られたら 1 枚も変えない
    func testMultiPhotoUndoIsAllOrNothing() throws {
        adjust(rawdev, ids, ["exposure": 1])
        adjust(app, [ids[1]], ["exposure": 2])
        XCTAssertTrue(rawdev.call("undo", as: ai).isError)
        XCTAssertEqual(saved(ids[0])?.exposure, 1, "断られなかった方の写真も変えない")
        XCTAssertEqual(saved(ids[1])?.exposure, 2)
    }
}

final class AppStateWithoutAppTests: XCTestCase {
    /// アプリにつながっていない(rawdev が自分で処理する)ときは、分からないと返す
    func testWithoutApp() throws {
        let surface = RawgenzoTools.makeSurface(workspace: RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory))
        let r = surface.call("get_app_state", as: .agent("t"))
        XCTAssertFalse(r.isError)
        guard case .json(let v)? = r.content.first else { return XCTFail("JSON が返らない") }
        XCTAssertEqual(v["app_connected"], false)
        XCTAssertNotNil(v["note"])
    }
}
