import CoreVideo
import Vision

/// Vision으로 종이 키보드의 QR 마커를 찾는다.
final class MarkerDetector {
    private let request: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// - Parameter knownIDs: 이 레이아웃의 마커 ID. 다른 QR 코드는 무시한다.
    /// - Returns: 정규화 이미지 좌표(좌상단 원점)의 마커 목록. ID당 하나.
    func detect(in pixelBuffer: CVPixelBuffer, knownIDs: Set<String>) throws -> [DetectedMarker] {
        // 버퍼를 회전 없이 그대로 쓴다. 좌표는 카메라 버퍼 기준이 되고,
        // 화면 표시 쪽에서 AVCaptureVideoPreviewLayer가 회전/미러링을 처리한다.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        var best: [String: (marker: DetectedMarker, confidence: Float)] = [:]
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue, knownIDs.contains(payload) else { continue }
            // Vision은 좌하단 원점이므로 y를 뒤집는다.
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                .map { CGPoint(x: $0.x, y: 1 - $0.y) }
            guard let center = Geometry.diagonalIntersection(corners) else { continue }
            if let existing = best[payload], existing.confidence >= observation.confidence { continue }
            best[payload] = (DetectedMarker(id: payload, corners: corners, center: center), observation.confidence)
        }
        return best.values.map { $0.marker }.sorted { $0.id < $1.id }
    }
}
