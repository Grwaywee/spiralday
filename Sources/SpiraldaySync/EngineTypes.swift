// 엔진의 공개 타입: 앱(호스트)과의 약속 · 상태 · 이벤트 · 오류 · 옵션.
import Foundation

// MARK: - 앱과의 약속

/// 책 파일 읽기 결과
public enum BookRead: Sendable, Equatable {
    /// 책 내용 (PlannerData JSON)
    case ok(JSONValue)
    /// 파일이 아직 없음
    case missing
    /// 읽을 수 없음 (깨진 파일 등) → 엔진은 그 책을 비교하지도 넣지도 않는다
    case unreadable
}

/// 앱(호스트)이 엔진에 주는 것: 책장과 책 파일을 읽고, 원자적으로 고친다.
///
/// 값은 앱 JSON 그대로다 (SpiraldayKit 의 PlannerData · Library 를 `JSONValue(encoding:using:)` 로 바꾼 것).
/// `update*` 의 `transform` 은 동기 함수다: 호스트는 그것을 "지금" 값으로 불러 돌려받은 값을 그대로 저장해야 한다
/// (그 사이에 사용자의 편집이 끼어들면 안 된다 — @MainActor 저장소라면 그 안에서 바로 부르고 바로 반영한다).
public protocol SyncHost: Sendable {
    /// library.json. 읽을 수 없으면(깨진 파일 등) nil → 엔진은 그때 책장을 비교하지 않는다
    func readLibrary() async -> JSONValue?
    /// 책 내용
    func readBook(id: String) async -> BookRead
    /// 책 내용 고치기. transform 이 nil 을 돌려주면 책 파일을 지운다. cur 가 nil 이면 아직 없는 책.
    /// 파일이 있는데 읽을 수 없으면 transform 을 부르지 말고 그대로 둔다 (엔진은 다음에 다시 넣는다)
    func updateBook(id: String, _ transform: @Sendable (_ cur: JSONValue?) -> JSONValue?) async throws
    /// 책장 고치기 (책 더하기 · 정보 바꾸기 · 지우기). 펼친 책이 지워졌으면 호스트가 다른 책을 편다
    func updateLibrary(_ transform: @Sendable (_ cur: JSONValue) -> JSONValue) async throws

    /// (선택) 이번 실행에서 책장 파일(library.json)이 없어 새로 만들었는지. true 면 엔진은 그 전부터 알던 책이 책장에서
    /// 사라진 것을 "지운 것" 이 아니라 "잃은 것" 으로 보고 되살린다 (데이터 폴더를 잃었을 때 모든 기기에서 지워지지 않게)
    func libraryRecreated() async -> Bool
    /// (선택) 모든 기기가 같이 쓰는 책장 수준 설정을 쓰는지
    var supportsSharedSettings: Bool { get }
    func readSharedSettings() async -> JSONValue?
    func updateSharedSettings(_ transform: @Sendable (_ cur: JSONValue) -> JSONValue) async throws

    // MARK: 실시간 쓰기 (선택 — docs/sync-live.md §8.3 · §10)

    /// (선택, 실시간 쓰기) 열린 책의 레코드 값들을 **지금 메모리 값**으로 (저장 전 편집 · IME 조합 중인 글자 포함). 엔진은 liveEdit 마다
    /// (50 ms 묶음) 이것을 부른다 — 메인 스레드에서 레코드 몇 개만 JSON 으로 바꾸면 된다 (책 전체가 아니다).
    /// keys = 레코드 키 ('d/<BOOK>/<yyyy-MM-dd>' · 'w/<BOOK>/<월요일>' · 'p/<BOOK>'). 돌려주는 값: 키 → 앱 JSON
    /// (하루 = PlannerData.days[날짜] · 한 주 = weeks[월요일] · 설정 = prefs, 앱 파일과 같은 인코더로. 없는 날 · 주는 .null).
    /// 그 책이 열려 있지 않거나 지금 읽을 수 없으면 nil → 엔진은 readBook(id:) 로 읽는다 (구현하지 않은 호스트도 그렇다)
    func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]?
    /// (선택, 실시간 쓰기) 다른 기기의 초안을 열린 책에 **지금 바로** 넣기. transform(그 레코드들의 지금 메모리 값, readLive 와 같은 모양) 의
    /// 결과를 같은 MainActor 차례 안에서 그대로 메모리에 둔다 (값 .null = 그 날 · 주를 없앤다). 파일 저장은 보통처럼 미룬다 (바로 쓰지 않는다 —
    /// 엔진이 받은 것을 먼저 저장한다. 다 쓴 뒤 localChanged(bookId:saved:) 로 알린다). 이 변경은 liveEdit 로 다시 알리지 않는다.
    /// 쓰고 있는 칸은 엔진이 이미 지켜서 넘긴다 (호스트가 따로 지키면 엔진보다 더 지키면 안 된다 — editingProtected 를 따른다).
    /// 그 책이 열려 있지 않거나 지금 넣을 수 없으면 transform 을 부르지 않고 false → 엔진은 다음 바퀴의 updateBook 으로 넣는다.
    /// transform 을 부른 뒤에는 꼭 넣고 true (넣지 못하면 updateBook 처럼 던지는 대신 false 로 — 엔진은 넣지 않은 것으로 본다)
    func applyLive(bookId: String, keys: [String], _ transform: @Sendable (_ cur: [String: JSONValue]) -> [String: JSONValue]) async -> Bool
}

extension SyncHost {
    public func libraryRecreated() async -> Bool { false }
    public var supportsSharedSettings: Bool { false }
    public func readSharedSettings() async -> JSONValue? { nil }
    public func updateSharedSettings(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {}
    public func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? { nil }
    public func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool { false }
}

// MARK: - 실시간 쓰기 (docs/sync-live.md)

/// 레코드 안의 칸 하나 (레코드와 같은 주소 — docs/sync-engine.md §2). "쓰고 있는 칸" · "다른 기기에서 쓰는 중" 에 쓴다.
/// 예: FieldAddress(key: RecordKeys.day(책, "2026-10-02"), field: "comment") · FieldAddress(key:, coll: .tasks, item: id, field: "text")
public struct FieldAddress: Sendable, Hashable, CustomStringConvertible {
    /// 항목 모음
    public enum ItemCollection: String, Sendable, Hashable, CaseIterable {
        case tasks, notes, ddays, categories
    }

    /// 레코드 키: 'd/<BOOK>/<yyyy-MM-dd>' · 'w/<BOOK>/<월요일>' · 'p/<BOOK>'
    public var key: String
    /// 단일 필드 ('comment' · 'm0' … · 'mt+' · 's07' · 'goal' · 'review' · 'mottoText' …) 또는 항목의 필드 ('text' · 'title' · 'name' …)
    public var field: String?
    /// 모음 (항목일 때)
    public var coll: ItemCollection?
    /// 항목 id: 대문자 UUID (형광펜은 10진 정수 문자열)
    public var item: String?

    /// 단일 필드
    public init(key: String, field: String) {
        self.key = key
        self.field = field
    }

    /// 모음 항목 (field 가 nil 이면 항목 전체)
    public init(key: String, coll: ItemCollection, item: String, field: String? = nil) {
        self.key = key
        self.coll = coll
        self.item = item
        self.field = field
    }

    public var description: String {
        if let coll, let item { return "\(key) \(coll.rawValue).\(item)" + (field.map { ".\($0)" } ?? "") }
        return "\(key) \(field ?? "")"
    }
}

/// 지금 연결의 presence (서버가 알려 준 것, docs/sync-live.md §3.1)
public struct LivePresence: Sendable, Equatable {
    /// 이 연결에서 서버가 초안을 중계한다 ({"peers"} 를 받았다)
    public let relay: Bool
    /// 연결이 열린 다른 기기 수
    public let peers: Int
    /// 그중 초안을 받는 기기 수
    public let live: Int

    public init(relay: Bool, peers: Int, live: Int) {
        self.relay = relay
        self.peers = peers
        self.live = live
    }
}

/// 실시간 쓰기 이벤트 (SyncEvent 와 따로 — 초당 여러 번 올 수 있다). addLiveListener · liveEvents() 로 받는다
public enum SyncLiveEvent: Sendable, Equatable {
    /// presence 가 바뀌었다 (연결 없음 · 서버가 알려 주지 않음 = nil)
    case presence(LivePresence?)
    /// 다른 기기(from = 그 기기 id, 기기 목록으로 이름을 풀 수 있다)의 초안을 받았다. at = 초안이 바꾼 곳,
    /// editing = 그중 하나가 내가 쓰고 있는 칸 (setEditing) → 그 칸 옆에 "다른 기기에서 쓰는 중" (마지막 이벤트부터 3초).
    /// 사용자가 그 칸에 쓰는 중이면 그 칸의 글은 그대로 두었고 (held), 포커스만 있으면 상대 글을 넣었다
    case remoteTyping(from: String, at: [FieldAddress], editing: Bool)
    /// 쓰고 있는 칸(setEditing)에 다른 기기의 더 새 글이 있는데 사용자가 그 칸에 쓰는 중이라 앱 글을 그대로 두었다 (그 칸) ·
    /// 그 일이 끝났다 (nil: 쓰기를 마쳤거나 editingGraceMs 동안 치지 않아 상태의 승자를 넣었다) → 그동안 "다른 기기의 글이 있어요"
    case held(FieldAddress?)
    /// 다른 기기의 초안을 열린 책에 바로 넣었다 (host.applyLive 로 — 메모리는 이미 바뀌었다. 가볍게 다룰 것: 상태 표시는 그대로)
    case applied(bookId: String)
}

/// 실시간 쓰기 세기 (앱 로그 · 모니터링, docs/sync-live.md §11.5)
public struct LiveCounters: Sendable, Equatable {
    /// 보낸 초안
    public var sent = 0
    /// 보내지 못하고 미룬 틱 (버킷 · 보내기 대기)
    public var deferred = 0
    /// 너무 커서 보내지 않은 조각 (레코드로 간다)
    public var tooLarge = 0
    /// 받아들인 초안
    public var received = 0
    /// 버린 초안: 재생 · 풀리지 않음 · 모양 · 그룹 밖
    public var dropped = 0
    /// 확인되지 않아 대신 올린 레코드
    public var adopted = 0

    public init() {}
}

/// 보내기 상황 (docs/sync-live.md §11.1)
public enum PushMode: String, Sendable, CaseIterable {
    /// 온라인 기기가 모두 초안을 받는데 초안으로 가지 않은 변경 (책 정보 · 책장 …) — 첫 변경 + 400 ms
    case fast
    /// 온라인 기기가 모두 초안을 받는다 — 첫 변경 + 2 s (보이는 지연은 초안이 맡는다)
    case covered
    /// 초안을 받지 않는 기기(옛 앱)가 온라인 — 마지막 변경 + 1 s, 첫 변경부터 최대 2 s
    case oldPeer = "old-peer"
    /// presence 를 모른다 (옛 서버 · WebSocket 이 막힘 · LIVE=off) — 마지막 변경 + 1.5 s, 최대 4 s (예전 비용 수준)
    case unknown
    /// 온라인 기기가 없다 — 마지막 변경 + 2 s, 최대 5 s (창을 닫을 때는 sendPending 으로 바로)
    case alone

    /// presence → 보내기 상황 (COVERED 인데 초안으로 가지 않은 변경이 있으면 엔진이 fast 로 바꾼다)
    public static func of(_ p: LivePresence?) -> PushMode {
        guard let p, p.relay else { return .unknown }
        if p.peers == 0 { return .alone }
        return p.live >= p.peers ? .covered : .oldPeer
    }
}

/// 상황별 보내기 지연 (ms)
public struct PushDelays: Sendable, Equatable {
    public var pushDelayMs = 400
    public var coveredPushDelayMs = 2000
    public var oldPeerPushDelayMs = 1000
    public var oldPeerMaxWaitMs = 2000
    public var unknownPushDelayMs = 1500
    public var unknownMaxWaitMs = 4000
    public var alonePushDelayMs = 2000
    public var aloneMaxWaitMs = 5000

    public init() {}

    /// 밀린 변경을 보낼 때 (ms 시각). fast · covered = 첫 변경부터 정한 지연 (뒤 변경으로 밀리지 않는다),
    /// oldPeer · unknown · alone = 마지막 변경 + 지연, 첫 변경부터 최대 maxWait (계속 치는 동안 요청 수를 줄인다)
    public func dueAt(_ mode: PushMode, firstAt: Int, lastAt: Int) -> Int {
        func debounce(_ delay: Int, _ maxWait: Int) -> Int { min(lastAt + delay, firstAt + max(maxWait, delay)) }
        switch mode {
        case .fast: return firstAt + pushDelayMs
        case .covered: return firstAt + coveredPushDelayMs
        case .oldPeer: return debounce(oldPeerPushDelayMs, oldPeerMaxWaitMs)
        case .unknown: return debounce(unknownPushDelayMs, unknownMaxWaitMs)
        case .alone: return debounce(alonePushDelayMs, aloneMaxWaitMs)
        }
    }
}

// MARK: - 상태 · 이벤트

public enum SyncState: String, Sendable {
    /// 동기화 꺼짐
    case off
    /// 동기화됨
    case idle
    /// 맞추는 중
    case syncing
    /// 오프라인 (편집은 쌓였다가 연결되면 올라간다)
    case offline
    /// 오류 (저절로 다시 시도)
    case error
    /// 이 기기가 그룹에서 빠짐
    case removed
    /// 그룹이 지워짐
    case groupGone = "group-gone"
    /// 저장 공간(50MB)이 가득 참
    case quota
}

public struct SyncStatus: Sendable, Equatable {
    public let state: SyncState
    /// 서버로 아직 보내지 않은 레코드 수
    public let pending: Int
    public let lastSyncAt: Int?
    /// 사람이 읽을 오류 (한국어)
    public let error: String?
    public let gid: String?
    public let deviceId: String?
    /// WebSocket 연결 중인지
    public let live: Bool
    /// 지금 연결의 presence (연결 없음 · 서버가 알려 주지 않음 = nil)
    public let presence: LivePresence?
}

public enum SyncWarning: String, Sendable {
    case massDeleteBooks = "mass-delete-books"
    case massDeleteDays = "mass-delete-days"
    case bookMissing = "book-missing"
    /// 책장에서만 사라지고 파일은 남은 책을 되살렸다
    case bookUnlisted = "book-unlisted"
    /// 다른 기기에서 지운 책이 다시 나타났다 (이 기기에만 남는다)
    case bookDeletedElsewhere = "book-deleted-elsewhere"
    /// 다른 기기의 시계가 하루 넘게 앞서 있다
    case clockSkew = "clock-skew"
    case undecryptable
    case updateRequired = "update-required"
    case libraryUnreadable = "library-unreadable"
    case recordTooLarge = "record-too-large"
}

public enum SyncEvent: Sendable, Equatable {
    case status(SyncStatus)
    /// 동기화가 앱 데이터를 바꿨다 (이 책들, 책장)
    case applied(books: [String], library: Bool)
    /// 기기 목록이 바뀜
    case devices
    /// 페어링 상태가 바뀜 (claimed · approved · denied) — 다른 기기에서 승인 · 거절했을 때 화면을 닫는 데 쓴다
    case pairing(id: String, status: String)
    /// bookId: book-deleted-elsewhere 의 그 책
    case warning(SyncWarning, message: String, bookId: String? = nil)
}

/// 기기가 처음 들어올 때 서버에 보이는 플랫폼 이름 (서버는 이 목록만 받는다)
public enum SyncPlatform: String, Sendable, CaseIterable {
    case mac = "Mac"
    case windows = "Windows"
    case iPhone
    case iPad
    case android = "Android"
    case web = "Web"
}

public enum SyncLogLevel: String, Sendable {
    case debug, info, warn, error
}

// MARK: - 오류

public struct SyncEngineError: Error, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable {
        case notInGroup = "not-in-group"
        case alreadyInGroup = "already-in-group"
        case invalidCode = "invalid-code"
        case deviceLimit = "device-limit"
        case pairingLimit = "pairing-limit"
        case pairingDenied = "pairing-denied"
        case pairingExpired = "pairing-expired"
        /// 원래 기기에서 입력한 확인 숫자가 새 기기의 것과 다르다
        case digitsMismatch = "digits-mismatch"
        case rateLimited = "rate-limited"
        /// 서버 전체의 8자 코드 실패 상한 (이 사람이 틀린 것이 아니다)
        case codeJoinPaused = "code-join-paused"
        case wrongKey = "wrong-key"
        case recoveryNotFound = "recovery-not-found"
        case libraryUnavailable = "library-unavailable"
        case offline
        case server
        case notInitialized = "not-initialized"
        case invalidArgument = "invalid-argument"
    }

    public let code: Code
    /// 그대로 보여 줄 수 있는 한국어
    public let message: String
    public let underlying: (any Error)?

    public init(_ code: Code, _ message: String, underlying: (any Error)? = nil) {
        self.code = code
        self.message = message
        self.underlying = underlying
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - 옵션

public struct SyncEngineOptions: Sendable {
    public var host: any SyncHost
    public var transport: any SyncTransport
    public var storage: any SyncStorage
    /// 토큰 · 그룹 키를 둘 곳 (Keychain). 없으면 storage 의 메타에 둔다 (테스트용)
    public var credentials: (any CredentialStore)?
    /// 시계 (ms)
    public var now: @Sendable () -> Int
    /// 저절로 돌기 (타이머 · WebSocket). 테스트는 false 로 두고 직접 부른다
    public var auto: Bool
    /// WebSocket 을 열지 (기본 = auto). auto 없이 초안을 시험할 때 true
    public var socket: Bool
    /// 저장 알림 뒤 비교까지 (ms, 기본 150)
    public var scanDelayMs: Int
    /// 보내기 — FAST (ms, 기본 400): 온라인 기기가 모두 초안을 받는데(COVERED) 초안으로 가지 않은 변경 (책 정보 · 책장 …), 첫 변경부터.
    /// 상황별 지연은 pushDelays (이 값만 준 예전 호출은 모든 상황에 이 값을 쓴다)
    public var pushDelayMs: Int { pushDelays.pushDelayMs }
    /// 상황별 보내기 지연 (FAST · COVERED · OLD-PEER · UNKNOWN · ALONE)
    public var pushDelays: PushDelays
    /// WebSocket {"head"} 를 받고 받기까지 (ms, 기본 0)
    public var headPullDelayMs: Int
    /// 받기 시작 사이 최소 간격 (ms, 기본 150)
    public var minPullIntervalMs: Int
    /// 실시간 쓰기 (기본 true). false 면 live 하위 프로토콜을 내밀지 않는다: presence · 초안 없음
    public var live: Bool
    /// liveEdit 묶음 (ms, 기본 50): 첫 입력은 바로, 그 뒤는 이 간격으로 (마지막 값은 꼭)
    public var liveThrottleMs: Int
    /// 실시간으로 받아들인 · 받은 편집을 동기화 저장소에 쓰는 최소 간격 (ms, 기본 100): 첫 변경은 바로, 그 뒤는 이 간격으로.
    /// 앱 파일 저장(0.6초 묶음)보다 늘 먼저 — 앱은 파일을 쓰기 전에 storageBehind 면 flushLive() 를 기다리면 확실하다
    public var liveFlushMs: Int
    /// 받은 초안이 레코드로 확인되지 않으면 받은 기기가 대신 올리기까지 (ms, 기본 30000)
    public var liveAdoptMs: Int
    /// 쓰고 있는 칸(setEditing)을 지키는 시간 (ms, 기본 5000): 마지막 입력(liveEdit)부터 이만큼 지나면 포커스만 있는 칸으로 보고
    /// 다른 기기의 더 새 글을 넣는다 (옛 글이 새 도장을 얻어 더 새 글을 덮지 않게 — SpiraldayKit editingGrace 와 같다)
    public var editingGraceMs: Int
    /// WebSocket 이 없을 때 서버 확인 간격 (ms)
    public var pollMs: Int
    /// WebSocket 이 있을 때 안전 확인 간격 (ms)
    public var safetyPollMs: Int
    /// 동시에 보내는 레코드 수 (batch 를 모르는 서버)
    public var concurrency: Int
    /// 한 번 비교에서 이만큼 넘는 날이 한꺼번에 사라지면 지우지 않고 되살린다
    public var massDeleteDays: Int
    /// 이 기기의 플랫폼 (들어오는 순간 서버에 "p.<플랫폼>" 으로 보인다)
    public var platform: SyncPlatform
    public var log: @Sendable (SyncLogLevel, String) -> Void

    /// - Parameters:
    ///   - pushDelayMs: 이것만 주면 (예전 호출) 모든 보내기 상황에 이 값. 주지 않으면 상황별 기본값 (docs/sync-live.md §11.1)
    ///   - pushDelays: 상황별 보내기 지연을 따로 (주면 pushDelayMs 보다 앞선다)
    public init(host: any SyncHost, transport: any SyncTransport, storage: any SyncStorage, credentials: (any CredentialStore)? = nil,
                platform: SyncPlatform, auto: Bool = true, socket: Bool? = nil, now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                scanDelayMs: Int = 150, pushDelayMs: Int? = nil, pushDelays: PushDelays? = nil, headPullDelayMs: Int = 0, minPullIntervalMs: Int = 150,
                live: Bool = true, liveThrottleMs: Int = 50, liveFlushMs: Int = 100, liveAdoptMs: Int = 30_000, editingGraceMs: Int = 5000,
                pollMs: Int = 30_000, safetyPollMs: Int = 5 * 60_000,
                concurrency: Int = 4, massDeleteDays: Int = 20, log: @escaping @Sendable (SyncLogLevel, String) -> Void = { _, _ in }) {
        self.host = host
        self.transport = transport
        self.storage = storage
        self.credentials = credentials
        self.platform = platform
        self.auto = auto
        self.socket = socket ?? auto
        self.now = now
        self.scanDelayMs = scanDelayMs
        if let pushDelays {
            self.pushDelays = pushDelays
        } else if let legacy = pushDelayMs {
            // 예전 옵션: 모든 상황에 그 값
            var d = PushDelays()
            d.pushDelayMs = legacy
            d.coveredPushDelayMs = legacy
            d.oldPeerPushDelayMs = legacy
            d.oldPeerMaxWaitMs = legacy
            d.unknownPushDelayMs = legacy
            d.unknownMaxWaitMs = legacy
            d.alonePushDelayMs = legacy
            d.aloneMaxWaitMs = legacy
            self.pushDelays = d
        } else {
            self.pushDelays = PushDelays()
        }
        self.headPullDelayMs = headPullDelayMs
        self.minPullIntervalMs = minPullIntervalMs
        self.live = live
        self.liveThrottleMs = liveThrottleMs
        self.liveFlushMs = liveFlushMs
        self.liveAdoptMs = liveAdoptMs
        self.editingGraceMs = editingGraceMs
        self.pollMs = pollMs
        self.safetyPollMs = safetyPollMs
        self.concurrency = concurrency
        self.massDeleteDays = massDeleteDays
        self.log = log
    }
}

// MARK: - 페어링 · 기기 · 기록

/// 원래 기기에 온 합류 요청. 이때 그룹 키는 아직 서버에 있고, 승인해야 새 기기로 간다.
/// 확인 숫자는 여기 없다: 원래 기기는 새 기기 화면의 숫자를 사용자에게 입력받아 approve(enteredDigits:) 에 넘긴다
/// (보여 주고 "같나요?" 를 묻는 방식은 [연결] 한 번으로 승인될 수 있다)
public struct JoinRequest: Sendable, Equatable {
    public let pairingId: String
    /// 들어오려는 기기 (승인하면 이 id 로 그룹에 들어온다)
    public let deviceId: String
    /// 들어오려는 기기의 플랫폼 (모르면 nil)
    public let platform: SyncPlatform?
    /// 이때까지 승인해야 한다 (ms)
    public let expiresAt: Int
}

/// 들어갈 그룹에 이미 있는 기기 (풀어 낸 이름)
public struct GroupDevice: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let platform: SyncPlatform?
}

/// 새 기기가 승인을 기다린 결과
public enum JoinOutcome: Sendable, Equatable {
    /// 원래 기기가 승인했고 그룹 키를 받았다. 수락 화면에 그룹의 기기 이름을 보여 준다.
    /// acceptBy (ms, 이 기기 시계) 까지 accept() 해야 한다 — 서버는 키를 받고도 수락하지 않은 기기를 30분 뒤에 뺀다
    case approved(groupDevices: [GroupDevice], acceptBy: Int)
    /// 원래 기기가 [아니에요] 를 눌렀다
    case denied
    /// 승인 기한이 지났다
    case expired
    /// 이 기기에서 그만뒀다 (reject · Task 취소)
    case cancelled
}

public struct DeviceInfo: Sendable, Equatable {
    public let id: String
    /// 풀어 낸 이름 (못 풀면 nil → "알 수 없는 기기")
    public let name: String?
    /// 합류 직후의 플랫폼 이름 (이름을 아직 올리지 못했을 때)
    public let platform: SyncPlatform?
    public let created: Int
    public let lastSeen: Int
    /// 이 기기인지
    public let current: Bool
}

public struct HistoryEntry: Sendable, Equatable {
    public let seq: Int
    /// 그 버전을 쓴 시각 (ms)
    public let at: Int
    public let current: Bool
    /// 앱 모양의 값 (하루 · 한 주 · 설정 · 책 정보). 빈 날이면 nil
    public let value: JSONValue?
}
