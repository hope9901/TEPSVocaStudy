#!/bin/bash
# 무료 Apple 계정으로 서명한 앱의 7일 수명을 되돌리는 주간 갱신 스크립트.
#
# 왜 프로파일을 먼저 지우는가: Xcode 는 캐시된 프로비저닝 프로파일이 만료되기
# 전까지 그대로 재사용한다. 수명이 2일 남은 프로파일로 빌드하면 앱도 이틀 뒤에
# 죽는다. 먼저 지우면 Apple 이 새 7일짜리를 발급한다.
#
# 앱은 삭제하지 않고 덮어 설치한다. 학습 진도는 앱 Documents 안에 있다.
#
# 사용법:
#   ./Scripts/refresh_app.sh              # 기기 자동 탐색
#   UDID=00008110-000... ./Scripts/refresh_app.sh
#   ./Scripts/refresh_app.sh --status     # 빌드 없이 현재 만료일만 확인

set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/hyg/Desktop/Xcode.app/Contents/Developer}"
[ -d "$DEVELOPER_DIR" ] || DEVELOPER_DIR="$(xcode-select -p)"
export DEVELOPER_DIR

BUILD_DIR="build/refresh"
APP="$BUILD_DIR/Build/Products/Debug-iphoneos/TEPSVocaStudy.app"

show_expiry() {
    local app="$1"
    [ -f "$app/embedded.mobileprovision" ] || { echo "  (프로파일 없음)"; return; }
    local plist; plist="$(mktemp)"
    security cms -D -i "$app/embedded.mobileprovision" > "$plist" 2>/dev/null || return
    echo "  이름   : $(plutil -extract Name raw -o - "$plist" 2>/dev/null || echo '?')"
    echo "  발급   : $(plutil -extract CreationDate raw -o - "$plist" 2>/dev/null || echo '?')"
    echo "  만료   : $(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || echo '?')"
    rm -f "$plist"
}

if [ "${1:-}" = "--status" ]; then
    echo "▸ 마지막 빌드의 프로파일"
    show_expiry "$APP"
    echo
    echo "▸ 서명 인증서"
    security find-identity -v -p codesigning | sed 's/^/  /'
    exit 0
fi

echo "▸ 1/4 캐시된 프로비저닝 프로파일 삭제"
PROFILES="$HOME/Library/MobileDevice/Provisioning Profiles"
if [ -d "$PROFILES" ]; then
    COUNT=$(find "$PROFILES" -type f | wc -l | tr -d ' ')
    find "$PROFILES" -type f -delete
    echo "  $COUNT 개 삭제 — Xcode 가 새 7일짜리를 발급합니다"
else
    echo "  캐시 폴더 없음 (건너뜀)"
fi

echo "▸ 2/4 연결된 기기 확인"
if [ -z "${UDID:-}" ]; then
    DEVJSON="$(mktemp)"
    xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true
    UDID="$(python3 - "$DEVJSON" <<'PY' || true
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(1)
for d in devices:
    conn = d.get("connectionProperties", {})
    if conn.get("pairingState") == "paired" and conn.get("tunnelState") != "unavailable":
        print(d.get("hardwareProperties", {}).get("udid") or d.get("identifier", ""))
        break
PY
)"
    rm -f "$DEVJSON"
fi
if [ -z "${UDID:-}" ]; then
    echo "  기기를 찾지 못했습니다. USB 로 연결하고 '신뢰'를 누른 뒤 다시 실행하거나,"
    echo "  아래 목록에서 UDID 를 골라 UDID=... 로 넘겨 주세요:"
    xcrun devicectl list devices || true
    exit 1
fi
echo "  UDID: $UDID"

echo "▸ 3/4 빌드 (새 프로파일 발급 포함)"
xcodebuild -project TEPSVocaStudy.xcodeproj \
    -scheme TEPSVocaStudy \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    build 2>&1 | grep -E "error:|warning: Signing|Signing Identity|BUILD" || true

[ -d "$APP" ] || { echo "빌드 실패: $APP 없음"; exit 1; }

echo "▸ 4/4 기기에 덮어 설치 (앱 삭제 안 함)"
xcrun devicectl device install app --device "$UDID" "$APP"

echo
echo "✓ 완료. 이번 서명의 유효 기간:"
show_expiry "$APP"
