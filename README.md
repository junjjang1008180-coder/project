# 종이 키보드 (Paper Keyboard)

인쇄한 종이 키보드를 카메라로 비추면, 손가락으로 누른 키를 인식해 아이패드의 모든 앱에 텍스트로 입력하는 프로젝트.

## 구조

키보드 익스텐션 안에서는 카메라를 쓸 수 없으므로(Apple 정책, Full Access와 무관) **메인 앱이 인식하고 키보드 익스텐션은 입력만 전달**한다.

```
[종이 키보드] ─카메라(USB-C 웹캠)─▶ [메인 앱: 인식]
                                      QR 마커 → 원근 보정 → (3단계) 손끝 → 키 이벤트
                                          │ App Group
                                          ▼
                       [키보드 익스텐션: 입력 전달] → 메모/사파리/카톡 …
```

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 익스텐션 카메라 / Full Access 조사 | 완료 |
| 2 | 카메라 프리뷰 + 종이 원근 보정 | **현재** |
| 3 | 키 격자 매핑 + 손가락 터치 인식 | |
| 4 | 키보드 익스텐션 타겟 추가 | |
| 5 | 인식 결과를 익스텐션으로 전달, 실제 앱 입력 | |
| 6 | 특수키·전체 흐름 다듬기 | |

## 폴더

- `App/` — 메인 앱 (카메라, Vision 마커 검출, 화면)
- `Shared/` — 앱·익스텐션·테스트가 함께 쓰는 순수 로직 (레이아웃 모델, 호모그래피, 종이 추적)
- `Layouts/` — 기준 템플릿 JSON + 인쇄용 PDF (둘 다 `tools/paper_template.py` 가 생성)
- `Tests/` — 단위 테스트 (시뮬레이터에서 실행, 카메라 불필요)
- `project.yml` — XcodeGen 프로젝트 정의, `Config/Signing.xcconfig` — 서명 설정

## 빌드 (Mac + Xcode, 무료 Apple ID로 충분)

유료 개발자 계정($99/년)은 App Store 배포할 때만 필요하다. 무료 Apple ID(Personal Team)로 내 아이패드에 설치할 수 있고,
이 프로젝트에 필요한 App Groups·백그라운드 모드도 무료 계정에서 쓸 수 있다.
대신 설치한 앱은 **7일 뒤 만료**되므로 Xcode에서 다시 실행해 주면 된다.

1. Mac App Store에서 Xcode 설치 → Xcode > Settings > Accounts 에서 Apple ID로 로그인.
2. XcodeGen 설치 (Homebrew가 없으면 https://brew.sh 의 설치 명령을 먼저 실행):

```bash
brew install xcodegen
```

3. 이 폴더에서 프로젝트를 만들고 연다:

```bash
xcodegen generate && open PaperKeyboard.xcodeproj
```

4. PaperKeyboard 타겟 > Signing & Capabilities > Team 에서 "(이름) (Personal Team)" 선택.
5. 아이패드를 케이블로 Mac에 연결 → "이 컴퓨터를 신뢰" → 아이패드 설정 > 개인정보 보호 및 보안 > **개발자 모드** 켜기(재시동).
6. Xcode 위쪽에서 기기를 내 아이패드로 고르고 ▶ 실행. 처음에는 아이패드 설정 > 일반 > VPN 및 기기 관리에서 개발자 앱을 신뢰해야 한다.

아이패드 USB-C 포트가 하나뿐이라 웹캠과 Mac 케이블을 동시에 꽂을 수 없다. 설치 후 케이블을 빼고 웹캠을 꽂은 다음
홈 화면에서 앱을 실행하면 된다. 또는 Xcode > Window > Devices and Simulators 에서 "Connect via network"를 켜 두면
케이블 없이 실행·디버깅할 수 있다.

단위 테스트: Xcode에서 ⌘U, 또는 GitHub에 푸시하면 `.github/workflows/ios.yml` 이 macOS 러너에서 빌드·테스트한다.

## 종이 키보드 인쇄

`Layouts/pk1-qwerty-a4.pdf` 를 A4 가로로 인쇄한다 (앱의 "인쇄용 종이 키보드" 버튼으로 아이패드에서 바로 인쇄 가능).
배율은 자동 보정되므로 상관없지만 가로세로 비율은 유지해야 한다. 레이아웃을 바꾸려면:

```bash
pip install reportlab segno
```

```bash
python tools/paper_template.py
```

## 2단계 테스트 방법

1. USB-C 웹캠을 아이패드에 연결하고, 책상 위 종이를 **위에서 비스듬히 내려다보게** 둔다 (높이 35~50cm).
2. 종이가 **화면 폭의 절반 이상**을 차지하게 맞춘다. 1080p 기준 종이 폭 850px 이상이면 QR 6개가 안정적으로 검출된다(시뮬레이션).
3. 확인할 것:
   - 왼쪽 위 배지가 초록색 "추적 중"이 되는지
   - 프리뷰의 노란 격자가 인쇄된 키 위에 정확히 겹치는지
   - 오른쪽 "원근 보정된 종이"가 반듯하게 펴지고 노란 칸이 키와 맞는지
   - 손으로 아래쪽 QR 2개를 가려도 주황색 "마지막 값 유지"로 격자가 그대로 있는지
   - "멀티태스킹 카메라" 값, 그리고 메모 앱과 화면을 나눴을 때 카메라가 멈추는지 (5단계 구조 결정에 필요)
