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

    func testToolsAreRegisteredInStableOrder() {
        let ws = RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory)
        let surface = RawgenzoTools.makeSurface(workspace: ws)
        XCTAssertEqual(surface.descriptors.map(\.name),
                       ["get_app_state", "list_photos", "get_photo", "get_stats", "get_preview", "adjust", "solve_exposure", "undo", "recent_operations"])
        XCTAssertEqual(surface.descriptors.first { $0.name == "adjust" }?.effect, .modify)
    }

    /// フォルダの外を指す ID は受け付けない
    func testIDsOutsideFolderAreRejected() {
        let ws = RawgenzoWorkspace(folder: FileManager.default.temporaryDirectory)
        for bad in ["../x.ARW", "a/b.ARW", "/etc/passwd", ".hidden.ARW", "..", "x.txt", ""] {
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
    private var id = ""
    private var id2 = ""
    private let ai = Caller.agent("test")

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let samples = try RAWEngine().listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
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
        surface = RawgenzoTools.makeSurface(workspace: RawgenzoWorkspace(folder: folder))
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
        XCTAssertEqual(list["photos"]?.arrayValue?.first?["photo"], .string(id))
        XCTAssertEqual(list["photos"]?.arrayValue?.first?["edited"], false)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["iso_min": 10_000_000], as: ai))["total"], 0)

        let state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["exposure"], 0)
        XCTAssertEqual(state["adjustments"]?["temperature"], state["as_shot"]?["temperature"])
        XCTAssertTrue(state["follows_baseline"]?.arrayValue?.contains("temperature") == true)
        XCTAssertEqual(state["crop"], .null)
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

        editor.folderShown = URL(fileURLWithPath: "/somewhere/else", isDirectory: true)
        editor.openURL = URL(fileURLWithPath: "/somewhere/else/DSC00001.ARW")
        s = try state()
        XCTAssertEqual(s["open_photo"], .null)
        XCTAssertEqual(s["open_photo_outside_workspace"], "DSC00001.ARW")
        XCTAssertEqual(s["app_folder"], "else")
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
