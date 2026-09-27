import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import QuartzCore

/// 카메라 프레임 → 마커 검출 → 종이 추적 → 화면 표시용 스냅샷.
///
/// `process(pixelBuffer:)` 는 카메라의 비디오 큐에서 호출되고,
/// @Published 값은 메인 스레드에서만 바뀐다.
final class FrameProcessor: ObservableObject {
    struct Snapshot {
        var trackerState: PaperTracker.State = .searching
        var isLocked = false
        var imageSize: CGSize = .zero
        /// 마지막 검출에서 찾은 마커 (정규화 이미지 좌표)
        var markers: [DetectedMarker] = []
        /// 종이 외곽 (정규화 이미지 좌표)
        var paperQuad: [CGPoint]?
        /// 템플릿의 각 키를 이미지에 투영한 사각형
        var keyQuads: [[CGPoint]] = []
        var reprojectionErrorPx: Double?
        var rejectedReason: String?
        var secondsSinceUpdate: TimeInterval?
        var detectionMs: Double?
        var fps: Double = 0
    }

    @Published private(set) var snapshot = Snapshot()
    /// 원근 보정된 종이 이미지 (종이 비율 그대로)
    @Published private(set) var rectifiedImage: CGImage?
    /// 켜면 마커 검출을 멈추고 현재 보정값을 고정한다.
    @Published var isLocked = false {
        didSet {
            let locked = isLocked
            withControl { $0.locked = locked }
        }
    }

    let layout: PaperLayout

    var detectionInterval: TimeInterval = 1.0 / 15
    var rectifyInterval: TimeInterval = 0.25
    var rectifiedWidth: CGFloat = 900

    // MARK: 비디오 큐 전용 상태
    private let tracker: PaperTracker
    private let detector = MarkerDetector()
    private let knownMarkerIDs: Set<String>
    private let ciContext = CIContext()
    private var lastDetectionTime: TimeInterval = 0
    private var lastRectifyTime: TimeInterval = 0
    private var lastPublishTime: TimeInterval = 0
    private var frameTimes: [TimeInterval] = []
    private var lastMarkers: [DetectedMarker] = []
    private var lastUpdate: PaperTracker.Update?
    private var lastDetectionMs: Double?

    // MARK: 메인 ↔ 비디오 큐 공유 값
    private struct Control {
        var locked = false
        var resetRequested = false
    }
    private let controlLock = NSLock()
    private var control = Control()

    init(layout: PaperLayout) {
        self.layout = layout
        self.tracker = PaperTracker(layout: layout)
        self.knownMarkerIDs = Set(layout.markers.map(\.id))
    }

    /// 보정값을 버리고 종이를 처음부터 다시 찾는다.
    func reset() {
        withControl { $0.resetRequested = true }
        isLocked = false
    }

    // MARK: - 비디오 큐

    func process(pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        while let first = frameTimes.first, now - first > 1 { frameTimes.removeFirst() }

        let (locked, resetRequested) = withControl { (control: inout Control) -> (Bool, Bool) in
            let values = (control.locked, control.resetRequested)
            control.resetRequested = false
            return values
        }
        if resetRequested {
            tracker.reset()
            lastMarkers = []
            lastUpdate = nil
            DispatchQueue.main.async { self.rectifiedImage = nil }
        }

        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        var detected = false
        if !locked, now - lastDetectionTime >= detectionInterval {
            lastDetectionTime = now
            let start = CACurrentMediaTime()
            lastMarkers = (try? detector.detect(in: pixelBuffer, knownIDs: knownMarkerIDs)) ?? []
            lastDetectionMs = (CACurrentMediaTime() - start) * 1000
            lastUpdate = tracker.update(markers: lastMarkers, imageSize: imageSize, time: now)
            detected = true
        }

        if let estimate = tracker.estimate, now - lastRectifyTime >= rectifyInterval {
            lastRectifyTime = now
            let image = makeRectifiedImage(from: pixelBuffer, paperQuad: estimate.paperCorners)
            DispatchQueue.main.async { self.rectifiedImage = image }
        }

        if detected || now - lastPublishTime >= 0.25 {
            lastPublishTime = now
            publishSnapshot(now: now, imageSize: imageSize, locked: locked)
        }
    }

    private func publishSnapshot(now: TimeInterval, imageSize: CGSize, locked: Bool) {
        var s = Snapshot()
        s.trackerState = tracker.state(at: now)
        s.isLocked = locked
        s.imageSize = imageSize
        s.markers = lastMarkers
        s.reprojectionErrorPx = lastUpdate?.reprojectionErrorPx
        s.rejectedReason = locked ? nil : lastUpdate?.rejectedReason
        s.secondsSinceUpdate = tracker.lastUpdateTime.map { now - $0 }
        s.detectionMs = lastDetectionMs
        s.fps = Double(frameTimes.count)
        if let estimate = tracker.estimate {
            s.paperQuad = estimate.paperCorners
            s.keyQuads = layout.keys.compactMap { estimate.project($0.corners) }
        }
        DispatchQueue.main.async { self.snapshot = s }
    }

    /// 종이 네 모서리를 펴서 종이 비율 그대로의 이미지로 만든다.
    private func makeRectifiedImage(from pixelBuffer: CVPixelBuffer, paperQuad: [CGPoint]) -> CGImage? {
        guard paperQuad.count == 4 else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        // Core Image는 좌하단 원점, 픽셀 단위
        func ciPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * width, y: (1 - p.y) * height) }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        filter.topLeft = ciPoint(paperQuad[0])
        filter.topRight = ciPoint(paperQuad[1])
        filter.bottomRight = ciPoint(paperQuad[2])
        filter.bottomLeft = ciPoint(paperQuad[3])
        guard let output = filter.outputImage,
              output.extent.width > 1, output.extent.height > 1,
              output.extent.width.isFinite, output.extent.height.isFinite
        else { return nil }

        let targetWidth = rectifiedWidth
        let targetHeight = (targetWidth / layout.aspectRatio).rounded()
        let scaled = output
            .transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: targetWidth / output.extent.width,
                                               y: targetHeight / output.extent.height))
        return ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    }

    private func withControl<T>(_ body: (inout Control) -> T) -> T {
        controlLock.lock()
        defer { controlLock.unlock() }
        return body(&control)
    }
}
