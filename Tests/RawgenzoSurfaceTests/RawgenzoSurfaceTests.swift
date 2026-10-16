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
                       ["list_photos", "get_photo", "get_stats", "get_preview", "adjust", "undo", "recent_operations"])
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
    private let ai = Caller.agent("test")

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let samples = try RAWEngine().listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let source = try XCTUnwrap(samples.first)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rawgenzo-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        id = source.lastPathComponent
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
        XCTAssertEqual(list["total"], 1)
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
            "photos": [.string(id)], "changes": ["exposure": 1, "saturation": 1.2],
        ], as: ai))
        XCTAssertEqual(r["results"]?.arrayValue?.first?["changed"]?["exposure"]?["to"], 1)
        XCTAssertEqual(r["results"]?.arrayValue?.first?["changed"]?["exposure"]?["from"], 0)
        let after = try XCTUnwrap(r["stats"]?[id]?["mean_luminance"]?.doubleValue)
        XCTAssertGreaterThan(after, try XCTUnwrap(before["mean_luminance"]?.doubleValue))

        let saved = try XCTUnwrap(SidecarStore().load(for: folder.appendingPathComponent(id)))
        XCTAssertEqual(saved.settings.exposure, 1)
        XCTAssertEqual(saved.settings.saturation, 1.2)
        XCTAssertEqual(try json(surface.call("list_photos", arguments: ["edited": true], as: ai))["total"], 1)

        XCTAssertFalse(surface.call("undo", as: ai).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "サイドカーが無かった写真は無い状態に戻る")
        let state = try json(surface.call("get_photo", arguments: ["photo": .string(id)], as: ai))
        XCTAssertEqual(state["adjustments"]?["exposure"], 0)
    }

    /// サイドカーがあった写真の undo は、前の設定を書き戻す。null は基準値に戻す
    func testUndoRestoresPreviousSidecarAndNullResets() throws {
        _ = try json(surface.call("adjust", arguments: ["photos": [.string(id)], "changes": ["temperature": 4000],
                                                        "observe": false], as: ai))
        _ = try json(surface.call("adjust", arguments: ["photos": [.string(id)], "changes": ["temperature": nil],
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
        let r1 = surface.call("adjust", arguments: ["photos": [.string(id)], "changes": ["exposure": 9]], as: ai)
        XCTAssertTrue(r1.isError)
        XCTAssertTrue(r1.summary.contains("$.changes.exposure"), r1.summary)
        let r2 = surface.call("adjust", arguments: ["photos": [.string(id)], "changes": ["brightness": 1]], as: ai)
        XCTAssertTrue(r2.isError)
        let r3 = surface.call("adjust", arguments: ["photos": [.string(id), "nope.ARW"], "changes": ["exposure": 1]], as: ai)
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
}
