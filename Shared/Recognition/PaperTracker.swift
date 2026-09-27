import CoreGraphics
import Foundation

/// 카메라 이미지에서 찾은 QR 마커 하나.
struct DetectedMarker: Equatable {
    var id: String
    /// 정규화 이미지 좌표(0...1, 좌상단 원점). 순환 순서.
    var corners: [CGPoint]
    /// 대각선 교점으로 구한 마커 중심.
    var center: CGPoint
}

/// 검출된 마커로 "템플릿(mm) → 이미지(정규화 좌표)" 호모그래피를 추정하고 흔들림을 줄인다.
///
/// - 마커가 4개 이상 보이면 최소제곱으로 추정한다 (6개 중 2개까지 손에 가려져도 된다).
/// - 종이와 카메라는 대개 고정되어 있으므로, 결과를 부드럽게 따라가고
///   마커가 가려진 동안에는 마지막 값을 유지(holding)한다.
final class PaperTracker {
    enum State: Equatable {
        /// 아직 한 번도 종이를 찾지 못함
        case searching
        /// 최근(holdTimeout 이내)에 마커로 갱신됨
        case tracking
        /// 마커가 가려져 마지막 추정을 유지하는 중
        case holding
    }

    struct Estimate: Equatable {
        /// 템플릿 mm → 정규화 이미지 좌표
        var homography: Homography
        /// 종이 네 모서리의 이미지 위치 (정규화 좌표, 좌상단부터 시계 방향)
        var paperCorners: [CGPoint]
    }

    struct Update {
        var usedMarkerIDs: [String]
        /// 마커 중심 재투영 RMS 오차 (px). 마커가 정확히 4개면 항상 0에 가깝다.
        var reprojectionErrorPx: Double?
        /// 이번 검출을 받아들이지 않은 이유
        var rejectedReason: String?
    }

    let layout: PaperLayout
    /// 0에 가까울수록 천천히 따라간다 (1 = 필터 없음).
    var smoothing: CGFloat = 0.35
    /// 한 번에 이보다 크게(px) 움직이면 종이를 옮긴 것으로 보고 즉시 따라간다.
    var snapThresholdPx: CGFloat = 25
    var holdTimeout: TimeInterval = 0.5
    var maxReprojectionErrorPx: Double = 8

    private(set) var estimate: Estimate?
    private(set) var lastUpdateTime: TimeInterval?

    init(layout: PaperLayout) {
        self.layout = layout
    }

    func reset() {
        estimate = nil
        lastUpdateTime = nil
    }

    func state(at time: TimeInterval) -> State {
        guard estimate != nil, let last = lastUpdateTime else { return .searching }
        return time - last <= holdTimeout ? .tracking : .holding
    }

    @discardableResult
    func update(markers: [DetectedMarker], imageSize: CGSize, time: TimeInterval) -> Update {
        var templatePoints: [CGPoint] = []
        var imagePoints: [CGPoint] = []
        var used: [String] = []
        for marker in markers {
            guard let reference = layout.marker(withID: marker.id) else { continue }
            templatePoints.append(reference.centerPoint)
            imagePoints.append(marker.center)
            used.append(marker.id)
        }

        guard used.count >= 4 else {
            let reason = used.isEmpty ? nil : "마커 \(used.count)개만 보임 (4개 이상 필요)"
            return Update(usedMarkerIDs: used, reprojectionErrorPx: nil, rejectedReason: reason)
        }
        guard let h = Homography.estimate(from: templatePoints, to: imagePoints) else {
            return Update(usedMarkerIDs: used, reprojectionErrorPx: nil,
                          rejectedReason: "보이는 마커가 한 줄에 몰려 보정 불가 (위·아래 줄에서 각각 2개 이상 필요)")
        }

        let error = Self.rmsErrorPx(h, templatePoints, imagePoints, imageSize)
        guard error <= maxReprojectionErrorPx else {
            return Update(usedMarkerIDs: used, reprojectionErrorPx: error,
                          rejectedReason: String(format: "재투영 오차가 큼 (%.1fpx)", error))
        }
        guard let corners = h.apply(layout.paperCorners), Geometry.isConvexQuad(corners) else {
            return Update(usedMarkerIDs: used, reprojectionErrorPx: error, rejectedReason: "종이 모양이 비정상")
        }

        accept(paperCorners: corners, imageSize: imageSize, time: time)
        return Update(usedMarkerIDs: used, reprojectionErrorPx: error, rejectedReason: nil)
    }

    private func accept(paperCorners corners: [CGPoint], imageSize: CGSize, time: TimeInterval) {
        var target = corners
        if let previous = estimate?.paperCorners {
            let maxMove = zip(previous, corners)
                .map { Self.pixelDistance($0, $1, imageSize) }
                .max() ?? 0
            if maxMove < snapThresholdPx {
                target = zip(previous, corners).map { p, c in
                    CGPoint(x: p.x + (c.x - p.x) * smoothing, y: p.y + (c.y - p.y) * smoothing)
                }
            }
        }
        // 부드럽게 만든 네 모서리로 호모그래피를 다시 만든다 (4점 → 정확해).
        guard let h = Homography.estimate(from: layout.paperCorners, to: target) else { return }
        estimate = Estimate(homography: h, paperCorners: target)
        lastUpdateTime = time
    }

    private static func pixelDistance(_ a: CGPoint, _ b: CGPoint, _ size: CGSize) -> CGFloat {
        hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
    }

    private static func rmsErrorPx(_ h: Homography, _ src: [CGPoint], _ dst: [CGPoint], _ size: CGSize) -> Double {
        var sum = 0.0
        for (s, d) in zip(src, dst) {
            guard let p = h.apply(s) else { return .infinity }
            let dist = Double(pixelDistance(p, d, size))
            sum += dist * dist
        }
        return (sum / Double(src.count)).squareRoot()
    }
}

extension PaperTracker.Estimate {
    /// 템플릿(mm) 위의 사각형을 이미지 정규화 좌표로 투영한다.
    func project(_ templatePoints: [CGPoint]) -> [CGPoint]? {
        homography.apply(templatePoints)
    }
}
