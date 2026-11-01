import XCTest
import CoreImage
@testable import RAWCore

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = DevelopSettings()
        s.exposure = 0.7
        s.hdr.strength = 0.5
        s.crop = CropSettings(x: 0.1, y: 0.2, width: 0.5, height: 0.4, angle: 2, aspect: .r3x2)
        s.look = LookSelection(id: "builtin.film", strength: 0.6)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: data), s)
    }

    func testOldSidecarWithMissingKeysStillLoads() throws {
        let json = #"{"exposure": 1.5}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DevelopSettings.self, from: json)
        XCTAssertEqual(s.exposure, 1.5)
        XCTAssertEqual(s.saturation, 1.0)
        XCTAssertNil(s.crop)
    }

    /// 旧形式(schemaVersion 1)の lensCorrection(Bool)は読み捨て、レンズ補正はカメラ設定に従う(lens = nil)
    func testSchema1LensCorrectionIsIgnored() throws {
        let json = #"{"schemaVersion": 1, "exposure": 0.5, "lensCorrection": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DevelopSettings.self, from: json)
        XCTAssertEqual(s.exposure, 0.5)
        XCTAssertNil(s.lens)
        // 新形式は書いて読める。指定が無ければ書かない
        var t = DevelopSettings()
        XCTAssertFalse(String(data: try JSONEncoder().encode(t), encoding: .utf8)!.contains("\"lens\""))
        t.lens = LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: true)
        let u = try JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(u.lens, t.lens)
        XCTAssertEqual(u.schemaVersion, DevelopSettings.currentSchemaVersion)
        // 項目が欠けていれば「掛ける」、型が違っていても全体の読み込みは失敗しない
        let partial = #"{"lens": {"distortion": false}}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: partial).lens,
                       LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: true))
        let broken = #"{"exposure": 1, "lens": true}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(DevelopSettings.self, from: broken)
        XCTAssertEqual(b.exposure, 1)
        XCTAssertNil(b.lens)
    }

    func testCenteredCropKeepsRatio() {
        // 3:2 の画像を 1:1 で切ると、幅は高さの 2/3
        let c = CropSettings.centered(aspect: .square, imageAspect: 1.5)
        XCTAssertEqual(c.height, 1, accuracy: 1e-9)
        XCTAssertEqual(c.width, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(c.x, (1 - 2.0 / 3) / 2, accuracy: 1e-9)
    }
}
