#!/bin/zsh
# Spiralday.app 을 만든다 → build/Spiralday.app
#   ./build.sh                 이 Mac 용 (애드혹 서명, 빠름)
#   UNIVERSAL=1 ./build.sh     Apple Silicon + Intel 유니버설
#   SIGN_ID="…" ./build.sh     그 인증서로 서명 (Hardened Runtime). SIGN_TIMESTAMP=1 이면 보안 타임스탬프도 붙인다
set -e
cd "$(dirname "$0")"
# 새 버전을 낼 때: VERSION 을 올리고 BUILD 를 1 씩 늘린다 (Sparkle 은 BUILD 로 새 버전을 판단한다)
VERSION="1.0.4"
BUILD=5

# 빌드한 컴퓨터의 경로가 실행 파일에 남지 않게 소스 경로를 저장소 기준(.)으로 적는다
FLAGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
if [ "$UNIVERSAL" = 1 ]; then
  swift build $FLAGS --arch arm64 --arch x86_64
  PRODUCTS=.build/apple/Products/Release
else
  swift build $FLAGS
  PRODUCTS=.build/release
fi
BIN=$PRODUCTS/Spiralday
APP="build/Spiralday.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spiralday"
# 디버그 정보는 build/Spiralday.dSYM 으로 따로 빼고 실행 파일에서는 지운다
# (경로를 바꿔 적어서 clang 모듈 .pcm 을 못 찾는다는 경고가 나오는데 크래시 기호 풀이와는 상관없어 로그로만 남긴다)
rm -rf build/Spiralday.dSYM
dsymutil "$APP/Contents/MacOS/Spiralday" -o build/Spiralday.dSYM 2> build/dsymutil-log.txt \
  || { cat build/dsymutil-log.txt; exit 1; }
strip -S -x "$APP/Contents/MacOS/Spiralday"
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
# 서명: SIGN_ID 가 있으면 그 인증서로 (Hardened Runtime), 없으면 애드혹
if [ -n "$SIGN_ID" ]; then
  TS=--timestamp=none
  [ "$SIGN_TIMESTAMP" = 1 ] && TS=--timestamp
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
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP  (${SIGN_ID:-애드혹 서명})"
