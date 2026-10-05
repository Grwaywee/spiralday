#!/bin/zsh
# Spiralday.app 을 만든다 → build/Spiralday.app
#   ./build.sh                 이 Mac 용 (애드혹 서명, 빠름)
#   UNIVERSAL=1 ./build.sh     Apple Silicon + Intel 유니버설
#   SIGN_ID="…" ./build.sh     그 인증서로 서명 (Hardened Runtime). SIGN_TIMESTAMP=1 이면 보안 타임스탬프도 붙인다
#                              — 출시 빌드: 아래 고친 커밋이 모두 HEAD 에 있고 소스를 커밋한 그대로일 때만 만든다
#   RELEASE=1 ./build.sh       서명 없이도 출시 빌드처럼 확인한다
#   FIX_CHECK_ONLY=1 ./build.sh   그 확인만 하고 끝낸다 (빌드하지 않음)
set -e
cd "$(dirname "$0")"
# 새 버전을 낼 때: VERSION 을 올리고 BUILD 를 1 씩 늘린다 (Sparkle 은 BUILD 로 새 버전을 판단한다)
# 빌드 10: 1.1.0 빌드 9 (dbe5152) 는 형광펜 사고 고침 · 사장님 피드백 고침보다 먼저 만든 것이라, 고친 뒤의 1.1.0 은 10 부터
VERSION="1.1.0"
BUILD=10

# ─────────────────────────────────────────────────────────────────────────────
# 출시 지킴이: 사장님이 알려 준 문제의 고침이 빠진 앱이 나가지 않게, 출시 빌드는 이 커밋들이 모두 HEAD 의 조상일 때만 만든다
# (Windows web/scripts/publish-windows.mjs · Android web/scripts/android.mjs · iOS apple/scripts/testflight.sh 와 같은 규칙).
# 저장소를 다시 쓰면(rebase) 해시가 바뀌므로 여기도 같이 고친다 — 지우지 말 것. 그래서 origin/main 의 커밋(사이트 등)을 로컬 main 에
# 들일 때는 rebase 말고 merge 를 쓴다 (rebase 하면 아래 해시가 모두 바뀌어 release/release.sh 가 멈춘다).
REQUIRED_FIXES=(
  "3f074d4 형광펜 사고: 기기가 채운 기본값이 다른 기기의 진짜 값을 이기지 않게 (A)"
  "63d21fc 형광펜 사고 검토: 예전 엔진 · 옛 사본 · 파일 없이 연 책이 형광펜을 덮지 못하게 (A)"
  "63ab4fb 팔레트의 지금 플래너 책 모양 (E)"
  "478e1de 넘어가는 종이 위로 스프링 고리가 비치지 않게 (B)"
  "d43ba6c 다른 창의 키 · 스크롤을 먹지 않게 · 주간 세로 넘김 · 작은 화면 팔레트 (G · H · J · E · D)"
  "0331099 기본 형광펜 세 벌을 한 값으로 · 옛 D-day id (A · O)"
  "cacdff6 처음 안내에서 동기화로 합류 · 빈 '내 플래너' 를 퍼뜨리지 않음 (I · P · O)"
  "9a1bd73 실패한 합류 · 되살리기는 빈 플래너를 지우지 않음 · 받는 중 30초 전에는 만들 수 없음 (I · P · O 검토)"
  "2a08fbe 넘김 고리 가닥을 쪽 그림을 그릴 때 구움 (B 검토 — 첫 프레임 · 메모리)"
)
check_required_fixes() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "✗ 출시 빌드는 git 저장소에서만 만들어요 (고친 커밋이 들어 있는지 확인할 수 없어요)"
    exit 1
  fi
  local missing=0 line c
  for line in "${REQUIRED_FIXES[@]}"; do
    c=${line%% *}
    if ! git merge-base --is-ancestor "$c" HEAD 2>/dev/null; then
      echo "✗ 빠진 고침: $line"
      missing=1
    fi
  done
  if [ $missing != 0 ]; then
    echo "출시 빌드를 멈춰요: 위 커밋이 HEAD($(git rev-parse --short HEAD)) 에 없어요 — 고침이 빠진 앱이 나가지 않게."
    echo "  로컬 main 을 rebase 해서 해시만 바뀌었으면: git log --oneline HEAD | grep '<제목 일부>' 로 새 해시를 찾아"
    echo "  이 목록과 Tests/SpiraldayAppTests/ReleaseGuardTests.swift 를 함께 고친다 (다음부터는 rebase 말고 merge)."
    exit 1
  fi
  if [ -n "$(git status --porcelain -- Sources Resources Package.swift Package.resolved)" ]; then
    echo "✗ 커밋하지 않은 소스 변경이 있어요 — 출시 빌드는 커밋한 그대로 만들어요."
    git status --short -- Sources Resources Package.swift Package.resolved
    exit 1
  fi
  echo "✓ 고친 커밋 ${#REQUIRED_FIXES[@]}개가 모두 들어 있어요 ($(git rev-parse --short HEAD))"
}
if [ -n "$SIGN_ID" ] || [ "$RELEASE" = 1 ] || [ "$FIX_CHECK_ONLY" = 1 ]; then
  check_required_fixes
  [ "$FIX_CHECK_ONLY" = 1 ] && exit 0
fi

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
# 오픈소스 고지 (libsodium · swift-sodium 은 ISC — 실행 파일에 정적으로 링크되므로 모든 사본에 고지를 넣는다 · Sparkle 은 MIT)
mkdir -p "$APP/Contents/Resources/Licenses"
cp Resources/Licenses/* "$APP/Contents/Resources/Licenses/"

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
