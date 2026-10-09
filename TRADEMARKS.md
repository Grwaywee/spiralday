# 상표 정책 · Trademark policy

**Spiralday™** 이름과 로고 · 앱 아이콘은 LeanAgileHungry Inc. (주식회사 린에자일헝그리) 의 상표입니다.
사용자가 공식 Spiralday 와 다른 사람이 만든 앱을 헷갈리지 않게 하려고 이 정책을 둡니다.

*English below.*

## 코드 라이선스와 상표는 따로예요

이 저장소의 [LICENSE](LICENSE) (PolyForm Noncommercial 1.0.0) 는 코드에 대한 저작권 · 특허 라이선스입니다.
LICENSE 의 ‘No Other Rights’ 항목에 적힌 대로 그 밖의 라이선스를 뜻하지 않으며, 상표를 쓸 권리는 들어 있지 않습니다.
코드를 어느 버전 · 어느 라이선스로 받았든 ([예전 MIT 버전](LICENSE-HISTORY.md) 포함), Spiralday 이름 · 로고 · 아이콘을 쓰는 일은 이 정책을 따라 주세요.

## 이 정책이 다루는 것

- 이름 **Spiralday**, **Spiralday Sync**, 그리고 헷갈릴 만큼 비슷한 이름
- Spiralday 로고와 앱 아이콘 (`Resources/AppIcon-1024.png`, `site/assets/` 의 아이콘 · 파비콘 등)
- LeanAgileHungry 이름과 로고 (`site/assets/lah-logo.svg`)

코드가 그리는 화면 — 종이 한 장 같은 창, 스프링 링, 표지 · 첫 장, 페이지 양식 — 은 이 정책이 다루지 않습니다. 그 화면을 그리는 코드를 쓰는 조건은 [LICENSE](LICENSE) 가 정합니다.

## 허락 없이 해도 되는 것

- 사실대로 가리키기 — 리뷰 · 글 · 기사 · 강의에서 Spiralday 를 말하기, 공식 다운로드 링크 공유
- 출처 밝히기 — “Spiralday 코드를 바탕으로 만들었습니다 (LeanAgileHungry Inc. 와 관계없음)” 처럼 쓰기
- 혼자 쓰려고 직접 빌드하기 — 남에게 나눠 주지 않으면 이름 · 아이콘을 그대로 둬도 됩니다

## 포크하거나 나눠 줄 때

[LICENSE](LICENSE) 에 따라 고친 앱이나 직접 만든 빌드를 남에게 나눠 줄 때는, 공식 Spiralday 로 오해받지 않고 공식 앱 · 서비스 · 사용자의 데이터와 섞이지 않도록 아래를 **모두** 바꿔 주세요.

| 바꿀 것 | 이 저장소의 자리 |
|---|---|
| 앱 이름 — Spiralday 나 비슷한 이름 쓰지 않기 | `build.sh` (`CFBundleName` · `CFBundleDisplayName`), 앱 안의 글 |
| 앱 아이콘 · 로고 | `Resources/AppIcon-1024.png`, `build.sh` 의 `ICON_SRC` |
| 번들 id · 키체인 이름 — `com.spiralday.*` 쓰지 않기 | `build.sh` (`CFBundleIdentifier` = `com.spiralday.app`), `Sources/Spiralday/Sync/SyncController.swift` (`releaseBundleID` · 키체인 서비스 `com.spiralday.sync`), `Sources/SpiraldaySync/Keychain.swift` · `EngineApp.swift` |
| 데이터 폴더 이름 · 앱 그룹 — 공식 앱의 플래너 파일을 읽고 쓰지 않게 | `Sources/SpiraldayKit/Models.swift` (`PlannerStore` 의 `appendingPathComponent("Spiralday")` → `~/Library/Application Support/Spiralday`, `appGroupID` = `group.com.spiralday.app`) |
| 업데이트 피드와 서명 키 — 공식 피드 · 키를 그대로 두지 않기 (자기 키를 만들거나 업데이트 끄기) | `build.sh` (`SUFeedURL` = `https://spiralday.com/appcast.xml`, `SUPublicEDKey`) |
| 동기화 서버 — 직접 운영하는 서버로 바꾸거나 동기화 끄기 | `Sources/SpiraldaySync/ServerConfig.swift` (`https://sync.spiralday.com`), `Sources/Spiralday/Sync/SyncServer.swift` |
| 사용 통계 주소 — 지우거나 자기 주소로 | `Sources/Spiralday/Telemetry.swift` (`https://leanagilehungry.com/api/spiralday/ping`) |
| 링크 · 문의처 | `Sources/SpiraldayKit/Platform.swift` 의 `Links` (웹사이트 · 개인정보 처리방침 · GitHub · 회사), 도움말 메뉴, 버그 신고 메일 |

공식 동기화 서버 · 업데이트 피드 · 통계 주소는 공식 앱을 위한 것입니다.
LICENSE 가 요구하는 고지(LICENSE 사본이나 URL, `Required Notice:` 줄)는 이름을 바꿔도 그대로 함께 나눠 주세요. `build.sh` 로 빌드하면 `.app` 의 `Contents/Resources/Licenses/Spiralday-LICENSE.txt` 에 들어갑니다.

위 표를 모두 바꾼 포크는 코드가 그리는 화면을 그대로 써도 이 정책에 어긋나지 않습니다.
소스 안의 모듈 · 타입 이름(`SpiraldayKit`, `SpiraldaySync` 등)은 사용자에게 보이는 이름이 아니므로 그대로 둬도 됩니다.

## 하지 말아 주세요

- 이름 · 아이콘 · 설명으로 공식 앱이거나 LeanAgileHungry Inc. 가 만들거나 보증 · 후원한 것처럼 보이게 하기
- Spiralday 이름이나 아이콘으로 앱 스토어 · 웹사이트에 올리기, 앱 · 도메인 · 계정 이름에 넣기
- 로고 · 아이콘을 고치거나 비슷하게 흉내 내기

## 공식 다운로드와 확인하는 법

공식 경로는 아래뿐입니다. 다른 곳에서 받은 ‘Spiralday’ 는 공식 앱이 아닐 수 있어요.

- **웹사이트**: <https://spiralday.com>
- **Mac**: [GitHub Releases](https://github.com/Grwaywee/spiralday/releases) 의 `Spiralday.dmg` · `Spiralday-<버전>.dmg` · `Spiralday-<버전>-macOS.zip`, 그리고 앱 안의 자동 업데이트 (피드 `https://spiralday.com/appcast.xml`)
  - 받은 파일: 같은 릴리스의 `SHA256SUMS.txt` 와 `shasum -a 256 <파일>` 값이 같은지
  - 디스크 이미지: `spctl -a -t open --context context:primary-signature -vv Spiralday-<버전>.dmg` → `accepted` · `source=Notarized Developer ID` · `origin=Developer ID Application: LeanAgileHungry Inc. (SCQ7JJP5MN)`
  - 설치한 앱: `codesign -dv --verbose=4 /Applications/Spiralday.app` → `Authority=Developer ID Application: LeanAgileHungry Inc. (SCQ7JJP5MN)` · `TeamIdentifier=SCQ7JJP5MN`
  - 자동 업데이트는 Sparkle 이 EdDSA 서명을 앱에 들어 있는 공개 키(`SUPublicEDKey`)로 확인한 뒤에만 설치합니다
- **Windows (베타)**: [GitHub Releases](https://github.com/Grwaywee/spiralday/releases) 의 `Spiralday-Setup.exe` (`win-latest` — 웹사이트의 Windows 다운로드 버튼이 거는 파일) · `Spiralday-Setup-<버전>.exe`, 그리고 앱 안의 자동 업데이트
  - 파일 속성 → 디지털 서명에서 서명자가 ‘LeanAgileHungry . INC’ 인지, PowerShell `Get-AuthenticodeSignature .\Spiralday-Setup.exe` (또는 `Spiralday-Setup-<버전>.exe`) 의 `Status` 가 `Valid` 인지
- **iPhone · iPad**: App Store — spiralday.com 에 걸린 App Store 링크로 들어가는 앱이 공식입니다.
- **Android**: Google Play 에 나오면 spiralday.com 에 링크를 올립니다. spiralday.com 에 걸린 스토어 링크만 공식입니다.

## 문의

상표 사용 허락, 상업 라이선스, 사칭 · 오해를 부르는 앱 신고: **contact@leanagilehungry.com**

이 정책은 바뀔 수 있고, 바뀌면 이 파일에 적습니다.

---

## English

**Spiralday™**, its logo and app icon are trademarks of LeanAgileHungry Inc. This policy exists so that people can tell the official Spiralday apart from apps made by others.

**The code license is separate from the trademarks.** The [LICENSE](LICENSE) in this repository (PolyForm Noncommercial 1.0.0) is a copyright and patent license for the code. As its “No Other Rights” section says, it does not imply any other licenses, and it does not include permission to use the trademarks. Whichever version or license you received the code under (including the [earlier MIT versions](LICENSE-HISTORY.md)), please follow this policy when using the Spiralday name, logo or icon.

**Covered:** the names *Spiralday* and *Spiralday Sync* and confusingly similar names; the Spiralday logo and app icon (`Resources/AppIcon-1024.png`, the icons and favicons in `site/assets/`); and the LeanAgileHungry name and logo. The screens the code draws — the window that is one sheet of paper, the spiral rings, the cover and first page, the page layouts — are not covered by this policy; the [LICENSE](LICENSE) sets the terms for using the code that draws them.

**Fine without asking:** referring to Spiralday truthfully (reviews, articles, talks, sharing the official download links); stating origin, e.g. “based on Spiralday code (not affiliated with LeanAgileHungry Inc.)”; building the app yourself for your own use — if you do not give it to anyone else, you do not need to rename it.

**Forks and redistribution:** when you distribute a modified app or your own build under the LICENSE, change **all** of the following so that it is not mistaken for the official Spiralday and does not mix with the official app, its services or its users’ data: the app name (no “Spiralday” or similar names); the app icon and logo; the bundle id and keychain names (`com.spiralday.app`, `com.spiralday.sync`, any `com.spiralday.*`); the data folder name and app group (`appendingPathComponent("Spiralday")` → `~/Library/Application Support/Spiralday`, and `appGroupID` = `group.com.spiralday.app`, in `Sources/SpiraldayKit/Models.swift`); the update feed and signing key (`SUFeedURL`, `SUPublicEDKey` — generate your own key or disable updates); the sync server (`https://sync.spiralday.com` — run your own or disable sync); the usage-statistics endpoint (`https://leanagilehungry.com/api/spiralday/ping` — remove it or use your own); and the links and contact addresses (`Links` in `Sources/SpiraldayKit/Platform.swift`, the Help menu, the bug-report e-mail). The table in the Korean section lists the files. The official sync server, update feed and statistics endpoint are for the official app. Keep the notices the LICENSE requires (a copy of the terms or their URL, and the `Required Notice:` line) when you redistribute; `build.sh` puts them in the app at `Contents/Resources/Licenses/Spiralday-LICENSE.txt`. A fork that has changed everything listed above may keep the screens as the code draws them without conflicting with this policy, and internal module and type names in the source (such as `SpiraldayKit` and `SpiraldaySync`) are not user-facing and may stay as they are.

**Please don't:** suggest, through names, icons or descriptions, that your app is official or made, endorsed or sponsored by LeanAgileHungry Inc.; publish an app or website under the Spiralday name or icon, or use them in app, domain or account names; modify or imitate the logo or icon.

**Official downloads and how to verify:** only <https://spiralday.com> and [GitHub Releases](https://github.com/Grwaywee/spiralday/releases) of this repository, plus the in-app updaters and the store links posted on spiralday.com.
- Mac: compare `shasum -a 256` with the release’s `SHA256SUMS.txt`; `spctl -a -t open --context context:primary-signature -vv Spiralday-<version>.dmg` should report `accepted`, `source=Notarized Developer ID`, `origin=Developer ID Application: LeanAgileHungry Inc. (SCQ7JJP5MN)`; `codesign -dv --verbose=4 /Applications/Spiralday.app` should show `TeamIdentifier=SCQ7JJP5MN`. Sparkle installs an update only after checking its EdDSA signature against the public key (`SUPublicEDKey`) inside the app.
- Windows (beta): `Spiralday-Setup.exe` from the `win-latest` release (the file the website’s Windows download button links to) or `Spiralday-Setup-<version>.exe`; the installer’s digital signature should name ‘LeanAgileHungry . INC’, and `Get-AuthenticodeSignature` should report `Status: Valid`.
- iPhone, iPad: the App Store — the app that the App Store link on spiralday.com opens is the official one.
- Android: when it is on Google Play, the store link will be posted on spiralday.com; only store links posted there are official.

**Contact** (trademark permission, commercial licensing, reporting impersonation): **contact@leanagilehungry.com**. This policy may change; changes will be recorded in this file.
