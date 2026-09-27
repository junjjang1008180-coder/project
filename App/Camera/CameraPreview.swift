import AVFoundation
import SwiftUI
import UIKit

/// 카메라 프리뷰 + 인식 결과 오버레이(마커, 종이 외곽, 투영된 키 격자).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let snapshot: FrameProcessor.Snapshot

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.attach(device: device)
        view.render(snapshot)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass를 AVCaptureVideoPreviewLayer로 지정했으므로 항상 성공한다.
        layer as! AVCaptureVideoPreviewLayer
    }

    private let keysLayer = CAShapeLayer()
    private let paperLayer = CAShapeLayer()
    private let markersLayer = CAShapeLayer()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var attachedDevice: AVCaptureDevice?
    private var lastSnapshot: FrameProcessor.Snapshot?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        configure(keysLayer, color: .systemYellow, width: 1)
        configure(paperLayer, color: .systemGreen, width: 3)
        configure(markersLayer, color: .systemCyan, width: 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ shape: CAShapeLayer, color: UIColor, width: CGFloat) {
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [keysLayer, paperLayer, markersLayer] {
            shape.frame = bounds
        }
        if let snapshot = lastSnapshot { render(snapshot) }
    }

    /// 카메라가 바뀌면 화면에 똑바로 보이도록 회전 코디네이터를 새로 만든다.
    func attach(device: AVCaptureDevice?) {
        if device !== attachedDevice {
            attachedDevice = device
            rotationObservation = nil
            rotationCoordinator = nil
            if let device {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                rotationCoordinator = coordinator
                rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                    let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                    DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
                }
            }
        }
        // 프리뷰 연결은 세션에 입력이 붙은 뒤에 생기므로 매번 확인해서 맞춘다.
        if let coordinator = rotationCoordinator {
            applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer.connection,
              connection.videoRotationAngle != angle,
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
        if let snapshot = lastSnapshot { render(snapshot) }
    }

    func render(_ snapshot: FrameProcessor.Snapshot) {
        lastSnapshot = snapshot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keysLayer.path = path(for: snapshot.keyQuads)
        paperLayer.path = path(for: snapshot.paperQuad.map { [$0] } ?? [])
        markersLayer.path = path(for: snapshot.markers.map(\.corners))

        let paperColor: UIColor
        if snapshot.isLocked {
            paperColor = .systemBlue
        } else {
            switch snapshot.trackerState {
            case .tracking: paperColor = .systemGreen
            case .holding: paperColor = .systemOrange
            case .searching: paperColor = .systemRed
            }
        }
        paperLayer.strokeColor = paperColor.cgColor
        CATransaction.commit()
    }

    /// 카메라 버퍼 기준 정규화 좌표(좌상단 원점) → 프리뷰 레이어 좌표.
    /// layerPointConverted가 회전·미러링·videoGravity를 모두 반영한다.
    private func path(for quads: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for quad in quads where quad.count >= 3 {
            let points = quad.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
            path.addLines(between: points)
            path.closeSubpath()
        }
        return path
    }
}
