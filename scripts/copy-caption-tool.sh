#!/bin/zsh
set -euo pipefail
contents=${1:A}
version=0.8.1
case $(uname -m) in
    arm64)
        wheel=imageio_ffmpeg-${version}-py3-none-macosx_12_0_arm64.whl
        prefix=2b/47/9f9b654f853598bae0850fa22bba168103e45d31b5a2a893ed474f28d54a
        digest=5636d691e36e5274b13fe38182b1f627b2e35dcecc63944012c2470f9484fc45 ;;
    x86_64)
        wheel=imageio_ffmpeg-${version}-py3-none-macosx_10_13_x86_64.whl
        prefix=da/24/2c3a7c69453bfb8374ddbbb5007346bad4a4247bc86882f3521cd615f929
        digest=9538a10e598257263b5de1a1c1b86e7603417bc219245b1e279b452e5e48cc20 ;;
    *) print -u2 "지원하지 않는 Mac 아키텍처입니다."; exit 1 ;;
esac
cache="$HOME/Library/Caches/JulPlayer"
mkdir -p "$cache" "$contents/Helpers" "$contents/Resources"
archive="$cache/$wheel"
verify() { [[ -f "$1" && "$(shasum -a 256 "$1" | awk '{print $1}')" == "$digest" ]]; }
if ! verify "$archive"; then
    partial=$(mktemp "$cache/caption-tool.XXXXXX")
    trap 'rm -f "$partial"' EXIT
    curl --fail --location --retry 3 "https://files.pythonhosted.org/packages/$prefix/$wheel" -o "$partial"
    verify "$partial" || { print -u2 "자막 도구 다운로드의 체크섬이 일치하지 않습니다."; exit 1; }
    mv -f "$partial" "$archive"
fi
unzip -p "$archive" 'imageio_ffmpeg/binaries/ffmpeg-*' > "$contents/Helpers/ffmpeg"
chmod 755 "$contents/Helpers/ffmpeg"
codesign --force --sign - "$contents/Helpers/ffmpeg"
unzip -p "$archive" '*/licenses/LICENSE' > "$contents/Resources/ImageIO-LICENSE.txt"
