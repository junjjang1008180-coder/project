import AVFoundation
import Foundation

/// 카메라 선택(내장 / 외장 USB-C 웹캠)과 AVCaptureSession 수명을 관리한다.
///
/// - 외장 웹캠이 연결되어 있으면 기본으로 그것을 쓴다 (iPadOS 17+, UVC 규격).
/// - 연결/분리를 감지해서 자동으로 카메라를 바꾼다.
/// - 세션 설정은 sessionQueue, 프레임 콜백은 videoQueue, @Published 변경은 메인 스레드.
final class CameraManager: NSObject, ObservableObject {
    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
        let isExternal: Bool
    }

    enum Status: Equatable {
        case idle
        case unauthorized
        case noCamera
        case running
        case interrupted(String)
        case failed(String)
    }

    @Published private(set) var cameras: [CameraOption] = []
    @Published private(set) var selectedCameraID: String?
    @Published private(set) var currentDevice: AVCaptureDevice?
    @Published private(set) var status: Status = .idle
    @Published private(set) var formatDescription = "-"
    /// 다른 앱과 화면을 함께 쓸 때(Split View, 창, PiP)도 카메라를 쓸 수 있는지.
    @Published private(set) var multitaskingCameraSupported = false

    let session = AVCaptureSession()
    /// 새 프레임. videoQueue에서 호출된다.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "PaperKeyboard.camera.session")
    private let videoQueue = DispatchQueue(label: "PaperKeyboard.camera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .builtInWideAngleCamera, .builtInUltraWideCamera],
        mediaType: .video,
        position: .unspecified)
    private var currentInput: AVCaptureDeviceInput?
    /// 사용자가 직접 고른 카메라. nil이면 자동 선택(외장 우선).
    private var userSelectedID: String?
    private var isConfigured = false
    private var devicesObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var statusMessage: String? {
        switch status {
        case .idle:
            return "카메라 준비 중…"
        case .unauthorized:
            return "카메라 권한이 필요합니다.\n설정 > 개인정보 보호 및 보안 > 카메라에서 허용해 주세요."
        case .noCamera:
            return "사용할 수 있는 카메라가 없습니다.\nUSB-C 웹캠을 연결해 보세요."
        case .running:
            return nil
        case .interrupted(let message), .failed(let message):
            return message
        }
    }

    // MARK: - 공개 동작

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureAndStart() }
                } else {
                    DispatchQueue.main.async { self.status = .unauthorized }
                }
            }
        default:
            status = .unauthorized
        }
    }

    func selectCamera(id: String) {
        sessionQueue.async {
            self.userSelectedID = id
            self.useCamera(id: id)
            self.refreshStatus()
        }
    }

    // MARK: - 세션 구성 (sessionQueue)

    private func configureAndStart() {
        if !isConfigured {
            isConfigured = true
            session.beginConfiguration()
            // 풀레인지 YUV: Vision과 Core Image가 추가 변환 없이 바로 쓴다.
            let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(format) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            session.commitConfiguration()
            installObservers()
        }
        useCamera(id: userSelectedID)
        if currentInput != nil, !session.isRunning {
            session.startRunning()
        }
        refreshStatus()
    }

    private func useCamera(id: String?) {
        let devices = discovery.devices
        publishCameraList(devices)

        guard let device = devices.first(where: { $0.uniqueID == id }) ?? Self.preferredDevice(in: devices) else {
            if let input = currentInput {
                session.beginConfiguration()
                session.removeInput(input)
                session.commitConfiguration()
                currentInput = nil
            }
            DispatchQueue.main.async {
                self.currentDevice = nil
                self.selectedCameraID = nil
            }
            return
        }
        if currentInput?.device.uniqueID == device.uniqueID { return }

        session.beginConfiguration()
        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.status = .failed("이 카메라를 세션에 추가할 수 없습니다.") }
                return
            }
            session.addInput(input)
            currentInput = input
        } catch {
            session.commitConfiguration()
            let message = "카메라를 열 수 없습니다: \(error.localizedDescription)"
            DispatchQueue.main.async { self.status = .failed(message) }
            return
        }

        // 외장 카메라는 모든 프리셋을 지원하지 않을 수 있으므로 지원 여부를 확인한다.
        let presets: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .high]
        if let preset = presets.first(where: { device.supportsSessionPreset($0) && session.canSetSessionPreset($0) }) {
            session.sessionPreset = preset
        }

        // 버퍼는 카메라 고유 방향 그대로, 미러링 없이 받는다 (좌표계를 하나로 유지).
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        session.commitConfiguration()

        let multitasking = session.isMultitaskingCameraAccessSupported
        let format = Self.describeFormat(of: device)
        DispatchQueue.main.async {
            self.currentDevice = device
            self.selectedCameraID = device.uniqueID
            self.formatDescription = format
            self.multitaskingCameraSupported = multitasking
        }
    }

    private func devicesChanged() {
        let devices = discovery.devices
        let currentID = currentInput?.device.uniqueID
        let currentStillConnected = devices.contains { $0.uniqueID == currentID }
        let externalAvailable = devices.contains { $0.deviceType == .external }
        let usingExternal = currentInput?.device.deviceType == .external

        if !currentStillConnected {
            if userSelectedID == currentID { userSelectedID = nil }
            useCamera(id: userSelectedID)
        } else if externalAvailable, !usingExternal, userSelectedID == nil {
            // 웹캠을 새로 꽂으면 자동으로 전환
            useCamera(id: nil)
        } else {
            publishCameraList(devices)
        }

        if currentInput != nil, !session.isRunning {
            session.startRunning()
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let running = session.isRunning
        let hasInput = currentInput != nil
        DispatchQueue.main.async {
            if !hasInput {
                self.status = .noCamera
            } else if running, case .interrupted = self.status {
                // 중단 해제 알림이 오면 running으로 바뀐다
            } else if running {
                self.status = .running
            }
        }
    }

    private func installObservers() {
        devicesObservation = discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.sessionQueue.async { self.devicesChanged() }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] note in
            let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = rawReason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.status = .interrupted(Self.describe(reason))
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            self?.status = .running
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.status = .failed("카메라 오류: \(error?.localizedDescription ?? "알 수 없음")")
            self.sessionQueue.async {
                if self.currentInput != nil { self.session.startRunning() }
                self.refreshStatus()
            }
        })
    }

    private func publishCameraList(_ devices: [AVCaptureDevice]) {
        let options = devices.map {
            CameraOption(id: $0.uniqueID, name: Self.displayName(of: $0), isExternal: $0.deviceType == .external)
        }
        DispatchQueue.main.async { self.cameras = options }
    }

    // MARK: - 도우미

    private static func preferredDevice(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first { $0.deviceType == .external }
            ?? devices.first { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first
    }

    private static func displayName(of device: AVCaptureDevice) -> String {
        if device.deviceType == .external { return "외장: \(device.localizedName)" }
        switch device.position {
        case .front: return "전면: \(device.localizedName)"
        case .back: return "후면: \(device.localizedName)"
        default: return device.localizedName
        }
    }

    private static func describeFormat(of device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameDuration = device.activeVideoMinFrameDuration.seconds
        let fps = frameDuration > 0 ? Int((1 / frameDuration).rounded()) : 0
        return "\(dimensions.width)×\(dimensions.height) @ \(fps)fps"
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps?:
            return "다른 앱과 화면을 함께 쓰는 중이라 카메라가 멈췄습니다.\n(이 기기/앱 설정에서는 멀티태스킹 카메라가 허용되지 않음)"
        case .videoDeviceInUseByAnotherClient?:
            return "다른 앱이 카메라를 쓰고 있습니다."
        case .videoDeviceNotAvailableInBackground?:
            return "앱이 백그라운드로 가서 카메라가 멈췄습니다."
        case .videoDeviceNotAvailableDueToSystemPressure?:
            return "기기 온도·부하 때문에 카메라가 멈췄습니다."
        default:
            return "카메라가 일시 중단되었습니다."
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
