import CoreGraphics
import XCTest

final class HomographyTests: XCTestCase {
    /// 종이(mm) → 비스듬히 본 카메라 이미지(정규화 좌표) 같은 전형적인 변환.
    private let truth = Homography([
        0.0031, 0.0004, 0.21,
        -0.0002, 0.0036, 0.17,
        0.0000011, 0.0006, 1,
    ])

    func testRecoversKnownHomographyFromFourPoints() throws {
        let src = [CGPoint(x: 24, y: 24), CGPoint(x: 273, y: 24), CGPoint(x: 273, y: 186), CGPoint(x: 24, y: 186)]
        let dst = try XCTUnwrap(truth.apply(src))
        let h = try XCTUnwrap(Homography.estimate(from: src, to: dst))
        for p in [CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 297, y: 210)] {
            try assertClose(h.apply(p), truth.apply(p))
        }
    }

    func testLeastSquaresWithSixPoints() throws {
        let src = [
            CGPoint(x: 24, y: 24), CGPoint(x: 148.5, y: 24), CGPoint(x: 273, y: 24),
            CGPoint(x: 24, y: 186), CGPoint(x: 148.5, y: 186), CGPoint(x: 273, y: 186),
        ]
        let dst = try XCTUnwrap(truth.apply(src))
        let h = try XCTUnwrap(Homography.estimate(from: src, to: dst))
        try assertClose(h.apply(CGPoint(x: 150, y: 100)), truth.apply(CGPoint(x: 150, y: 100)))
    }

    func testRejectsDegenerateConfiguration() {
        // 네 점 중 세 점이 한 직선 위 → 유일한 해가 없다
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 1)]
        XCTAssertNil(Homography.estimate(from: pts, to: pts))
        XCTAssertNil(Homography.estimate(from: Array(pts.prefix(3)), to: Array(pts.prefix(3))))
    }

    func testInverseRoundTrip() throws {
        let inverse = try XCTUnwrap(truth.inverse)
        let p = CGPoint(x: 120, y: 80)
        let q = try XCTUnwrap(truth.apply(p))
        try assertClose(inverse.apply(q), p, accuracy: 1e-6)
        let identity = truth.followed(by: inverse).normalized()
        for (a, b) in zip(identity.m, Homography.identity.m) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    func testDiagonalIntersectionIsProjectedCenter() throws {
        let square = [CGPoint(x: 10, y: 10), CGPoint(x: 36, y: 10), CGPoint(x: 36, y: 36), CGPoint(x: 10, y: 36)]
        let projected = try XCTUnwrap(truth.apply(square))
        let center = try XCTUnwrap(Geometry.diagonalIntersection(projected))
        try assertClose(center, truth.apply(CGPoint(x: 23, y: 23)), accuracy: 1e-9)
    }

    func testConvexQuad() {
        let convex = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let twisted = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        XCTAssertTrue(Geometry.isConvexQuad(convex))
        XCTAssertFalse(Geometry.isConvexQuad(twisted))
    }

    private func assertClose(_ a: CGPoint?, _ b: CGPoint?, accuracy: CGFloat = 1e-7,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(a, file: file, line: line)
        let b = try XCTUnwrap(b, file: file, line: line)
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }
}
