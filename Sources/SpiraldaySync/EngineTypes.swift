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
}

extension SyncHost {
    public func libraryRecreated() async -> Bool { false }
    public var supportsSharedSettings: Bool { false }
    public func readSharedSettings() async -> JSONValue? { nil }
    public func updateSharedSettings(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {}
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
    /// 저장 알림 뒤 비교까지 (ms)
    public var scanDelayMs: Int
    /// 비교 뒤 보내기까지 (ms)
    public var pushDelayMs: Int
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

    public init(host: any SyncHost, transport: any SyncTransport, storage: any SyncStorage, credentials: (any CredentialStore)? = nil,
                platform: SyncPlatform, auto: Bool = true, now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                scanDelayMs: Int = 400, pushDelayMs: Int = 1500, pollMs: Int = 30_000, safetyPollMs: Int = 5 * 60_000,
                concurrency: Int = 4, massDeleteDays: Int = 20, log: @escaping @Sendable (SyncLogLevel, String) -> Void = { _, _ in }) {
        self.host = host
        self.transport = transport
        self.storage = storage
        self.credentials = credentials
        self.platform = platform
        self.auto = auto
        self.now = now
        self.scanDelayMs = scanDelayMs
        self.pushDelayMs = pushDelayMs
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
