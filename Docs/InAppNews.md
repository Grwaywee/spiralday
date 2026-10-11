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

종이 위에 그리지 않는다. Mac 은 플래너 창 옆 여백의 작은 카드 (팔레트처럼 창에 붙어 함께 움직인다 — 팔레트의 반대쪽 → 아래 → 위 → 팔레트 너머 중
화면에 들어가고 팔레트 · 스프링과 겹치지 않는 첫 자리. 창이 화면을 꽉 채워 자리가 없을 때만 종이 아래 가운데에 겹친다),
iPhone · iPad 는 시트(iPhone 은 중간 높이), Windows · Android 는 앱의 기존 대화상자 모양.
소리 · 진동 없음, 플랫폼 기본보다 큰 움직임 없음.

| | 소식 카드 | 이번에 달라진 점 카드 |
|---|---|---|
| 위 작은 글자 | 소식 · 10월 20일 (en News · Oct 20) | 이번에 달라진 점 (en What’s new) |
| 제목 | 항목의 `title` | Spiralday 1.2.0 |
| 본문 | 항목의 `body` (길면 카드 안에서 스크롤) | 노트의 `body` |
| 아래 | [자세히 보기] (`link` 가 있을 때만, en Learn more) · [확인] (en OK) | ‘설정 › 소식에서 다시 볼 수 있어요.’ (en You can read this again in Settings › News.) · [확인] |

- **띄우는 순간 본 것**으로 저장한다 (§5.4). [확인] · Esc · 바깥 누르기 · 아래로 쓸기 · 뒤로 가기 — 어떻게 닫아도, 그 사이 앱이 꺼져도 다시 뜨지 않는다.
- [자세히 보기]는 시스템 브라우저로 열고(§8.2) 카드를 닫는다.

### 1.2 설정 › 소식

- 자리: Mac 은 설정 창의 새 항목 ‘소식’ (`SettingsPane.news`, 부제 ‘새 소식과 업데이트에서 달라진 점을 모아 둬요.’), iPhone · iPad · Windows · Android 는 설정 목록의 ‘소식’.
  (선택: Mac 도움말 메뉴의 ‘소식…’ 으로 이 항목을 연다)
- 줄: 날짜 · 종류(작은 글자 ‘알림’ · ‘업데이트’, en Notice · Update) · 제목, 안 본 줄은 제목 앞에 작은 점. 누르면 펼쳐 본문과 [자세히 보기].
- 날짜: 올해면 ‘10월 20일’ (en Oct 20), 아니면 ‘2025년 12월 3일’ (en Dec 3, 2025). `YYYY-MM-DD` 를 달력 날짜 그대로 쓴다 —
  UTC 시각으로 바꾸지 말 것 (JS 의 `new Date('2026-10-20')` 은 UTC 자정이라 미국에서는 19일로 보인다).
- 비었을 때: ‘아직 소식이 없어요.’ (en No news yet.) — 오프라인 · 받기 실패도 같은 화면. 오류 문구는 보이지 않는다.
- 스위치: ‘spiralday.com 에서 소식 받기’ (기본 켬, en Get news from spiralday.com).
  - 켰을 때 설명: ‘앱을 열 때 spiralday.com 의 소식 파일을 읽어 와요. 설치 번호나 기기 정보는 보내지 않아요.’
  - 껐을 때 설명: ‘받아 오지 않아요. 이미 받은 소식과 이번에 달라진 점은 그대로 볼 수 있어요.’
- 점: 안 본 줄이 있으면 설정 안의 ‘소식’ 항목(Mac 설정 창의 옆 목록, 모바일 · Windows 설정 목록)에만 작은 점. 종이 · 팔레트 · 설정 버튼 · 앱 아이콘에는 아무것도 없다.
- 목록을 열면: 이번에 보이는 점은 그대로 두고(무엇이 새것인지 보이게) 보이는 줄을 모두 본 것으로 저장한다(§5.5) → ‘소식’ 항목의 점은 바로 사라지고, 다음에 열면 줄의 점도 없다.

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

## 3. 앱에 넣는 노트 — 이번에 달라진 점

플랫폼마다 앱 묶음 안에 `whats-new.json` 을 넣는다:

```json
{ "version": 1, "notes": [ { "app": "1.2.0", "date": "2026-10-20", "body": { "ko": "…", "en": "…" } } ] }
```

- `app` 은 버전 꼴, `date` 는 출시일, `body` 는 피드와 같은 규칙. 잘못된 노트는 건너뛴다.
- 지금 앱 버전과 **숫자로 같은** 노트가 ‘이번 버전의 노트’ (`1.2` 로 적어도 앱 1.2.0 의 노트, 여럿이면 처음 것). 없으면 그 버전은 카드가 없다.
- 목록에서는 id `app-<app>` (적힌 그대로), 제목 ‘`<app>` 에서 달라진 점’ (en ‘What’s new in `<app>`’), 종류 업데이트, 보통, 링크 없음.
- 글: 그 버전의 릴리스 노트(Mac 은 `Docs/release-notes/<ver>.md`)를 3–5줄로 줄인 같은 목소리. 설치 안내는 빼고 600자 안.
  작은 고침 버전은 노트를 빼도 된다 (카드 없이 지나간다).
- Mac: `Docs/release-notes/whats-new.json` 에 버전마다 적고 `build.sh` 가 `Spiralday.app/Contents/Resources/whats-new.json` 으로 넣는다
  (출시 빌드는 이 파일도 커밋한 그대로여야 만든다). `InAppNewsTests.testBundledNotesAreAllRead` 가 노트가 모두 읽히는지 · 릴리스 노트가 있는 버전인지 본다.

## 4. 받아 오기

| | |
|---|---|
| 주소 | `https://spiralday.com/news/news.json` 고정 — 쿼리 문자열 · 조각 없음. 출시 빌드에는 바꾸는 길이 없다 |
| 요청 | GET. 헤더는 `User-Agent: Spiralday`, `Accept: application/json`, `Accept-Language: *`, 받아 둔 것이 있으면 `If-None-Match`(ETag) · `If-Modified-Since`(Last-Modified) 뿐. 쿠키 · 인증 · Referer 없음 |
| 시간 | 연결부터 다 받을 때까지 5초 |
| 넘겨주기 | 따르지 않는다 (3xx 는 실패) |
| 크기 | 65,536 바이트를 넘으면 끊는다 (읽는 중에 못 끊으면 다 받은 뒤 버린다) |
| 200 | §2 대로 받아들이면 본문 · ETag · Last-Modified 를 캐시에 (빈 `items` 도). 아니면 캐시 그대로 |
| 304 · 4xx · 5xx · 시간 초과 · 연결 없음 | 캐시 그대로, 조용히 — 다음 기회에 |
| 언제 | ‘열 때’(§5.1)마다. 단 마지막 시도 뒤 60분이 안 지났으면 건너뛴다. 계속 켜 둔 동안은 24시간마다 한 번 (이때는 목록 · 점만 바뀌고 카드는 다음 ‘열 때’) |
| 끄기 | 설정 › 소식의 스위치를 끄면 요청하지 않는다. 받아 둔 소식과 노트는 그대로 보인다 |
| 개발 · QA | `--demo` · 스냅샷 · 시험 실행은 요청하지 않는다. 디버그 · QA 빌드만 로컬 파일로 바꿔 끼울 수 있다 (Mac `--news-feed <파일>`, 다른 플랫폼도 같은 뜻의 개발용 스위치) |

플랫폼별 (모두 지금의 익명 통계 보내기와 같은 방식):

- **Mac · iPhone · iPad** — `URLSessionConfiguration.ephemeral`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCache = nil`,
  `requestCachePolicy = .reloadIgnoringLocalCacheData`, `timeoutIntervalForRequest` · `timeoutIntervalForResource` 5초, 넘겨주기 delegate 에서 `nil`.
  URLSession 이 저절로 붙이는 `Accept-Language` 는 `*` 로 덮어쓴다.
- **Android** — `CapacitorHttp.request` (네이티브라 WebView 의 CORS · 쿠키 밖), 넘겨주기 끄기, 5초.
- **Windows** — 메인 프로세스의 `fetch` (Node — 쿠키 없음), `redirect: 'manual'`, `AbortSignal.timeout(5000)`. 렌더러는 IPC 로 검사가 끝난 항목만 받는다.
- 소식은 spiralday.com (GitHub Pages) 에만 닿는다. 회사 서버(leanagilehungry.com) · 동기화 서버 · 통계와 상관없고, 받은 것 · 본 것을 어디로도 보내지 않는다.

## 5. 고르기 규칙

참고 구현의 `open` · `list` · `markListSeen` 세 함수 (공유 벡터의 `select`).

입력:

- `platform` — `mac` · `win` · `ios` · `ipados` · `android`. iPad 에서 도는 iPhone · iPad 앱은 `ipados`, Android 폰 · 태블릿은 모두 `android`
- `appVersion` — Mac · iOS `CFBundleShortVersionString`, Android `versionName`, Windows `app.getVersion()`
- `today` — **기기 시간대**의 오늘 `YYYY-MM-DD` (UTC 아님)
- `lang` — 앱 화면이 한국어면 `ko`, 아니면 `en`. Mac 은 지금 화면이 한국어뿐이라 늘 `ko`, iPhone · iPad 는 `Bundle.main.preferredLocalizations.first`, Windows · Android 는 셸의 `lang`
- `syncOn` — 이 앱에서 동기화를 켜 그룹에 들어가 있다 (Mac `SyncController.inGroup`)
- `firstRun` — 이번에 열면서 처음 안내를 띄운다
- 상태(§6) `lastSeenAppVersion` · `since` · `seen`, 캐시에서 받아들인 항목 (없으면 빈 목록), `whats-new.json` 의 노트

### 5.1 ‘열 때’

- 앱을 새로 켰을 때, 또는 60분 넘게 뒤에 있다가 앞으로 돌아왔을 때 (Mac 은 다른 앱을 쓰다 Spiralday 가 다시 활성, iPhone · iPad 는 scene 이 active, Android 는 resume, Windows 는 창 포커스 · 복원).
- 순서: ① 받아 오기를 시작(§4) ② 끝나거나 5초가 지나면 ③ 카드 차례 — 그때의 캐시로 고른다.
- 카드 차례에 처음 안내를 띄우는 중이면 `open(firstRun: true)` 의 저장만 하고 카드는 없다.
- 플래너가 앞에 있고, 다른 창 · 시트 · 메뉴 · 둘러보기 · 동기화 연결이 떠 있지 않고, 글을 쓰는 중도 아니면 `open()` 의 저장을 하고 그 카드를 띄운다.
  그렇지 않으면 이번에는 건너뛴다 (아무것도 저장하지 않고 다음 ‘열 때’ 다시).
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
  Windows · Android: `app-settings.json` (기기마다 — 클라우드 백업 · 동기화 밖), 캐시는 앱 캐시 폴더.
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

벡터 안의 약속은 파일의 `conventions` 에 있다: `feed` 는 아무 JSON 쓰개로 직렬화해 **바이트로** 넘기고, `feedText` 는 그 글 그대로,
`feedBase64` 는 그 바이트 그대로, `bom` · `padToBytes`, `{"$repeat": …, "times": n}` 펼치기.

자리:

- SpiraldayKit: `Sources/SpiraldayKit/InAppNews.swift` (순수 `NewsRules` — 읽기 · 걸러 내기 · open · list · markListSeen · 날짜 글 · 문구 `NewsCopy`),
  `Sources/SpiraldayKit/InAppNewsFetch.swift` (받기 `NewsFetcher` · `NewsURLSessionTransport`, 저장 `NewsDefaultsStorage` · `NewsMemoryStorage` —
  iPhone · iPad 도 그대로 쓴다), `Tests/SpiraldayKitTests/InAppNewsTests.swift` · `InAppNewsFetchTests.swift` (127.0.0.1 의 작은 서버로 실제 요청).
  iPhone · iPad 는 `KitSharedVectorsTests` 에서 같은 파일을 읽는다.
- web: `web/src/core/news.ts`, `web/tests/news.test.ts`.
- 참고 구현: `node Scripts/news-check.mjs --fixtures` 가 모든 벡터를 통과한다.

## 8. 보안

### 8.1 글로만

- SwiftUI 는 `Text(verbatim:)` (`LocalizedStringKey` 는 마크다운을 해석한다). AppKit · UIKit 텍스트 뷰는 링크 · 데이터 감지를 끈다.
  React 는 텍스트 노드로 (`dangerouslySetInnerHTML` · `innerHTML` 금지), 줄바꿈은 `white-space: pre-line`.
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
  짝 없는 서로게이트 · 깊이 · BOM 은 §2.1 대로 직접 확인한다.
- 날짜는 달력 날짜 문자열끼리 비교한다 (시각으로 바꾸지 않는다).

## 9. 소식 올리기

1. `site/news/news.json` 의 `items` **맨 앞**에 항목을 더한다. id 는 `날짜-짧은-이름` (예 `2026-10-20-sync-check`).
   한 번 올린 id 는 바꾸지 않는다 — 글을 고쳐도 이미 본 분께 다시 뜨지 않는다. 다시 알려야 하면 새 id 로.
2. 한국어 · 영어 둘 다 쓴다 (`en` 이 없으면 영어로 쓰는 분께도 한국어로 보인다). 앱의 목소리대로 짧고 따뜻하게, 본문 600자 안.
3. `important` 는 꼭 알아야 할 것만 (요금 · 약관 · 처리방침 · 점검 · 꼭 필요한 업데이트) — 그리고 `expires` 를 꼭.
   미리 알릴 일은 바뀌는 날보다 30일 이상 앞에 올린다. `date` 를 뒷날로 적으면 그날부터 보인다.
4. 검사: `node Scripts/news-check.mjs site/news/news.json` — 앱이 버릴 항목 · 빠질 링크가 있으면 오류, en · expires 가 없으면 주의.
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
| 공개 저장소 (이 브랜치 `site/news-feed`) | 이 문서 · 공유 벡터 · 빈 피드 · 검사기 · 배포 전 검사 |
| SpiraldayKit | `InAppNews.swift` (순수) · `InAppNewsFetch.swift` (받기 · 저장) + 벡터 시험 |
| Mac | 받아 오기 · ‘열 때’ · 종이 옆 카드 · 설정 › 소식 (`SettingsPane.news`) · `whats-new.json` 묶기 (`Docs/release-notes/whats-new.json` → `build.sh`) · `--news-feed` · `SPIRALDAY_NEWS_URL` · `--news-qa` 스냅샷 (라이트 · 다크) |
| iPhone · iPad | Kit 쓰기 · 받아 오기 · 카드 시트 · 설정 › 소식 · `whats-new.json` · `KitSharedVectorsTests` 에 `news-rules.json` |
| Windows · Android (web) | `news.ts` + 벡터 시험 · `SHARED` 에 더하기 · 메인 프로세스 / 네이티브 받아 오기 · 카드 · 설정 › 소식 · `whats-new.json` |
| 사이트 | 처리방침 반영 (§10) — 첫 앱 버전보다 먼저 |

기본값으로 적어 두었고, 바꾸려면 정해 주실 것:

1. ‘spiralday.com 에서 소식 받기’ 스위치를 둔다 (기본 켬).
2. 업데이트 직후 중요한 소식이 함께 있으면 중요한 소식이 먼저, 이번에 달라진 점은 다음 ‘열 때’.
3. 중요한 소식은 새로 설치한 분께도 `expires` 전까지 한 번 뜬다.
