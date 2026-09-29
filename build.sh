#!/bin/zsh
# Spiralday.app 을 만든다
#   ./build.sh            이 Mac 용 (빠름)
#   ./build.sh --release  Apple Silicon + Intel 유니버설, dist/ 에 배포용 zip 까지
set -e
cd "$(dirname "$0")"
VERSION="1.0.0"
RELEASE=0
[ "$1" = "--release" ] && RELEASE=1

if [ $RELEASE = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Spiralday
else
  swift build -c release
  BIN=.build/release/Spiralday
fi
APP="build/Spiralday.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spiralday"

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
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 LeanAgileHungry Inc. · MIT License</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✓ $APP"

if [ $RELEASE = 1 ]; then
  mkdir -p dist
  ZIP="dist/Spiralday-$VERSION-macOS.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "✓ $ZIP"
fi
