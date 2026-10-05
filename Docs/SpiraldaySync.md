# SpiraldaySync

Spiralday Sync 클라이언트 엔진 (Swift). Mac · iPad · iPhone 앱이 같은 패키지의 `SpiraldaySync` 제품으로 가져다 쓴다.
Windows 앱의 TypeScript 엔진과 **바이트 · 동작이 같다** — 같은 서버에 두 엔진이 섞여 붙어도 모든 기기가 같은 플래너가 된다.

- **종단간 암호화**: 그룹 키 K 는 기기(Keychain)에만 있다. 서버는 암호문 · 불투명 id · 순번만 본다 (책 이름 · 날짜 · 기기 이름도 암호문).
- **계정 없음**: QR(기본)이나 8자 코드로 들어오고, 새 기기 화면의 확인 숫자 4자리를 원래 기기에 **입력**하고 [연결] 을 눌러야 그룹 키가 간다 (승인 게이트). 모든 기기를 잃으면 25자 복구 코드.
- **충돌 없는 합치기**: 필드마다 HLC 도장 · 마지막 쓴 것이 이김. 타임테이블은 시간 줄마다, 메모 · 메모 태그는 줄마다, 할 일 · 타임테이블 메모 · D-day · 형광펜은 id 별로. 지운 것은 되살아나지 않는다.
- **앱 JSON 형식은 그대로**: 엔진은 앱 파일을 바꾸지 않고, 따로 둔 동기화 상태(그림자 · 도장 · 서버 순번)와 비교해 바뀐 것을 찾는다. 엔진이 앱에 넣는 값은 SpiraldayKit 이 늘 읽을 수 있는 값이다 (퍼징 테스트).
- **꺼 두면 아무것도 하지 않는다**: 엔진을 만들지 않으면 네트워크 요청도 파일도 없다. 앱이 동기화를 켤 때만 만든다.

동기화 서버는 이 저장소에 없다 (운영: `https://sync.spiralday.com`). 프로토콜은 종단간 암호화라 클라이언트 코드가 공개되어도 서버는 플래너 내용을 볼 수 없다.

```
Sources/SpiraldaySync/
  Engine.swift          SyncEngine (actor) — 수명 · 그룹 · 복구 · 기기 · 이전 버전 · 타이머 · WebSocket
  EngineSync.swift      한 바퀴: 비교(앱 → 상태) · 받기 · 409 합치기 · 보내기(batch) · 넣기(상태 → 앱) · 안전장치
  EngineLive.swift      실시간 쓰기: liveEdit · setEditing · 초안 보내기 · 받기 · presence · 보호 칸 · 확인 대기 · 대신 올리기 · 보내기 상황
  EnginePairing.swift   PairingOffer (원래 기기) · PendingJoin (새 기기) · 승인 게이트
  EngineTypes.swift     SyncHost (앱과의 약속) · 상태 · 이벤트 · 오류 · 옵션
  EngineApp.swift       기본 구성 SyncEngine.standard · suspend/resume · os 로그
  Records.swift         앱 JSON ↔ 레코드 (평평한 모양 · 비교 · 상태 → 앱 값 · 날짜 정규화)
  CRDT.swift            레코드 상태와 합치기 (반격자)
  HLC.swift             하이브리드 논리 시계 (32자 고정 폭 도장)
  Crypto.swift          libsodium (swift-sodium): 하위 키 · rid · 봉인 · 기기 이름 · 페어링 · 확인 숫자 · 복구
  Codes.swift           8자 페어링 코드 · 25자 복구 코드 (Crockford base32 + 검사)
  UUIDv5.swift          CarryID.carryTaskId (→ 미룸 할 일의 결정적 id)
  JSON.swift            JSONValue (JS 와 같은 숫자 · 정렬 · 정규 JSON) · 파서
  Gzip.swift            zlib gzip (압축 폭탄 상한 32 MiB)
  Protocol.swift        서버 JSON
  Transport.swift       HTTPTransport (URLSession · URLSessionWebSocketTask)
  Storage.swift         동기화 상태 저장소: FileSyncStorage (일지 + 사본) · 메모리 / Credentials
  Keychain.swift        KeychainCredentialStore (AfterFirstUnlockThisDeviceOnly)
  ServerConfig.swift    서버 주소 (빌드 설정 · 숨은 개발용 덮어쓰기)
Sources/SpiraldaySyncTesting/
  FakeSyncServer.swift  메모리 안의 가짜 서버 (URLProtocol 로 HTTPTransport 를 그대로 · 말 안 듣는 네트워크)
  MemoryHost.swift      메모리 앱 (테스트 · 미리보기)
Tests/SpiraldaySyncTests/  XCTest (아래 표)
```

## 빌드 · 테스트

```bash
swift build
swift test --filter SpiraldaySyncTests     # 동기화 엔진만 (약 35초)

# 오래 돌리기
CONVERGENCE_RUNS=3000 swift test --filter ConvergenceTests
CHAOS_RUNS=300 swift test --filter ChaosTests          # 실패하면 씨앗이 나온다 → CHAOS_SEED=<씨앗>
SPIRALDAY_KEYCHAIN_TEST=1 swift test --filter KeychainTests   # 서명 없는 명령줄에서는 로그인 키체인으로 (테스트마다 따로 된 서비스 이름)
```

| 테스트 | 내용 |
|---|---|
| `VectorsTests` | 프로토콜 테스트 벡터 전부 (하위 키 · rid · 봉인 · 기기 이름 · 페어링 코드/QR · confirmKey · 확인 숫자 · 복구 · carryTaskId · **실시간 초안 K_live · 세 초안 · 반대 벡터 · 크기 · 모양 거절**) 바이트 그대로 |
| `BasicsTests` | 코드(한 글자 틀림 · 이웃 바뀜 검출), UUIDv5(RFC 9562), HLC, base64url, JS 규칙(숫자 → 글 · UTF-16 정렬 · JSON.stringify 이스케이프 · 파서), 날짜, 암호(변조 · 다른 키 · 이름 바꿔치기), **TypeScript 엔진이 만든 암호문을 풀고 같은 상태를 만든다**, 압축 폭탄 · 크기 속임 · `__proto__` |
| `ConvergenceTests` | N 복제본 · 아무 순서 · 중복 · 지연 → 같은 상태 · 같은 앱 데이터, 되살아남 없음, 교환 · 결합 · 멱등, 동시 편집이 모두 남음 |
| `AppDecodeTests` | 받은 상태에 아무 값이 들어 있어도 앱에 넣는 값을 SpiraldayKit 의 진짜 모델(`PlannerData` · `BookInfo`)로 늘 읽을 수 있다 (600번 퍼징) |
| `Engine*Tests` | 엔진 + 가짜 서버: 승인 게이트 (요청 응답 · 기다리는 동안 키 없음, 거절 · 거둠 · 기한 · 취소 · 코드 실패 상한 · 이름 바꿔치기), 주고받기 · 409 · 책 만들기/지우기 · 오프라인 대기열 · 응답만 잃은 쓰기 · 안전장치 · 복구 · 그룹 지우기 · 이전 버전 · 새 버전 레코드 · WebSocket · 다시 붙기 · suspend/resume |
| `LifecycleAndLossyHostTests` | 올리는 동안(느린 망) 앞으로 돌아오면 엔진이 멈추지 않음 · 모르는 키를 버리는 앱(모델로 다시 쓰는 앱)이 새 버전 기기의 키를 `null` 로 지우지 않음 |
| `ChaosTests` | 엔진 2–3대 + 요청이 늦게 · 뒤섞여 · 두 번 · 안 닿거나 응답만 사라지는 네트워크, 동시 편집 · 동시 동기화 → 수렴 · 되살아남 없음 |
| `StorageTests` | 파일 저장소 (일지 다시 읽기 · 사본으로 줄이기 · 끊긴 마지막 줄 · 사본 뒤 옛 일지), 껐다 켜도 남는 오프라인 편집, Keychain, 서버 주소 |
| `Live*Tests` | 실시간 쓰기 (가짜 서버의 중계 · presence 흉내): 한글 조합 단계 · 할 일 · 칠하기가 상대 앱에 바로, 받은 기기는 올리지 않음 · 뒤따른 레코드는 바뀌는 것 없음, 닫힌 책은 보통 넣기, 옛 서버 · 듣는 기기 없음 · `live: false` · 섞인 그룹(옛 앱), 보내기 대기 · 버킷 · 너무 큰 조각, 재생 · 위조 · 자기 것 · 모양 거르기(다시 켠 뒤에도) · 시계가 9시간 다른 기기, 반쪽 항목 없음, 보호 칸(핑퐁 없음 · 쓰는 중 한 글자 · 포커스만 있는 칸 · 쉬면 들어옴 · 지운 할 일), 저장 전 죽음(보낸 쪽 · 받은 쪽 · 미뤄 둔 칸 · 파일이 먼저 쓰임), 저장 알림, 대신 올리기(다시 켠 뒤에도), 상황별 보내기 지연 · 자기 쓰기 다시 받지 않기 · `sendPending` · presence 가 늘면 바로, 멈췄다 켜기 · 뒤로 가기의 미뤄 둔 칸, 칸마다 지키기(↓ 로 옮긴 칸), 받기만 한 변경의 저장 간격 · 넣기 묶음 · 저전력, 찬 보내기 대기의 물러서기 · 답 없는 ping · live 를 받지 않는 서버 |
| `LiveChaosTests` | property: 초안이 늦게 · 두 번 · 순서가 바뀌어 · 안 닿고 HTTP 도 혼란 · 앱 파일 저장 전 죽음 · 보호 칸 · 시계 → 모든 기기가 같고 보낼 것이 없다 (`LIVE_CHAOS_RUNS`), 저절로 도는 타이머와 겹치는 경주 (`LIVE_RACE_RUNS`) |

진짜 서버 · TypeScript 엔진과 함께 붙이는 교차 언어 끝-끝 테스트는 서버 코드와 함께 따로 돌린다 (이 저장소에는 없다).

## 앱에 붙이기

### 1. 패키지

이 저장소의 패키지(`Spiralday`)를 더하고 `SpiraldaySync` 제품을 쓴다. 의존성은 `swift-sodium` (libsodium xcframework) 하나. iOS 17 · macOS 14 이상.

```swift
// Package.swift
.package(url: "https://github.com/Grwaywee/spiralday", branch: "main"),
// target
.product(name: "SpiraldaySync", package: "spiralday"),
```

XcodeGen 이면 `packages:` 에 같은 저장소(로컬 체크아웃은 `path:`)를 두고 `product: SpiraldaySync`.
테스트에서 가짜 서버(`SpiraldaySyncTesting`)를 쓸 때: Xcode 앱 + 단위 테스트 번들 둘 다에 패키지 제품을 링크하면 Xcode 가 `SpiraldaySync` 를 동적 프레임워크로 감싸며 libsodium(정적 xcframework)을 빠뜨린다 → `Sources/SpiraldaySyncTesting` 을 테스트 타깃의 소스로 넣고 `SpiraldaySync` 는 테스트 호스트(앱)의 것을 쓴다.

### 2. 서버 주소

| 순서 | 어디 | 쓰는 때 |
|---|---|---|
| 1 | `UserDefaults` 의 `SpiraldaySyncServerURLOverride` | 숨은 개발용 덮어쓰기. `SyncServerConfig.setDeveloperOverride("http://127.0.0.1:<포트>")`, 또는 실행 인수 `-SpiraldaySyncServerURLOverride http://127.0.0.1:<포트>` |
| 2 | 환경 변수 `SPIRALDAY_SYNC_URL` | 테스트 · 명령줄 |
| 3 | Info.plist 의 `SpiraldaySyncServerURL` | 빌드 설정. xcconfig 에 `SPIRALDAY_SYNC_URL = https:/$()/sync.spiralday.com` 을 두고 Info.plist 에 `$(SPIRALDAY_SYNC_URL)` |
| 4 | 기본값 | `https://sync.spiralday.com` |

https 만 받는다. http 는 개발 서버(localhost · 127.0.0.1 · ::1 · `*.local` · 사설망 IP)에만. 출시 빌드는 앱이 덮어쓰기를 받지 않게 한다.

### 3. 엔진 만들기

```swift
import SpiraldaySync

let host = PlannerSyncHost(store: plannerStore)          // 아래 4
let sync = try SyncEngine.standard(host: host, platform: .mac)   // iPad: .iPad · iPhone: .iPhone
try await sync.initialize()                               // 그룹에 들어 있으면 바로 동기화 시작
```

`standard` = HTTPTransport(서버 주소) + `FileSyncStorage(Application Support/Spiralday/SyncState)` + `KeychainCredentialStore(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)` + os 로그.
따로 짜려면 `SyncEngine(SyncEngineOptions(host:transport:storage:credentials:platform:…))`.

- 동기화 상태는 앱 파일(`library.json` · `books/`)과 섞지 않는다 (바꾸려면 `storageDirectory:`). 오프라인 동안의 편집은 여기에 남았다가 다음에 올라간다. 비밀(토큰 · K)은 여기가 아니라 Keychain 에 있다.
- 테스트 · QA 는 `keychainService:` 에 따로 된 이름을, `storageDirectory:` 에 따로 된 폴더를 준다 (실제 사용자 항목을 건드리지 않게).
- iOS: 앱을 지웠다 다시 깔면 Keychain 의 자격은 남고 동기화 상태 폴더는 사라진다 → 엔진은 같은 기기로 다시 붙어 이 기기의 플래너를 "시각 0" 으로 다시 합친다. 다시 깐 뒤 새로 시작하게 하려면 첫 실행 표시(UserDefaults)가 없을 때 `KeychainCredentialStore().set(nil)` 을 부른다. 동기화 상태 파일이 깨졌으면 옆에 남겨 두고(`state.json.corrupt-…`) 같은 방법으로 다시 맞춘다.

### 4. 호스트 (앱 데이터를 읽고 고치는 곳)

엔진은 앱 JSON 을 `JSONValue` 로 받는다 — SpiraldayKit 모델에 의존하지 않는다. 앱 쪽 어댑터는 SpiraldayKit 이 주는 것만으로 짠다 (`Sources/SpiraldayKit/ExternalChanges.swift` · `TaskIDs.swift`):

| SpiraldayKit (`PlannerStore`, MainActor) | 하는 일 |
|---|---|
| `onSaved: ((UUID?, Bool) -> Void)?` | 저장소가 파일을 쓴 뒤 (책 id · library.json 을 썼는지). 사용자 편집 · 책 만들기 · 책 정보 · 펼친 책 바꾸기 · `apply…` 가 쓴 것. `writeBookRaw` · `removeBookFile` 은 알리지 않는다 |
| `onDeleted: ((UUID) -> Void)?` | 사용자가 책을 지웠다 (`deleteBook`). 밖에서 지운 책은 알리지 않는다 |
| `libraryCreated: Bool` | 이번 실행에서 library.json 이 없어 책장을 새로 시작했다 → `libraryRecreated()` |
| `libraryUnreadable` · `unreadableBooks` | 읽지 못한 파일 (그대로 둔다) |
| `booksOpenedWithoutFile: Set<UUID>` · `clearOpenedWithoutFile(_:)` | 이번 실행에서 파일 없이 (빈 책으로) 편 책 — 막 만든 책이 아니라 파일을 잃은 책. 호스트는 엔진이 받아들일 때까지(`missingNoted` · `updateBook`) 이 책을 `readBook` 에 `.missing` 으로 알리고, `updateBook` 에도 `nil` 을 넘기고(펼친 책이어도 — IME 조합 중이어도), 실시간으로 다루지 않는다 (`readLive` → nil · `applyLive` → false). 빈 책을 이 기기의 편집으로 비교하면 다른 기기의 할 일 · COMMENT · 형광펜이 모두 지워진다 — 엔진은 동기화된 내용으로 되살린다 |
| `applyLibrary(_ merged: Library) -> ExternalApplyResult` | 책장 넣기. 펼친 책(activeID)은 이 기기의 것 그대로 · 빠졌으면 그 책은 저장하지 않고 다른 책을 편다 (`closedBook` · `openedBook`) · 아무 책도 안 폈으면 들어온 내가 만든 첫 책을 편다 · `sampleSeeded` 는 지우지 않음 · 같은 id 는 앞의 것만 · `libraryUnreadable` 이면 아무것도 안 함 · 같으면 아무것도 안 함. 바뀌면 library.json 에 쓰고 `onSaved(nil, true)` |
| `applyActiveData(_ merged: PlannerData, keepingEditOf: String?) -> ExternalApplyResult` | 펼친 책 넣기 + **바로 저장** (`onSaved(id, true)`). 쓰고 있는 칸(`AppState.editingKey`)은 화면의 글을 지킴 (`keptEdit` — 다음 비교에서 새 편집으로 올라간다), 쓰던 할 일 · 메모가 지워졌으면 `editedItemRemoved`. `lastKind` · `ddaysPerDay` 는 이 기기의 것, 줄 없는 할 일은 줄을 매김, 같으면 아무것도 안 함 |
| `readBookRaw(_ id: UUID) -> RawBookFile` | `.missing` · `.unreadable` · `.data(Data)` (앱이 읽을 수 있는 것만). **펼친 책이면 지금 내용** (저장 전 편집 포함). 읽지 못하면 책을 열 때처럼 복사본을 남기고 `unreadableBooks` 에 적는다 |
| `writeBookRaw(_ id: UUID, _ raw: Data) throws` | 펼치지 않은 책 파일을 그대로 원자적으로 쓴다 (책장에 아직 없는 책도). 거절 `BookFileError`: `.bookIsOpen` · `.unreadable` · `.invalidContent` · `.fileError`. 호스트는 엔진의 값을 `decodeFile(PlannerData.self…)` → `encodeFile` 로 한 번 거쳐 넘긴다 — Mac 의 `JSONEncoder` 와 같은 바이트 (기본값인 칸 · `null` 은 빠지고 `/` 는 `\/`). 엔진의 정규 JSON(`jsonData()`)을 그대로 쓰면 읽을 수는 있어도 기기마다 바이트가 달라진다 |
| `removeBookFile(_ id: UUID) throws` | 책장에서 뺀 책의 파일 (+ D-day 옮기기 백업) 을 지운다. 없으면 아무것도 안 함. 거절: `.bookIsOpen` · `.bookIsListed` · `.unreadable` · `.fileError` |
| `isApplyingExternalChange: Bool` | `apply…` 가 `data` · `library` 를 바꾸는 동안 true (`$data` sink 안에서 읽는다) |
| `applyActiveChange(editingKey:_:) -> ExternalApplyResult` | 실시간: 펼친 책의 레코드 몇 개를 메모리에 바로 (밖에서 온 변경 — 사용자의 편집으로 세지 않음, 쓰는 칸의 기록은 새 글로). 파일은 평소 묶음 저장. 쓰던 할 일 · 메모가 없어졌으면 `editedItemRemoved` |
| `settleBeforeCleanup` · `afterEditing(_:)` | 쓰기를 마친 뒤의 정리(빈 할 일 · 빈 글씨 메모 지우기)를 밖의 일 뒤로 (nil 이면 바로 — 기본). 동기화는 `setEditingAndSettle` 뒤에 |
| `beforeScheduledSave` | 묶어 둔 저장이 파일을 쓰기 직전에 거치는 곳 (nil 이면 바로 — 기본). 동기화는 `storageBehind` 면 `flushLive` 뒤에 |
| `PlannerStore.encodeFile(_:)` · `decodeFile(_:from:)` | 앱 파일과 같은 JSON (`.iso8601`, `.sortedKeys`) |
| `PlannerData.rebased(from:to:)` | 밖에서 온 변경(base → theirs)을 되돌리기 단계에 옮긴다 (칸마다) |
| `PlanTask.carryTaskId(_ id: UUID) -> UUID` | → 미룸 사본 id = UUIDv5(원래 id, "carry") — `carryForward` 가 이미 쓴다. `CarryID.carryTaskId` 와 같은 값 |
| `DDay.legacyID(title:date:) -> UUID` | 옛 D-day 하나짜리 파일(`ddayTitle` · `ddayDate`)의 D-day id = UUIDv5(NameSpace_URL, `"https://spiralday.com/ns/legacy-dday/" + ISO 날짜 + "/" + 제목`) — `Prefs` 디코더가 쓴다. 같은 옛 파일을 읽은 두 기기가 D-day 를 둘 만들지 않게 (Windows · Android `legacyDDayId` 와 같은 값, `DefaultCategoriesParityTests`) |

`update*` 의 `transform` 은 동기 함수다: 호스트는 그것을 "지금" 값으로 불러 돌려받은 값을 같은 MainActor 차례 안에서 바로 넣는다 (그 사이 사용자의 편집이 끼어들면 안 된다). 그리고 **transform 을 부른 뒤에 넣지 못했으면 던진다** — 던지지 않으면 엔진은 넣은 것으로 적고, 다음 비교에서 옛 값을 새 편집으로 올려 다른 기기의 편집을 되돌린다. 넣으면 안 되는 책(읽지 못한 파일)은 transform 을 부르기 **전에** 돌아간다 (엔진은 다음에 다시 넣는다).

```swift
import Foundation
import SpiraldayKit
import SpiraldaySync

/// PlannerStore ↔ 동기화 엔진. 값은 앱 파일과 같은 JSON (PlannerStore.encodeFile · decodeFile)
@MainActor
final class PlannerSyncHost: SyncHost {
    let store: PlannerStore
    /// 지금 쓰고 있는 칸 (AppState.editingKey)
    var editingKey: () -> String? = { nil }
    /// 쓰던 할 일 · 메모가 다른 기기에서 지워졌다 → 편집을 끝낸다 (state.endEditing())
    var onEditedItemRemoved: () -> Void = {}

    init(store: PlannerStore) { self.store = store }

    func libraryRecreated() async -> Bool { store.libraryCreated }

    func readLibrary() async -> JSONValue? {
        // 책장을 읽지 못한 실행에서는 nil → 엔진은 비교하지 않는다 (지운 것으로 오해하지 않게)
        if store.libraryUnreadable { return nil }
        return try? JSONValue.parse(PlannerStore.encodeFile(store.library))
    }

    func readBook(id: String) async -> BookRead {
        guard let uuid = UUID(uuidString: id) else { return .unreadable }
        if store.booksOpenedWithoutFile.contains(uuid) { return .missing }   // 파일 없이 연 빈 책: 엔진이 되살린다
        switch store.readBookRaw(uuid) {                       // 펼친 책은 지금 내용
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .data(let raw): return (try? JSONValue.parse(raw)).map { .ok($0) } ?? .unreadable   // 모르는 키도 그대로
        }
    }

    func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        guard let uuid = UUID(uuidString: id) else { return }
        let cur: JSONValue?
        if store.booksOpenedWithoutFile.contains(uuid) {
            cur = nil                                           // 파일 없이 연 빈 책: readBook 과 같게 nil (엔진은 다시 비교해 되살린다)
        } else {
            switch store.readBookRaw(uuid) {                    // 펼친 책은 지금 내용
            case .unreadable: return                            // 읽지 못한 파일: transform 을 부르지 않고 그대로
            case .missing: cur = nil
            case .data(let raw):
                guard let v = try? JSONValue.parse(raw) else { return }
                cur = v
            }
        }
        let next = transform(cur)
        // 여기부터 넣지 못하면 던진다
        if uuid == store.library.activeID {
            guard let next else { return }                      // 펼친 책은 이렇게 지우지 않는다 (엔진은 책장에서 먼저 뺀다)
            let r = store.applyActiveData(try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData()),
                                          keepingEditOf: editingKey())
            if r.editedItemRemoved { onEditedItemRemoved() }
        } else if let next {
            // 앱 모델로 읽고 다시 써서 Mac 의 JSONEncoder 와 같은 바이트로. writeBookRaw 는 앱이 읽을 수 있는지 다시 보고 원자적으로 쓴다
            try store.writeBookRaw(uuid, PlannerStore.encodeFile(try PlannerStore.decodeFile(PlannerData.self, from: next.jsonData())))
        } else if cur != nil {
            try store.removeBookFile(uuid)                      // 책장에서 이미 빠진 책
        }
        if next != nil { store.clearOpenedWithoutFile(uuid) }   // 동기화된 내용을 넣었다
    }

    /// 엔진이 파일 없음을 받아들였다 (되살리기로 함 · 되살릴 것이 없음) → 이제 보통 책
    func missingNoted(bookId: String) async {
        if let uuid = UUID(uuidString: bookId) { store.clearOpenedWithoutFile(uuid) }
    }

    func updateLibrary(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {
        guard !store.libraryUnreadable else { return }
        let cur = try JSONValue.parse(PlannerStore.encodeFile(store.library))
        store.applyLibrary(try PlannerStore.decodeFile(Library.self, from: transform(cur).jsonData()))
    }
}
```

> 책 파일은 펼친 책이든 아니든 SpiraldayKit 모델을 거쳐 쓴다 — Mac 앱이 파일을 읽고 쓸 때와 같다. 그래서 모든 기기의 책 파일이 Mac 의 `JSONEncoder` 와 같은 바이트가 되고, 모델이 모르는 키(새 버전 앱의 것)는 이 기기의 파일에 남지 않는다. 그래도 그 키를 지운 것으로 올리지는 않는다 — 엔진은 그림자에 있던 `x:` 가 지금 값에 없으면 바뀐 것으로 보지 않는다.

### 5. 저장할 때마다 · 되돌리기 · 앱 수명

```swift
store.onSaved = { bookId, library in
    if let bookId { sync.localChanged(bookId: bookId.uuidString) }
    if library { sync.localChanged(library: true) }
}
// 사용자가 책을 지웠을 때는 꼭 이렇게 알려 준다 (알림 없이 책장에서 사라진 책은 엔진이 "잃은 것" 인지 먼저 따져 되살린다)
store.onDeleted = { bookId in sync.localChanged(deletedBooks: [bookId.uuidString]) }
host.editingKey = { [weak state] in state?.editingKey }
host.onEditedItemRemoved = { [weak state] in state?.endEditing() }
```

- iOS: 뒤로 갈 때 `beginBackgroundTask` 안에서 `store.saveNow(); await sync.suspend()` (남은 편집을 올리고 연결을 닫는다), 앞으로 올 때 `await sync.resume()` (다시 붙고 받기 · 비교 · 보내기).
- macOS: 잠자기 · 앱 끝내기 전에 `store.saveNow(); await sync.suspend()`, 깨어날 때 · 네트워크가 돌아올 때 `resume()`. 앱을 닫을 때는 `await sync.dispose()` 까지 (못 올린 것은 다음에 켤 때 올린다).
- 올리는 동안(느린 망) 앞으로 돌아와 `resume()` 이 불리면 그 `suspend()` 는 연결을 닫지 않고 끝난다. 두 Task 의 순서는 보장되지 않으므로 앱은 `suspend()` 가 끝났을 때 앞에 있으면 `resume()` 을 한 번 더 부른다.

되돌리기(`store.$data` 를 보고 PlannerData 통째로 쌓는 것)는 밖에서 온 변경을 사용자의 편집으로 쌓지 않고, 쌓인 단계에 옮겨 둔다 — 그래야 되돌리기가 다른 기기의 편집을 지우지 않는다:

```swift
private func observe(_ new: PlannerData) {
    if store.isApplyingExternalChange, store.library.activeID == bookID {
        undoStack = undoStack.map { $0.rebased(from: last, to: new) }
        redoStack = redoStack.map { $0.rebased(from: last, to: new) }
        groupStart = groupStart?.rebased(from: last, to: new)
        last = new
        publish()
        return
    }
    …
}
```

엔진은 저장 알림 0.15초 뒤 비교하고, 보내기는 상황에 따라 미룬다 (아래 7 — 다른 기기가 모두 초안을 받으면 2초, 없으면 마지막 변경 + 2초 · 최대 5초, presence 를 모르면 1.5초 · 최대 4초, 옛 앱이 있으면 1초 · 최대 2초, 초안으로 가지 않은 변경은 0.4초). 다른 기기의 편집은 WebSocket `{head}` 알림을 받는 즉시 받고(자기 쓰기의 알림은 받지 않는다), 알림이 없을 때는 30초(연결 중이면 5분)마다 확인한다. 연결이 끊기면 1 → 2 → 4 … 60초 + 무작위로 다시 붙는다.

### 6. 화면 흐름

| 화면 | 엔진 | 비고 |
|---|---|---|
| 동기화 켜기 (첫 기기) | `try await sync.createGroup(deviceName:)` → `let code = try await sync.setupRecovery()` | 복구 코드는 **한 번만** 보여 준다 (적어 두기 · 인쇄 · "적어 두었어요" 확인) |
| 기기 추가 (원래 기기) | `let offer = try await sync.startPairing(mode: .qr)` → QR(`offer.qrText`) → `let req = try await offer.wait()` (요청이 오면 돌아온다, 만료 · 취소면 nil) | "코드로 연결" → `offer.cancel()` 뒤 `startPairing(mode: .code)` → `offer.code` ("ABCD-EFGH"). 10분 (`offer.expiresAt`) |
| 확인 숫자 (원래 기기) | `req.platform` (목록 밖이면 nil → "새 기기"): 그 기기 화면의 숫자 4자리를 **입력**받는다. 원래 기기는 숫자를 보여 주지 않는다 (`req` 에 없다). [연결] 에 처음부터 포커스를 두지 않는다 | [연결] `offer.approve(enteredDigits:)` — 다르면 `.digitsMismatch` (서버에 아무것도 안 감, `offer.triesLeft`), 3번 틀리면 거절 · `.pairingDenied`. [아니에요] `offer.deny()`. 승인 기한 `req.expiresAt` |
| 들어오기 (새 기기) | `let j = try await sync.joinGroup(QR글 또는 코드, deviceName:)` → `j.confirmDigits` 를 보여 준다 → `let r = try await j.waitForApproval()` | [그만두기] `j.reject()`. `.denied` · `.expired` · `.cancelled` (기다리던 Task 를 취소). 코드 429: `.rateLimited` (이 네트워크) · `.codeJoinPaused` (서버 전체 — QR 로 안내) |
| 수락 (새 기기) | `.approved(groupDevices, acceptBy)` → 연결될 기기 이름. 이 기기에 플래너가 있으면 "이 기기의 플래너 N권도 함께 동기화돼요" 를 꼭 보여 준다. `acceptBy` 까지 시작해야 한다 | [시작하기] `j.accept()` (그 직전에 앱 백업을 권한다) · [그만두기] `j.reject()` (서버에서 이 기기를 뺀다) |
| 복구 | `try await sync.restoreFromRecovery(code:deviceName:)` | 입력 칸은 하이픈 · 대소문자 · O/0 · I/1 을 가리지 않는다. 입력 중 `Codes.checkRecoveryCode(_:)` (`.short` · `.checksum` …) |
| 복구 코드 바꾸기 | `try await sync.rotateRecovery()` | 예전 코드는 바로 못 쓰게 된다. 새 코드는 한 번만 보여 준다 |
| 기기 목록 | `try await sync.listDevices()` | `name` 이 nil 이면 `platform` (합류 직후) 또는 "알 수 없는 기기". `current` = 이 기기. 이름 바꾸기 `renameThisDevice(_:)` · 빼기 `removeDevice(_:)` |
| 이 기기 빼기 / 그룹 지우기 | `sync.leaveGroup()` / `sync.wipeGroup()` | 둘 다 플래너는 남는다. 그룹 지우기는 되돌릴 수 없다 (두 번 확인) |
| 이전 버전 | `sync.history(RecordKeys.day(책, 날짜))` → `sync.restoreVersion(키, seq:)` | 서버가 덮인 때부터 30일 보관. 되돌림은 새 편집으로 퍼지고 그때의 지금 버전도 이전 버전으로 남는다 |
| 빠짐 · 그룹 없음 | `state == .removed / .groupGone` | 정리 버튼은 먼저 `await sync.recheck()` (`.ok` 면 이어서 동기화) — 확실할 때만 `forgetGroup()`. 키체인 항목이 손상되면 `initialize()` 가 `CredentialsUnreadable` 을 던진다 (조용히 "그룹 없음" 으로 보지 않는다) |

상태: `await sync.status` · `.status` 이벤트 (`sync.addListener { … }` 또는 `for await e in sync.events()`; 콜백은 엔진 쪽에서 불리므로 화면은 MainActor 로 옮겨 쓴다).

| `state` | 보여 줄 것 |
|---|---|
| `.off` | 동기화 꺼짐 |
| `.idle` | 동기화됨 · `lastSyncAt` |
| `.syncing` | 맞추는 중 |
| `.offline` | 오프라인 (편집은 쌓였다가 연결되면 올라가요, `pending` 개) |
| `.error` | `error` 문구, 저절로 다시 시도 |
| `.quota` | 저장 공간이 가득 찼어요 |
| `.removed` · `.groupGone` | "이 기기는 동기화에서 빠졌어요" — 확인을 누르면 `sync.forgetGroup()` (플래너는 그대로) |

경고 `.warning(code, message)`: `massDeleteBooks` · `massDeleteDays` · `bookMissing` (한꺼번에 사라진 것을 지우지 않고 되살림), `updateRequired`, `undecryptable`, `libraryUnreadable`, `recordTooLarge`.
오류 `SyncEngineError.code`: `invalidCode` · `pairingDenied` · `pairingExpired` · `deviceLimit` · `pairingLimit` · `rateLimited` (8자 코드를 너무 많이 틀리면 QR 로 연결하라고 안내) · `wrongKey` · `recoveryNotFound` · `offline` · `alreadyInGroup` · `notInGroup` · `server`. `message` 는 그대로 보여 줄 수 있는 한국어.

### 7. 실시간 쓰기 (글자 하나 단위)

두 기기가 함께 열려 있으면 친 글자 하나(한글은 조합되는 음절마다) · 칠한 칸 하나가 상대 종이에 바로 보인다 (로컬 서버에서 3 ms, 운영에서는 + 왕복 약 0.2초).
연결 · 메시지는 아래 7.5, 봉인 · 받는 쪽 검사 · 한도는 7.6, 엔진 안쪽의 규칙(그림자 · 저장 순서 · 확인 대기 · 쓰는 칸)은 7.7 (TypeScript 엔진과 같은 바이트 · 동작 — `VectorsTests`).

**흐름**: 앱이 바꿀 때마다 `liveEdit(keys)` → 엔진이 50 ms 묶음으로 그 레코드만 `host.readLive` 로 읽어 비교 → 바뀐 조각에 HLC 도장 → 상태에 합침(보낼 것) →
다른 기기가 듣고 있으면 봉인한 초안(`K_live`, 256바이트 채움)을 WebSocket 으로. 서버는 저장하지 않고 같은 그룹의 다른 기기에만 건넨다.
받은 기기는 보낸 기기의 도장 그대로 상태에 합치고 `host.applyLive` 로 열린 책 메모리에 바로 넣는다 (올릴 이유가 아니다 — 받은 기기는 아무것도 올리지 않는다).
레코드는 보낸 기기가 보통처럼 올리고, 같은 도장이라 받은 기기에서는 바뀌는 것이 없다. 30초 안에 레코드로 확인되지 않으면 받은 기기가 대신 올린다.
서버가 중계를 모르면(지금 운영 서버 · `LIVE=off`) `{"peers"}` 가 오지 않으므로 초안 없이 예전처럼 레코드로 (약 1.5–2초).

#### 7.1 엔진 API

| | |
|---|---|
| `engine.liveEdit(_ keys: [String])` | **nonisolated · 기다리지 않음** (메인 스레드에서 입력마다). 앱의 메모리 값이 방금 바뀌었다: 키 입력 · IME 조합 한 단계(marked text 포함) · 칠하기 한 칸 · 표시 · 할 일 더하기/지우기 … `keys` = 바뀐 레코드 키 — 열린 책의 `RecordKeys.day(책, "yyyy-MM-dd")` · `RecordKeys.week(책, 월요일)` · `RecordKeys.prefs(책)` (책 id 대소문자 무관, 다른 종류는 무시). 첫 입력은 바로, 그 뒤는 50 ms 묶음 (마지막 값은 꼭). 그룹 밖 · 멈춤이면 아무것도 하지 않는다 (네트워크 0). 이 부름이 곧 "사용자가 치는 중" 이다 |
| `engine.setEditing(_ at: FieldAddress?)` | **nonisolated · 기다리지 않음**. 캐럿이 있는 칸 (없으면 nil). 쓰는 중인 동안(**그 칸에서의** 마지막 `liveEdit` — 그 칸의 레코드를 바꾼 것 — 부터 `editingGraceMs` 5초) 들어오는 변경으로 덮지 않는다. 포커스만 있는 칸은 지키지 않는다 (더 새 글을 받는다): 다른 칸에서 치다 ↓ · Return · 탭으로 옮겨 온 칸은 그 칸에서 칠 때까지 포커스만 있는 칸이다 |
| `await engine.setEditingAndSettle(_ at:)` | 같고, 미뤄 둔 상대 글을 앱에 넣을 때까지 기다린다 — 쓰기를 마친 뒤 정리(빈 할 일 · 빈 메모 지우기)를 하는 곳은 이것을 기다린 뒤 정리한다 (정리가 화면의 옛 값을 보고 지우지 않게). 앞서 부른 `setEditing` 이 시작한 넣기가 아직 앱 값을 다루는 중이면 그것이 끝날 때까지도 기다린다 (앱의 `$editingKey` 구독이 `setEditing(nil)` 을 먼저 부르는 흔한 순서) |
| `engine.editingProtected: Bool?` | **nonisolated**. 쓰고 있는 칸을 지금 지키는지 (칸이 없으면 nil). 호스트가 따로 칸을 지키는 안전망은 이 값을 따라야 한다 — 엔진보다 더 지키면 옛 글이 새 도장을 얻어 더 새 글을 덮는다 |
| `engine.localChanged(bookId:saved:)` | 앱이 책 파일을 **다 쓴 뒤**: `saved` = 쓴 그 책의 PlannerData JSON 을 주는 함수 (`{ try? JSONValue.parse(raw) }` — 엔진이 앞선 레코드가 있을 때만 부른다). 실시간 쓰기를 하는 앱은 꼭 준다: 앱이 파일 저장 전에 죽었을 때 친 글 · 받은 글을 되살리고, 옛 파일 값이 새 편집으로 올라가 다른 기기의 글을 지우지 않게 |
| `await engine.storageBehind` · `await engine.flushLive()` | 동기화 저장소가 메모리보다 뒤처졌는지 · 남은 실시간 일을 지금 (비교 · 초안 · 저장). 책 파일을 쓰기 직전에 `storageBehind` 면 `flushLive()` 를 기다린다 — 기본 간격(첫 변경은 바로, 그 뒤 0.1초)이면 0.6초 묶음 저장 앞에서 거의 늘 false. 이 훅을 늘 거치는 앱은 저장 간격을 넓혀도 된다 (7.7) |
| `await engine.hasUnsent` · `await engine.sendPending()` | 서버에 아직 없는 이 기기의 편집이 있는지 · 지금 보내기 (창을 닫기 전 · 뒤로 갈 때 · 잠자기 전). 보낼 것이 없으면 요청 0. `suspend()` 도 먼저 `flushLive()` 한다 |
| `await engine.presence` · `status.presence` | `LivePresence(relay:peers:live:)` 또는 nil (연결 없음 · 중계 없는 서버) |
| `await engine.liveCounters` | `sent` · `deferred` · `tooLarge` · `received` · `dropped` · `adopted` (로그용) |
| 실시간 이벤트 | `addLiveListener { … }` 또는 `for await e in engine.liveEvents()` — `SyncEvent` 와 따로 (초당 여러 번 온다). 콜백은 엔진 쪽에서 불리므로 MainActor 로 옮겨 쓴다 |

`SyncLiveEvent`:

| | 앱이 할 일 |
|---|---|
| `.presence(LivePresence?)` | (선택) 표시 |
| `.remoteTyping(from:at:editing:)` | `editing == true` 면 그 칸 오른쪽 위에 작은 회색 글 **"다른 기기에서 쓰는 중"** (마지막 이벤트부터 3초, `allowsHitTesting(false)` — 포커스 · 레이아웃을 건드리지 않는다). `false` 면 아무것도 (종이가 바뀌는 것 자체가 표시) |
| `.held(FieldAddress?)` | 칸이 있으면 쓰는 중이라 상대의 더 새 글을 미뤄 둠 → **"다른 기기의 글이 있어요"** (앞의 것이 있으면 앞의 것), nil 이면 끝 |
| `.applied(bookId:)` | 받은 초안을 열린 책에 넣었다 (호스트가 이미 메모리를 바꿨다). 위젯 · 썸네일 다시 그리기 같은 무거운 일은 묶어서. 동기화 상태 표시는 그대로 (`SyncEvent.applied` 는 오지 않는다) |

`FieldAddress(key: RecordKeys.day(책, 날짜), field: "comment")` · `field: "m0"`…`"m2"` · `"mt0"`… (메모 태그) · `"m+"` · `"mt+"` (3줄 넘은 메모) · 한 주 `RecordKeys.week(책, 월요일)` 의 `"goal"` · `"review"` · 첫 장 `RecordKeys.prefs(책)` 의 `"mottoText"` ·
항목 `FieldAddress(key:, coll: .tasks, item: 할 일 id, field: "text")` · `.notes` (`"text"`) · `.ddays` (`"title"`) · `.categories` (형광펜 id 는 정수 문자열, `"name"`).

#### 7.2 호스트에 더할 것 (선택 — 없으면 초안을 받아도 다음 바퀴의 `updateBook` 으로 넣는다)

```swift
/// 열린 책의 레코드 값 (메모리, 저장 전 편집 · 조합 중인 글자 포함). 열린 책이 아니면 nil (엔진은 readBook 으로)
func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? {
    guard let uuid = UUID(uuidString: bookId), uuid == store.library.activeID else { return nil }
    var out: [String: JSONValue] = [:]
    for key in keys {
        guard let pk = RecordKeys.parse(key) else { continue }
        switch pk.kind {
        // 앱 파일과 같은 JSON (PlannerStore.encodeFile — .iso8601 · .sortedKeys), 레코드 하나만
        case .day: out[key] = store.data.days[pk.date!].flatMap { try? JSONValue.parse(PlannerStore.encodeFile($0)) } ?? .null
        case .week: out[key] = store.data.weeks[pk.date!].flatMap { try? JSONValue.parse(PlannerStore.encodeFile($0)) } ?? .null
        case .prefs: out[key] = (try? JSONValue.parse(PlannerStore.encodeFile(store.data.prefs))) ?? .null
        default: break
        }
    }
    return out
}

/// 받은 초안을 열린 책 메모리에 바로 (같은 MainActor 차례 안에서). 파일은 보통처럼 묶어서 나중에 (바로 쓰지 않는다)
func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool {
    guard let uuid = UUID(uuidString: bookId), uuid == store.library.activeID, store.unreadableBooks[uuid] == nil,
          let cur = await readLive(bookId: bookId, keys: keys) else { return false }
    let next = transform(cur)                                  // 여기부터는 꼭 넣고 true
    store.applyLiveRecords(next)                               // (앱이 만들 것) 레코드마다 decodeFile → 밖에서 온 변경으로
                                                               // (isApplyingExternalChange — 되돌리기 단계에 옮김, liveEdit 를 부르지 않음)
    store.scheduleSave()                                       // 0.6초 묶음 저장 → 다 쓴 뒤 localChanged(bookId:saved:)
    return true
}
```

- 값은 레코드 하나씩: 하루 = `PlannerData.days[날짜]` 의 JSON (없는 날 · 지운 날은 `.null`), 한 주 = `weeks[월요일]`, 설정 = `prefs` (기기마다 따로인 `lastKind` · `ddaysPerDay` 는 엔진이 지금 값 그대로 돌려준다). 앱 파일과 같은 인코더로 — 책 전체를 JSON 으로 바꾸지 않는다 (입력마다 불린다).
- `transform` 은 그 순간의 앱 값을 먼저 비교해(그 사이에 친 글을 잃지 않게) 상태와 합친 값을 돌려준다. 쓰고 있는 칸은 이미 앱 값 그대로다 — 호스트가 칸을 따로 지키려면 `editingProtected` 를 따른다 (`keepingEditOf` 는 그 값이 true 일 때만).
- 받은 값은 사용자의 편집이 아니다: `liveEdit` 를 부르지 않고, 되돌리기(⌘Z)에는 **밖에서 온 변경**으로 (쌓인 단계에 `rebased(from:to:)` 로 옮긴다 — 5 와 같다). 포커스 · 캐럿 · marked text · Scribble 을 건드리지 않게 쓰고 있는 칸은 엔진이 이미 바꾸지 않았다. 포커스만 있던 칸의 글이 다른 기기의 글로 바뀌었으면 그 칸의 되돌리기 기록을 비운다 (Mac `onEditedFieldReplaced` 와 같다).
- `transform` 을 부르지 않고 false 를 돌려주면(열려 있지 않음 · 지금 넣을 수 없음) 엔진은 다음 바퀴의 `updateBook` 으로 넣는다. 부른 뒤에는 꼭 넣고 true.
- 파일을 바로 쓰지 않는다 (`applyActiveData` 처럼 바로 저장하면 엔진 저장보다 파일이 먼저 쓰일 수 있다). 저장 직전에 `storageBehind` 면 `flushLive()` 를 기다리면 확실하다.

#### 7.3 앱이 부를 곳

```swift
// 저장소가 열린 책을 바꿀 때마다 (글자 · 조합 단계 · 칠하기 한 칸 · 표시 · 할 일 더하기/지우기 · 미룸 · 메모 · D-day · 형광펜 …)
sync.liveEdit([RecordKeys.day(book, Dates.key(day))])           // 미룸은 오늘과 다음 날 둘 다, 주 목표는 RecordKeys.week, 첫 장의 말 · 형광펜은 RecordKeys.prefs
// 캐럿이 들어가고 나갈 때 (AppState.editingKey 가 바뀔 때)
sync.setEditing(FieldAddress(key: RecordKeys.day(book, date), coll: .tasks, item: taskId, field: "text"))
sync.setEditing(nil)                                              // 정리 전이면 await sync.setEditingAndSettle(nil)
// 파일을 다 쓴 뒤
store.onSaved = { bookId, library in
    if let bookId { let raw = lastWrittenBytes; sync.localChanged(bookId: bookId.uuidString, saved: { try? JSONValue.parse(raw) }) }
    if library { sync.localChanged(library: true) }
}
// 실시간 이벤트 → 힌트
Task { for await e in sync.liveEvents() { await MainActor.run { hints.handle(e) } } }
// 뒤로 갈 때 · 창을 닫기 전 · 잠자기 전: store.saveNow(); await sync.sendPending() (또는 suspend())
```

- IME: marked text(조합 중인 글자)도 엔진이 보는 값에 넣고 `liveEdit` 한다 — 상대 종이에 "ㅎ" → "하" → "한" 이 차례로 보인다. 조합 중인 칸은 쓰고 있는 칸이라 상대의 초안이 그 칸을 바꾸지 않는다 (조합이 깨지지 않는다).
  저장소(바인딩)에 조합 중인 글을 넣어도 되는지는 글 칸에 따라 다르다: macOS 의 SwiftUI `TextField` 는 조합 중인 글을 바인딩에 넣으면 다음 화면 갱신(다른 칸이 바뀌어도)이 조합을 깬다.
  그래서 Mac 앱은 저장소에 넣지 않고, 필드 편집기의 글이 바뀔 때마다(`NSText.didChangeNotification`) 그 칸의 레코드를 `liveEdit` 하고 호스트가 `readLive` · `readBook` · `updateBook` · `applyLive` 의
  "지금 값"에만 조합 중인 글을 얹는다. 넣을 때 그 칸이 조합 중인 글 그대로면(엔진이 지킨 것) 저장소의 글로 되돌려 넣는다 — 저장소 · 화면은 조합을 모른다.
  조합이 끝나면(확정 · 마지막 자모를 Backspace 로 지워 취소 · 조합 중에 칸을 떠남) 칸의 글이 저장소와 같아도 그 레코드를 한 번 더 `liveEdit` 한다 —
  취소는 바인딩도 `$data` 도 바꾸지 않으므로, 알리지 않으면 엔진이 본 조합 글(‘회의 ㄱ’)이 상대 종이와 레코드에 남는다.
- 타임테이블: 끄는 동안 칸이 바뀔 때마다 `liveEdit` (그 날 키 하나). 끌기는 **지금 칸 위에 끈 범위만** 칠한다 (끌기 시작의 스냅샷으로 줄 전체를 다시 쓰면 그 사이 받은 상대 칸을 새 도장으로 되돌린다).
- 동기화가 꺼져 있으면 엔진이 없으므로 아무것도 부르지 않는다 (네트워크 0 · 화면 그대로).

#### 7.4 보내기 상황 (`PushMode.of(presence)` · `PushDelays.dueAt`)

| 상황 | presence | 레코드 보내기 |
|---|---|---|
| COVERED | `live == peers > 0` | 첫 변경 + 2초 (보이는 지연은 초안이 맡는다) |
| FAST | COVERED 인데 초안으로 가지 않은 변경 (책 정보 · 책장 · 너무 큰 조각) | 첫 변경 + 0.4초 |
| OLD-PEER | `peers > live` (실시간을 모르는 옛 앱이 켜져 있음) | 마지막 변경 + 1초, 최대 2초 |
| UNKNOWN | nil (중계 없는 서버 · WebSocket 막힘 · 연결 직후) | 마지막 변경 + 1.5초, 최대 4초 |
| ALONE | `peers == 0` | 마지막 변경 + 2초, 최대 5초 (창을 닫을 때는 `sendPending` 으로 바로) |

presence 가 늘면(다른 기기가 막 켜짐) 밀린 것을 바로 보낸다. `{"head"}` 를 받으면 바로 받는다 (0 ms, 받기 사이 최소 0.15초). 자기 쓰기의 head 로는 받지 않는다.
옵션: `SyncEngineOptions(…, live: true, liveThrottleMs: 50, liveFlushMs: 100, liveReceiveFlushMs: nil (= liveFlushMs), liveApplyMs: 100, lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled }, liveAdoptMs: 30_000, editingGraceMs: 5000, pingMs: 30_000, pongTimeoutMs: 10_000, pushDelays: PushDelays(), headPullDelayMs: 0, minPullIntervalMs: 150)` — `pushDelayMs:` 만 준 예전 호출은 모든 상황에 그 값.

#### 7.5 연결 · 메시지

- WebSocket `wss://<서버>/v1/groups/<gid>/ws` (`Authorization: Bearer <토큰>` — 토큰은 주소에 넣지 않는다), `Sec-WebSocket-Protocol: spiralday.v1, spiralday.live.1`.
  실시간을 아는 서버는 `spiralday.v1` 을 골라 돌려주고 이 연결을 **live 연결**로 받아 `{"head":N}` 다음에 presence 를 보낸다. 모르는 서버(옛 서버 · `LIVE=off`)는 목록을 무시한다 —
  presence 가 오지 않으므로 엔진은 "중계 없음"(presence nil)으로 보고 초안을 보내지 않는다. 중계가 있는지는 **그 연결에서 presence 를 받았는지**로만 가르고, 연결이 끊기면 다시 모름.
- presence (서버 → live 연결): `{"peers":p,"live":l}` — 이 기기를 뺀 같은 그룹 기기 중 연결이 열린 기기 수 p, 그중 live 연결이 있는 기기 수 l (0 ≤ l ≤ p). 연결 직후와 바뀔 때.
- 초안 (클라이언트 → 서버): `{"draft":"<base64url 396–32,000자>","q":"<32자 소문자 hex>"}`, 프레임 ≤ 32,768자. 서버는 **저장하지 않고** 같은 그룹의 **다른 기기**의 live 연결에만
  `{"draft","q","from"}` 로 다시 만들어 건넨다 (`from` = 보낸 연결의 인증된 기기 id — 서버가 붙인다). 모양 · 크기 · 속도를 넘긴 것은 끊지 않고 버린다.
- 살아 있음: 서버는 `"ping"` 에 늘 `"pong"` 을 답한다. 엔진은 `pingMs`(30초)마다 보내고 `pongTimeoutMs`(10초) 안에 아무것도 오지 않으면(반쯤 열린 셀룰러 연결 — 닫힘이 몇 분 동안 오지 않는다)
  닫고 바로 다시 연결한다 (죽은 연결이 presence 를 붙잡아 COVERED 지연이 이어지지 않게). `SocketHandle` 을 직접 구현하면 `"pong"` 도 `onMessage` 로 넘긴다.
- 물러서기: live 를 내민 업그레이드가 **열리기 전에 서버의 답으로** 끝나면 (101 이 아닌 HTTP — 401 · 403 · 404 · 408 · 429 · 5xx 는 빼고 — 또는 받아들일 수 없는 101,
  `WSClose.handshakeRejected`) 엔진은 live 없이 바로 다시 연결하고 다음 `start()` 까지 내밀지 않는다 (초안 없이 보통 동기화 — UNKNOWN). 네트워크 오류는 물러설 이유가 아니다.
  운영 서버(실시간 중계 전 코드)와의 호환은 로컬 workerd 의 옛 서버 코드로만 확인했다 — 앱을 서버보다 먼저 낸다면 운영과 같은 엣지 뒤의 시험 서버(옛 서버 코드)에서
  연결 · head · 주기 확인을 한 번 확인한다. 엔진은 서버가 고른 하위 프로토콜 값을 보지 않는다 (내밀지 않은 값이면 URLSession 이 열지 않는다).

#### 7.6 봉인 · 받는 쪽 검사 · 한도

```
K_live = crypto_kdf_derive_from_key(32, 5, "SpSync01", K)          (하위 키: 1 레코드 · 2 rid · 4 기기 이름 · 5 초안)
plain  = UTF-8(정규 JSON {"k": 레코드 키, "s": 조각, "v": 1}) ‖ 0x20 × 채움     — 256바이트의 배수 (최소 256, 최대 23,552 — 넘으면 보내지 않는다)
         책 설정(p/) 초안은 "v": 2 — 레코드와 같다 (받는 쪽은 p/ 의 v 1 을 고치기 전 엔진의 것으로 버린다)
q      = 보낸 기기의 HLC 도장 (조각을 상태에 합친 뒤 새로 뽑는다 — 기기마다 늘 커진다)
AD     = UTF-8("spiralday/draft/v1:" + gid + ":" + from + ":" + q)
draft  = base64url(0x01 ‖ nonce(24, 늘 난수) ‖ XChaCha20-Poly1305(plain, AD))
```

- `k` 는 하루 `d/` · 한 주 `w/` · 책 설정 `p/` 뿐 (책 정보 · 책장은 레코드로만). `s` 는 레코드 상태와 같은 모양의 **바뀐 필드 · 항목만** (시간 줄 `s00`–`s23`, 새 항목은 `a` 와 모든 필드), 레코드 지움 `x` 는 넣지 않는다.
  채움은 서버가 크기로 몇 글자를 쳤는지 세지 못하게 한다. 단일 필드는 값 전체를 보낸다 (텍스트 diff 가 아니다 — 멱등 · LWW).
- 받는 쪽 검사 (이 순서로, 하나라도 틀리면 **조용히 버린다** — 레코드가 같은 값을 가져온다): 모양 · `from` ≠ 나 · 그룹 안 · 처음 가져오기를 마침 →
  **재생**: `q` > 그 기기에서 마지막으로 받아들인 `q` (메타에 저장, 기기 32개까지 — `q` 를 벽시계와 견주지 않는다: 시계가 다른 기기의 초안을 버리지 않게, 옛 조각은 옛 도장이라 LWW 로 이기지 못한다) →
  풀기 → 평문 ≤ 23,552바이트 · JSON 객체 · `v == 1` · 키 종류 · 상태 모양 · `x` 없음 → 받아들이고 그 `q` 를 적는다.
- 바이트는 TypeScript 엔진과 같다 (`VectorsTests`: K_live · 세 초안 · from/q 를 바꾼 AD · K_enc 로 열기 반대 벡터).

| 한도 | 값 | 넘으면 |
|---|---|---|
| 묶음 | 50 ms (첫 입력은 바로, 마지막 값은 꼭) | — |
| 클라이언트 버킷 (연결) | 20 메시지/초 (버킷 20) · 96 Ki자/초 (버킷 192 Ki) | 그 조각은 다음 틱에 다음 조각과 합쳐 보낸다 (새 항목의 `a` 를 건너뛰지 않게) |
| 클라이언트 보내기 대기 | ≤ 64 KiB (`WSProtocol.draftBufferLimit`) | 봉인하기 **전에** 본다. 찬 채로 이어지면 다시 보내 보는 간격을 50 ms → 2초로 늘린다 |
| 서버 (기기마다, 그 기기의 모든 연결이 함께) | 25 메시지/초 (버킷 40) · 128 Ki자/초 (버킷 256 Ki) | 버린다 (끊지 않음). 한도의 10배가 60초 넘게 이어지면 그 기기의 연결을 1008 로 닫는다 |
| 받는 쪽 확인 기다림 | 30초 (`liveAdoptMs`) | 받은 기기가 대신 올린다 (7.7) |

#### 7.7 엔진 안쪽 — 그림자 · 저장 순서 · 확인 대기 · 쓰는 칸

- **그림자 둘**: 실시간으로 받아들인 값은 앱 파일보다 앞선다 (파일은 0.6초 묶음). 레코드마다 메모리 그림자(앱 메모리에 있다고 아는 값 — 실시간 비교의 기준)와 저장된 그림자(앱 **파일**에 있다고 아는 값)를 따로 둔다.
  저장소에는 `{shadow: 저장된 그림자, pend: 메모리 그림자}` 로 쓰고, 앱이 파일을 다 쓴 뒤 `localChanged(bookId:saved:)` 로 준 값이 저장된 그림자를 앞으로 옮긴다.
  앱이 파일 저장 전에 죽으면 다시 켤 때 파일 값 = 저장된 그림자 → 편집으로 보지 않고 상태(친 글 · 받은 글)를 다시 넣는다 — 옛 파일 값이 새 도장으로 올라가 다른 기기의 글을 지우는 일이 없다.
- **저장 순서**: 이 장치는 엔진 저장소가 앱 파일보다 **뒤처지지 않을 때만** 맞다 (파일이 앞선 채 꺼지면 다시 켤 때 그 파일 값을 이 기기의 새 도장으로 올린다).
  엔진은 실시간 변경을 첫 변경은 바로, 그 뒤는 이 기기의 편집 `liveFlushMs` · 받기만 한 변경 `liveReceiveFlushMs` 간격으로 쓰고 (저전력 모드면 3배), 실시간 묶음은 fsync 하지 않는다
  (앱이 죽어도 남는다 — 전원이 꺼질 때만 잃을 수 있고, 잃어도 레코드 · 대신 올리기가 가져온다). 기본 0.1초는 0.6초 묶음 저장보다 늘 먼저다.
  **책 파일을 쓰기 직전에 늘 `storageBehind` → `flushLive()` 를 기다리는 앱**(묶은 저장 · 뒤로 가기 · 끝내기 모두)은 파일이 엔진 저장소를 앞지를 수 없으므로 둘 다 넓혀도 된다 —
  Mac · iOS 앱은 이 기기의 편집 0.5초 · 받기만 한 변경 1초 (다른 기기가 계속 치는 동안 받기만 하는 iPhone 이 초당 10번 레코드 전체를 일지에 쓰지 않게).
- **받은 초안**: 보낸 기기의 도장 그대로 상태에 합치고 `dirty` 를 만들지 않는다 (받은 기기는 아무것도 올리지 않는다). 앱에는 `liveApplyMs`(0.1초, 저전력 모드면 2배)마다 넣는다 —
  첫 초안은 바로, 그 사이에 온 초안은 다음 넣기에 함께 (초당 20번 오는 초안마다 메인 스레드가 JSON 왕복 · 종이 다시 그리기를 하지 않게).
  `setEditingAndSettle` 은 묶어 두고 기다리는 넣기도 그 자리에서 한다 (정리가 아직 넣지 않은 다른 기기의 글을 보지 못하고 지우지 않게).
- **확인 대기 · 대신 올리기**: 초안으로 이긴 경로(필드 · 항목 필드 · 항목 더함/지움)는 서버 버전(받기 · 409 · 내가 올린 상태)이 덮을 때까지 확인 대기다.
  한 경로라도 30초(`liveAdoptMs`) 동안 확인되지 않으면 받은 기기가 가진 상태(보낸 기기의 원래 도장 그대로)를 올린다 — 보낸 기기가 저장 전에 죽었을 때의 오프라인 대기열. 다시 켜도 이어진다.
- **쓰는 칸**: 지키는 것은 칸마다다 — `liveEdit` 의 시각은 그때 쓰고 있던 칸(그 칸의 레코드를 바꾼 입력일 때)과 함께 적고, 그 칸이 지금 쓰고 있는 칸이고 `editingGraceMs` 안일 때만 지킨다.
  지키는 칸은 들어오는 변경으로 덮지 않고 그림자도 앱 값으로 둔다 (다시 올리지 않는다 — 두 기기가 같은 칸을 써도 핑퐁 없음). 상태와 다르면 미뤄 둔다(`held` → "다른 기기의 글이 있어요").
  칸이 바뀌거나 · 지키는 시간이 끝나거나 · 앱이 뒤로 가면(`suspend()` — 사용자가 치는 중이 아니다, 지키기를 끝내고 바로) 그 레코드를 다시 맞춘다: 마지막 입력이 더 나중인 쪽의 글 (LWW).
  `start()` · `resume()` 은 멈춘 동안 남은 미뤄 둔 칸을 다시 잡고(지키는 시간이 끝났으면 바로 넣는다) 쓰던 칸이 아직 미뤄져 있으면 `held` 를 다시 알린다 (앱은 뒤로 가며 힌트를 지웠다).

### Mac 앱

- 플랫폼 `.mac`. 동기화 상태 폴더는 `~/Library/Application Support/Spiralday/SyncState` (앱 데이터 폴더 안, 앱 파일과 섞지 않는다, Time Machine 제외).
- Keychain: 샌드박스 · keychain-access-groups 가 없는 Developer ID 앱은 `SyncEngine.standard(…, useDataProtectionKeychain: false)` (로그인 키체인, 같은 접근성 값).
  로그인 키체인은 `ThisDeviceOnly` 를 지키지 않는다 — 이전 지원 · Time Machine 복원으로 새 Mac 에 옮겨 갈 수 있다. Mac 앱은 그룹에 들어갈 때
  이 Mac 의 표시(IOPlatformUUID 의 해시, UserDefaults `sync.machine`)를 적어 두고, 켤 때 다르면 키체인을 읽기 전에 멈추고
  ‘이 Mac 에서 이어 쓰기’(원래 Mac 을 더 쓰지 않음) · ‘정리하기’(이 Mac 의 열쇠 · SyncState 만 지우고 다시 합류 — 서버에는 묻지 않는다) 를 묻는다.
- 그룹에 들어 있다는 표시(`sync.groupURL`)는 UserDefaults 에 있고 UserDefaults 는 번들 id 마다 따로라서, 키체인 항목 · SyncState 도 번들 id 로 가른다:
  `com.spiralday.app` (build.sh 의 `.app`) 은 `com.spiralday.sync` · `SyncState`, 그 밖의 실행(`swift run` · 테스트)은 `com.spiralday.sync.dev` · `SyncState-dev`.
- `carryForward` 의 미룸 id 규칙은 SpiraldayKit 에 들어 있어 Mac 앱도 이미 같다 (`PlanTask.carryTaskId`).
- 처음 안내에서 합류 (`Sources/Spiralday/Onboarding.swift` · `FirstRunFlow.swift`, 시험 `FirstRunJoinTests`): iOS · Android 와 같은 상태 기계
  (공유 벡터 `Tests/Fixtures/mobile-tour.json`). 합류하는 동안에는 기본 책을 만들지 않고, 3–6 사용법을 지나 준비 끝(가져왔어요 · 되찾았어요 · 받는 중 —
  30초 뒤에만 [새 플래너 만들기]) → 둘러보기. 받는 중에 [이전] · Esc · 점으로 플래너 단계에 와도 만들기 양식 대신 받는 중 카드
  (`PlannerMode.waiting` — [다음] 뿐, 30초 뒤에만 [새 플래너 만들기]). 창을 닫으면 예시 플래너를 펴 두고 그룹의 첫 플래너가 들어오면 그 책을 편다 (`openArrivingBook`).
- 합류 · 복구 코드로 합칠 때 막 만든 그대로인 내 플래너(`PlannerData.isUntouched` — 날 · 주 기록 · D-day · 형광펜 · 기본 컬러 · 첫 장의 말이 새 책 그대로)는
  합치기 설명의 스위치(기본 켬)대로 백업 뒤 · 그룹에 들어가기 전에 지운다 — 새 기기가 합류할 때마다 모든 기기에 빈 ‘내 플래너’ 가 생기던 것.
  그룹에 들어가지 못하면 (지난 · 다른 그룹의 복구 코드, 승인 기한 지남, 네트워크) 같은 id · 같은 자리 · 같은 내용으로 되돌리고 다시 편다 (`undoDrop`).
- 이 저장소의 Mac 앱이 실제로 붙인 곳은 `Sources/Spiralday/Sync/` 다:
  - `SyncController` — 엔진 하나 · 설정 → 동기화의 단계별 흐름 · 앱 수명. 기본은 꺼짐: 이 설치가 그룹에 들어간 적이 있을 때(UserDefaults `sync.groupURL`)만
    켤 때 키체인을 읽고 엔진을 만든다. 그 전에는 키체인 · 네트워크를 건드리지 않는다. 잠자기(`NSWorkspace.willSleepNotification`) → 저장 · `suspend()`,
    깨어남 · 네트워크가 돌아옴(`NWPathMonitor`) · 앱이 앞으로 옴(15초에 한 번까지) → `resume()`, 끝낼 때(`applicationShouldTerminate`) → 저장 · `suspend()` (최대 2.5초).
  - `PlannerSyncHost` — 위 4 의 호스트. 쓰던 칸(포커스만)의 글이 다른 기기의 글로 바뀌면 `onEditedFieldReplaced(새 글)` 로 알리고, 컨트롤러가 그 칸의
    되돌리기 기록을 비운다. Mac 앱의 ⌘Z 는 글 칸(필드 편집기)의 것뿐이라 PlannerData 를 쌓는 되돌리기가 없다 — 이것이 Mac 의 "되돌리기 옮기기"다.
    ⌘Z(`undo:`)는 응답자 사슬로 가서 필드 편집기가 보는 기록을 되돌리는데, SwiftUI 글 칸의 필드 편집기는 창의 `undoManager` 가 아니라 호스팅 뷰의 기록을 쓰고,
    SwiftUI 가 다음 화면 갱신에서 새 글을 칸에 넣는 것도 그 기록에 남는다. 그래서 필드 편집기의 기록(과 창의 것)을 바로 한 번, 새 글이 칸에 들어간 뒤(최대 3초 기다림) 한 번 더 비운다.
    쓰는 중인지는 그 칸으로 가른다: `AppState.editingKey` 가 바뀌면 `PlannerStore.noteEditingField` 가 그 칸의 글을 적어 두고, 그 글이 바뀐 때만 쓰는 중으로 본다
    (다른 칸에 막 쓰거나 칠하고 옮겨 온 칸은 포커스만 있는 칸 — 다른 기기의 더 새 글을 받는다).
    설정 창의 형광펜 이름 · D-day 제목(칠 때마다 저장소에 쓰는 칸)은 쓰는 칸 지키기 밖이다. 그 값이 다른 기기의 값으로 바뀌면 `onSettingsTextReplaced` 로 알리고,
    설정 창의 포커스 칸에 그 새 값이 들어오면 그 칸의 되돌리기 기록을 비운다.
  - 펼친 책이 다른 기기에서 지워지면 다른 책을 펴고 플래너 위에 안내, 펼치지 않은 책이 지워지면 그 이름으로 안내. 지금 장이 기간 밖이면 오늘로.
  - 설정 → 동기화 (`SyncSettingsPane` · `SyncFlows` · `SyncHistory`), 팔레트의 설정 단추 귀퉁이 표시, 플래너 메뉴의 ‘지금 맞추기’ · ‘이 날(주)의 이전 버전…’ · ‘동기화 설정…’.
    Mac 은 QR 을 카메라로 찍지 않는다 — Windows PC 처럼 8자리 코드나 원래 기기의 ‘연결 글 복사’로 받은 글을 붙여 넣는다.
  - `Spiralday --sync-qa <폴더>` 가 설정 → 동기화의 모든 상태를 라이트 · 다크 PNG 로 (메모리에서만), `Tests/SpiraldayAppTests` 가 호스트 · 컨트롤러 · 말을 가짜 서버로 시험한다.
  - 실시간 쓰기 (`Sync/SyncLive.swift` — 그룹에 있는 동안만 붙이고, 나오면 저장소 · 창에 건 것을 모두 걷는다. 꺼져 있으면 아무것도 보지 않고 그리지 않는다):
    - `store.$data` 를 보고 바뀐 레코드(하루 · 한 주 · 책 설정 — 바뀌지 않은 날은 값을 나눠 써서 비교가 거의 공짜)만 `liveEdit`. 밖에서 넣은 것(`isApplyingExternalChange`) · 다른 책을 편 것은 빼고.
      글자 · 칠한 칸 · 표시 · 할 일 더하기/지우기 · 미룸 · 메모 · 형광펜 이름 … 저장소를 바꾸는 모든 것이 이 한 곳으로 간다.
    - 조합 중인 글자: 위 7.3 의 IME (저장소에 넣지 않고 엔진이 보는 값에만 — `PlannerSyncHost.composing`).
    - `AppState.editingKey` → `setEditing` (칸 주소: `t|날|id` → tasks.text · `tn|` → notes.text · `c|` → comment · `m|날|0–2` → m0–m2, 3 넘으면 m+ · `mt|` 같게 · `wg|주` → goal · `motto` → mottoText).
    - `PlannerSyncHost.readLive` · `applyLive`: 레코드 하나씩 앱 파일과 같은 인코더로, 받은 초안은 SpiraldayKit `PlannerStore.applyActiveChange` 로 메모리에 바로
      (밖에서 온 변경 — 사용자의 편집으로 세지 않음, 파일은 0.6초 묶음 저장). 쓰던 칸(포커스만)의 글이 바뀌면 그 칸의 ⌘Z 기록을 비운다 (레코드로 받을 때와 같다).
      `updateBook` 의 쓰는 칸 안전망(`keepingEditOf`)은 `engine.editingProtected` 가 false 가 아닐 때만.
    - 쓰기를 마친 뒤의 정리(빈 할 일 · 빈 글씨 메모 지우기)는 `PlannerStore.settleBeforeCleanup` 으로 `setEditingAndSettle` 뒤에, 묶어 둔 저장은 `beforeScheduledSave` 로
      `storageBehind` 면 `flushLive` 뒤에 (둘 다 최대 1.5초 — 엔진이 늦어도 정리 · 저장을 오래 미루지 않는다). 파일을 다 쓰면 `localChanged(bookId:saved:)` 에 그 값을.
    - `.remoteTyping(editing: true)` → 쓰는 칸 오른쪽 위에 작은 회색 "다른 기기에서 쓰는 중" (마지막 이벤트부터 3초), `.held` 동안 "다른 기기의 글이 있어요".
      플래너 창에 붙은 작은 패널(누를 수 없고 키 창이 되지 않는다 — 포커스 · 조합 · ⌘Z · 레이아웃을 건드리지 않는다), VoiceOver 에는 처음 보일 때 한 번.
    - 받은 기기는 아무것도 올리지 않는다. 잠자기 · 끝내기는 엔진 저장소를 먼저 맞춘 뒤(`storageBehind` → `flushLive`) 파일을 쓰고 `suspend()` 한다
      (끝내기는 최대 2.5초 — 엔진이 늦어도 파일은 꼭 쓴다).
    - `Tests/SpiraldayAppTests/SyncLiveTests` 가 두 Mac(가짜 서버 · 중계)과 앱의 진짜 종이(`RootView`)로 시험한다: 글자 · 칠한 칸이 레코드 전에, 한글 조합 단계마다(조합 · 포커스 · ⌘Z 그대로),
      쓰는 칸 지키기와 알림, 포커스만 있는 칸, 정리가 미뤄 둔 글을 기다림, 꺼져 있으면 아무것도 걸지 않음, 중계 없는 서버.
  - 디버그 빌드만: `Spiralday --sync-drive <폴더> [--sync-drive-keychain com.spiralday.mac.sync.qa.<이름>]` — 여러 기기 검증 스크립트가 이 Mac 앱을 모는 통로
    (`Sync/SyncQADrive.swift`). `<폴더>/in/*.json` 의 명령을 화면이 부르는 것과 같은 저장소 · 컨트롤러 함수로 실행하고 `<폴더>/out` 에 답한다.
    플래너 파일은 `<폴더>/data`, 비밀은 테스트용 키체인 서비스 이름, 설정 값은 `<폴더>` 안 — 앱의 데이터 폴더 · `com.spiralday.sync` 키체인 항목은 거절한다.
    플래너 종이는 화면 밖 창에 두고 앱을 앞으로 가져오지 않으며, 통계 · 업데이트 확인 · 처음 안내 · 둘러보기는 켜지 않는다. 서버는 운영 주소(또는 디버그의 `SPIRALDAY_SYNC_URL`).
    실시간 쓰기용 명령: `compose` (조합 한 단계 — marked text) · `commit` · `type` · `paintDrag` (타임테이블 끌기 걸음) · `watchStart` / `watchStop` (그 날이 바뀐 때와 값 — 지연 재기) ·
    `day` · `liveState` (presence · 세기 · 알림) · `snapshot` (화면 밖 종이 + 알림 패널을 PNG 로) ·
    `framesStart` / `framesStop` (화면 밖 종이를 `everyMs` 마다 JPEG 로 — 여러 기기 실시간 검증이 받은 글이 언제 보였는지 장면으로 남긴다. 메인 스레드에서 찍어 그동안 받은 초안을 넣는 일이 수십 ms 늦을 수 있다).

## TypeScript 엔진과 다른 점

- **같다**: 바이트 규칙 전부, 레코드 payload · 필드 이름 · 기본값, 합치기, 비교 순서(같은 시계면 같은 도장 — TypeScript 엔진이 만든 상태와 바이트까지 같은 것을 테스트로 확인), 안전장치, 페어링 · 복구 흐름, 오류 코드 · 문구.
- **기본값은 다른 기기의 값을 이기지 않는다** (2026-10-04 형광펜 사고, `Tests/SpiraldaySyncTests/DefaultFillTests.swift` — TS 와 같은 시험 · 교차 언어 벡터):
  이 기기에 없던 책을 만들 때(`updateBook` 의 cur = nil)는 넣기 직전의 비교를 하지 않는다 · 그림자 없이 넣기 직전에 비교하면(잃은 책 되살리기) 시각 0 도장 ·
  기본 형광펜 그대로인 목록은 "설정 안 됨" (도장 없음 — 처음 바꿀 때 기본 항목은 `Stamps.defaultStamp`, 목록에 없는 기본 id 는 지움 표시) ·
  이 기기에 없는 책은 서버 head 까지 다 받은 뒤에 만든다 · 파일 없이 연 책은 호스트가 `.missing` (`missingNoted`) · `updateBook` 에도 nil.
- **고치기 전 엔진이 덮지 못하게** (2026-10-05, `Tests/SpiraldaySyncTests/MixedVersionTests.swift` · TS `mixed-versions.test.ts` — 그쪽은 고치기 전 TS 엔진을 그대로 붙인다):
  책 설정(`p/`) 레코드 · 초안은 payload `v: 2` (나머지는 1) — 고치기 전 엔진(Mac 1.1.0 등, v 1 만 읽음)은 건너뛰고(업데이트 안내) 덮어쓰지 못한다.
  v 1 로 받은 책 설정은 v 2 로 다시 올리고, 예전 엔진의 저장소(메타에 `pv` 없음)로 켜면 처음부터 다시 받고(서버 순번도 잊는다) 보내지 못한 책 설정은 버린다 ·
  그룹을 만든 기기의 첫 가져오기는 형광펜을 모두 진짜 도장으로 (`Records.diff(seed: true)`) · 기본값 도장으로만 더한 형광펜은 진짜 순서 목록에 없으면 보이지 않는다 (`Records.isShown`) ·
  기본 형광펜을 보던 기기의 순서는 기본값 도장 · 책 정보(`b/`)는 맨 뒤에 올린다 · 그림자 없는 레코드의 바퀴 비교는 시각 0 도장 · 기본 형광펜 목록은 고정 상수 (`DefaultCategoriesPinTests`).
  그 목록은 Windows · Android 와도 한 값이다: `Tests/Fixtures/default-categories.json` (비공개 저장소 `sync/engine/test/fixtures/default-categories.json` 을 그대로 옮긴 것) 과
  Kit · 엔진을 견주고, Kit 이 채운 목록(새 책 · 형광펜 없는 파일 · 12개 넘는 파일)을 엔진이 "설정 안 됨" 으로 읽는지 본다 (`DefaultCategoriesParityTests`).
- **앱 값을 Swift 가 늘 읽게**: `x:` 필드로 앱이 아는 키를 덮어쓰지 않고, 날짜는 Swift 가 읽는 범위(월 1–12 …, 0000–9999 년)만 넣는다. 둘 다 받은 상태를 꾸며 넣었을 때만 생기는 일이다.
- **없는 것**: 같은 객체면 비교를 건너뛰기 — Swift 값 타입에는 객체 정체성이 없다. 저장 알림(`localChanged(bookId:)`)으로는 그 책만 비교하고, 모든 책을 비교하는 것은 시작 · `syncNow()` · `resume()` 때뿐이다.
- **실시간 쓰기의 모양**: 동작 · 바이트는 같고, Swift 에 맞게 —
  - 호스트는 레코드 하나씩 (`readLive` · `applyLive(bookId:keys:)` — TS 의 `readBook` · `applyLive(bookId, fn(PlannerData))` 대신). 입력마다 책 전체를 JSON 으로 바꾸지 않게.
  - `liveEdit` · `setEditing` · `editingProtected` 는 nonisolated (메인 스레드에서 기다리지 않고). 쓰고 있는 칸 · 마지막 입력 시각은 앱에 넣는 순간(호스트의 차례) 바로 읽는다.
  - 실시간 이벤트는 `SyncLiveEvent` 로 따로 (`addLiveListener` · `liveEvents()`). `SyncEvent.applied` 는 실시간 넣기에 오지 않는다.
  - 쓰기를 마친 뒤의 정리 앞에는 `setEditingAndSettle(nil)` 을 기다린다 (TS 는 `setEditing(null)` 이 동기라 그 자리에서 넣는다).
  - 휴대 기기 비용 (Swift 만 — 바이트 · 수렴은 같다): 받기만 한 변경의 저장 간격(`liveReceiveFlushMs`) · 넣기 묶음(`liveApplyMs`) · 저전력 모드 · 실시간 묶음은 fsync 없음,
    찬 보내기 대기는 봉인 전에 보고 물러서기, ping 뒤 답이 없으면 다시 연결, live 하위 프로토콜을 받지 않는 서버에는 내밀지 않고 다시 연결 (7.5 · 7.7).
  - 받은 초안은 넣기 전에 `apply` 로 적어 둔다 (넣기가 엔진 밖 차례라, 그 사이 저장되고 꺼져도 다시 켤 때 넣게). 앱 값을 읽고 비교하거나 넣는 일(실시간 · 바퀴)은 한 줄로 차례대로 (`appLock`), 넣은 결과는 그 사이의 변경을 덮지 않게 변경분만 돌려놓는다.
- **문자열**: Swift `==` 는 유니코드 정규화로 같은 글도 같다고 보지만 엔진은 JS 처럼 글자 그대로 비교한다 (`JS.same` · `JS.less` — UTF-16 순서).
