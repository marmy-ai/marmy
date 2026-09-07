import XCTest
@testable import MarmyUI

/// Fit has to actually fit — including a wide team in a small window.
final class CanvasFitTests: XCTestCase {

    private func fits(bounds: CGRect, viewport: CGSize) -> Bool {
        let result = CanvasFit.compute(bounds: bounds, viewport: viewport)
        let left = bounds.minX * result.scale + result.offset.width
        let top = bounds.minY * result.scale + result.offset.height
        let right = left + bounds.width * result.scale
        let bottom = top + bounds.height * result.scale
        return left >= -0.5 && top >= -0.5
            && right <= viewport.width + 0.5 && bottom <= viewport.height + 0.5
    }

    func testASmallTeamIsNotScaledDown() {
        let result = CanvasFit.compute(
            bounds: CGRect(x: 40, y: 40, width: 600, height: 320),
            viewport: CGSize(width: 900, height: 620))
        XCTAssertEqual(result.scale, 1, accuracy: 0.001)
    }

    func testAWideTeamFitsInsideASmallWindow() {
        // Thirteen nodes across: the case that used to run off the right edge.
        let bounds = CGRect(x: 40, y: 40, width: 13 * 216, height: 3 * 142)
        let viewport = CGSize(width: 480, height: 520)
        let result = CanvasFit.compute(bounds: bounds, viewport: viewport)

        XCTAssertLessThan(result.scale, 1)
        XCTAssertTrue(fits(bounds: bounds, viewport: viewport), "the whole graph has to be inside the viewport")
    }

    func testATallTeamFitsToo() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 2400)
        let viewport = CGSize(width: 700, height: 500)
        XCTAssertTrue(fits(bounds: bounds, viewport: viewport))
    }

    func testTheResultIsCentred() {
        let bounds = CGRect(x: 100, y: 100, width: 200, height: 100)
        let viewport = CGSize(width: 800, height: 600)
        let result = CanvasFit.compute(bounds: bounds, viewport: viewport)

        let left = bounds.minX * result.scale + result.offset.width
        let right = left + bounds.width * result.scale
        XCTAssertEqual(left, viewport.width - right, accuracy: 0.5)
    }

    func testAGraphDraggedFarApartStillFits() {
        // Nodes hand-placed thousands of points apart: no clamp may leave part
        // of the team off the edge.
        let bounds = CGRect(x: 0, y: 0, width: 10000, height: 4000)
        let viewport = CGSize(width: 480, height: 520)
        let result = CanvasFit.compute(bounds: bounds, viewport: viewport)

        XCTAssertLessThan(result.scale, 0.05)
        XCTAssertGreaterThan(result.scale, 0)
        XCTAssertTrue(fits(bounds: bounds, viewport: viewport))
    }

    func testDegenerateInputsAreHarmless() {
        XCTAssertEqual(CanvasFit.compute(bounds: .zero, viewport: CGSize(width: 100, height: 100)).scale, 1)
        XCTAssertEqual(
            CanvasFit.compute(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), viewport: .zero).scale, 1)
    }
}
