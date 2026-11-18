#!/bin/zsh
set -euo pipefail

destination="${1:A}"
version=1.5.1
digest=f414507ec60bcfeda3a9f539f74470253e31b619d031e7a9e9a71519da1598cd
filename="IINA.v${version}.dmg"
cache="$HOME/Library/Caches/JulPlayer"
archive="$cache/$filename"
mkdir -p "$cache" "$destination"
scratch=$(mktemp -d "$cache/build.XXXXXX")
mountpoint="$scratch/image"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mountpoint" -quiet || return 1
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT

matches_digest() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$digest" ]]
}

if ! matches_digest "$archive"; then
    curl --fail --location --retry 3 --output "$scratch/$filename" \
        "https://github.com/iina/iina/releases/download/v$version/$filename"
    if ! matches_digest "$scratch/$filename"; then
        print -u2 "IINA 다운로드의 SHA-256 체크섬이 일치하지 않습니다."
        exit 1
    fi
    mv -f "$scratch/$filename" "$archive"
fi

mkdir "$mountpoint"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$archive" -quiet
mounted=true
architecture=$(uname -m)
for library in "$mountpoint/IINA.app/Contents/Frameworks"/*.dylib; do
    [[ "${library:t}" == libswift_Concurrency.dylib ]] && continue
    xcrun lipo "$library" -thin "$architecture" -output "$destination/${library:t}"
done
