import CoreGraphics
import Foundation

/// 인쇄용 종이 키보드의 기준 템플릿.
///
/// 좌표 단위는 mm, 원점은 종이 좌상단, y는 아래로 증가한다.
/// `Layouts/*.json` 은 `tools/paper_template.py` 가 인쇄용 PDF와 함께 생성한다.
struct PaperLayout: Codable, Equatable {
    struct Paper: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct Marker: Codable, Equatable {
        /// QR 코드에 인코딩된 문자열과 같다 (예: "PK1-TL").
        var id: String
        var center: [Double]
        /// QR 심볼 한 변의 길이 (여백 제외).
        var size: Double

        var centerPoint: CGPoint { CGPoint(x: center[0], y: center[1]) }
    }

    struct Key: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        var alt: String?
        var action: KeyAction
        /// [x, y, width, height]
        var rect: [Double]

        var frame: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }

        /// 좌상단부터 시계 방향.
        var corners: [CGPoint] {
            let f = frame
            return [
                CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY),
            ]
        }
    }

    var id: String
    var name: String
    var version: Int
    var paper: Paper
    var markers: [Marker]
    var keys: [Key]

    /// 종이 네 모서리, 좌상단부터 시계 방향.
    var paperCorners: [CGPoint] {
        [
            CGPoint(x: 0, y: 0), CGPoint(x: paper.width, y: 0),
            CGPoint(x: paper.width, y: paper.height), CGPoint(x: 0, y: paper.height),
        ]
    }

    var aspectRatio: CGFloat { CGFloat(paper.width / paper.height) }

    func marker(withID id: String) -> Marker? {
        markers.first { $0.id == id }
    }

    func key(at point: CGPoint) -> Key? {
        keys.first { $0.frame.contains(point) }
    }

    func validate() throws {
        guard markers.count >= 4 else { throw LayoutError.invalid("마커가 4개 미만입니다") }
        guard Set(markers.map(\.id)).count == markers.count else { throw LayoutError.invalid("마커 ID가 중복됩니다") }
        guard Set(keys.map(\.id)).count == keys.count else { throw LayoutError.invalid("키 ID가 중복됩니다") }
        if let bad = markers.first(where: { $0.center.count != 2 }) {
            throw LayoutError.invalid("마커 \(bad.id)의 center는 [x, y] 여야 합니다")
        }
        if let bad = keys.first(where: { $0.rect.count != 4 }) {
            throw LayoutError.invalid("키 \(bad.id)의 rect는 [x, y, w, h] 여야 합니다")
        }
    }
}

extension PaperLayout {
    static let defaultResourceName = "pk1-qwerty-a4"

    static func load(named name: String = defaultResourceName, in bundle: Bundle) throws -> PaperLayout {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw LayoutError.missingResource(name)
        }
        let layout = try JSONDecoder().decode(PaperLayout.self, from: Data(contentsOf: url))
        try layout.validate()
        return layout
    }
}

enum LayoutError: LocalizedError {
    case missingResource(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "레이아웃 파일 \(name).json 을 찾을 수 없습니다"
        case .invalid(let reason): return "레이아웃이 올바르지 않습니다: \(reason)"
        }
    }
}

/// 키를 눌렀을 때의 동작. JSON 예: {"type": "char", "value": "q", "shift": "Q"}
enum KeyAction: Codable, Equatable {
    case character(String, shifted: String?)
    case space
    case enter
    case backspace
    case shift
    case languageToggle

    private enum CodingKeys: String, CodingKey {
        case type, value, shift
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "char":
            self = .character(try container.decode(String.self, forKey: .value),
                              shifted: try container.decodeIfPresent(String.self, forKey: .shift))
        case "space": self = .space
        case "enter": self = .enter
        case "backspace": self = .backspace
        case "shift": self = .shift
        case "languageToggle": self = .languageToggle
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "알 수 없는 키 동작: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .character(value, shifted):
            try container.encode("char", forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(shifted, forKey: .shift)
        case .space: try container.encode("space", forKey: .type)
        case .enter: try container.encode("enter", forKey: .type)
        case .backspace: try container.encode("backspace", forKey: .type)
        case .shift: try container.encode("shift", forKey: .type)
        case .languageToggle: try container.encode("languageToggle", forKey: .type)
        }
    }
}
