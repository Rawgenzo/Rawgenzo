import XCTest
import CoreImage
@testable import RAWCore

final class FileNameTemplateTests: XCTestCase {
    private let ctx: FileNameTemplate.Context = {
        var c = FileNameTemplate.Context.sample
        c.sequence = 7
        return c
    }()

    private func render(_ p: String) throws -> String { try FileNameTemplate(p).render(ctx) }

    func testBasicVariables() throws {
        XCTAssertEqual(try render("{name}"), "DSC01234")
        XCTAssertEqual(try render("{date}_{name}"), "20260914_DSC01234")
        XCTAssertEqual(try render("{date:yyyy-MM-dd}_{seq:3}"), "2026-09-14_007")
        XCTAssertEqual(try render("{model}_ISO{iso}_{name}"), "ILCE-7SM3_ISO12800_DSC01234")
        XCTAssertEqual(try render("F{f}_{shutter}_{focal}mm"), "F2.8_1-250_35mm")
        XCTAssertEqual(try render("{folder}"), "2026-09 Kanazawa")
        XCTAssertEqual(try render("{width}x{height}"), "4240x2832")
    }

    func testEmptyValuesAndUnsafeCharacters() throws {
        var c = ctx
        c.metadata.lensModel = nil
        XCTAssertEqual(try FileNameTemplate("{lens}_{name}").render(c), "DSC01234")   // 端の _ は落とす
        XCTAssertEqual(try render("{date:yyyy/MM/dd}"), "2026-09-14")                // / は使えない
        XCTAssertEqual(try render("..{name}"), "DSC01234")                           // 隠しファイルにしない
        XCTAssertEqual(try render("{{x}}_{name}"), "{x}_DSC01234")
    }

    func testErrors() {
        XCTAssertEqual(FileNameTemplate("{name").validate(), .unclosedBrace)
        XCTAssertEqual(FileNameTemplate("{foo}").validate(), .unknownVariable("foo"))
        XCTAssertEqual(FileNameTemplate("{seq:0}").validate(), .badSequenceDigits("0"))
        XCTAssertNil(FileNameTemplate("{date:yyyy}_{seq:5}").validate())
    }

    func testUsesSequence() {
        XCTAssertTrue(FileNameTemplate("{date}_{seq}").usesSequence)
        XCTAssertFalse(FileNameTemplate("{date}_{name}").usesSequence)
    }
}
