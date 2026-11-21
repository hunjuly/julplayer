#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
bundle="${1:-$PWD/JulPlayer.app}"
contents="$bundle/Contents"
work=$(mktemp -d /private/tmp/julplayer-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
if [[ -f Engine/Frameworks/libmpv.2.dylib ]]; then
    cp -p Engine/Frameworks/*.dylib "$contents/Frameworks/"
else
    ./scripts/copy-frameworks.sh "$contents/Frameworks"
fi
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -Wno-deprecated-declarations -I Engine/include -c Engine/VideoEngine.m -o "$work/engine.o"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" -import-objc-header Engine/VideoEngine.h \
   Sources/*.swift "$work/engine.o" "$contents/Frameworks/libmpv.2.dylib" \
   -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -framework OpenGL -framework IOSurface -o "$contents/MacOS/JulPlayer"
cp Resources/Info.plist "$contents/Info.plist"
rm -f "$contents/Resources/Lake.mkv" "$contents/Resources/lake.jpg"
cp Resources/*.icns Resources/ThirdParty.txt Resources/LibraryCredits.rtf "$contents/Resources/"
# The libmpv OpenGL renderer loads fixed shaders and has no tunable shader parameters.
for transfer in pq srgb; do
    for gain in {2..10}; do
        sed -e "s/@transfer@/$transfer/g" -e "s/@gain@/$gain.0/g" Engine/Brightness.glsl.in \
            > "$contents/Resources/Brightness-$transfer-$gain.glsl"
    done
done
codesign --force --sign - "$bundle"
