import XCTest
import CoreImage
@testable import RAWCore

/// 項目が欠けた・型が違う設定ファイルでも、読める項目は読む(1 つの項目のせいで写真の設定が全部消えないように)
final class TolerantDecodingTests: XCTestCase {
    private func settings(_ json: String) throws -> DevelopSettings {
        try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
    }

    func testPartialNestedSettings() throws {
        let s = try settings(#"{"exposure":0.5,"hdr":{"strength":0.4},"crop":{"x":0.1,"y":0.1,"width":0.8,"height":0.8},"look":{"id":"builtin.film"}}"#)
        XCTAssertEqual(s.exposure, 0.5)
        XCTAssertEqual(s.hdr.strength, 0.4)
        XCTAssertFalse(s.hdr.extendedOutput)
        XCTAssertEqual(s.crop?.width, 0.8)
        XCTAssertEqual(s.crop?.angle, 0)
        XCTAssertEqual(s.crop?.aspect, .free)
        XCTAssertEqual(s.look?.id, "builtin.film")
        XCTAssertEqual(s.look?.strength, 1)
    }

    func testWrongTypesFallBackPerField() throws {
        let s = try settings(#"{"exposure":"x","contrast":0.3,"crop":{"width":0.5,"aspect":"r99x1"},"look":{"strength":0.5},"hdr":[1]}"#)
        XCTAssertEqual(s.exposure, 0)
        XCTAssertEqual(s.contrast, 0.3)
        XCTAssertEqual(s.crop?.width, 0.5)
        XCTAssertEqual(s.crop?.aspect, .free)
        XCTAssertNil(s.look, "id の無いルックは無し")
        XCTAssertEqual(s.hdr, HDRSettings())
    }

    func testRoundTripKeepsAllFields() throws {
        var s = DevelopSettings()
        s.hdr.highlights = 0.3; s.hdr.extendedOutput = true
        s.crop = CropSettings(x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: 1.5, aspect: .r3x2)
        s.look = LookSelection(id: "builtin.cinema", strength: 0.4)
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(s)), s)
    }

    func testExportPreferencesWrongTypes() throws {
        let e = try JSONDecoder().decode(ExportPreferences.self, from: Data(#"{"subfolder":5,"quality":"high","format":"heif"}"#.utf8))
        XCTAssertEqual(e.subfolder, ExportPreferences().subfolder)
        XCTAssertEqual(e.quality, ExportPreferences().quality)
        XCTAssertEqual(e.format, "heif")
    }
}
