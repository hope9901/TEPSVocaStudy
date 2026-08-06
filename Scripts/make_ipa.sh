#!/bin/bash
# Builds an unsigned .ipa for sideloading with SideStore/AltStore.
# SideStore re-signs the app with your own Apple ID on install, so no
# signing identity is needed here.
#
# Usage: ./Scripts/make_ipa.sh
# Output: build/TEPSVocaStudy.ipa

set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/hyg/Desktop/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

echo "▸ Release 빌드 (실기기용, 서명 없음)"
xcodebuild -project TEPSVocaStudy.xcodeproj \
    -scheme TEPSVocaStudy \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    build | grep -E "error:|warning: Signing|BUILD" || true

APP="build/Build/Products/Release-iphoneos/TEPSVocaStudy.app"
[ -d "$APP" ] || { echo "빌드 실패: $APP 없음"; exit 1; }

echo "▸ .ipa 패키징"
rm -rf build/Payload build/TEPSVocaStudy.ipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry TEPSVocaStudy.ipa Payload)
rm -rf build/Payload

echo "✓ 완료: $(pwd)/build/TEPSVocaStudy.ipa"
du -h build/TEPSVocaStudy.ipa | cut -f1
