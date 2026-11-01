import XCTest
import CoreImage
@testable import RAWCore

final class LookTests: XCTestCase {
    func testBuiltInLooksHaveUniqueIDs() {
        let ids = BuiltInLooks.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testIdentityCubeFileParses() throws {
        var text = "TITLE \"Identity\"\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
        let look = try CubeFileLook(text: text, id: "cube:test", fallbackName: "test")
        XCTAssertEqual(look.size, 2)
        XCTAssertEqual(look.displayName, "Identity")
    }

    func testUserLooksAreSortedByNameAfterBuiltIns() throws {
        func cube(_ title: String) throws -> CubeFileLook {
            var text = "TITLE \"\(title)\"\nLUT_3D_SIZE 2\n"
            for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
            return try CubeFileLook(text: text, id: "cube:\(title)", fallbackName: title)
        }
        let registry = LookRegistry(looks: BuiltInLooks.all)
        for title in ["08_Night", "02_Warm", "10_Extra", "01_Teal", "9_Nine", "b_lower", "A_upper"] {
            registry.register(try cube(title))
        }
        // 組み込みは元の順のまま先頭
        XCTAssertEqual(registry.all.prefix(BuiltInLooks.all.count).map(\.id), BuiltInLooks.all.map(\.id))
        // 数字は数値として比べる(08 < 9 < 10)、大文字小文字は区別しない
        XCTAssertEqual(registry.userLooks.map(\.displayName),
                       ["01_Teal", "02_Warm", "08_Night", "9_Nine", "10_Extra", "A_upper", "b_lower"])
    }

    func testCubeWithWrongCountFails() {
        let text = "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"
        XCTAssertThrowsError(try CubeFileLook(text: text, id: "x", fallbackName: "x"))
    }

    /// リポジトリ付属の LUT_examples がすべてルックとして読み込めること
    func testBundledLUTExamplesLoad() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LUT_examples", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "cube" }
        XCTAssertFalse(files.isEmpty, "LUT_examples に .cube がありません")

        let registry = LookRegistry(looks: BuiltInLooks.all)
        let failures = registry.loadCubeFiles(from: dir)
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
        XCTAssertEqual(registry.userLooks.count, files.count)
        XCTAssertTrue(registry.userLooks.allSatisfy { $0.id.hasPrefix("cube:") })
    }
}
