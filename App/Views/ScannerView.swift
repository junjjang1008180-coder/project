import SwiftUI
import UIKit

/// 2단계 프로토타입 화면: 카메라 프리뷰 + 원근 보정 결과 + 진단 정보.
struct ScannerView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var processor: FrameProcessor
    @State private var copiedDiagnostics = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HStack(spacing: 0) {
                    previewArea
                    Divider()
                    ScrollView { sidePanel.padding() }
                        .frame(width: 360)
                }
            } else {
                VStack(spacing: 0) {
                    previewArea
                        .frame(height: geometry.size.height * 0.5)
                    Divider()
                    ScrollView { sidePanel.padding() }
                }
            }
        }
        .onAppear {
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: camera.selectedCameraID) {
            // 다른 카메라의 보정값은 의미가 없으므로 처음부터 다시 찾는다.
            processor.reset()
        }
    }

    // MARK: - 프리뷰

    private var previewArea: some View {
        ZStack {
            Color.black
            CameraPreview(session: camera.session, device: camera.currentDevice, snapshot: processor.snapshot)
            if let message = camera.statusMessage {
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            stateBadge.padding(12)
        }
    }

    private var stateBadge: some View {
        let (text, color) = stateTextAndColor
        return Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
    }

    private var stateTextAndColor: (String, Color) {
        let s = processor.snapshot
        if s.isLocked { return ("보정 고정됨", .blue) }
        switch s.trackerState {
        case .searching: return ("종이 찾는 중", .red)
        case .tracking: return ("추적 중", .green)
        case .holding:
            let age = s.secondsSinceUpdate.map { String(format: " %.0f초", $0) } ?? ""
            return ("마커 가려짐 · 마지막 값 유지\(age)", .orange)
        }
    }

    // MARK: - 측면 패널

    private var sidePanel: some View {
        let s = processor.snapshot
        let layout = processor.layout
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("카메라") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("카메라", selection: Binding(
                        get: { camera.selectedCameraID ?? "" },
                        set: { camera.selectCamera(id: $0) }
                    )) {
                        if camera.cameras.isEmpty {
                            Text("없음").tag("")
                        }
                        ForEach(camera.cameras) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("형식", value: camera.formatDescription)
                    LabeledContent("처리 FPS", value: String(format: "%.0f", s.fps))
                    LabeledContent("멀티태스킹 카메라", value: camera.multitaskingCameraSupported ? "지원" : "미지원")
                }
            }

            GroupBox("종이 인식") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("마커", value: s.isLocked ? "고정 중 (검출 안 함)" : "\(s.markers.count) / \(layout.markers.count)")
                    if !s.missingMarkerIDs.isEmpty {
                        Text("안 보이는 QR: \(Self.shortNames(s.missingMarkerIDs))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("재투영 오차", value: s.reprojectionErrorPx.map { String(format: "%.2f px", $0) } ?? "-")
                    LabeledContent("검출 시간", value: s.detectionMs.map { String(format: "%.0f ms", $0) } ?? "-")
                    LabeledContent("보조 검출", value: "\(s.extraPasses)회")
                    if let reason = s.rejectedReason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Toggle("보정 고정", isOn: $processor.isLocked)
                        .disabled(s.paperQuad == nil)
                    Button("다시 찾기") { processor.reset() }
                }
            }

            GroupBox("원근 보정된 종이") {
                RectifiedPaperView(image: processor.rectifiedImage, layout: layout)
                Text("노란 칸이 인쇄된 키와 겹치면 보정이 맞는 것입니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let url = Bundle.main.url(forResource: PaperLayout.defaultResourceName, withExtension: "pdf") {
                ShareLink(item: url) {
                    Label("인쇄용 종이 키보드 (PDF)", systemImage: "printer")
                }
            }

            Button {
                UIPasteboard.general.string = diagnosticsText
                copiedDiagnostics = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copiedDiagnostics = false }
            } label: {
                Label(copiedDiagnostics ? "복사됨 — 채팅에 붙여 넣어 주세요" : "진단 정보 복사",
                      systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
            }
        }
    }

    // MARK: - 진단 정보

    /// 문제가 생겼을 때 그대로 붙여 넣으면 원인을 알 수 있도록 현재 상태를 글로 정리한다.
    private var diagnosticsText: String {
        let s = processor.snapshot
        let state: String
        if s.isLocked {
            state = "고정됨"
        } else {
            switch s.trackerState {
            case .searching: state = "찾는 중"
            case .tracking: state = "추적 중"
            case .holding: state = "유지 중"
            }
        }
        func number(_ value: Double?, _ format: String) -> String {
            value.map { String(format: format, $0) } ?? "-"
        }
        let cameraName = camera.selectedCameraName ?? "-"
        let statusDetail = camera.statusMessage.map { " — " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
        let multitasking = camera.multitaskingCameraSupported ? "지원" : "미지원"
        let fps = String(format: "%.0f", s.fps)
        let missing = s.missingMarkerIDs.isEmpty ? "-" : Self.shortNames(s.missingMarkerIDs)
        let lines = [
            "[종이 키보드 진단]",
            "기기: \(Self.deviceModelIdentifier) / iPadOS \(UIDevice.current.systemVersion)",
            "카메라: \(cameraName) (\(camera.formatDescription))",
            "카메라 상태: \(camera.statusSummary)\(statusDetail)",
            "멀티태스킹 카메라: \(multitasking)",
            "처리 FPS: \(fps) / 검출 시간: \(number(s.detectionMs, "%.0f ms")) / 보조 검출: \(s.extraPasses)회",
            "이미지: \(Int(s.imageSize.width))×\(Int(s.imageSize.height))",
            "추적: \(state) / 마커 \(s.markers.count)개 / 안 보임: \(missing)",
            "재투영 오차: \(number(s.reprojectionErrorPx, "%.2f px")) / 거부 사유: \(s.rejectedReason ?? "-")",
        ]
        return lines.joined(separator: "\n")
    }

    /// "PK1-TL" → "TL"
    private static func shortNames(_ ids: [String]) -> String {
        ids.map { $0.split(separator: "-").last.map(String.init) ?? $0 }.joined(separator: ", ")
    }

    /// 예: "iPad16,3"
    private static var deviceModelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// 보정된 종이 이미지 위에 템플릿의 키 영역을 겹쳐 그린다.
struct RectifiedPaperView: View {
    let image: CGImage?
    let layout: PaperLayout

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Text("종이를 찾는 중…").foregroundStyle(.secondary))
            }
            Canvas { context, size in
                let sx = size.width / CGFloat(layout.paper.width)
                let sy = size.height / CGFloat(layout.paper.height)
                for key in layout.keys {
                    let f = key.frame
                    let rect = CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.yellow), lineWidth: 1)
                }
                for marker in layout.markers {
                    let c = marker.centerPoint
                    let half = CGFloat(marker.size) / 2
                    let rect = CGRect(x: (c.x - half) * sx, y: (c.y - half) * sy,
                                      width: half * 2 * sx, height: half * 2 * sy)
                    context.stroke(Path(rect), with: .color(.cyan), lineWidth: 1)
                }
            }
        }
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
