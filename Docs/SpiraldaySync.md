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
| `VectorsTests` | 프로토콜 테스트 벡터 전부 (하위 키 · rid · 봉인 · 기기 이름 · 페어링 코드/QR · confirmKey · 확인 숫자 · 복구 · carryTaskId) 바이트 그대로 |
| `BasicsTests` | 코드(한 글자 틀림 · 이웃 바뀜 검출), UUIDv5(RFC 9562), HLC, base64url, JS 규칙(숫자 → 글 · UTF-16 정렬 · JSON.stringify 이스케이프 · 파서), 날짜, 암호(변조 · 다른 키 · 이름 바꿔치기), **TypeScript 엔진이 만든 암호문을 풀고 같은 상태를 만든다**, 압축 폭탄 · 크기 속임 · `__proto__` |
| `ConvergenceTests` | N 복제본 · 아무 순서 · 중복 · 지연 → 같은 상태 · 같은 앱 데이터, 되살아남 없음, 교환 · 결합 · 멱등, 동시 편집이 모두 남음 |
| `AppDecodeTests` | 받은 상태에 아무 값이 들어 있어도 앱에 넣는 값을 SpiraldayKit 의 진짜 모델(`PlannerData` · `BookInfo`)로 늘 읽을 수 있다 (600번 퍼징) |
| `Engine*Tests` | 엔진 + 가짜 서버: 승인 게이트 (요청 응답 · 기다리는 동안 키 없음, 거절 · 거둠 · 기한 · 취소 · 코드 실패 상한 · 이름 바꿔치기), 주고받기 · 409 · 책 만들기/지우기 · 오프라인 대기열 · 응답만 잃은 쓰기 · 안전장치 · 복구 · 그룹 지우기 · 이전 버전 · 새 버전 레코드 · WebSocket · 다시 붙기 · suspend/resume |
| `LifecycleAndLossyHostTests` | 올리는 동안(느린 망) 앞으로 돌아오면 엔진이 멈추지 않음 · 모르는 키를 버리는 앱(모델로 다시 쓰는 앱)이 새 버전 기기의 키를 `null` 로 지우지 않음 |
| `ChaosTests` | 엔진 2–3대 + 요청이 늦게 · 뒤섞여 · 두 번 · 안 닿거나 응답만 사라지는 네트워크, 동시 편집 · 동시 동기화 → 수렴 · 되살아남 없음 |
| `StorageTests` | 파일 저장소 (일지 다시 읽기 · 사본으로 줄이기 · 끊긴 마지막 줄 · 사본 뒤 옛 일지), 껐다 켜도 남는 오프라인 편집, Keychain, 서버 주소 |

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
| `applyLibrary(_ merged: Library) -> ExternalApplyResult` | 책장 넣기. 펼친 책(activeID)은 이 기기의 것 그대로 · 빠졌으면 그 책은 저장하지 않고 다른 책을 편다 (`closedBook` · `openedBook`) · 아무 책도 안 폈으면 들어온 내가 만든 첫 책을 편다 · `sampleSeeded` 는 지우지 않음 · 같은 id 는 앞의 것만 · `libraryUnreadable` 이면 아무것도 안 함 · 같으면 아무것도 안 함. 바뀌면 library.json 에 쓰고 `onSaved(nil, true)` |
| `applyActiveData(_ merged: PlannerData, keepingEditOf: String?) -> ExternalApplyResult` | 펼친 책 넣기 + **바로 저장** (`onSaved(id, true)`). 쓰고 있는 칸(`AppState.editingKey`)은 화면의 글을 지킴 (`keptEdit` — 다음 비교에서 새 편집으로 올라간다), 쓰던 할 일 · 메모가 지워졌으면 `editedItemRemoved`. `lastKind` · `ddaysPerDay` 는 이 기기의 것, 줄 없는 할 일은 줄을 매김, 같으면 아무것도 안 함 |
| `readBookRaw(_ id: UUID) -> RawBookFile` | `.missing` · `.unreadable` · `.data(Data)` (앱이 읽을 수 있는 것만). **펼친 책이면 지금 내용** (저장 전 편집 포함). 읽지 못하면 책을 열 때처럼 복사본을 남기고 `unreadableBooks` 에 적는다 |
| `writeBookRaw(_ id: UUID, _ raw: Data) throws` | 펼치지 않은 책 파일을 그대로 원자적으로 쓴다 (책장에 아직 없는 책도). 거절 `BookFileError`: `.bookIsOpen` · `.unreadable` · `.invalidContent` · `.fileError`. 호스트는 엔진의 값을 `decodeFile(PlannerData.self…)` → `encodeFile` 로 한 번 거쳐 넘긴다 — Mac 의 `JSONEncoder` 와 같은 바이트 (기본값인 칸 · `null` 은 빠지고 `/` 는 `\/`). 엔진의 정규 JSON(`jsonData()`)을 그대로 쓰면 읽을 수는 있어도 기기마다 바이트가 달라진다 |
| `removeBookFile(_ id: UUID) throws` | 책장에서 뺀 책의 파일 (+ D-day 옮기기 백업) 을 지운다. 없으면 아무것도 안 함. 거절: `.bookIsOpen` · `.bookIsListed` · `.unreadable` · `.fileError` |
| `isApplyingExternalChange: Bool` | `apply…` 가 `data` · `library` 를 바꾸는 동안 true (`$data` sink 안에서 읽는다) |
| `PlannerStore.encodeFile(_:)` · `decodeFile(_:from:)` | 앱 파일과 같은 JSON (`.iso8601`, `.sortedKeys`) |
| `PlannerData.rebased(from:to:)` | 밖에서 온 변경(base → theirs)을 되돌리기 단계에 옮긴다 (칸마다) |
| `PlanTask.carryTaskId(_ id: UUID) -> UUID` | → 미룸 사본 id = UUIDv5(원래 id, "carry") — `carryForward` 가 이미 쓴다. `CarryID.carryTaskId` 와 같은 값 |

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
        switch store.readBookRaw(uuid) {                       // 펼친 책은 지금 내용
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .data(let raw): return (try? JSONValue.parse(raw)).map { .ok($0) } ?? .unreadable   // 모르는 키도 그대로
        }
    }

    func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        guard let uuid = UUID(uuidString: id) else { return }
        let cur: JSONValue?
        switch store.readBookRaw(uuid) {
        case .unreadable: return                                // 읽지 못한 파일: transform 을 부르지 않고 그대로
        case .missing: cur = nil
        case .data(let raw):
            guard let v = try? JSONValue.parse(raw) else { return }
            cur = v
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

엔진은 0.4초 뒤 비교하고 1.5초 뒤 올린다. 다른 기기의 편집은 WebSocket `{head}` 알림으로 1초 안팎에 받고, 알림이 없을 때는 30초(연결 중이면 5분)마다 확인한다. 연결이 끊기면 1 → 2 → 4 … 60초 + 무작위로 다시 붙는다.

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

### Mac 앱

- 플랫폼 `.mac`. 동기화 상태 폴더는 `~/Library/Application Support/Spiralday/SyncState` (앱 데이터 폴더 안, 앱 파일과 섞지 않는다).
- Keychain: 샌드박스 · keychain-access-groups 가 없는 Developer ID 앱은 `SyncEngine.standard(…, useDataProtectionKeychain: false)` (로그인 키체인, 같은 접근성 값).
- `carryForward` 의 미룸 id 규칙은 SpiraldayKit 에 들어 있어 Mac 앱도 이미 같다 (`PlanTask.carryTaskId`).
- 이 저장소의 Mac 앱이 실제로 붙인 곳은 `Sources/Spiralday/Sync/` 다:
  - `SyncController` — 엔진 하나 · 설정 → 동기화의 단계별 흐름 · 앱 수명. 기본은 꺼짐: 이 설치가 그룹에 들어간 적이 있을 때(UserDefaults `sync.groupURL`)만
    켤 때 키체인을 읽고 엔진을 만든다. 그 전에는 키체인 · 네트워크를 건드리지 않는다. 잠자기(`NSWorkspace.willSleepNotification`) → 저장 · `suspend()`,
    깨어남 · 네트워크가 돌아옴(`NWPathMonitor`) · 앱이 앞으로 옴(15초에 한 번까지) → `resume()`, 끝낼 때(`applicationShouldTerminate`) → 저장 · `suspend()` (최대 2.5초).
  - `PlannerSyncHost` — 위 4 의 호스트. 쓰던 칸(포커스만)의 글이 다른 기기의 글로 바뀌면 `onEditedFieldReplaced(새 글)` 로 알리고, 컨트롤러가 그 칸의
    되돌리기 기록을 비운다. Mac 앱의 ⌘Z 는 글 칸(필드 편집기)의 것뿐이라 PlannerData 를 쌓는 되돌리기가 없다 — 이것이 Mac 의 "되돌리기 옮기기"다.
    ⌘Z(`undo:`)는 응답자 사슬로 가서 필드 편집기가 보는 기록을 되돌리는데, SwiftUI 글 칸의 필드 편집기는 창의 `undoManager` 가 아니라 호스팅 뷰의 기록을 쓰고,
    SwiftUI 가 다음 화면 갱신에서 새 글을 칸에 넣는 것도 그 기록에 남는다. 그래서 필드 편집기의 기록(과 창의 것)을 바로 한 번, 새 글이 칸에 들어간 뒤 한 번 더 비운다.
  - 펼친 책이 다른 기기에서 지워지면 다른 책을 펴고 플래너 위에 안내, 펼치지 않은 책이 지워지면 그 이름으로 안내. 지금 장이 기간 밖이면 오늘로.
  - 설정 → 동기화 (`SyncSettingsPane` · `SyncFlows` · `SyncHistory`), 팔레트의 설정 단추 귀퉁이 표시, 플래너 메뉴의 ‘지금 맞추기’ · ‘이 날(주)의 이전 버전…’ · ‘동기화 설정…’.
    Mac 은 QR 을 카메라로 찍지 않는다 — Windows PC 처럼 8자리 코드나 원래 기기의 ‘연결 글 복사’로 받은 글을 붙여 넣는다.
  - `Spiralday --sync-qa <폴더>` 가 설정 → 동기화의 모든 상태를 라이트 · 다크 PNG 로 (메모리에서만), `Tests/SpiraldayAppTests` 가 호스트 · 컨트롤러 · 말을 가짜 서버로 시험한다.
  - 디버그 빌드만: `Spiralday --sync-drive <폴더> [--sync-drive-keychain com.spiralday.mac.sync.qa.<이름>]` — 여러 기기 검증 스크립트가 이 Mac 앱을 모는 통로
    (`Sync/SyncQADrive.swift`). `<폴더>/in/*.json` 의 명령을 화면이 부르는 것과 같은 저장소 · 컨트롤러 함수로 실행하고 `<폴더>/out` 에 답한다.
    플래너 파일은 `<폴더>/data`, 비밀은 테스트용 키체인 서비스 이름, 설정 값은 `<폴더>` 안 — 앱의 데이터 폴더 · `com.spiralday.sync` 키체인 항목은 거절한다.
    플래너 종이는 화면 밖 창에 두고 앱을 앞으로 가져오지 않으며, 통계 · 업데이트 확인 · 처음 안내 · 둘러보기는 켜지 않는다. 서버는 운영 주소(또는 디버그의 `SPIRALDAY_SYNC_URL`).

## TypeScript 엔진과 다른 점

- **같다**: 바이트 규칙 전부, 레코드 payload · 필드 이름 · 기본값, 합치기, 비교 순서(같은 시계면 같은 도장 — TypeScript 엔진이 만든 상태와 바이트까지 같은 것을 테스트로 확인), 안전장치, 페어링 · 복구 흐름, 오류 코드 · 문구.
- **앱 값을 Swift 가 늘 읽게**: `x:` 필드로 앱이 아는 키를 덮어쓰지 않고, 날짜는 Swift 가 읽는 범위(월 1–12 …, 0000–9999 년)만 넣는다. 둘 다 받은 상태를 꾸며 넣었을 때만 생기는 일이다.
- **없는 것**: 같은 객체면 비교를 건너뛰기 — Swift 값 타입에는 객체 정체성이 없다. 저장 알림(`localChanged(bookId:)`)으로는 그 책만 비교하고, 모든 책을 비교하는 것은 시작 · `syncNow()` · `resume()` 때뿐이다.
- **문자열**: Swift `==` 는 유니코드 정규화로 같은 글도 같다고 보지만 엔진은 JS 처럼 글자 그대로 비교한다 (`JS.same` · `JS.less` — UTF-16 순서).
