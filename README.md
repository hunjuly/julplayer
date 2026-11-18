# JulPlayer

MKV, MOV, MP4, AVI 등을 지원하는 macOS용 동영상 플레이어입니다. Finder에서 영상을 열면 같은 폴더의 영상으로 재생목록을 만듭니다. 재생이 끝나면 다음 파일로 넘어갑니다.

## 빌드 및 실행

macOS 13 이상과 Xcode Command Line Tools가 필요합니다. 첫 빌드에서 재생 엔진인 libmpv를 자동으로 내려받습니다.

```sh
git clone https://github.com/hunjuly/julplayer.git
cd julplayer
./build.sh
open ./JulPlayer.app
```

## 주요 조작

| 입력 | 동작 |
| --- | --- |
| `Space` | 재생 / 일시 정지 |
| `←` / `→` | 10초 뒤로 / 앞으로 |
| `⌘←` / `⌘→` | 이전 / 다음 영상 |
| `↑` / `↓` 또는 트랙패드 위아래 스크롤 | 음량 조절 |
| `F` 또는 `Enter` | 전체 화면 전환 |
| `P` | 화면 속 화면(PiP) 전환 |
| `Backspace` / `⌘Backspace` | 현재 영상과 연결된 자막을 휴지통으로 이동 (확인 후 / 즉시) |
