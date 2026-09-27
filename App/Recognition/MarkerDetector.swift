import CoreImage
import CoreVideo
import Vision

/// Vision으로 종이 키보드의 QR 마커를 찾는다.
///
/// 반환 좌표는 모두 전체 카메라 버퍼 기준 정규화 좌표(0...1, 좌상단 원점)다.
/// 버퍼는 회전 없이 그대로 쓰고, 화면 표시 쪽에서 AVCaptureVideoPreviewLayer가 회전/미러링을 처리한다.
final class MarkerDetector {
    private let request: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// 프레임 전체에서 찾는다.
    func detect(in pixelBuffer: CVPixelBuffer, knownIDs: Set<String>) throws -> [DetectedMarker] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return try run(handler, knownIDs: knownIDs) { $0 }
    }

    /// 프레임의 일부(`region`, 정규화 좌표·좌상단 원점)만 잘라서 찾는다.
    /// 작게 찍힌 QR은 잘라서 보면 Vision 입력에서 상대적으로 커져 더 잘 잡힌다.
    func detect(in pixelBuffer: CVPixelBuffer, region: CGRect, knownIDs: Set<String>) throws -> [DetectedMarker] {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0.02, clipped.height > 0.02 else { return [] }

        // Core Image 좌표(좌하단 원점, 픽셀)로 바꿔 자른 뒤 원점으로 옮긴다.
        // 이렇게 하면 Vision 결과가 "잘라낸 이미지 기준"이 되어 되돌리는 계산이 명확하다.
        let crop = CGRect(x: clipped.minX * width, y: (1 - clipped.maxY) * height,
                          width: clipped.width * width, height: clipped.height * height).integral
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        return try run(handler, knownIDs: knownIDs) { p in
            // 잘라낸 영역 기준(좌하단 원점) → 전체 버퍼 기준(좌하단 원점)
            CGPoint(x: (crop.minX + p.x * crop.width) / width,
                    y: (crop.minY + p.y * crop.height) / height)
        }
    }

    /// - Parameter toFullImage: Vision 결과 좌표(좌하단 원점)를 전체 버퍼 기준(좌하단 원점)으로 바꾼다.
    private func run(_ handler: VNImageRequestHandler, knownIDs: Set<String>,
                     toFullImage: (CGPoint) -> CGPoint) throws -> [DetectedMarker] {
        try handler.perform([request])

        var best: [String: DetectedMarker] = [:]
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue, knownIDs.contains(payload) else { continue }
            // Vision은 좌하단 원점이므로 y를 뒤집는다.
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                .map(toFullImage)
                .map { CGPoint(x: $0.x, y: 1 - $0.y) }
            guard let center = Geometry.diagonalIntersection(corners) else { continue }
            if let existing = best[payload], existing.confidence >= observation.confidence { continue }
            best[payload] = DetectedMarker(id: payload, corners: corners, center: center,
                                           confidence: observation.confidence)
        }
        return best.values.sorted { $0.id < $1.id }
    }
}
