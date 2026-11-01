import XCTest
import CoreImage
@testable import RAWCore

final class ExportPreferencesTests: XCTestCase {
    func testDirectoryModes() {
        let raw = URL(fileURLWithPath: "/Photos/trip/DSC0001.ARW")
        var p = ExportPreferences()
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip/developed")
        p.subfolder = ""
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip")
        p.directoryMode = .fixed
        p.fixedDirectory = "/Exports"
        XCTAssertEqual(p.directory(for: raw).path, "/Exports")
        p.directoryMode = .lastUsed      // まだ前回が無ければRAWの横
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip")
    }

    func testConflictAddsNumber() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.jpg"))
        try Data().write(to: dir.appendingPathComponent("a-2.jpg"))
        let url = ExportPreferences.resolve(directory: dir, baseName: "a", fileExtension: "jpg", policy: .addNumber)
        XCTAssertEqual(url.lastPathComponent, "a-3.jpg")
        let over = ExportPreferences.resolve(directory: dir, baseName: "a", fileExtension: "jpg", policy: .overwrite)
        XCTAssertEqual(over.lastPathComponent, "a.jpg")
    }

    func testOldOrHandEditedConfigStillLoads() throws {
        let json = #"{"export": {"fileNameTemplate": "{date}_{name}", "directoryMode": "somethingNew"}, "other": 1}"#
        let c = try JSONDecoder().decode(SharedConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(c.export.fileNameTemplate, "{date}_{name}")
        XCTAssertEqual(c.export.directoryMode, .sameAsRAW)   // 未知の値は既定に戻す
        XCTAssertEqual(c.export.quality, 0.92)
    }
}
