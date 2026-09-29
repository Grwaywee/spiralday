#!/bin/zsh
# Spiralday.app 을 만든다
#   ./build.sh            이 Mac 용 (빠름)
#   ./build.sh --release  Apple Silicon + Intel 유니버설 + 공증, dist/ 에 설치용 DMG 와 업데이트용 zip
set -e
cd "$(dirname "$0")"
# 새 버전을 낼 때: VERSION 을 올리고 BUILD 를 1 씩 늘린다 (Sparkle 은 BUILD 로 새 버전을 판단한다)
VERSION="1.0.2"
BUILD=3
RELEASE=0
[ "$1" = "--release" ] && RELEASE=1

if [ $RELEASE = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  PRODUCTS=.build/apple/Products/Release
else
  swift build -c release
  PRODUCTS=.build/release
fi
BIN=$PRODUCTS/Spiralday
APP="build/Spiralday.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spiralday"
# 원격 업데이트 프레임워크
mkdir -p "$APP/Contents/Frameworks"
SPARKLE=$PRODUCTS/Sparkle.framework
[ -d "$SPARKLE" ] || SPARKLE=$(find .build/artifacts/sparkle -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 5 | head -1)
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# 아이콘: Resources/AppIcon-1024.png (Spiralday --icon 으로 그린 것) → .icns
ICON_SRC=Resources/AppIcon-1024.png
if [ ! -f build/AppIcon.icns ] || [ "$ICON_SRC" -nt build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf $ICONSET && mkdir -p $ICONSET
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spiralday</string>
  <key>CFBundleDisplayName</key><string>Spiralday</string>
  <key>CFBundleIdentifier</key><string>com.spiralday.app</string>
  <key>CFBundleExecutable</key><string>Spiralday</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 LeanAgileHungry.Inc · MIT License</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleLocalizations</key><array><string>ko</string><string>en</string></array>
  <key>SUFeedURL</key><string>https://spiralday.com/appcast.xml</string>
  <key>SUPublicEDKey</key><string>5DarUKmySbc2Fbpl2odCdBw16l9YElGn+E3AEXa/mRQ=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST
# 서명: 이 Mac 에 Developer ID 인증서가 있으면 그것으로 (Hardened Runtime, 공증 가능), 없으면 애드혹
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
if [ -n "$SIGN_ID" ]; then
  TS=--timestamp=none
  [ $RELEASE = 1 ] && TS=--timestamp
  sign() { codesign --force --options runtime $TS -s "$SIGN_ID" "$@" }
  # 안쪽부터 바깥으로 (Sparkle 문서의 순서)
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
  sign "$APP"
else
  [ $RELEASE = 1 ] && { echo "✗ 배포판은 Developer ID Application 인증서로 서명해야 해요"; exit 1; }
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP  (${SIGN_ID:-애드혹 서명})"

# 공증: Apple 에 제출 → 통과하면 티켓을 붙인다 (staple)
# 자격 증명은 키체인 프로필 "spiralday" — 한 번만 만들어 두면 된다:
#   
NOTARY=${NOTARY_PROFILE:-spiralday}
notarize() {
  local target=$1 upload=$1
  if [ -d "$target" ]; then
    upload=build/notarize.zip
    rm -f $upload && ditto -c -k --keepParent "$target" $upload
  fi
  echo "… 공증 중: $(basename $target)  (보통 1–5분)"
  local out=$(xcrun notarytool submit "$upload" --keychain-profile "$NOTARY" --wait --output-format json)
  local id=$(plutil -extract id raw -o - - <<< "$out")
  local st=$(plutil -extract status raw -o - - <<< "$out")
  if [ "$st" != "Accepted" ]; then
    echo "✗ 공증 실패 ($st)"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY"
    exit 1
  fi
  xcrun stapler staple -q "$target"
  echo "✓ 공증 통과: $(basename $target)"
}

if [ $RELEASE = 1 ]; then
  xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1 || {
    echo "✗ 공증 자격 증명(키체인 프로필 \"$NOTARY\")이 없어요. 한 번만 실행해 두세요:"
    echo "   
    exit 1
  }
  notarize "$APP"
  mkdir -p dist
  rm -f dist/Spiralday*
  # 1) 자동 업데이트(Sparkle)용 zip
  ZIP="dist/Spiralday-$VERSION-macOS.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  # 2) 사람이 받는 설치용 DMG (끌어다 놓기 화면 + 웹사이트 바로가기)
  DMG="dist/Spiralday-$VERSION.dmg"
  Scripts/make-dmg.sh "$APP" "$DMG" "$SIGN_ID"
  notarize "$DMG"
  # 소개 페이지의 "최신 버전 받기" 링크용 (releases/latest/download/Spiralday.dmg)
  cp "$DMG" dist/Spiralday.dmg
  shasum -a 256 "$DMG" "$ZIP" | tee dist/SHA256SUMS.txt
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -v "$APP"
  echo "✓ $DMG  (+ dist/Spiralday.dmg, $ZIP)"
fi
