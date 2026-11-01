import XCTest
import CoreImage
@testable import RAWCore

final class StageTests: XCTestCase {
    private let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))

    func testCropProducesExpectedSize() {
        var s = DevelopSettings()
        s.crop = CropSettings(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let out = CropStage().apply(image, settings: s, options: RenderOptions())
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 150, height: 100))
    }

    func testCropTopLeftMapsToCoreImageTop() {
        // 左上原点の (0,0,0.5,0.5) は Core Image(左下原点) では上半分
        let r = CropStage.pixelRect(for: CropSettings(x: 0, y: 0, width: 0.5, height: 0.5),
                                    in: CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(r, CGRect(x: 0, y: 100, width: 150, height: 100))
    }

    func testRotateOnlyKeepsFrame() {
        var s = DevelopSettings()
        s.crop = CropSettings(x: 0.2, y: 0.2, width: 0.3, height: 0.3, angle: 5)
        let out = CropStage().apply(image, settings: s, options: RenderOptions(cropMode: .rotateOnly))
        XCTAssertEqual(out.extent, image.extent)
    }

    func testStagesRunInPhaseOrder() {
        let looks = LookRegistry(looks: [])
        let phases = DevelopPipeline.makeDefault(looks: looks).stages.map(\.phase)
        XCTAssertEqual(phases, phases.sorted())
    }
}
