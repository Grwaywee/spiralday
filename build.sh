#!/bin/zsh
# Spiralday.app 을 만든다
#   ./build.sh            이 Mac 용 (빠름)
#   ./build.sh --release  Apple Silicon + Intel 유니버설, dist/ 에 배포용 zip 까지
set -e
cd "$(dirname "$0")"
# 새 버전을 낼 때: VERSION 을 올리고 BUILD 를 1 씩 늘린다 (Sparkle 은 BUILD 로 새 버전을 판단한다)
VERSION="1.0.0"
BUILD=1
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
# 애드혹 서명 (Sparkle 안의 도우미 앱까지)
codesign --force --deep -s - "$APP"
echo "✓ $APP"

if [ $RELEASE = 1 ]; then
  mkdir -p dist
  ZIP="dist/Spiralday-$VERSION-macOS.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  # 소개 페이지의 "최신 버전 받기" 링크용 (releases/latest/download/Spiralday.zip)
  cp "$ZIP" dist/Spiralday.zip
  echo "✓ $ZIP  (+ dist/Spiralday.zip)"
fi
