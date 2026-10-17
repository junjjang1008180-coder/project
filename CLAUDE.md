# CLAUDE.md — 종이 키보드 프로젝트 맥락

인쇄한 종이 키보드를 카메라로 인식해 iPad의 모든 앱에 텍스트를 입력하는 프로젝트. 개요·빌드 방법은 README.md 참고.

## 사용자와 일하는 방식
- 한국어로 소통한다. iOS 개발 경험이 많지 않으므로 Xcode 서명·설치 절차는 단계별로 풀어서 안내한다.
- **6단계 계획을 단계별로 진행하고, 각 단계 끝에 결과를 보여 준 뒤 확인을 받고 다음 단계로 넘어간다.**
- 직접 코드를 고치기 어려워하므로, 넘기기 전에 실행 중에 생길 문제까지 꼼꼼히 검토한다.
- 문제가 생기면 앱의 "진단 정보 복사" 결과를 받아 원인을 찾는다.

## 장비·계정
- iPad 11인치 M4, iPadOS 26. 카메라는 USB-C 외장 웹캠(UVC).
- iPad의 USB-C 포트가 하나뿐이다. 설치는 케이블로 하고, 실행할 때는 웹캠을 꽂는다. Xcode의 "Connect via network"를 켜면 케이블 없이 디버깅할 수 있다.
- **유료 개발자 계정 없음 → 무료 Apple ID(Personal Team).** 설치한 앱은 7일 뒤 만료되고, 기기에 설치할 수 있는 앱은 3개까지다. App Groups와 백그라운드 모드는 무료 계정에서도 쓸 수 있다.
- 번들 ID 앞부분: `io.github.junjjang1008180` (Config/Signing.xcconfig).

## 핵심 결정 (1단계 조사 결과)
- 키보드 익스텐션 안에서는 **카메라를 쓸 수 없다**(Full Access와 무관, Apple 공식). 익스텐션 메모리 한도는 약 48~60MB.
- 그래서 **메인 앱이 카메라로 인식하고, 키보드 익스텐션은 App Group으로 받은 이벤트를 `textDocumentProxy.insertText`로 입력만** 한다.
- 실시간 입력을 하려면 메인 앱이 다른 앱과 화면을 나눠 쓰는 동안에도 카메라가 켜져 있어야 한다. 이 경우 `AVCaptureSession.isMultitaskingCameraAccessSupported`가 true여야 한다(iOS 18 이상 SDK에서는 `UIBackgroundModes`에 `voip` 필요. App Store 가이드라인 2.5.4 위반 소지).
  안 되면 대안은 "메인 앱에서 쳐서 대기열에 쌓고, 키보드에서 한꺼번에 입력"하는 방식이다.
- **미정:** 배포 목표(개인용 vs App Store). 5단계 전에 사용자에게 확인해야 한다.
- 키보드 익스텐션 규칙(App Store 가이드라인 4.4.1): Full Access 없이도 동작해야 하고(화면 키 필요), 다음 키보드로 넘어가는 키가 있어야 하고, 다른 앱을 실행하면 안 된다.

## 인식 방식
- 종이 템플릿: `tools/paper_template.py`가 `Layouts/pk1-qwerty-a4.json`(인식 기준)과 `.pdf`(인쇄용)를 함께 생성한다. 좌표는 mm 단위, 원점은 종이 좌상단, y는 아래로 증가한다.
- QR 마커 6개(PK1-TL/TC/TR/BL/BC/BR, 26mm, QR v1). 4개 이상 보이면 정규화 DLT로 호모그래피를 계산한다(템플릿 mm → 이미지 정규화 좌표, 좌상단 원점).
- 위쪽 3개처럼 한 줄에 몰린 마커 조합은 해가 하나로 정해지지 않는다. `Geometry.hasFourPointsInGeneralPosition`으로 반드시 거른다(거르지 않으면 잡음 때문에 엉터리 해가 나온다).
- 재투영 오차 허용치는 이미지 대각선의 1.5%다(광각 웹캠의 렌즈 왜곡 대비).
- 카메라 버퍼는 회전·미러링 없이 쓴다. 화면 표시는 `AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)`로 변환한다.
- 시뮬레이션(zxing-cpp) 결과: 1080p에서 종이 폭이 850px 이상이면 마커 6개를 안정적으로 검출하고, 키 중심 오차는 약 1px이다.

## 진행 상황
| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 익스텐션 카메라·Full Access 조사 | 완료 |
| 2 | 카메라 프리뷰 + 종이 원근 보정 | 코드 완료(PR #1 머지), CI 통과. **iPad 실기기 확인 대기** |
| 3 | 손가락 터치 인식 + 오탐지 방지(디바운스) | |
| 4 | 키보드 익스텐션 타겟 추가, 등록·활성화 확인 | |
| 5 | 인식 결과를 익스텐션으로 전달, 메모 앱 등에서 입력 | |
| 6 | 특수키(스페이스/엔터/백스페이스/Shift/한영) 다듬기 | |

**바로 다음 할 일:** 맥에서 빌드해 iPad에 설치하고, README의 "2단계 테스트 방법"대로 확인한다. 특히 "멀티태스킹 카메라" 값과 화면을 나눴을 때 카메라가 멈추는지 기록한다.

## 개발 메모
- 프로젝트 파일은 XcodeGen으로 만든다(`xcodegen generate`). `.xcodeproj`와 `App/Info.plist`는 생성물이라 git에 넣지 않는다. Info.plist 내용은 `project.yml`에서 고친다.
- Swift 5 언어 모드, 배포 대상 iOS 17.0, iPad 전용.
- `.github/workflows/ios.yml`이 푸시마다 Xcode 16 / 26 / 최신 버전으로 빌드하고 단위 테스트를 돌린다.
- 단위 테스트(`Tests/`)는 `Shared/`의 순수 로직만 다루므로 시뮬레이터에서 돈다.
