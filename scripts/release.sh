#!/bin/zsh
# 배포용 빌드: Developer ID 서명 + Apple 공증 + 스테이플 → dist/
#
# Xcode에 로그인된 Apple 계정(개인 개발자 프로그램 팀 4Y6Z5689CK)으로 공증을 제출한다.
# 필요: 키체인의 "Developer ID Application: … (4Y6Z5689CK)" 인증서, Xcode → 설정 → Accounts 로그인
set -euo pipefail

TEAM_ID="4Y6Z5689CK"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/WithShell.xcarchive"
DIST="$ROOT/dist"
cd "$ROOT"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"
xcodegen generate >/dev/null

echo "▶ Archive (Release, Developer ID 서명)"
xcodebuild archive -project WithShell.xcodeproj -scheme WithShell -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/build/DerivedData" \
  -skipPackagePluginValidation -skipMacroValidation > "$BUILD/archive.log" 2>&1 || true
grep -E "error:|\*\* ARCHIVE" "$BUILD/archive.log" | tail -5
[[ -d "$ARCHIVE" ]] || { echo "✘ archive 실패 ($BUILD/archive.log)"; exit 1; }

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

echo "▶ 공증 제출 (Xcode 계정)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/upload" -allowProvisioningUpdates > "$BUILD/upload.log" 2>&1 \
  || { tail -20 "$BUILD/upload.log"; echo "✘ 공증 제출 실패"; exit 1; }
tail -3 "$BUILD/upload.log"

echo "▶ 공증 완료 대기 (최대 30분)"
APP="$BUILD/notarized/WithShell.app"
for i in $(seq 1 60); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$BUILD/notarized" > "$BUILD/notarized.log" 2>&1 \
     && [[ -d "$APP" ]]; then
    break
  fi
  sleep 30
done
[[ -d "$APP" ]] || { tail -20 "$BUILD/notarized.log"; echo "✘ 공증된 앱을 받지 못했습니다"; exit 1; }

echo "▶ 검증"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
rm -rf "$DIST/WithShell.app" "$DIST/WithShell-$VERSION-arm64.zip"
ditto "$APP" "$DIST/WithShell.app"
(cd "$DIST" && ditto -c -k --keepParent WithShell.app "WithShell-$VERSION-arm64.zip")
echo "✔ 완료: $DIST/WithShell-$VERSION-arm64.zip"
