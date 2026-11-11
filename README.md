# 후면캠 (RearCam) — 고장 난 아이폰 후면 카메라용 카메라 앱

후면 광각(1×) 카메라가 고장 나서 **초광각(0.5×)만 살아 있는** 아이폰에서 정상적인 사진과 동영상을 찍기 위한 iOS 앱입니다.

## 증상 분석

| 관찰 | 해석 |
|---|---|
| 기본 카메라 앱에서 후면/플래시가 안 되는 것처럼 보임 | 기본 앱은 광각(1×) 카메라로 시작하는데, 그 모듈이 고장 남 |
| 배율 버튼 중 0.5×만 동작, 0.5×에서 확대하면 1×처럼 보임 | 초광각 모듈은 정상. 기본 앱의 1×는 광각 모듈로 전환하려다 실패함 |
| 사진은 무지개색 왜곡, 길게 눌러 찍은 영상은 정상 | 사진 처리 경로(Smart HDR / Deep Fusion 등 다중 프레임 합성, 가상 듀얼 카메라)가 깨진 데이터를 쓰고 있음. 동영상 경로는 초광각 센서 데이터를 그대로 써서 깨끗함 |

## 해결 방법 (앱이 하는 일)

1. **초광각 물리 카메라(`builtInUltraWideCamera`)만 직접 연결합니다.** 기본 앱처럼 가상 듀얼 카메라를 쓰지 않아서 고장 난 광각 모듈을 아예 깨우지 않습니다.
2. **사진도 동영상 경로로 찍습니다.** `AVCaptureVideoDataOutput`에서 프레임 한 장을 떠서 HEIF/JPEG로 저장합니다. 영상이 깨끗하게 나왔던 바로 그 경로라서 무지개 왜곡이 생기지 않습니다. 사진 모드에서는 4:3 최대 해상도(보통 4032×3024)를 쓰고, 어두운 곳에서는 프레임레이트를 15fps까지 낮춰 노출 시간을 확보합니다.
3. **1×, 2×는 초광각 디지털 줌(2배, 4배)입니다.** 버튼은 `0.5× / 1×`로 표시되고 두 손가락으로 최대 5×까지 확대할 수 있습니다.
4. **동영상**은 같은 프레임을 `AVAssetWriter`로 HEVC `.mov` 파일에 기록합니다. 4K30, 1080p30, 1080p60을 고를 수 있고 손떨림 보정과 마이크 녹음을 지원합니다.
5. 기타
   - 탭하면 그 위치로 노출을 맞춥니다. 위아래로 끌면 밝기(EV)를 조절합니다.
   - 가속도계로 기기 방향을 읽어서 가로로 찍어도 사진과 영상이 올바른 방향으로 저장됩니다.
   - 전면 카메라 전환, 격자, 셔터음, 손전등을 시도하는 버튼이 있습니다. 플래시 하드웨어가 고장 났다면 손전등은 켜지지 않을 수 있습니다.
   - 설정 화면에 **진단 정보**(카메라 목록, 현재 포맷, 지원 포맷)가 있습니다.
   - 설정에서 사진 방식을 "시스템 사진(테스트용)"으로 바꾸면 `AVCapturePhotoOutput`(속도 우선)으로도 찍어 볼 수 있습니다. 비교용입니다.

> 초광각 카메라는 초점이 고정되어 있습니다. 1×, 2× 화질은 원래 1× 카메라보다 떨어집니다. 이건 하드웨어의 물리적 한계입니다.

## 웹앱 버전 (아이폰만으로 사용, 설치 불필요)

컴퓨터가 없다면 `web/` 폴더의 웹앱을 쓰세요. Safari로 링크를 열기만 하면 됩니다.

- 주소: `https://c7chord.github.io/broken_iphone_camera/` (GitHub Pages 배포 후)
- Safari 공유 버튼 → **홈 화면에 추가**를 누르면 앱처럼 아이콘이 생깁니다.
- 카메라 목록에서 **초광각(Ultra Wide)** 카메라를 찾아 직접 엽니다. 고장 난 광각 카메라는 열지 않습니다. 자동으로 못 찾으면 설정에서 고를 수 있습니다.
- 사진은 영상 스트림의 프레임을 떠서 JPEG로 저장합니다. 동영상은 MediaRecorder로 녹화합니다(MP4, 소리 포함).
- 찍은 것은 웹앱 안에 임시로 보관됩니다. 촬영 직후 뜨는 **사진 앱에 저장** 버튼이나 왼쪽 아래 미리보기를 누르고, 공유 창에서 **"이미지 저장"/"비디오 저장"**을 고르세요.
- 촬영하면 바로 공유 창이 떠서 **"이미지 저장"** 한 번이면 사진 앱에 들어갑니다. iOS는 웹페이지가 사진 앱에 직접 저장하는 것을 허용하지 않아서 이 한 번의 탭은 꼭 필요합니다.
- 화질: Safari에서 받을 수 있는 가장 큰 해상도를 받습니다. 4:3이 작으면 4K로 받아 4:3으로 자릅니다. Safari가 하드웨어 줌을 지원하지 않으면 1×는 화면을 잘라서 만드는데, 이때는 고품질로 키우고 선명하게 보정합니다. 화면 위쪽에 `HW줌`/`SW줌`과 해상도가 표시됩니다.
- 네이티브 앱보다 화질이 떨어질 수 있고, 탭해서 노출 맞추기는 지원하지 않습니다.

### GitHub Pages 배포 방법 (처음 한 번)

1. 저장소를 Public으로 바꿉니다. 무료 플랜에서는 공개 저장소만 Pages를 쓸 수 있습니다.
2. **Settings → Pages → Build and deployment → Source**를 **GitHub Actions**로 바꿉니다.
3. `web/`이 들어 있는 브랜치를 `main`에 합칩니다. 그러면 `.github/workflows/pages.yml`이 자동으로 배포합니다. 이미 `main`에 있다면 **Actions → Deploy web app to GitHub Pages → Run workflow**를 누릅니다.

## 네이티브 앱 설치 방법

App Store에 올라간 앱이 아니므로 직접 설치해야 합니다. 둘 중 하나를 고르세요.

### A. Mac + Xcode (가장 쉬움, 무료 Apple ID로 가능)

1. Mac에 Xcode(최신 버전)를 설치합니다.
2. 이 저장소를 받아서 `RearCam.xcodeproj`를 엽니다.
3. 왼쪽에서 **RearCam** 프로젝트를 고르고 **TARGETS > RearCam > Signing & Capabilities**로 갑니다.
   - **Team**: 내 Apple ID를 선택합니다. 없으면 Xcode > Settings > Accounts에서 추가합니다.
   - **Bundle Identifier**: `com.example.rearcam`을 겹치지 않는 값으로 바꿉니다. (예: `com.내이름.rearcam`)
4. 아이폰을 USB로 연결하고, 위쪽 기기 목록에서 아이폰을 고른 뒤 ▶︎(Run)를 누릅니다.
5. 아이폰에서 **설정 > 개인정보 보호 및 보안 > 개발자 모드**를 켭니다. 처음 한 번만 하면 됩니다.
6. 처음 실행할 때 "신뢰하지 않는 개발자"가 뜨면 **설정 > 일반 > VPN 및 기기 관리**에서 내 Apple ID를 신뢰합니다.

무료 Apple ID로 설치한 앱은 **7일 후 만료**됩니다. 만료되면 Xcode에서 다시 Run 하면 됩니다. 유료 개발자 계정이면 1년간 유지됩니다.

### B. Mac 없이 (Windows PC + Sideloadly/AltStore)

1. GitHub 저장소의 **Actions** 탭 → **Build unsigned IPA** → 최근 성공한 실행 → **Artifacts**에서 `RearCam-unsigned-ipa`를 받아 압축을 풉니다.
2. [Sideloadly](https://sideloadly.io) 또는 AltStore를 PC에 설치합니다.
3. 아이폰을 연결하고, IPA 파일과 Apple ID를 넣어 설치합니다. 도구가 Apple ID로 서명해 줍니다.
4. 위 A의 5, 6번처럼 개발자 모드를 켜고 Apple ID를 신뢰합니다.

## 프로젝트 구조

```
RearCam.xcodeproj/          Xcode 프로젝트 (iOS 17+, SwiftUI)
RearCam/
  RearCamApp.swift          앱 진입점
  ContentView.swift         카메라 UI (미리보기, 줌, 셔터, 제스처)
  CameraManager.swift       AVFoundation 카메라 엔진 (초광각 전용, 프레임 캡처, 녹화)
  CameraTypes.swift         모드/화질 정의, 포맷 선택 로직
  MovieRecorder.swift       AVAssetWriter 동영상 기록
  PhotoLibrary.swift        사진 앱 저장, HEIF/JPEG 인코딩
  OrientationMonitor.swift  가속도계 기반 기기 방향
  CameraPreview.swift       AVCaptureVideoPreviewLayer 래퍼
  SettingsView.swift        설정, 진단 정보
web/                        웹앱 (index.html, app.js, style.css, manifest.json)
.github/workflows/build.yml macOS에서 빌드해서 서명 안 된 IPA를 만드는 CI
.github/workflows/pages.yml 웹앱을 GitHub Pages로 배포
```

## 문제가 생기면

- 사진에 여전히 무지개색이 보이면 설정에서 사진 방식이 **"영상 프레임 캡처 (권장)"**인지 확인하세요.
- 설정 > 진단 정보 > **복사**를 눌러 그 내용을 이슈에 붙여 주시면 원인을 찾는 데 도움이 됩니다.
