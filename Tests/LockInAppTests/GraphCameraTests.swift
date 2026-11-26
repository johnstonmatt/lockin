import XCTest
@testable import LockIn

final class GraphCameraTests: XCTestCase {
    func testZoomKeepsAnchorOverSameGraphPoint() {
        var camera = GraphCamera(scale: 0.75, offset: CGSize(width: -50, height: 80))
        let anchor = CGPoint(x: 200, y: 300)
        let point = CGPoint(x: (anchor.x - camera.offset.width) / camera.scale,
                            y: (anchor.y - camera.offset.height) / camera.scale)
        camera.zoom(to: 1.5, around: anchor)
        XCTAssertEqual(point.x * camera.scale + camera.offset.width, anchor.x, accuracy: 0.001)
        XCTAssertEqual(point.y * camera.scale + camera.offset.height, anchor.y, accuracy: 0.001)
        camera.zoom(to: 100, around: anchor)
        XCTAssertEqual(camera.scale, 2)
        camera.zoom(to: 0, around: anchor)
        XCTAssertEqual(camera.scale, 0.1)
    }

    func testFitCentersGraphWithinViewport() {
        var camera = GraphCamera()
        let content = CGSize(width: 1120, height: 1700)
        let viewport = CGSize(width: 800, height: 600)
        camera.fit(content: content, viewport: viewport)
        XCTAssertLessThanOrEqual(content.width * camera.scale, viewport.width - 64)
        XCTAssertLessThanOrEqual(content.height * camera.scale, viewport.height - 96)
        XCTAssertEqual(content.width * camera.scale / 2 + camera.offset.width, viewport.width / 2, accuracy: 0.001)
        XCTAssertEqual(content.height * camera.scale / 2 + camera.offset.height, viewport.height / 2, accuracy: 0.001)
    }

    func testFitDoesNotEnlargeSmallGraphs() {
        var camera = GraphCamera()
        camera.fit(content: CGSize(width: 280, height: 170), viewport: CGSize(width: 800, height: 600))
        XCTAssertEqual(camera.scale, 1)
    }
}
