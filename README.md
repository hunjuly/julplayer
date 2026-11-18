# JulPlayer

SwiftUI와 AppKit으로 만든 macOS 동영상 플레이어입니다. libmpv와 FFmpeg로 MKV, MOV, MP4, AVI 등을 재생합니다. Finder에서 영상을 열면 같은 폴더의 영상이 재생목록에 들어가고, 재생이 끝나면 다음 파일로 넘어갑니다.

## 빌드

macOS 13 이상을 대상으로 하며 Apple Silicon에서 확인했습니다. Xcode Command Line Tools가 설치된 Mac에서 다음 명령을 실행합니다.

```sh
./build.sh
open ./JulPlayer.app
```

첫 빌드는 IINA 1.5.1 공식 배포본의 체크섬을 검증한 뒤 재생 라이브러리를 추출합니다. 이후 빌드는 캐시된 배포본을 사용합니다. [IINA 1.5.1](https://github.com/iina/iina/releases/tag/v1.5.1) · [라이브러리 고지](Resources/ThirdParty.txt)

## 조작

| 입력 | 동작 |
| --- | --- |
| Space | 재생 또는 일시정지 |
| ← / → | 10초 뒤로 / 앞으로 |
| ⌘← / ⌘→ | 이전 / 다음 영상 |
| ↑ / ↓ 또는 영상 위에서 두 손가락으로 위아래 스크롤 | 음량 조절 |
| M | 음소거 전환 |
| F / Enter | 전체 화면 전환 |
| P | 화면 속 화면(PiP) 전환 |
| 1 / 2 / 3 | 최소 창 / 영상 크기 50% / 100% |
| Backspace 또는 삭제 버튼 | 확인 후 현재 영상과 연결된 자막을 휴지통으로 이동 |
| ⌘Backspace | 현재 영상과 연결된 자막을 즉시 휴지통으로 이동 |
