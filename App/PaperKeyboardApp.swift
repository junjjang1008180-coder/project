import SwiftUI

@main
struct PaperKeyboardApp: App {
    private let model = ScannerModel()

    var body: some Scene {
        WindowGroup {
            ScannerView(camera: model.camera, processor: model.processor)
        }
    }
}

/// 카메라와 프레임 처리기를 한 번만 만들어 연결한다.
final class ScannerModel {
    let layout: PaperLayout
    let camera = CameraManager()
    let processor: FrameProcessor

    init() {
        do {
            layout = try PaperLayout.load(in: .main)
        } catch {
            // 레이아웃 JSON은 앱 번들에 포함되어 있어야 한다 (단위 테스트로도 검증).
            fatalError("기본 레이아웃을 불러오지 못했습니다: \(error.localizedDescription)")
        }
        processor = FrameProcessor(layout: layout)
        camera.onFrame = { [processor] pixelBuffer in
            processor.process(pixelBuffer: pixelBuffer)
        }
    }
}
