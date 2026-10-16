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
                       ["list_photos", "get_photo", "get_stats", "get_preview", "adjust", "solve_exposure", "undo", "recent_operations"])
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
