import CoreGraphics
import XCTest

final class PaperLayoutTests: XCTestCase {
    private func loadDefault() throws -> PaperLayout {
        try PaperLayout.load(in: Bundle(for: PaperLayoutTests.self))
    }

    func testBundledLayoutDecodes() throws {
        let layout = try loadDefault()
        XCTAssertEqual(layout.id, "PK1")
        XCTAssertEqual(layout.markers.count, 6)
        XCTAssertEqual(layout.paper.width, 297)
        XCTAssertEqual(layout.paper.height, 210)
        XCTAssertGreaterThanOrEqual(layout.keys.count, 40)
    }

    func testSpecialKeysExist() throws {
        let layout = try loadDefault()
        let actions = layout.keys.map(\.action)
        for action in [KeyAction.space, .enter, .backspace, .shift, .languageToggle] {
            XCTAssertTrue(actions.contains(action), "\(action) 키가 없습니다")
        }
        XCTAssertEqual(layout.keys.first { $0.id == "q" }?.action, .character("q", shifted: "Q"))
    }

    func testKeysAreInsidePaperAndDoNotOverlap() throws {
        let layout = try loadDefault()
        let paper = CGRect(x: 0, y: 0, width: layout.paper.width, height: layout.paper.height)
        for (i, a) in layout.keys.enumerated() {
            XCTAssertTrue(paper.contains(a.frame), "\(a.id) 키가 종이 밖에 있습니다")
            for b in layout.keys[(i + 1)...] {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(a.id)와 \(b.id)가 겹칩니다")
            }
        }
    }

    func testKeysDoNotOverlapMarkers() throws {
        let layout = try loadDefault()
        for marker in layout.markers {
            // QR 주변 여백(4모듈)까지 비어 있어야 인식이 잘 된다.
            let quiet = marker.size / 21 * 4
            let half = marker.size / 2 + quiet
            let zone = CGRect(x: marker.center[0] - half, y: marker.center[1] - half, width: half * 2, height: half * 2)
            for key in layout.keys {
                XCTAssertFalse(zone.intersects(key.frame), "\(key.id) 키가 마커 \(marker.id) 여백을 침범합니다")
            }
        }
    }

    func testKeyLookup() throws {
        let layout = try loadDefault()
        let q = try XCTUnwrap(layout.keys.first { $0.id == "q" })
        XCTAssertEqual(layout.key(at: CGPoint(x: q.frame.midX, y: q.frame.midY))?.id, "q")
        XCTAssertNil(layout.key(at: CGPoint(x: 1, y: 1)))
    }

    func testKeyActionRoundTrip() throws {
        let actions: [KeyAction] = [.character("a", shifted: "A"), .character("1", shifted: nil), .space, .languageToggle]
        let data = try JSONEncoder().encode(actions)
        XCTAssertEqual(try JSONDecoder().decode([KeyAction].self, from: data), actions)
    }
}
