import CoreGraphics
import XCTest

final class PaperTrackerTests: XCTestCase {
    private let imageSize = CGSize(width: 1920, height: 1080)
    /// 템플릿(mm) → 정규화 이미지 좌표. 종이가 화면 가운데에 약간 비스듬히 놓인 상황.
    private let truth = Homography([
        0.0024, 0.0003, 0.18,
        -0.0001, 0.0033, 0.16,
        0.0000008, 0.0005, 1,
    ])

    private func layout() throws -> PaperLayout {
        try PaperLayout.load(in: Bundle(for: PaperTrackerTests.self))
    }

    /// 템플릿 마커를 truth로 투영해서 "카메라가 찾은 마커"를 만든다.
    private func observedMarkers(_ layout: PaperLayout, ids: Set<String>? = nil) throws -> [DetectedMarker] {
        try layout.markers.filter { ids?.contains($0.id) ?? true }.map { marker in
            let c = marker.centerPoint
            let h = CGFloat(marker.size) / 2
            let square = [CGPoint(x: c.x - h, y: c.y - h), CGPoint(x: c.x + h, y: c.y - h),
                          CGPoint(x: c.x + h, y: c.y + h), CGPoint(x: c.x - h, y: c.y + h)]
            let corners = try XCTUnwrap(truth.apply(square))
            let center = try XCTUnwrap(Geometry.diagonalIntersection(corners))
            return DetectedMarker(id: marker.id, corners: corners, center: center)
        }
    }

    func testTracksPaperFromAllMarkers() throws {
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        XCTAssertEqual(tracker.state(at: 0), .searching)

        let update = tracker.update(markers: try observedMarkers(layout), imageSize: imageSize, time: 1)
        XCTAssertNil(update.rejectedReason)
        XCTAssertEqual(update.usedMarkerIDs.count, 6)
        XCTAssertEqual(try XCTUnwrap(update.reprojectionErrorPx), 0, accuracy: 0.01)
        XCTAssertEqual(tracker.state(at: 1.1), .tracking)

        // 모든 키 중심이 실제 위치와 0.1px 이내로 맞아야 한다.
        let estimate = try XCTUnwrap(tracker.estimate)
        for key in layout.keys {
            let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
            let a = try XCTUnwrap(estimate.homography.apply(center))
            let b = try XCTUnwrap(truth.apply(center))
            XCTAssertLessThan(hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height), 0.1, key.id)
        }
    }

    func testWorksWithTwoMarkersHiddenByHand() throws {
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        let visible: Set<String> = ["PK1-TL", "PK1-TR", "PK1-BL", "PK1-BC"]
        let update = tracker.update(markers: try observedMarkers(layout, ids: visible), imageSize: imageSize, time: 1)
        XCTAssertNil(update.rejectedReason)
        XCTAssertNotNil(tracker.estimate)
    }

    func testRejectsThreeTopMarkersPlusOneEvenWithNoise() throws {
        // 위 3개가 한 줄 → 4점이어도 해가 유일하지 않다. 검출 잡음이 있어도 엉터리 해를 받아들이면 안 된다.
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        var markers = try observedMarkers(layout, ids: ["PK1-TL", "PK1-TC", "PK1-TR", "PK1-BL"])
        markers[1].center.y += 0.0007
        let update = tracker.update(markers: markers, imageSize: imageSize, time: 1)
        XCTAssertNotNil(update.rejectedReason)
        XCTAssertNil(tracker.estimate)
    }

    func testRejectsCollinearMarkers() throws {
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        // 위쪽 세 개만 보이면 한 줄이라 보정할 수 없다 (게다가 4개 미만).
        let update = tracker.update(markers: try observedMarkers(layout, ids: ["PK1-TL", "PK1-TC", "PK1-TR"]),
                                    imageSize: imageSize, time: 1)
        XCTAssertNotNil(update.rejectedReason)
        XCTAssertNil(tracker.estimate)
    }

    func testHoldsLastEstimateWhenMarkersDisappear() throws {
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        tracker.update(markers: try observedMarkers(layout), imageSize: imageSize, time: 1)
        let before = tracker.estimate
        tracker.update(markers: [], imageSize: imageSize, time: 2)
        XCTAssertEqual(tracker.estimate, before)
        XCTAssertEqual(tracker.state(at: 2), .holding)

        tracker.reset()
        XCTAssertNil(tracker.estimate)
        XCTAssertEqual(tracker.state(at: 2), .searching)
    }

    func testRejectsInconsistentMarkers() throws {
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        var markers = try observedMarkers(layout)
        // 한 마커를 크게(480px) 어긋나게 → 재투영 오차(약 79px)가 허용치(약 33px)를 넘어 거부
        markers[0].center.x += 0.25
        let update = tracker.update(markers: markers, imageSize: imageSize, time: 1)
        XCTAssertNotNil(update.rejectedReason)
        XCTAssertNil(tracker.estimate)
    }

    func testAcceptsLensDistortionSizedErrors() throws {
        // 광각 웹캠 왜곡 정도(마커마다 ±6px)는 받아들여야 한다 (RMS 약 5.7px).
        let layout = try layout()
        let tracker = PaperTracker(layout: layout)
        var markers = try observedMarkers(layout)
        let offsets: [(CGFloat, CGFloat)] = [(6, -6), (0, 6), (-6, -6), (6, 6), (0, -6), (-6, 6)]
        for i in markers.indices {
            markers[i].center.x += offsets[i].0 / imageSize.width
            markers[i].center.y += offsets[i].1 / imageSize.height
        }
        let update = tracker.update(markers: markers, imageSize: imageSize, time: 1)
        XCTAssertNil(update.rejectedReason)
        XCTAssertNotNil(tracker.estimate)
    }
}
