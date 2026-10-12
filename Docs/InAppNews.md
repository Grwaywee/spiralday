# 앱 안 소식

사장님 결정 (2026-10-11): **로그인 · 계정은 만들지 않는다.** 푸시 알림도 없이, 앱 안에 ‘소식’을 둔다.
Mac · iPhone · iPad · Windows · Android 가 똑같이 동작하도록 이 문서가 기준이고, 규칙은 공유 벡터
[`Tests/Fixtures/news-rules.json`](../Tests/Fixtures/news-rules.json) 으로 확인한다 (참고 구현: [`Scripts/news-check.mjs`](../Scripts/news-check.mjs)).

## 0. 한눈에

- **이번에 달라진 점** — 업데이트하고 처음 열 때 한 번. 앱에 들어 있는 노트라 오프라인이어도 된다. 새로 설치했을 때(처음 안내)는 띄우지 않는다.
- **중요한 소식** — spiralday.com 의 정적 파일 `https://spiralday.com/news/news.json` 에서 받아, 앱을 열 때 조용한 카드로 한 번. 닫으면 다시 뜨지 않는다.
- **설정 › 소식** — 받은 소식과 이번 버전의 노트를 모아 둔 목록. 아직 안 본 것에만 작은 점.
- **하지 않는 것** — 푸시 알림, 계정, 종이 위의 표시 · 배지, 앱 아이콘 · Dock 배지, 반복 팝업, ‘나중에 다시 알림’, 읽음 통계.
  받을 때 설치 번호 · 기기 정보 · 쿼리 문자열 · 쿠키를 보내지 않는다.
- 쓰임: 요금 · 약관처럼 30일 이상 미리 알려야 하는 변화, 개인정보 처리방침이 바뀔 때, 동기화 점검, 오래된 버전에 업데이트 부탁.

## 1. 화면

### 1.1 카드 — ‘열 때’(§5.1)마다 많아야 하나

종이에 그리지 않는다 — 종이 안의 표시가 아니라 잠깐 떠 있는 카드라, 닫으면 흔적이 없다. 소리 · 진동 없음, 플랫폼 기본보다 큰 움직임 없음
(나타날 때 살짝 떠오르거나 흐려지는 정도, 동작 줄이기면 흐려지기만 또는 없음). 플랫폼마다의 모양 — 지금 구현 그대로 (2026-10-12):

| | 모양 · 자리 | 닫기 | 키보드 |
|---|---|---|---|
| Mac | 플래너 창 **옆 여백**의 작은 카드 (너비 320pt). 팔레트처럼 본 창에 붙은 창이라 함께 움직인다. 자리는 팔레트의 반대쪽 → 아래 → 위 → 팔레트 너머 중 화면에 들어가고 팔레트 · 스프링과 겹치지 않는 첫 자리 (옆이면 종이 위끝에서 36pt 아래). 창이 화면을 꽉 채워(최대화 · 전체 화면) 어디에도 자리가 없을 때만 종이 아래 가운데(메모 · 타임테이블 위)에 겹친다 | [확인] · Return · Esc · 카드 밖 누르기 · [자세히 보기] · 플래너 단축키 | 플래너 단축키(← → · T W D H · E · 1–7)는 플래너가 처리하고 카드는 닫힌다. Return · Esc · Tab · 스페이스는 카드 몫 — 앱을 켜자마자 → 를 누르는 분이 반응 없이 기다리지 않게 |
| iPhone | 종이 위에 잠깐 **얹는 쪽지** (가이드 투어의 쪽지와 같은 종이 — 어두운 모드에서도 밝다). 아래 끝을 일간은 필통의 도구 이름표 바로 위, 주간은 요일 띠 바로 위에 맞춘다 (홈 · 가로 주간은 화면 아래). 너비는 화면 − 20pt (440pt 까지), 높이는 머리 막대 밑까지 · 화면의 55% 까지. 종이 아래쪽을 가린다 (아래) | [확인] · 카드 밖 누르기 (누른 것은 그대로 앱으로 간다) · 아래로 쓸기 · VoiceOver 닫기 손짓 · 하드웨어 키보드의 Esc · Return · Enter · Space | 다른 키(글자 · 화살표 · 단축키)는 카드를 그대로 두고 플래너로 간다 — 카드는 띄우는 순간 본 것이라, 키를 누르다 읽지도 못한 채 사라지지 않게 |
| iPad | 같은 쪽지. 레일 바로 옆(12pt 띄워), 아래 끝을 레일 아래 끝에 맞춘다. 너비 260–360pt, 높이 화면의 60% 까지. 종이 위에 얹힌다 (세로 일간은 메모 · 타임테이블 아래쪽, 가로 펼침은 오른쪽 장). 좁은 창(아래 막대)은 막대 바로 위 가운데 (420pt 까지) | iPhone 과 같다 | iPhone 과 같다 |
| Windows | 창 가운데의 대화상자 카드 (420px — GitHub ⭐ 대화상자와 같은 모양), 플래너를 옅게 어둡게 덮는다 | [확인] · Esc · 카드 밖 누르기 · [자세히 보기] | 카드가 모든 키를 받고 플래너 단축키는 쉰다. Tab · Shift+Tab 으로 본문 · 단추를 돌고, ↑ ↓ · Page Up / Down · Home · End 는 본문을 스크롤 |
| Android | 폰은 떠 있는 중간 높이 시트 (손잡이 — iPhone 의 중간 높이 시트처럼), 태블릿은 가운데 폼 시트 (480dp). 둘 다 뒤를 옅게 덮는다 | [확인] · 덮개 누르기 · 뒤로 가기 · 손잡이를 아래로 쓸기 · Esc · [자세히 보기] | — |

| | 소식 카드 | 이번에 달라진 점 카드 |
|---|---|---|
| 위 작은 글자 | `noticeCaption` — 소식 · 10월 20일 (en News · Oct 20) | `whatsNewCaption` — 이번에 달라진 점 (en What’s new) |
| 제목 | 항목의 `title` | `whatsNewTitle` — Spiralday 1.2.0 |
| 본문 | 항목의 `body` (길면 카드 안에서 스크롤) | 노트의 `body` |
| 아래 | [자세히 보기] (`link` 가 있을 때만) · [확인] | `whatsNewFoot` — 설정 › 소식에서 다시 볼 수 있어요. · [확인] |

- 글은 §1.3 의 문구 그대로. 이번에 달라진 점 카드의 제목은 ‘Spiralday’ 와 **앱 버전** — 모든 플랫폼 (노트에 `1.2` 로 적었어도 앱이 1.2.0 이면
  ‘Spiralday 1.2.0’. Kit `NewsCopy.whatsNewTitle(appVersion:)`, web `cardView`). 목록 줄의 제목은 노트에 적힌 그대로 (§3).
- 본문 · 제목은 적힌 그대로 — 줄바꿈 · 띄어쓰기 · 줄 앞 들여쓰기를 지우지 않는다 (§8.1).
- **띄우는 순간 본 것**으로 저장한다 (§5.4). 위 표의 어떤 길로 닫아도, 그 사이 앱이 꺼져도 다시 뜨지 않는다.
- [자세히 보기]는 시스템 브라우저로 열고(§8.2) 카드를 닫는다.
- 화면 읽기: 카드가 뜨면 제목부터 읽는다 (Mac 은 카드가 열쇠 창이 되고 ‘소식: 제목’을 알린다). 바탕의 종이 그림은 읽지 않는다.
- **iPhone · iPad 의 쪽지는 종이를 일부 가린다** — 책상 여백(종이와 레일 · 막대 사이)이 카드보다 좁아서
  (2026-10-11 측정: iPad 세로 일간은 카드의 82%, iPhone SE 일간 86% · 주간 99% 가 종이 위). 시트보다 덜 가리고 밖을 누르면 바로 닫힌다.
  이 자리를 그대로 둘지는 사장님 결정을 기다린다 (§11) — **정할 때까지 지금 자리 그대로** 둔다.

### 1.2 설정 › 소식

- 자리: Mac 은 설정 창의 항목 ‘소식’ (`SettingsPane.news`, 튜토리얼과 데이터 사이), iPhone · iPad 는 설정 목록의 ‘소식’ (도움말 칸 맨 위),
  Windows · Android 는 설정 목록의 ‘소식’. Mac · iPad 는 도움말 메뉴의 ‘소식…’ 으로도 이 화면을 연다.
- 아이콘: 신문 — SF Symbols `newspaper.fill` (Windows · Android 도 같은 모양의 그림), 타일 바탕색 `#C2783A`, 모든 플랫폼이 같다.
  확성기(megaphone)는 ‘알림’ 느낌이 강해 쓰지 않는다. (공유 벡터의 `icon`)
- 위에서부터: 머리(아이콘 · `paneSubtitle`) → 목록 → 받기 스위치와 그 설명(`fetchOn` · `fetchOff`) → 맨 아래 작은 글 한 줄 `paneNote`.
  `paneNote` 는 모든 플랫폼이 같은 말 — 카드 · 쪽지 · 시트 · 대화상자 어느 모양에도 맞게 ‘종이 옆’ · ‘카드’ 같은 말은 쓰지 않는다.
- 줄: 날짜 · 종류(작은 글자 `kindNotice` · `kindUpdate`) · 제목, 안 본 줄은 제목 앞에 작은 점. 누르면 펼쳐 본문과 [자세히 보기].
- 날짜: 올해면 ‘10월 20일’ (en Oct 20), 아니면 ‘2025년 12월 3일’ (en Dec 3, 2025) — 앞에 0 을 붙이지 않는다 (공유 벡터 `dateLabels`).
  `YYYY-MM-DD` 를 달력 날짜 그대로 쓴다 — UTC 시각으로 바꾸지 말 것 (JS 의 `new Date('2026-10-20')` 은 UTC 자정이라 미국에서는 19일로 보인다).
- 비었을 때: `empty` — 오프라인 · 받기 실패도 같은 화면. 오류 문구는 보이지 않는다.
- 스위치: `fetchSwitch` (기본 켬). 그 아래 설명은 켰을 때 `fetchOn`, 껐을 때 `fetchOff`.
- 점: 안 본 줄이 있으면 설정 안의 ‘소식’ 항목(Mac 설정 창의 옆 목록, 모바일 · Windows 설정 목록)에만 작은 점. 종이 · 팔레트 · 설정 버튼 · 앱 아이콘에는 아무것도 없다.
- 화면 읽기: 안 본 줄 앞과 ‘소식’ 항목의 점은 `unseen` 으로 읽는다. 아이콘의 기호 이름은 읽지 않는다.
- 목록을 열면: 이번에 보이는 점은 그대로 두고(무엇이 새것인지 보이게) 보이는 줄을 모두 본 것으로 저장한다(§5.5) → ‘소식’ 항목의 점은 바로 사라지고, 다음에 열면 줄의 점도 없다.

### 1.3 문구 — 모든 플랫폼이 글자 그대로

공유 벡터의 `copy` 와 글자까지 같다 (`’` U+2019 · `›` U+203A · `·` U+00B7 · `…` U+2026 — 곧은 따옴표 · `>` · 마침표 셋으로 바꾸지 않는다).
바꿀 때는 이 표와 벡터를 함께 고친다 — `node Scripts/news-check.mjs --fixtures` 가 둘이 다르면 멈춘다.
앱 화면 언어가 한국어면 ko, 아니면 en (지금 Mac · Windows · Android 는 ko 만, iPhone · iPad 는 둘 다 — §5 `lang`).
자리 표시: `{date}` 는 §1.2 의 날짜, `{appVersion}` 은 **앱 버전** (노트에 적힌 것 아님), `{app}` 은 노트에 적힌 그대로.
자리: SpiraldayKit `NewsCopy` (Mac · iPhone · iPad), web `NEWS_COPY` (Windows · Android).

| 키 | 어디 | ko | en |
|---|---|---|---|
| `pane` | 설정의 항목 · 화면 제목 | 소식 | News |
| `paneSubtitle` | 설정 › 소식 머리, 아이콘 옆 부제 | 새 소식과 업데이트에서 달라진 점을 모아 둬요. | News from Spiralday and what’s new in each update, kept in one place. |
| `paneNote` | 설정 › 소식 맨 아래 작은 글 (받기 스위치 다음) | 업데이트한 뒤 달라진 점과 꼭 알아야 할 소식만 앱을 열 때 한 번 보여 드려요. 푸시 알림 · 배지는 없어요. | Only what’s new after an update and news you need to know show once when you open the app. No push notifications or badges. |
| `empty` | 목록이 비었을 때 (오프라인 · 받기 실패도) | 아직 소식이 없어요. | No news yet. |
| `fetchSwitch` | 받기 스위치 | spiralday.com 에서 소식 받기 | Get news from spiralday.com |
| `fetchOn` | 스위치 아래 — 켰을 때 | 앱을 열 때(켜 둔 동안은 하루 한 번) spiralday.com 의 소식 파일을 읽어 와요. 설치 번호나 기기 정보는 보내지 않아요. | When you open the app (and once a day while it stays open), it reads the news file on spiralday.com. No install ID or device information is sent. |
| `fetchOff` | 스위치 아래 — 껐을 때 | 받아 오지 않아요. 이미 받은 소식과 이번에 달라진 점은 그대로 볼 수 있어요. | News isn’t fetched. You can still read the news you already have and what’s new in this version. |
| `kindNotice` | 줄의 작은 글자 — `kind` notice | 알림 | Notice |
| `kindUpdate` | 줄의 작은 글자 — `kind` update · 노트 | 업데이트 | Update |
| `unseen` | 안 본 줄 · ‘소식’ 항목의 점을 읽어 주는 말 | 새 소식 | New |
| `noticeCaption` | 소식 카드 위 작은 글자 | 소식 · {date} | News · {date} |
| `whatsNewCaption` | 이번에 달라진 점 카드 위 작은 글자 | 이번에 달라진 점 | What’s new |
| `whatsNewTitle` | 이번에 달라진 점 카드 제목 | Spiralday {appVersion} | Spiralday {appVersion} |
| `whatsNewFoot` | 이번에 달라진 점 카드 아래 | 설정 › 소식에서 다시 볼 수 있어요. | You can read this again in Settings › News. |
| `noteTitle` | 목록에서 노트 줄의 제목 (§3) | {app} 에서 달라진 점 | What’s new in {app} |
| `learnMore` | [자세히 보기] — 카드 · 펼친 줄, `link` 가 있을 때만 | 자세히 보기 | Learn more |
| `ok` | 카드의 [확인] | 확인 | OK |
| `menu` | 도움말 메뉴 (Mac · iPad) | 소식… | News… |

한 플랫폼에만 있는 말 (공유 벡터 밖 — 그 플랫폼 화면에만 있는 자리라서):

- iPhone · iPad 설정 › 개인정보의 한 줄 ‘앱 안 소식’ (en In-app news) — 받기 스위치를 따라 (표 `News`, `App/News/News.xcstrings`):
  - 켜면 ‘앱을 열 때(켜 둔 동안은 하루 한 번) spiralday.com 의 공개 소식 파일을 읽어 오기만 해요. 어떤 소식을 봤는지는 이 기기에만 남아요.’
    (en When you open the app (and once a day while it stays open), it only reads the public news file on spiralday.com. What you’ve read stays on this device.)
  - 끄면 ‘지금은 받아 오지 않아요. 설정 › 소식에서 다시 켤 수 있어요. 이미 받은 소식과 본 기록은 이 기기에만 남아요.’
    (en News isn’t being fetched. You can turn it back on in Settings › News. News you already have and what you’ve read stay on this device.)
- 펼치기 · 접기 같은 화면 읽기 힌트 · 단추 모양은 플랫폼의 말을 쓴다.

## 2. 피드 형식 v1

`https://spiralday.com/news/news.json` (저장소의 `site/news/news.json`), UTF-8 JSON. 아래는 모양을 보이는 예시일 뿐 실제 공지가 아니다.

```json
{
  "version": 1,
  "items": [
    {
      "id": "2026-10-20-sync-check",
      "date": "2026-10-20",
      "kind": "notice",
      "importance": "important",
      "title": { "ko": "25일 새벽, 동기화를 잠깐 쉬어요", "en": "Sync takes a short break early on the 25th" },
      "body": {
        "ko": "새벽 2시부터 30분쯤 서버를 손봐요.\n그동안 쓴 것은 기기에 남아 있다가, 끝나면 저절로 맞춰져요.",
        "en": "We’ll be servicing the server for about 30 minutes from 2 a.m.\nWhat you write stays on your device and syncs once we’re done."
      },
      "syncOnly": true,
      "link": "https://spiralday.com/privacy.html",
      "expires": "2026-10-25"
    }
  ]
}
```

| 필드 | 필수 | 규칙 | 어기면 |
|---|---|---|---|
| `version` | 예 | 숫자 `1` | 파일 전체를 읽지 않음 |
| `items` | 예 | 배열. 앞의 50개만 읽는다 | 파일 전체를 읽지 않음 |
| `id` | 예 | `^[a-z0-9][a-z0-9-]{0,63}$`, `app-` 로 시작하지 않음(앱 노트 몫). 같은 id 는 처음 나온 **유효한** 항목만 | 항목 버림 |
| `date` | 예 | 실제 있는 날짜 `YYYY-MM-DD`. 그날부터 보인다 | 항목 버림 |
| `kind` | 예 | `notice` · `update` (목록의 작은 글자에만 쓴다) | 항목 버림 |
| `importance` | 예 | `normal` · `important` (important 는 카드로 한 번) | 항목 버림 |
| `title` | 예 | `{ "ko", "en"? }` — 1–80자, 한 줄. `en` 이 없거나 `""` 이면 ko 로 | 항목 버림 |
| `body` | 예 | `{ "ko", "en"? }` — 1–600자, 줄바꿈은 `\n` 만 | 항목 버림 |
| `platforms` | 아니오 | `mac` · `win` · `ios` · `ipados` · `android` 중에서, 비어 있지 않은 글자 배열. 모르는 값은 무시 | 항목 버림 |
| `minVersion` · `maxVersion` | 아니오 | `{ "플랫폼": "x.y.z" }`, 양끝 포함. 모르는 키도 값은 버전이어야 한다 | 항목 버림 |
| `syncOnly` | 아니오 | 불리언. `true` 면 이 앱에서 동기화를 켠 사람만 | 항목 버림 |
| `link` | 아니오 | `https://spiralday.com/…` 만 (§8.2) | **링크만** 빼고 항목은 보인다 |
| `expires` | 아니오 | `YYYY-MM-DD`, 그날까지 보인다. important 에는 꼭 | 항목 버림 |

- 모르는 필드는 맨 위 · 항목 안 모두 무시한다. 선택 필드의 `null` 은 없는 것과 같다.
- 글자 수는 유니코드 코드 포인트 (Swift `unicodeScalars.count`, JS `[...s].length`).
- 제목 · 본문에 넣지 못하는 글자: 제어 문자 U+0000–U+001F (본문의 줄바꿈 U+000A 만 예외), U+007F–U+009F, 방향 제어 U+200E · U+200F · U+202A–U+202E · U+2066–U+2069, 줄 · 문단 구분자 U+2028 · U+2029.
- HTML · 마크다운은 해석하지 않는다 (`**굵게**` 는 별표 그대로 보인다).
- 버전: `^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$`, 빈 자리는 0 (`1.2` = `1.2.0`), 자리마다 숫자로 비교 (`1.10` > `1.9`).
- 날짜: `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` 이고 달력에 있는 날 (윤년 포함, 0년 없음). 같은 꼴이라 글자 그대로 비교해도 날짜 순서다.
- 형식을 바꿀 때는 v1 을 고치지 않고 새 주소(예 `news-v2.json`)에 올린다. `news.json` 은 예전 앱을 위해 v1 그대로 둔다.

### 2.1 파일 전체를 읽지 않는 경우 — 받아 둔 것을 그대로 쓴다

1. 65,536 바이트를 넘는다
2. 맨 앞의 UTF-8 BOM(EF BB BF) 하나는 떼고 읽는다. 그 뒤가 UTF-8 이 아니거나 JSON 이 아니다
3. 어디에든(모르는 필드 · 키 포함) 짝 없는 서로게이트가 있다 (U+D800 을 escape 로 적은 것 같은)
4. 객체 · 배열이 16단계보다 깊다 (맨 위 객체가 1단계, `items` 가 2, 항목이 3, `title` 이 4)
5. 맨 위가 객체가 아니다 · `version` 이 숫자 1 이 아니다 (`"1"` · `true` · 2 도 아님) · `items` 가 배열이 아니다

같은 객체에 같은 키가 두 번 나오면 **뒤의 값**을 쓴다 (JS `JSON.parse` 와 같다). 그래도 3 · 4 는 **적힌 글 그대로**, 덮어써진 앞의 값까지 본다 —
뒤의 값만 남기는 파서에 맡기면 앞의 값을 보지 못해 플랫폼마다 달라진다. Kit 의 읽개는 읽으면서 모든 값을 보고, JS 는 `JSON.parse` 앞에
글을 한 번 훑는다 (참고 구현 · web 의 `rawJsonOk`: 문자열 밖 괄호의 깊이, 문자열 안 `\uD800`–`\uDFFF` escape 의 짝).
공유 벡터 `parse` 의 ‘a key written twice …’ 넷. 올리기 전 검사(§9)는 같은 키가 두 번 있는 파일을 아예 오류로 막는다.

## 3. 앱에 넣는 노트 — 이번에 달라진 점

플랫폼마다 앱 묶음 안에 `whats-new.json` 을 넣는다:

```json
{ "version": 1, "notes": [ { "app": "1.2.0", "date": "2026-10-20", "body": { "ko": "…", "en": "…" } } ] }
```

- `app` 은 버전 꼴, `date` 는 출시일, `body` 는 피드와 같은 규칙. 잘못된 노트는 건너뛴다.
- 지금 앱 버전과 **숫자로 같은** 노트가 ‘이번 버전의 노트’ (`1.2` 로 적어도 앱 1.2.0 의 노트, 여럿이면 처음 것). 없으면 그 버전은 카드가 없다.
- 목록에서는 id `app-<app>` (적힌 그대로), 제목 `noteTitle` — ‘`<app>` 에서 달라진 점’ (en ‘What’s new in `<app>`’), 종류 업데이트, 보통, 링크 없음.
- 카드 제목은 지금 **앱 버전** (`whatsNewTitle` — ‘Spiralday 1.2.0’, 노트를 `1.2` 로 적어도. §1.1).
- 글: 그 버전의 릴리스 노트(Mac 은 `Docs/release-notes/<ver>.md`)를 3–5줄로 줄인 같은 목소리. 설치 안내는 빼고 600자 안.
  작은 고침 버전은 노트를 빼도 된다 (카드 없이 지나간다).
- 글 안의 길 표기는 ‘설정 › …’ (카드 아래 글 · 목록과 같게 — 릴리스 노트 .md 의 → 는 그대로 둬도 된다).
- 소식이 처음 들어가는 버전의 노트에는 플랫폼마다 같은 뜻의 안내를 넣는다 (날짜는 실제 출시일):
  ‘- 설정 › 소식이 생겼어요. 새 소식과 업데이트에서 달라진 점을 여기에 모아 둬요’ ·
  ‘- 꼭 알려 드릴 일이 있을 때만, 앱을 열 때 이렇게 한 번 알려 드려요. 푸시 알림은 보내지 않아요’
  (en ‘- Settings › News is new. News and what’s new in each update are kept there’ ·
  ‘- Only when there’s something you need to know, a note like this shows once when you open the app. No push notifications’).
- 파일 자리:
  - Mac — `Docs/release-notes/whats-new.json` 에 버전마다 적고 `build.sh` 가 `Spiralday.app/Contents/Resources/whats-new.json` 으로 넣는다
    (출시 빌드는 이 파일도 커밋한 그대로여야 만든다). `build.sh` 의 `VERSION` 과 숫자로 같은 노트가 없으면 빌드 끝에 한 줄로 알린다
    (작은 고침 버전은 빼도 되니 멈추지는 않는다). `InAppNewsTests.testBundledNotesAreAllRead` 가 노트가 모두 읽히는지 · 릴리스 노트가 있는 버전인지 ·
    길 표기를 본다.
  - iPhone · iPad — 비공개 저장소 `apple/App/Resources/whats-new.json`. `scripts/news-notes-check.sh` (`testflight.sh` 가 먼저 돌린다) 가
    `MARKETING_VERSION` 과 숫자로 같은 노트가 없으면 멈춘다 (일부러 빼면 `NEWS_NO_NOTE=1`).
  - Windows · Android — 비공개 저장소 `web/release-notes/whats-new/windows.json` · `android.json` (빌드 · 출시 글 스크립트가 없으면 알린다).

## 4. 받아 오기

| | |
|---|---|
| 주소 | `https://spiralday.com/news/news.json` 고정 — 쿼리 문자열 · 조각 없음. 출시 빌드에는 바꾸는 길이 없다 |
| 요청 | GET. 앱이 정하는 헤더는 `User-Agent: Spiralday`, `Accept: application/json`, `Accept-Language: *`, 받아 둔 것이 있으면 `If-None-Match`(ETag) · `If-Modified-Since`(Last-Modified) 뿐. 쿠키 · 인증 · Referer 없음. 플랫폼이 연결에 스스로 붙이는 헤더는 아래 |
| 시간 | 연결부터 다 받을 때까지 5초 |
| 넘겨주기 | 따르지 않는다 (3xx 는 실패) |
| 크기 | 65,536 바이트를 넘으면 끊는다 (읽는 중에 못 끊으면 다 받은 뒤 버린다) |
| 200 | §2 대로 받아들이면 본문 · ETag · Last-Modified 를 캐시에 (빈 `items` 도). 아니면 캐시 그대로 |
| 304 · 4xx · 5xx · 시간 초과 · 연결 없음 | 캐시 그대로, 조용히 — 다음 기회에 |
| 언제 | ‘열 때’(§5.1)마다. 단 마지막 시도 뒤 60분이 안 지났으면 건너뛴다. 계속 켜 둔 동안은 24시간마다 한 번 (이때는 목록 · 점만 바뀌고 카드는 다음 ‘열 때’) |
| 끄기 | 설정 › 소식의 스위치를 끄면 요청하지 않는다. 받아 둔 소식과 노트는 그대로 보인다 |
| 개발 · QA | `--demo` · 스냅샷 · 시험 실행은 요청하지 않는다. 디버그 · QA 빌드만 로컬 파일 · 주소로 바꿔 끼울 수 있다 (Mac `--news-feed <파일>` · `SPIRALDAY_NEWS_URL`, iPhone · iPad `--news-feed <파일>`, Windows 개발 실행의 `SPIRALDAY_NEWS_URL`, Android 디버그 빌드의 `qa` 의 `newsUrl=http://127.0.0.1:…`) |

플랫폼별 (모두 지금의 익명 통계 보내기와 같은 방식):

- **Mac · iPhone · iPad** — `URLSessionConfiguration.ephemeral`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCache = nil`,
  `requestCachePolicy = .reloadIgnoringLocalCacheData`, `timeoutIntervalForRequest` · `timeoutIntervalForResource` 5초, 넘겨주기 delegate 에서 `nil`.
  URLSession 이 저절로 붙이는 `Accept-Language` 는 `*` 로 덮어쓴다.
- **Android** — 앱의 네이티브 GET (`NewsHttp.java`, `HttpURLConnection` — WebView 의 CORS · 쿠키 밖): 이 요청만 앱의 쿠키 저장소를 건너뛰고,
  넘겨주기 끄기, 5초, 64 KB 에서 끊기. 받은 **바이트**를 그대로 웹 쪽 검사(§2 · §2.1)에 넘긴다.
  `CapacitorHttp.request` 는 쓰지 않는다 — `application/json` 본문을 객체로 바꿔 BOM · 서로게이트 · 크기 검사에 필요한 바이트를 잃고,
  기기 언어를 `Accept-Language` 로 보낸다. (고칠 때 CapacitorHttp 로 되돌리지 말 것)
- **Windows** — 메인 프로세스의 `fetch` (Node — 쿠키 없음), `redirect: 'manual'`, `AbortSignal.timeout(5000)`. 렌더러는 IPC 로 검사가 끝난 항목만 받는다.
- **플랫폼이 스스로 붙이는 헤더** — 위의 헤더 말고, 플랫폼의 HTTP 가 연결에 필요한 헤더를 스스로 붙인다. 끄는 길은 없고, 기기 · 설치 · 사람을 알아볼 수 있는 값이 아니다:
  - 모두: `Host`, `Connection` (`keep-alive`), `Accept-Encoding` (받을 수 있는 압축 — `gzip` · `deflate` · `br` 중에서, 플랫폼 · 버전마다 다르다)
  - Mac · iPhone · iPad (URLSession): 새 OS 에서는 `Priority` 도 (요청의 우선순위)
  - Windows (Node 의 `fetch`): `Sec-Fetch-Mode: cors` 도
  - Android (`HttpURLConnection`): 위의 셋 (`Accept-Encoding: gzip`)

  시험은 이 목록 밖의 헤더가 없는지 본다 (Kit `InAppNewsFetchTests` · web `newsElectron.test.ts` 의 허용 목록 — 127.0.0.1 서버로 실제 요청.
  Android 의 `NewsHttpTest` 는 정한 헤더 · 쿠키 없음만 본다).
  플랫폼이 붙이는 헤더가 늘면 이 목록과 시험의 허용 목록을 함께 고치고, 알아볼 수 있는 값이면 막는다.
  처리방침(§10)의 ‘설치 번호 · 기기 정보 · 플래너 내용은 붙이지 않아요’ 는 이 헤더들까지 보고 쓴 말이다.
- 소식은 spiralday.com (GitHub Pages) 에만 닿는다. 회사 서버(leanagilehungry.com) · 동기화 서버 · 통계와 상관없고, 받은 것 · 본 것을 어디로도 보내지 않는다.

## 5. 고르기 규칙

참고 구현의 `open` · `list` · `markListSeen` 세 함수 (공유 벡터의 `select`).

입력:

- `platform` — `mac` · `win` · `ios` · `ipados` · `android`. iPad 에서 도는 iPhone · iPad 앱은 `ipados`, Android 폰 · 태블릿은 모두 `android`
- `appVersion` — Mac · iOS `CFBundleShortVersionString`, Android `versionName`, Windows `app.getVersion()`
- `today` — **기기 시간대**의 오늘 `YYYY-MM-DD` (UTC 아님)
- `lang` — 앱 화면이 한국어면 `ko`, 아니면 `en`. iPhone · iPad 는 `Bundle.main.preferredLocalizations.first`.
  Mac · Windows · Android 는 지금 화면이 한국어뿐이라 늘 `ko` (영어 화면이 생기면 그 앱의 화면 언어를 따른다 — 기기 언어가 아니다)
- `syncOn` — 이 앱에서 동기화를 켜 그룹에 들어가 있다 (Mac `SyncController.inGroup`)
- `firstRun` — 이번에 열면서 처음 안내를 띄운다
- 상태(§6) `lastSeenAppVersion` · `since` · `seen`, 캐시에서 받아들인 항목 (없으면 빈 목록), `whats-new.json` 의 노트

### 5.1 ‘열 때’

- 앱을 새로 켰을 때, 또는 60분 넘게 뒤에 있다가 앞으로 돌아왔을 때 (Mac 은 다른 앱을 쓰다 Spiralday 가 다시 활성, iPhone · iPad 는 scene 이 active, Android 는 resume, Windows 는 창 포커스 · 복원).
  앱을 앞에 둔 채 컴퓨터가 60분 넘게 잠들었거나 잠겼다 돌아온 것도 같다 (Mac 잠자기 · 깨어나기, Windows `powerMonitor` 의 절전 · 잠금 — 한 번만).
- 순서: ① 받아 오기를 시작(§4) ② 끝나거나 5초가 지나면 ③ 카드 차례 — 그때의 캐시로 고른다.
  켤 때는 플래너 창이 화면에 나와 앞에 올 때까지도 기다린다 (Windows 의 종이 창은 다 그려진 뒤에 보인다 — 받아 오기가 먼저 끝나기 쉽다).
- 카드 차례에 처음 안내를 띄우는 중이면 `open(firstRun: true)` 의 저장만 하고 카드는 없다.
- 플래너가 앞에 있고, 다른 창 · 시트 · 메뉴 · 팝오버 · 둘러보기 · 동기화 연결이 떠 있지 않고, 글을 쓰는 중도 아니면 `open()` 의 저장을 하고 그 카드를 띄운다.
  그렇지 않으면 이번에는 건너뛴다 (아무것도 저장하지 않고 다음 ‘열 때’ 다시). ‘앞에 있다’는 이 앱이 활성이고 플래너 창이 그 앞 창이라는 뜻 —
  켜는 사이 다른 앱으로 옮겼으면 건너뛴다 (Mac `NSApp.isActive`, iPhone · iPad `applicationState == .active`, Windows 포커스 창이 종이 창).
- 카드 차례에 앱이 앞에 있지 않아 건너뛰었으면 (뒤에서 켜진 앱 — Mac 로그인 항목 · `open -g`, 켜자마자 다른 앱으로 간 경우) 앱이 **처음 앞으로 올 때**를
  ‘열 때’로 친다 — 60분을 기다리지 않는다. 한 번도 앞에 온 적이 없는 앱은 ‘뒤로 간 때’가 없어, 이렇게 하지 않으면 업데이트 노트 · 중요한 소식이
  다음에 60분 넘게 자리를 비울 때까지 밀린다.
- 본 것을 저장할 수 없는 실행(설정 파일을 읽지 못해 건드리지 않는 실행 등)은 카드를 띄우지 않는다 — 닫아도 다음에 또 뜨게 되니까. 목록은 그대로.
- **열 때 카드는 하나**: 카드(소식 카드든 이번에 달라진 점 카드든)를 띄운 실행에서는 저절로 뜨는 둘러보기 · 제안을 다음 실행으로 미룬다 —
  카드가 떠 있는 동안만이 아니라, 카드가 닫힌 뒤에도 그 실행에서는 (한 번에 하나, 연달아 두 번 뜨지 않게). 미루는 것: iPhone · iPad 는 켤 때의
  둘러보기 시작 카드 · 이어 보기, Android 는 둘러보기 시작 카드 · ‘새로 생긴 기능’ · 이어 보기, Windows 는 처음 둘러보기 · GitHub ⭐ 부탁,
  Mac 은 GitHub ⭐ 제안.
- **GitHub ⭐ 제안과 카드가 같은 실행에 겹칠 때** (Mac · Windows — 서로 다른 날로 7일째, 켜고 4초 뒤에 한 번 묻는다). 어느 쪽이 먼저든
  한 번에 하나만 뜨니 둘 다 ‘열 때 카드는 하나’를 지킨다:
  - Mac — 소식이 먼저. ⭐ 제안은 4초 뒤 켤 때의 카드 차례(받아 오기 5초까지 + 자리 잡기 1.5초)가 끝나기를 기다렸다가 정하고,
    그 실행에서 카드를 띄웠으면 다음 실행으로 (`Sources/Spiralday/StarPrompt.swift` 의 `schedule` — `NewsCenter.launchTurn` 을 기다린 뒤
    `yieldsToNews`, 시험 `InAppNewsMacTests.testACardShownThisRunHoldsTheStarPromptUntilTheNextLaunch`).
  - Windows — ⭐ 부탁은 종이 창이 열리고 4초 뒤에 한 번 정하고, 카드 차례를 기다리지 않는다. 그때 이 실행에서 카드를 이미 띄웠으면(떠 있든 닫았든)
    다음 실행으로 (`web/src/shell/starRules.ts:83` `canPresent` ← `StarPrompt.tsx:33` `newsCardShownThisRun()`, 카드를 띄울 때
    `web/src/news/controller.ts:112` `noteNewsCardShown()` — 2026-10-12 `web/in-app-news` 4206d18 의 줄).
    카드 차례가 4초보다 늦으면 — 주로 받아 오기가 4초를 넘을 때 (받아 오기는 5초까지) — ⭐ 대화상자가 먼저 뜨고, 소식의 카드 차례는 그 대화상자
    (`role="alertdialog"`)를 보고 건너뛴다 (`web/src/news/controller.ts:108` `newsBusy` → `:79` `appUiOpen`,
    `web/src/tour/mobile/controller.ts:152`). 건너뛴 차례는 아무것도 저장하지 않으니 그 소식은 다음 ‘열 때’ 뜬다.
- 창이 여럿이어도 앱 하나에 한 번.

### 5.2 보이는 항목

1. `date` ≤ today (뒷날 것은 그날부터)
2. `expires` 가 없거나 today ≤ `expires` (그날까지)
3. `platforms` 가 없거나 지금 플랫폼이 들어 있다 (`ios` 와 `ipados` 는 다른 값)
4. 버전: `minVersion` · `maxVersion` 에서 지금 플랫폼의 키를 쓴다. `ipados` 는 그 키가 없으면 `ios` 키 (같은 앱). 키가 있으면 min ≤ 앱 버전 ≤ max.
   앱 버전이 버전 꼴이 아니면 이 플랫폼 키가 있는 항목은 숨긴다
5. `syncOnly` 면 `syncOn` 일 때만

이번 버전의 노트(§3)도 목록에 들어간다.

### 5.3 순서

날짜가 늦은 것부터. 같은 날이면 이번 버전의 노트가 먼저, 그다음 파일에 적힌 순서. 중요도는 순서에 쓰지 않는다.

### 5.4 open() — 카드 하나와 저장

- **처음 안내(firstRun)**: 카드 없음. `lastSeenAppVersion` = 앱 버전 (저장된 것이 더 높으면 그대로), `since` 가 없으면 today, 이번 버전의 노트 id 를 `seen` 에.
- 그 밖:
  - updated = 앱 버전이 버전 꼴이고, `lastSeenAppVersion` 이 없거나(소식 이전 버전에서 올라옴) · 버전 꼴이 아니거나 · 더 낮다
  - whatsNewDue = updated 이고, 이번 버전의 노트가 있고, 그 id 가 `seen` 에 없다 (설정 › 소식에서 이미 읽었으면 띄우지 않는다)
  - 카드 = ① 보이는 항목 중 §5.3 순서로 처음인, `seen` 에 없는 `important` → **소식 카드**, 그 id 를 `seen` 에
    ② 없으면 whatsNewDue 일 때 **이번에 달라진 점 카드**, 노트 id 를 `seen` 에
  - updated 면 `lastSeenAppVersion` = 앱 버전. 단 whatsNewDue 인데 소식 카드가 자리를 차지했으면 그대로 둔다 → 다음 ‘열 때’ 이번에 달라진 점
  - 낮은 버전으로 되돌렸으면 아무것도 바꾸지 않는다 (높은 버전을 기억한다)
- 카드는 ‘열 때’마다 하나. 중요한 소식이 둘이면 다음 ‘열 때’ 다음 것.
- 중요한 소식은 새로 설치한 분께도 (처음 안내 다음의 ‘열 때’) 한 번 뜬다 — `expires` 전이면 그분도 알아야 할 것이라서. 그래서 important 에는 `expires` 를 꼭 적는다.

### 5.5 list() — 목록과 점 · markListSeen()

- 줄: 보이는 항목을 §5.3 순서로. 제목 · 본문은 `lang` 으로, `en` 이 없는 글만 ko 로 (제목과 본문은 따로).
- 안 본 줄(점) = `seen` 에 없고, 그리고 (`important` 이거나 · `since` 가 없거나 · `date` ≥ `since`).
  새로 설치하기 전에 올라온 **보통** 소식에는 점이 없다.
- ‘소식’ 항목의 점 = 안 본 줄이 하나라도 있다.
- markListSeen: 목록을 열면 보이는 줄의 id 를 모두 `seen` 에.

### 5.6 오프라인 · 실패

받아 둔 것이 없으면 노트만 보인다. 실패는 조용히 지나가고 다시 묻지 않는다. 카드 차례는 받아 오기를 5초 넘게 기다리지 않는다.

## 6. 저장 — 기기마다, 로컬만

| 키 | 값 |
|---|---|
| `news.lastSeenAppVersion` | 마지막으로 연 앱 버전 |
| `news.since` | 새로 설치한 날 `YYYY-MM-DD`. 소식 이전 버전에서 올라온 분은 없다 |
| `news.seen` | 본 id, 오래된 것부터. 200개를 넘으면 앞에서 지운다 |
| `news.fetchEnabled` | 받아 오기 스위치 (기본 true) |
| 캐시 | 마지막으로 받아들인 피드 바이트 · ETag · Last-Modified · 마지막 시도 시각 |

- Mac · iPhone · iPad: UserDefaults (`news.` 접두), 캐시는 Caches 폴더(`Caches/<묶음 id>/`)의 `news.json` 과 ETag · Last-Modified ·
  마지막 시도 시각을 적은 `news-meta.json` (지워지면 다시 받으면 된다 — `news.json` 이 없으면 조건부 헤더도 보내지 않는다). Kit `NewsDefaultsStorage`.
- Windows · Android: `app-settings.json` 의 `news.*` (기기마다 — 클라우드 백업 · 동기화 밖), 캐시는 앱 캐시 폴더의 `news/news.json`
  (Windows `sessionData/news/`, Android `<cache>/news/`).
- 동기화로 보내지 않고, 통계에도 넣지 않는다 (카드를 봤는지 세지 않는다).
- 데모 · 스냅샷 · 시험 실행은 이 값을 읽거나 쓰지 않는다 (메모리 값만).

## 7. 공유 벡터

`Tests/Fixtures/news-rules.json` — 비공개 저장소의 `web/tests/fixtures/news-rules.json` 과 **같은 바이트**
(`web/tests/kitSharedVectors.test.ts` 의 `SHARED` 에 더한다. 바꿀 때는 두 저장소를 함께 — `comment-return.json` 과 같다).

| 표 | 확인하는 것 |
|---|---|
| `request` · `limits` | 앱의 상수가 이 값과 같다 |
| `dates` · `versions` · `links` | 날짜 · 버전 꼴과 비교 · 링크 허용 목록 |
| `parse` | 받은 바이트 → 파일을 받아들이는지, 남는 id 와 링크 |
| `select` | 열 때의 카드 · 저장, 그 뒤의 목록 · 점 (`selectDefaults` 위에 덮어쓴다), 목록을 연 뒤에는 점 없음 |
| `fetch` | 응답 → 캐시를 바꿀지 둘지 |
| `copy` | 카드 · 설정 › 소식의 글 (§1.3 의 표와 글자까지 같다) — Kit `NewsCopy` · web `NEWS_COPY` 가 이 값과 같다 |
| `dateLabels` | 줄 · 카드 위 작은 글자의 날짜 (§1.2) — Kit `NewsRules.displayDate` · web `newsDateLabel` |
| `icon` | 설정 › 소식의 아이콘 · 타일 색 (§1.2) |

벡터 안의 약속은 파일의 `conventions` 에 있다: `feed` 는 아무 JSON 쓰개로 직렬화해 **바이트로** 넘기고, `feedText` 는 그 글 그대로,
`feedBase64` 는 그 바이트 그대로, `bom` · `padToBytes`, `{"$repeat": …, "times": n}` 펼치기, `copy` 의 자리 표시.

**지금의 바이트**: sha256 `9b64bb475da6f2628729da9f46b20ddee44046ca1ff6ba34a49796bc53976890` · 66,262 바이트.
두 저장소의 파일과 앱 쪽 시험이 고정해 둔 값(Kit `InAppNewsTests.fixtureSHA256` · 크기, iPhone · iPad `KitSharedVectorsTests`)은 이 줄과 같아야 한다.
벡터를 바꾸면 이 줄도 함께 — `node Scripts/news-check.mjs --fixtures` 가 다르면 맞는 값을 알려 주고 멈춘다.

자리:

- SpiraldayKit: `Sources/SpiraldayKit/InAppNews.swift` (순수 `NewsRules` — 읽기 · 걸러 내기 · open · list · markListSeen · 날짜 글 · 문구 `NewsCopy`),
  `Sources/SpiraldayKit/InAppNewsFetch.swift` (받기 `NewsFetcher` · `NewsURLSessionTransport`, 저장 `NewsDefaultsStorage` · `NewsMemoryStorage` —
  iPhone · iPad 도 그대로 쓴다), `Tests/SpiraldayKitTests/InAppNewsTests.swift` · `InAppNewsFetchTests.swift` (127.0.0.1 의 작은 서버로 실제 요청).
  iPhone · iPad 는 `KitSharedVectorsTests` 에서 같은 파일을 읽는다.
- web: `web/src/core/news.ts` (`NEWS_COPY` · `newsDateLabel` · `rawJsonOk`), `web/tests/news.test.ts`.
- 참고 구현: `node Scripts/news-check.mjs --fixtures` 가 모든 벡터를 통과하고, 이 문서가 벡터와 같은 말을 하는지(§1.3 표 · 아이콘 · 위의 바이트) 본다.

합치는 순서 — Kit 가 먼저:

1. 공개 저장소 `feature/in-app-news` (Kit `InAppNews.swift` · `InAppNewsFetch.swift` · `NewsCopy` 와 Mac. 이 브랜치의 사양 · 벡터 · 검사기도
   품고 있다) 를 `main` 에 합친다.
2. 그 `main` 커밋으로 iPhone · iPad 시험을 다시 돌린 뒤에 `ios/in-app-news` 를 합친다 (비공개 저장소 `sync` 로 — `apple/README.md`).
   iPhone · iPad 는 옆 체크아웃(`../paper-planner`)의 Kit 로 빌드하는데 지금 `main` 에는 소식 Kit 가 없어, 먼저 합치면 `main` 으로 하는 빌드가
   깨진다. 그때까지 로컬은 옆 체크아웃을 `feature/in-app-news` 로, CI 는 `scripts/use-remote-kit.sh feature/in-app-news`.
3. Windows · Android 는 Kit 를 쓰지 않아 (web 의 자기 구현) 이 순서와 상관없다. `windows-1.0.0` 은 `web/in-app-news` 를 이미 품고 있다.

## 8. 보안

### 8.1 글로만

- SwiftUI 는 `Text(verbatim:)` (`LocalizedStringKey` 는 마크다운을 해석한다). AppKit · UIKit 텍스트 뷰는 링크 · 데이터 감지를 끈다.
  React 는 텍스트 노드로 (`dangerouslySetInnerHTML` · `innerHTML` 금지), 줄바꿈 · 띄어쓰기는 적힌 그대로 `white-space: pre-wrap`
  (`pre-line` 은 이어진 띄어쓰기를 하나로 줄이고 줄 앞 들여쓰기를 지운다 — `Text(verbatim:)` 과 달라진다).
- 숫자 · 주소 · 날짜를 링크로 바꾸지 않는다. 누를 수 있는 링크는 `link` 하나뿐.

### 8.2 링크

- `^https://spiralday\.com/[A-Za-z0-9._~/-]*(#[A-Za-z0-9._~-]*)?$`, 200자 이하.
  쿼리 · 퍼센트 인코딩 · 포트 · 사용자 정보 · 대문자 · `www.` · `http:` 모두 안 된다.
- URL 파서로 고쳐 읽지 말고 이 꼴로만 검사한다 (파서마다 다르게 고친다). 열 때 한 번 더 검사한다 —
  Windows 는 메인 프로세스의 `shell.openExternal` 바로 앞에서, Android 는 네이티브에서.
- 시스템 브라우저로 연다: Mac `NSWorkspace.shared.open`, iPhone · iPad `UIApplication.shared.open` (앱 안 브라우저 아님), Android `Intent.ACTION_VIEW`, Windows `shell.openExternal`.

### 8.3 언어마다 빠지기 쉬운 곳 (벡터가 잡는다)

- 글자 수: Swift 의 `String.count` 는 글자 묶음, JS 의 `length` 는 UTF-16 — 둘 다 아니고 코드 포인트.
- 정규식: `\d` 대신 `[0-9]` (Swift 의 `\d` 는 다른 문자의 숫자도 맞춘다). 끝의 `$` 는 ICU · Swift 에서 마지막 줄바꿈 앞에도 맞을 수 있다 → `\z` 나 글자 검사.
- JSON: `JSONSerialization` 의 NSNumber 는 `true` 와 `1` 을 섞는다 → `version` · `syncOnly` 는 CFBoolean 을 가려 읽거나 Codable 로.
  짝 없는 서로게이트 · 깊이 · BOM 은 §2.1 대로 직접 확인한다 — 파서가 남긴 값이 아니라 적힌 글에서 (같은 키의 덮어써진 값까지).
  JS 는 `JSON.parse` 앞에 글을 한 번 훑는다 (참고 구현 `rawJsonOk`).
- 날짜는 달력 날짜 문자열끼리 비교하고, 보이는 날짜 글(§1.2)도 그 문자열에서 바로 만든다 (시각으로 바꾸지 않는다 — `dateLabels`).

## 9. 소식 올리기

1. `site/news/news.json` 의 `items` **맨 앞**에 항목을 더한다. id 는 `날짜-짧은-이름` (예 `2026-10-20-sync-check`).
   한 번 올린 id 는 바꾸지 않는다 — 글을 고쳐도 이미 본 분께 다시 뜨지 않는다. 다시 알려야 하면 새 id 로.
2. 한국어 · 영어 둘 다 쓴다 (`en` 이 없으면 영어로 쓰는 분께도 한국어로 보인다). 앱의 목소리대로 짧고 따뜻하게, 본문 600자 안.
3. `important` 는 꼭 알아야 할 것만 (요금 · 약관 · 처리방침 · 점검 · 꼭 필요한 업데이트) — 그리고 `expires` 를 꼭.
   미리 알릴 일은 바뀌는 날보다 30일 이상 앞에 올린다. `date` 를 뒷날로 적으면 그날부터 보인다.
4. 검사: `node Scripts/news-check.mjs site/news/news.json` — 앱이 버릴 항목 · 빠질 링크 · 한 객체에 두 번 나온 키가 있으면 오류,
   en · expires 가 없으면 주의.
   배포 워크플로(`.github/workflows/pages.yml`)도 이 검사를 통과해야 사이트를 올린다.
5. `main` 에 올리면 GitHub Pages 로 몇 분 안에 나간다 (페이지 캐시 10분). 앱은 다음 ‘열 때’ 받아서, 중요한 소식이면 그때 카드로 띄운다.
6. 내리기: 항목을 지우면 다음에 받을 때 목록에서 사라진다 (본 기록은 기기에 남는다). `items` 가 비어도 된다.
   파일은 작게 — 1년쯤 지난 것은 지운다 (앱은 앞의 50개 · 64 KB 까지만 읽는다).

## 10. 개인정보 처리방침 — 문구 초안 (privacy.html 은 아직 고치지 않음)

소식이 들어간 첫 앱 버전이 나가기 전에 반영한다.

- 개정 줄에: `2026년 ○월 ○일 (앱 안 ‘소식’ 추가)`
- 요약 목록에 한 줄:
  > **앱 안 소식** — spiralday.com 의 공개 파일을 읽어 오기만 해요. 어떤 소식을 봤는지는 내 기기에만 남아요
- 4. 처리 장소와 외부 서비스, ‘앱을 받고 업데이트하는 곳’ 다음에:
  > 앱 안 ‘소식’: 앱을 열 때(켜 둔 동안은 하루 한 번) spiralday.com 의 소식 파일(https://spiralday.com/news/news.json)을 읽어 와요.
  > 웹 페이지를 열 때처럼 IP 주소와 요청 시각은 이 사이트를 여는 GitHub Pages 에 닿지만, 설치 번호 · 기기 정보 · 플래너 내용은 붙이지 않아요
  > (User-Agent 도 ‘Spiralday’ 뿐이에요). 어떤 소식을 봤는지는 내 기기에만 남고 회사로 보내지 않아요.
  > 설정 → 소식에서 ‘spiralday.com 에서 소식 받기’를 끄면 받아 오지 않아요.
- 9. 바뀔 때:
  > 이 방침이 바뀌면 이 페이지와 앱 안 ‘소식’, 앱 릴리스 노트 · 스토어의 업데이트 설명으로 알려요.

## 11. 나누어 할 일

| 어디 | 할 일 |
|---|---|
| 공개 저장소 (이 브랜치 `site/news-feed`) | 이 문서 · 공유 벡터 · 빈 피드 · 검사기 · 배포 전 검사 — **사양과 벡터는 이 브랜치의 것이 기준** (다른 브랜치는 이 파일들을 그대로 가져간다) |
| SpiraldayKit | `InAppNews.swift` (순수 · `NewsCopy`) · `InAppNewsFetch.swift` (받기 · 저장) + 벡터 시험 (`copy` · `dateLabels` · `icon` 포함) |
| Mac | 받아 오기 · ‘열 때’ · 종이 옆 카드 · 설정 › 소식 (`SettingsPane.news`) · `whats-new.json` 묶기 (`Docs/release-notes/whats-new.json` → `build.sh`) · `--news-feed` · `SPIRALDAY_NEWS_URL` · `--news-qa` 스냅샷 (라이트 · 다크) |
| iPhone · iPad | Kit 쓰기 · 받아 오기 · 종이 위 쪽지 · 설정 › 소식 · `whats-new.json` · `KitSharedVectorsTests` 에 `news-rules.json` |
| Windows · Android (web) | `news.ts` + 벡터 시험 · `SHARED` 에 더하기 · 메인 프로세스 / 네이티브 받아 오기 · 카드 · 설정 › 소식 · `whats-new.json` |
| 사이트 | 처리방침 반영 (§10) — 첫 앱 버전보다 먼저 |

### 이 사양과 맞춘 브랜치 (2026-10-12 확인)

모든 브랜치가 이 사양에 맞는다 — 공유 벡터는 §7 의 바이트 그대로이고 고정해 둔 sha256 · 크기도 같다. `copy` · `dateLabels` · `icon` 시험,
신문 타일 `#C2783A`, `fetchOn` · `paneNote`, 열 때 카드는 하나(§5.1)도 모두 들어 있다. 확인한 커밋:

- Mac · Kit — 공개 저장소 `feature/in-app-news` bd3d62c (벡터 · `Scripts/news-check.mjs` 는 이 브랜치와 같은 파일, 이 문서도 이 브랜치에서 합쳐 간다)
- iPhone · iPad — 비공개 저장소 `ios/in-app-news` 04033a2
- Windows · Android (web) — `web/in-app-news` 4206d18, `windows-1.0.0` 009ff33 (`web/in-app-news` 를 품고 있다)

사양 · 벡터를 바꾸면 위 브랜치를 다시 맞추고 이 목록도 고친다.

### 출시 전 확인 — 소식이 들어간 첫 버전 (플랫폼마다)

1. 개인정보 처리방침(§10)을 **먼저** 올린다. Mac `build.sh` 의 출시 빌드는 `site/privacy.html` 에 소식(`news/news.json`)이 없으면 알린다.
2. `site/news/news.json` 을 `main` 에 합친 뒤 `curl -sI https://spiralday.com/news/news.json` 이 넘겨주기 없이 `200` 인지 본다
   (Mac 출시 빌드도 확인해 알린다). 앱은 3xx 를 따르지 않아, 주소가 바뀌거나 넘겨주면 모든 앱에서 소식이 소리 없이 끊긴다.
3. 그 버전의 ‘이번에 달라진 점’ 노트를 넣는다 (§3 — 소식 안내 한 줄과 실제 출시일).

기본값으로 적어 두었고, 바꾸려면 정해 주실 것:

1. ‘spiralday.com 에서 소식 받기’ 스위치를 둔다 (기본 켬).
2. 업데이트 직후 중요한 소식이 함께 있으면 중요한 소식이 먼저, 이번에 달라진 점은 다음 ‘열 때’.
3. 중요한 소식은 새로 설치한 분께도 `expires` 전까지 한 번 뜬다.
4. Mac: 창이 화면을 꽉 채워(최대화 · 전체 화면) 종이 옆에 자리가 없을 때 — 지금은 카드가 종이 아래 가운데(메모 · 타임테이블 위)에 겹친다.
   그대로 둘지, 그때만 창 시트로 띄울지.
5. Windows · Android 의 카드는 플래너를 옅게 어둡게 덮는 대화상자, Mac · iPhone · iPad 는 덮지 않는다 — 덮개를 맞출지.
6. iPhone · iPad: 책상 여백이 좁아 쪽지가 종이를 일부 가린다 (§1.1 — iPad 세로 일간 82%, iPhone SE 일간 86% · 주간 99%).
   **정할 때까지 지금 자리 그대로.** 바꾸면 §1.1 의 iPhone · iPad 줄도 함께.
