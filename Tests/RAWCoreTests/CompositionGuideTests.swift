import XCTest
import CoreImage
@testable import RAWCore

final class CompositionGuideTests: XCTestCase {
    func testRatioPositions() {
        XCTAssertEqual(CompositionGuides.golden.positions[1], 0.618, accuracy: 0.001)
        XCTAssertEqual(CompositionGuides.silver.positions[0], 0.414, accuracy: 0.001)
        // 縦線と横線が1本ずつ × 分割位置の数
        XCTAssertEqual(CompositionGuides.thirds.paths(aspect: 1.5, options: GuideOptions()).count, 4)
        XCTAssertEqual(CompositionGuides.halves.paths(aspect: 1.5, options: GuideOptions()).count, 2)
    }

    func testSpiralStaysInsideAndIsContinuous() {
        let paths = CompositionGuides.spiral.paths(aspect: 1.5, options: GuideOptions())
        let spiral = paths.last!.points
        for p in spiral {
            XCTAssert((-1e-9...1 + 1e-9).contains(Double(p.x)) && (-1e-9...1 + 1e-9).contains(Double(p.y)))
        }
        for (a, b) in zip(spiral, spiral.dropFirst()) {
            XCTAssertLessThan(hypot(a.x - b.x, a.y - b.y), 0.08, "螺旋が途切れています")
        }
    }

    func testFlipsMoveTheEyeToEachCorner() {
        let g = CompositionGuides.spiral
        let eye = g.eye(aspect: 1.5, options: GuideOptions())
        XCTAssertGreaterThan(eye.x, 0.5); XCTAssertGreaterThan(eye.y, 0.5)       // 右下
        let h = g.eye(aspect: 1.5, options: GuideOptions(flipHorizontal: true))
        XCTAssertLessThan(h.x, 0.5); XCTAssertGreaterThan(h.y, 0.5)              // 左下
        let v = g.eye(aspect: 1.5, options: GuideOptions(flipVertical: true))
        XCTAssertGreaterThan(v.x, 0.5); XCTAssertLessThan(v.y, 0.5)              // 右上
    }

    func testDiagonalConnectsCorners() {
        let paths = CompositionGuides.diagonal.paths(aspect: 1.5, options: GuideOptions())
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].points, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
    }

    func testGoldenTrianglePerpendicularsOnScreen() {
        let aspect = 1.5
        let paths = CompositionGuides.triangle.paths(aspect: aspect, options: GuideOptions())
        XCTAssertEqual(paths.count, 3)
        // 画面上(ピクセル空間)で直角になっていること
        func px(_ p: CGPoint) -> (Double, Double) { (Double(p.x) * aspect, Double(p.y)) }
        let d0 = px(paths[0].points[0]), d1 = px(paths[0].points[1])
        let diag = (d1.0 - d0.0, d1.1 - d0.1)
        for perp in paths.dropFirst() {
            let a = px(perp.points[0]), b = px(perp.points[1])
            let dot = (b.0 - a.0) * diag.0 + (b.1 - a.1) * diag.1
            XCTAssertEqual(dot, 0, accuracy: 1e-9)
            // 垂線の足は対角線上にある
            let cross = (b.0 - d0.0) * diag.1 - (b.1 - d0.1) * diag.0
            XCTAssertEqual(cross, 0, accuracy: 1e-9)
        }
    }

    func testGoldenTriangleFlipUsesOtherDiagonal() {
        let paths = CompositionGuides.triangle.paths(aspect: 1.5, options: GuideOptions(flipTriangle: true))
        XCTAssertEqual(paths[0].points[0], CGPoint(x: 1, y: 0))
        XCTAssertEqual(paths[0].points[1], CGPoint(x: 0, y: 1))
    }

    func testGuideIDsAreUnique() {
        let ids = CompositionGuides.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
