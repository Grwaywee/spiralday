import AppKit
import Combine
import Network
import SystemConfiguration
import IOKit
import CryptoKit
import SpiraldayKit
import SpiraldaySync

// ─────────────────────────────────────────────────────────────────────────────
// Spiralday Sync 를 Mac 앱에 붙이는 곳: 엔진 하나 · 설정 → 동기화의 단계별 흐름 · 앱 수명
// (Windows 앱 · iOS 앱의 SyncController 와 같은 흐름).
//
//   켤 때          이 설치가 그룹에 들어간 적이 있을 때(UserDefaults 의 그룹 주소)만 키체인을 읽고 엔진을 만든다.
//                  기본값은 꺼짐 — 켜기 전까지는 키체인도 네트워크도 건드리지 않는다
//   저장할 때마다  PlannerStore.onSaved → engine.localChanged (책 · 책장), onDeleted → deletedBooks
//   앱 수명        잠자기 → 저장 · suspend, 깨어남 · 네트워크가 돌아옴 · 앱이 앞으로 옴 → resume,
//                  끝낼 때 → 저장 · suspend (남은 편집을 올린다, 오래 기다리지 않는다)
//   받은 편집      펼친 책이 빠졌으면 안내 · 다른 책, 지금 장이 기간 밖이면 오늘로, 쓰던 칸이 바뀌었으면 그 칸의 ⌘Z 기록을 비운다
//
// 비밀(기기 토큰 · 그룹 키)은 로그인 키체인 (KeychainCredentialStore — Developer ID 앱이라 데이터 보호 키체인은 쓰지 않는다).
// 로그인 키체인은 ThisDeviceOnly 를 지키지 않아 이전 지원 · Time Machine 복원으로 새 Mac 에 옮겨 갈 수 있다 →
// 그룹에 들어갈 때 이 Mac 의 표시(IOPlatformUUID 의 해시)를 적어 두고, 켤 때 다르면 엔진을 띄우지 않고 묻는다 (movedFromOtherMac).
// 동기화 상태(도장 · 그림자 · 순번)는 ~/Library/Application Support/Spiralday/SyncState (앱 파일과 섞지 않는다).
// .app 이 아닌 실행(swift run 등 — 번들 id 가 다름)은 키체인 항목 · 상태 폴더를 따로 쓴다 (Environment.sharesReleaseIdentity).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - 화면이 보는 값 (엔진의 값을 옮겨 담는다 — 화면 · 테스트 · 스크린샷이 엔진 없이도 만들 수 있게)

struct SyncViewStatus: Equatable {
    var state: SyncState
    /// 서버로 아직 보내지 않은 기록 수
    var pending = 0
    /// ms
    var lastSyncAt: Int?
    /// 엔진이 적은 한국어
    var error: String?
    /// WebSocket 으로 이어져 있는지
    var live = false

    init(state: SyncState, pending: Int = 0, lastSyncAt: Int? = nil, error: String? = nil, live: Bool = false) {
        self.state = state
        self.pending = pending
        self.lastSyncAt = lastSyncAt
        self.error = error
        self.live = live
    }

    init(_ s: SyncStatus) {
        self.init(state: s.state, pending: s.pending, lastSyncAt: s.lastSyncAt, error: s.error, live: s.live)
    }
}

/// 그룹의 기기 한 대
struct SyncDeviceRow: Identifiable, Equatable {
    let id: String
    /// 풀어 낸 이름 (못 풀면 nil)
    let name: String?
    let platform: SyncPlatform?
    /// ms
    let created: Int
    let lastSeen: Int
    let current: Bool

    init(id: String, name: String?, platform: SyncPlatform?, created: Int, lastSeen: Int, current: Bool) {
        self.id = id
        self.name = name
        self.platform = platform
        self.created = created
        self.lastSeen = lastSeen
        self.current = current
    }

    init(_ d: DeviceInfo) {
        self.init(id: d.id, name: d.name, platform: d.platform, created: d.created, lastSeen: d.lastSeen, current: d.current)
    }
}

/// 들어갈 그룹에 이미 있는 기기 (수락 화면)
struct SyncGroupDeviceName: Equatable {
    let name: String?
    let platform: SyncPlatform?
}

// MARK: - 흐름 (설정 → 동기화가 그 자리에서 그린다)

struct SyncRequestInfo: Equatable {
    var platform: SyncPlatform?
    var deadline: Date
    var triesLeft: Int
    var wrong = false
}

enum SyncFlow: Equatable {
    enum RecoveryReason: Equatable { case create, rotate }
    enum RecoveryStage: Equatable {
        case working
        /// 한 번만 보여 준다 (메모리에만)
        case show(code: String)
        case failed(String)
    }

    enum PairStage: Equatable {
        case opening
        case waiting(qrText: String?, code: String?, deadline: Date)
        case request(SyncRequestInfo)
        case approving(SyncRequestInfo)
        case approved(platform: SyncPlatform?)
        case denied
        case withdrawn
        case expired(wasRequest: Bool)
        case error(String)
    }

    enum JoinStage: Equatable {
        case waiting(digits: String, deadline: Date)
        case approved(devices: [SyncGroupDeviceName], deadline: Date)
        case accepting(devices: [SyncGroupDeviceName], deadline: Date)
        case done(backup: SyncBackupSnapshot?)
        case denied
        case expired(afterApproval: Bool)
        case error(String)
    }

    case recovery(reason: RecoveryReason, stage: RecoveryStage)
    case pair(mode: PairingMode, stage: PairStage)
    case join(stage: JoinStage, localBooks: [String])
    case restore(evicted: Bool, backup: SyncBackupSnapshot?)

    /// 서버 일이 도는 중이라 그만둘 수 없는 단계
    var busy: Bool {
        switch self {
        case .recovery(_, .working): true
        case .pair(_, .opening), .pair(_, .approving): true
        case .join(.accepting, _): true
        default: false
        }
    }

    /// 비밀(복구 코드 · 연결 코드 · QR)이 화면에 있다 → 설정 창을 화면 공유 · 캡처에서 가린다
    var showsSecret: Bool {
        switch self {
        case .recovery(_, .show): true
        case .pair(_, .waiting): true
        default: false
        }
    }
}

/// 흐름을 시작하기 전에 설정 → 동기화가 혼자 갖는 단계 (서버 일은 아직)
enum SyncLocalStep: String, Identifiable {
    case start, join, restore
    var id: String { rawValue }
}

struct SyncWarningItem: Identifiable, Equatable {
    let id: String
    let warning: SyncWarning
    let bookName: String?
    let at: Date
}

/// 플래너 위에 잠깐 뜨는 안내 (다른 기기에서 지운 플래너 등)
struct SyncNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// 하던 일의 결과 (화면이 오류를 그 자리에 보인다)
struct SyncActionResult: Equatable {
    var ok: Bool
    var message: String?
    var code: SyncEngineError.Code?
    /// 합치기 전 백업을 만들지 못해 멈췄다 (화면이 "백업 없이 합칠까요?" 를 묻는다)
    var backupFailed = false

    static let done = SyncActionResult(ok: true)
    static func failed(_ message: String, _ code: SyncEngineError.Code? = nil) -> SyncActionResult {
        SyncActionResult(ok: false, message: message, code: code)
    }
    static func noBackup(_ error: Error) -> SyncActionResult {
        SyncActionResult(ok: false, message: SyncText.backupFailedText(error), backupFailed: true)
    }
}

/// 메뉴의 ‘이 날의 이전 버전…’ · ‘이 주의 이전 버전…’ — 설정 → 동기화가 그 날(주)로 이전 버전을 연다
struct SyncHistoryRequest: Equatable, Identifiable {
    let id = UUID()
    let book: UUID
    let kind: SyncController.HistoryKind
    let date: Date
}

// MARK: - 팔레트 · 플래너 위의 작은 표시 (동기화를 켰을 때만 — 꺼져 있으면 아무것도 그리지 않는다)

struct SyncGearInfo: Equatable {
    let tone: SyncTone
    /// 손볼 것이 있다 (설정 단추가 설정 → 동기화로 바로 연다)
    let attention: Bool
    /// "동기화: 동기화됨 · 3분 전"
    let spoken: String
}

/// 화면 곳곳(팔레트 · 플래너 창)이 보는 동기화 표시. 늘 있는 하나라서 동기화가 꺼진 실행 · 스냅샷에서도 그대로 쓸 수 있다
@MainActor
final class SyncIndicator: ObservableObject {
    static let shared = SyncIndicator()
    @Published var gear: SyncGearInfo?
    @Published var notice: SyncNotice?
}

// MARK: - 컨트롤러

@MainActor
final class SyncController: ObservableObject {
    /// 앱의 컨트롤러 (AppDelegate 가 만든다 — 설정 창 · 메뉴 · 팔레트가 쓴다)
    static var shared: SyncController?

    /// 엔진을 만드는 법 · 비밀을 두는 곳 (테스트 · QA 는 가짜 서버 · 메모리 · 따로 된 키체인 이름으로 바꾼다)
    struct Environment {
        /// 출시 앱(build.sh 의 .app — 번들 id com.spiralday.app)의 키체인 서비스 이름
        static let releaseKeychainService = "com.spiralday.sync"
        /// 번들 id 가 다른 실행(`swift run` · `.build/debug/Spiralday` 처럼 .app 이 아닌 실행)의 키체인 서비스 이름
        static let developmentKeychainService = "com.spiralday.sync.dev"
        static let releaseBundleID = "com.spiralday.app"

        /// 이 실행이 설치된 앱과 같은 동기화 자리(키체인 항목 · SyncState)를 써도 되는지.
        /// 그룹에 들어 있다는 표시(sync.groupURL)는 UserDefaults 에 있고, UserDefaults 는 번들 id 마다 따로다 →
        /// 번들 id 가 같은 실행만 같은 열쇠 · 상태를 써야 서로 어긋나지 않는다 (.app 이 아닌 실행이 설치된 앱의 열쇠를 지우거나
        /// SyncState 를 다른 그룹 것으로 덮지 않게). 디버그 빌드인지가 아니라 번들 id 로 가른다
        static func sharesReleaseIdentity(bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
            bundleID == releaseBundleID
        }

        /// 이 실행의 키체인 서비스 이름
        static var keychainService: String {
            sharesReleaseIdentity() ? releaseKeychainService : developmentKeychainService
        }

        /// 이 실행의 동기화 상태 폴더 이름 (데이터 폴더 안)
        static var stateFolderName: String {
            sharesReleaseIdentity() ? "SyncState" : "SyncState-dev"
        }

        var platform: SyncPlatform = .mac
        var suggestedName: String
        var credentials: any CredentialStore
        var defaults: UserDefaults
        var makeEngine: @MainActor (_ host: PlannerSyncHost, _ server: URL, _ credentials: any CredentialStore) throws -> SyncEngine
        /// 페어링 · 합류를 서버에 묻는 간격 (nil = 엔진 기본 2초 · 1.5초)
        var pollIntervalMs: Int?
        var backupRoot: URL
        var now: () -> Date = { Date() }
        /// 잠자기 · 깨어남 · 네트워크 · 앱 활성을 볼지 (테스트는 끈다)
        var watchesSystem = true
        /// 이 Mac 의 표시 (IOPlatformUUID 의 해시). 그룹 정보가 다른 Mac 에서 옮겨 왔는지 가른다. nil = 보지 않는다 (테스트 · QA)
        var machineTag: @MainActor () -> String? = { nil }
        /// 이 Mac 의 동기화 상태(SyncState)를 지운다 — 다른 Mac 에서 옮겨 온 상태를 버릴 때 (엔진이 없을 때만 부른다)
        var clearLocalState: @MainActor () -> Void = {}

        /// 앱의 구성: 로그인 키체인 · 앱 데이터 폴더 안의 SyncState · 운영 서버. 저장 폴더가 없는 저장소(메모리)면 nil.
        /// .app 이 아닌 실행(번들 id 가 다름)은 키체인 · 상태 폴더를 따로 쓴다 (sharesReleaseIdentity)
        @MainActor static func live(store: PlannerStore, keychainService: String = Environment.keychainService,
                                    stateFolder: String = Environment.stateFolderName,
                                    defaults: UserDefaults = .standard) -> Environment? {
            guard let folder = store.folder else { return nil }
            // Developer ID 앱(샌드박스 · keychain-access-groups 없음)은 데이터 보호 키체인을 열 수 없다 → 로그인 키체인.
            // 로그인 키체인은 ThisDeviceOnly 를 지키지 않는다 (이전 지원 · Time Machine 복원으로 새 Mac 에 옮겨 간다) →
            // machineTag 로 옮겨 온 것을 알아본다
            let credentials = KeychainCredentialStore(service: keychainService, useDataProtectionKeychain: false)
            let stateDir = folder.appendingPathComponent(stateFolder, isDirectory: true)
            return Environment(
                suggestedName: SyncController.defaultDeviceName(), credentials: credentials, defaults: defaults,
                makeEngine: { host, server, creds in
                    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
                    // 동기화 상태는 Time Machine 에 넣지 않는다 (복원한 Mac 이 옛 Mac 과 같은 기기로 붙지 않게 — 옮겨 와도 machineTag 가 가른다)
                    var url = stateDir
                    var v = URLResourceValues()
                    v.isExcludedFromBackup = true
                    try? url.setResourceValues(v)
                    return SyncEngine(SyncEngineOptions(host: host, transport: HTTPTransport(baseURL: server),
                                                        storage: FileSyncStorage(directory: stateDir), credentials: creds,
                                                        platform: .mac, log: SyncLog.os()))
                },
                backupRoot: folder.appendingPathComponent("SyncBackups", isDirectory: true),
                machineTag: { SyncMachine.tag() },
                clearLocalState: { try? FileManager.default.removeItem(at: stateDir) })
        }
    }

    /// 동기화를 쓸 수 없는 실행(데모 · 스냅샷)의 컨트롤러: 엔진을 만들지 않고 꺼짐으로만 보인다
    static func unavailable(store: PlannerStore, defaults: UserDefaults = .standard) -> SyncController {
        let env = Environment(
            suggestedName: "내 Mac", credentials: MemoryCredentialStore(), defaults: defaults,
            makeEngine: { _, _, _ in throw SyncEngineError(.notInitialized, "이 실행에서는 동기화를 쓸 수 없어요.") },
            backupRoot: FileManager.default.temporaryDirectory.appendingPathComponent("spiralday-sync-unavailable", isDirectory: true),
            watchesSystem: false)
        let c = SyncController(store: store, env: env)
        c.startUnavailable(state: nil)
        return c
    }

    // MARK: 화면이 보는 것

    /// 엔진을 아직 안 만들었으면 nil (꺼짐이거나 켜는 중)
    @Published private(set) var status: SyncViewStatus?
    /// 처음 읽기를 끝냈는지 (그 전에는 "준비하는 중")
    @Published private(set) var ready = false
    /// 동기화를 쓸 수 있는 실행인지 (데모 · 스냅샷 실행은 파일에 저장하지 않아 쓸 수 없다)
    @Published private(set) var available = true
    @Published private(set) var inGroup = false
    @Published var flow: SyncFlow?
    /// 흐름을 시작하기 전의 단계 (시작 · 합류 · 복구 코드 입력)
    @Published var localStep: SyncLocalStep?
    @Published private(set) var warnings: [SyncWarningItem] = []
    /// 기기 목록을 다시 받을 때
    @Published private(set) var devicesRev = 0
    /// 키체인 항목은 있는데 읽지 못한다
    @Published private(set) var credsUnreadable = false
    /// 엔진을 시작하지 못한 까닭 (그룹이 다른 서버에 있음 · 키체인 등)
    @Published private(set) var startProblem: String?
    /// 받은 편집으로 책장이 바뀐 횟수
    @Published private(set) var appliedRev = 0
    /// 지금 서버와 하는 일이 있는지 (create · join · restore 의 첫 서버 요청)
    @Published private(set) var starting = false
    /// 메뉴의 ‘이 날(주)의 이전 버전…’ (설정 → 동기화가 열면 비운다)
    @Published var historyRequest: SyncHistoryRequest?
    /// 그룹 정보(설정 · 키체인)가 다른 Mac 에서 옮겨 왔다 (이전 지원 · Time Machine 복원). 엔진을 띄우지 않고 이어 쓸지 · 정리할지 묻는다
    @Published private(set) var movedFromOtherMac = false

    let env: Environment
    let store: PlannerStore
    weak var state: AppState?
    var platform: SyncPlatform { env.platform }

    private var engine: SyncEngine?
    private var host: PlannerSyncHost?
    private var engineURL: URL?
    private var eventTask: Task<Void, Never>?
    private var listenerID: UUID?
    private var offer: PairingOffer?
    private var join: PendingJoin?
    private var flowSeq = 0
    private var timers: [Task<Void, Never>] = []
    private var statusWork: Task<Void, Never>?
    private var lastNudge = Date.distantPast
    private var lastResume = Date.distantPast
    private var watch: SyncSystemWatch?
    private var bag = Set<AnyCancellable>()
    /// 잠자는 중 (깨어나면 다시 켠다)
    private var asleep = false

    // MARK: 이 Mac 의 동기화 설정 (비밀 아님 — UserDefaults)

    enum Key {
        static let deviceName = "sync.deviceName"
        /// 그룹이 있는 서버. 이것이 있을 때만 켤 때 키체인을 읽는다 (= 이 설치가 동기화를 켰다)
        static let groupURL = "sync.groupURL"
        static let recoveryPending = "sync.recoveryPending"
        /// 그룹에 들어간 Mac 의 표시 (SyncMachine.tag — IOPlatformUUID 의 해시). 켤 때 이 Mac 과 다르면 옮겨 온 그룹 정보다
        static let machine = "sync.machine"
    }

    var deviceName: String {
        get { env.defaults.string(forKey: Key.deviceName) ?? "" }
        set { env.defaults.set(newValue, forKey: Key.deviceName); objectWillChange.send() }
    }

    var suggestedName: String { deviceName.isEmpty ? env.suggestedName : deviceName }

    /// 그룹이 있는 서버 (그룹은 빌드가 바뀌어도 옮겨 가지 않는다)
    private(set) var groupURL: String? {
        get { env.defaults.string(forKey: Key.groupURL) }
        set { env.defaults.set(newValue, forKey: Key.groupURL) }
    }

    /// 복구 코드를 보여 줬는데 적어 두었다고 확인하지 않았다
    var recoveryPending: Bool {
        get { env.defaults.bool(forKey: Key.recoveryPending) && inGroup }
        set { env.defaults.set(newValue, forKey: Key.recoveryPending); objectWillChange.send() }
    }

    var server: SyncServerChoice {
        SyncServer.choose(groupURL: inGroup ? groupURL : nil, defaults: env.defaults)
    }

    /// 이 Mac 의 내 플래너 이름 (예시 플래너 빼고)
    var localBooks: [String] { store.userBooks.map(\.name) }

    /// 엔진이 있는지 (테스트: 꺼져 있으면 만들지 않는다)
    var hasEngine: Bool { engine != nil }

    init(store: PlannerStore, env: Environment) {
        self.store = store
        self.env = env
        // 팔레트 · 메뉴의 표시를 상태에 맞춘다 (바뀐 뒤에 — objectWillChange 는 바뀌기 전에 온다)
        objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishIndicator() }
            .store(in: &bag)
    }

    /// 이 Mac 의 이름 (시스템 설정 → 일반 → 정보의 이름, 예: "서재 MacBook Air"). 없으면 "내 Mac".
    /// SystemConfiguration 에서 바로 읽는다 (Host.current() 처럼 이름을 찾으러 네트워크에 묻지 않는다)
    static func defaultDeviceName() -> String {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        let raw = SyncText.clampDeviceName(name)
        return raw.isEmpty ? "내 Mac" : raw
    }

    // MARK: - 수명

    /// 앱이 켜질 때 (저장소를 읽은 뒤). 이 설치가 그룹에 들어간 적이 있을 때만 키체인을 읽고 엔진을 만든다
    func start(state: AppState) async {
        self.state = state
        attachStore()
        guard groupURL != nil else {
            // 동기화를 켠 적이 없다: 키체인도 네트워크도 건드리지 않는다
            ready = true
            return
        }
        if let here = env.machineTag() {
            if let tag = env.defaults.string(forKey: Key.machine), tag != here {
                // 다른 Mac 의 그룹 정보 (같은 기기 id · 토큰으로 두 Mac 이 한 기기처럼 붙지 않게): 키체인을 읽기 전에 멈추고 묻는다
                movedFromOtherMac = true
                ready = true
                return
            }
            env.defaults.set(here, forKey: Key.machine)
        }
        await readCredentialsAndBoot()
        ready = true
    }

    /// 그룹에 들어간 이 Mac 을 적어 둔다 (만들기 · 합류 · 되살리기 · 옮겨 온 정보를 이어 쓰기)
    private func rememberMachine() {
        if let here = env.machineTag() { env.defaults.set(here, forKey: Key.machine) }
    }

    /// 옮겨 온 그룹 정보: [이 Mac 에서 이어 쓰기] — 원래 Mac 을 더 쓰지 않는다 (이 Mac 이 그 기기를 이어받는다)
    func keepMovedGroup() async {
        guard movedFromOtherMac else { return }
        movedFromOtherMac = false
        rememberMachine()
        await readCredentialsAndBoot()
    }

    /// 옮겨 온 그룹 정보: [정리하기] — 이 Mac 의 열쇠 · 동기화 상태만 지운다. 서버에는 묻지 않는다
    /// (그 기기 id 는 원래 Mac 의 것이다 — 그룹에서 빼면 원래 Mac 이 빠진다). 플래너는 그대로
    func forgetMovedGroup() async -> SyncActionResult {
        guard movedFromOtherMac, engine == nil else { return .failed("") }
        do {
            try await env.credentials.set(nil)
        } catch {
            return .failed(SyncText.errorText(error))
        }
        env.clearLocalState()
        movedFromOtherMac = false
        afterLeaving()
        return .done
    }

    private func readCredentialsAndBoot() async {
        var creds: Credentials?
        do {
            creds = try await env.credentials.get()
        } catch is CredentialsUnreadable {
            credsUnreadable = true
            return
        } catch {
            // 키체인을 열지 못했다 (접근을 거절함 등): 그룹 주소는 두고 알린다 — [다시 해 보기] · 다음에 켤 때 다시
            startProblem = SyncText.errorText(error, .launch)
            return
        }
        guard creds != nil else {
            // 그룹 주소는 남았는데 열쇠가 없다 (키체인 항목을 지움): 꺼짐으로
            groupURL = nil
            env.defaults.removeObject(forKey: Key.recoveryPending)
            env.defaults.removeObject(forKey: Key.machine)
            return
        }
        inGroup = true
        await bootEngine()
    }

    /// 데모 · 스냅샷 실행: 엔진을 만들지 않고 꺼짐으로만 보인다
    func startUnavailable(state: AppState?) {
        self.state = state
        available = false
        ready = true
    }

    private func attachStore() {
        store.onSaved = { [weak self] bookID, library in self?.saved(bookID: bookID, library: library) }
        store.onDeleted = { [weak self] id in self?.deleted(id) }
    }

    /// 그룹에 들어 있는 엔진을 띄운다 (그룹의 서버가 이 빌드와 다르면 띄우지 않고 알린다)
    private func bootEngine() async {
        let s = server
        if let g = groupURL, s.source != .group {
            startProblem = "이 Mac 의 동기화 그룹은 다른 서버(\(g))에 있어요."
            return
        }
        do {
            _ = try await ensureEngine()
            startProblem = nil
        } catch is CredentialsUnreadable {
            credsUnreadable = true
            inGroup = false
        } catch {
            startProblem = SyncText.errorText(error, .launch)
        }
    }

    /// [다시 해 보기] (시작하지 못했을 때)
    func retryStart() async {
        guard ready, available, !movedFromOtherMac else { return }
        startProblem = nil
        if inGroup {
            await bootEngine()
        } else if groupURL != nil {
            await readCredentialsAndBoot()
        }
    }

    private func ensureEngine() async throws -> SyncEngine {
        let want = server.url
        if let engine, inGroup || engineURL == want { return engine }
        if let old = engine {
            // 꺼진 동안 서버를 바꿨다 (개발자 설정): 새 서버로 새 엔진
            await detach(old)
        }
        let host = PlannerSyncHost(store: store)
        host.editingKey = { [weak self] in self?.state?.editingKey }
        host.onEditedItemRemoved = { [weak self] in self?.state?.endEditing() }
        host.onEditedFieldReplaced = { [weak self] text in self?.editedFieldReplaced(with: text) }
        host.onLibraryApplied = { [weak self] r, removed in self?.libraryApplied(r, removed: removed) }
        host.onActiveApplied = { [weak self] _ in self?.activeApplied() }
        host.onSettingsTextReplaced = { [weak self] values in self?.settingsTextReplaced(values) }
        let e = try env.makeEngine(host, want, env.credentials)
        let (stream, cont) = AsyncStream<SyncEvent>.makeStream()
        listenerID = await e.addListener { cont.yield($0) }
        eventTask = Task { [weak self] in
            for await ev in stream { self?.onEvent(ev) }
        }
        do {
            try await e.initialize()
        } catch {
            if let id = listenerID { await e.removeListener(id) }
            listenerID = nil
            cont.finish()
            eventTask?.cancel()
            eventTask = nil
            await e.dispose()
            throw error
        }
        self.host = host
        engine = e
        engineURL = want
        inGroup = await e.inGroup
        status = SyncViewStatus(await e.status)
        if inGroup { startWatching() }
        return e
    }

    private func detach(_ e: SyncEngine) async {
        stopWatching()
        if let id = listenerID { await e.removeListener(id) }
        listenerID = nil
        eventTask?.cancel()
        eventTask = nil
        await e.dispose()
        engine = nil
        host = nil
        engineURL = nil
    }

    // MARK: 앱 수명 (잠자기 · 깨어남 · 네트워크 · 앱이 앞으로 · 끝내기)

    private func startWatching() {
        guard env.watchesSystem, watch == nil else { return }
        watch = SyncSystemWatch(
            sleep: { [weak self] in self?.willSleep() },
            wake: { [weak self] in self?.didWake() },
            networkBack: { [weak self] in self?.networkChanged() },
            active: { [weak self] in self?.appBecameActive() })
    }

    private func stopWatching() {
        watch?.stop()
        watch = nil
    }

    /// 잠자기 직전: 남은 편집을 저장하고 올린 뒤 연결을 닫는다 (오프라인이면 기다리지 않는다)
    func willSleep() {
        guard let engine, inGroup else { return }
        asleep = true
        store.saveNow()
        Task {
            await engine.suspend()
            // 올리는 동안 깨어났다: 엔진은 그 resume 을 보고 멈추지 않는다. resume 이 suspend 보다 먼저 닿았으면
            // suspend 가 멈췄으니 다시 켠다 (깨어 있는데 엔진이 멈춘 채 '동기화됨' 으로 남지 않게)
            if !self.asleep, self.engine === engine { await engine.resume() }
        }
    }

    /// 깨어났다: 다시 붙고 받기 · 비교 · 보내기
    func didWake() {
        asleep = false
        resumeNow()
    }

    /// 네트워크가 돌아왔거나 바뀌었다 (와이파이 ↔ 유선 등)
    func networkChanged() {
        guard !asleep else { return }
        resumeNow(throttle: 5)
    }

    /// 앱이 앞으로 왔다 (Mac 앱은 뒤에서도 돈다 — 여러 번 오가도 15초에 한 번까지만)
    func appBecameActive() {
        guard !asleep else { return }
        resumeNow(throttle: 15)
    }

    private func resumeNow(throttle: TimeInterval = 0) {
        guard ready, available, !qaMode else { return }
        if let engine, inGroup {
            let now = env.now()
            guard now.timeIntervalSince(lastResume) >= throttle else { return }
            lastResume = now
            Task { await engine.resume() }
            return
        }
        // 엔진을 띄우지 못했던 그룹 (오프라인으로 켜기 실패 등): 다시 (20초에 한 번까지)
        let now = env.now()
        guard inGroup, startProblem != nil, now.timeIntervalSince(lastNudge) > 20 else { return }
        lastNudge = now
        Task { await bootEngine() }
    }

    /// 앱을 끝내기 전: 저장하고 남은 편집을 올린다 (최대 timeout 초 — 못 올린 것은 다음에 켤 때 올린다). 끝나면 done
    func prepareToQuit(timeout: TimeInterval = 2.5, done: @escaping @MainActor () -> Void) {
        guard let engine, inGroup, !qaMode else { done(); return }
        store.saveNow()
        var finished = false
        let finish = { @MainActor in
            guard !finished else { return }
            finished = true
            done()
        }
        Task {
            await engine.suspend()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
    }

    func dispose() async {
        for t in timers { t.cancel() }
        timers = []
        if let engine { await detach(engine) }
    }

    // MARK: - 저장소 알림

    private func saved(bookID: UUID?, library: Bool) {
        guard let engine, inGroup else { return }
        if let bookID { engine.localChanged(bookId: bookID.uuidString) }
        if library { engine.localChanged(library: true) }
        // 엔진은 상태가 바뀔 때만 알린다: "기다리는 기록 N개" 는 비교(0.4초) · 보내기(1.5초) 뒤에 다시 읽는다
        if status?.state != .idle { refreshStatus(after: 2.5) }
    }

    private func deleted(_ id: UUID) {
        guard let engine, inGroup else { return }
        engine.localChanged(deletedBooks: [id.uuidString])
    }

    // MARK: - 엔진 이벤트

    private func onEvent(_ ev: SyncEvent) {
        switch ev {
        case .status(let s):
            status = SyncViewStatus(s)
            if s.state == .removed || s.state == .groupGone { endFlowNow() }
        case .devices:
            devicesRev += 1
        case .warning(let w, _, let bookId):
            let name = bookId.flatMap(UUID.init(uuidString:)).flatMap { id in store.books.first { $0.id == id }?.name }
            warnings.removeAll { $0.warning == w }
            warnings.insert(SyncWarningItem(id: "\(w.rawValue)-\(env.now().timeIntervalSince1970)", warning: w, bookName: name, at: env.now()), at: 0)
            if warnings.count > 6 { warnings.removeLast(warnings.count - 6) }
        case .pairing(let id, let st):
            // 새 기기가 요청을 거뒀다 (이 Mac 의 [아니에요] · 그만두기는 offer 를 먼저 비운다)
            if st == "denied", let offer, offer.pairingId == id, case .pair(let mode, let stage)? = flow {
                switch stage {
                case .request, .waiting:
                    flowSeq += 1
                    self.offer = nil
                    flow = .pair(mode: mode, stage: .withdrawn)
                default: break
                }
            }
        case .applied(let books, let library):
            appliedRev += 1
            if library || !books.isEmpty { refreshStatus(after: 0.3) }
        }
    }

    private func libraryApplied(_ r: ExternalApplyResult, removed: [BookInfo]) {
        if r.closedBook != nil {
            // 쓰던 칸은 지운 책의 것이다: 편집을 끝낸다 (남은 키가 새로 편 책의 같은 칸을 가리키지 않게)
            state?.endEditing()
            showNotice(SyncText.closedBookNotice)
        } else if let text = SyncText.removedBooksNotice(removed.filter { !$0.isSample }.map(\.name)) {
            showNotice(text)
        }
        keepPageInRange()
    }

    private func activeApplied() {
        keepPageInRange()
    }

    /// 다른 기기에서 펼친 책의 기간을 줄였으면 지금 장이 범위 밖일 수 있다 → 오늘(가장 가까운 장)로
    private func keepPageInRange() {
        DispatchQueue.main.async { [weak self] in
            guard let state = self?.state, state.kind.flips, !state.canStep(0) else { return }
            state.goToday()
        }
    }

    /// 쓰던 칸(포커스만 있던 칸)의 글이 다른 기기의 글로 바뀌었다: 그 칸의 되돌리기(⌘Z) 기록을 비운다.
    /// 앱의 되돌리기는 글 칸의 것뿐이라 비워도 다른 것을 잃지 않는다 — 남겨 두면 ⌘Z 가 다른 기기의 글을 지우고 이 Mac 의 옛 글로 돌아간다.
    /// ⌘Z(undo:)는 응답자 사슬로 가서 필드 편집기가 보는 기록을 되돌린다 (SwiftUI 글 칸은 창의 undoManager 가 아니라 호스팅 뷰의 기록).
    /// SwiftUI 는 다음 화면 갱신에서 새 글을 필드 편집기에 넣고, 그 넣기도 되돌리기 기록에 남는다 → 새 글이 칸에 들어간 뒤에 한 번 더 비운다.
    /// 메인 스레드가 바쁘면(넘김 애니메이션 등) 늦게 들어올 수 있어 글이 같아질 때까지 기다린다 (최대 3초 — 그 사이 사용자가 더 쳤으면
    /// 3초 뒤에 비운다). 포커스가 다른 칸으로 옮겨 가면 그만 기다린다
    func editedFieldReplaced(with text: String? = nil) {
        clearFocusedFieldUndo()
        fieldUndoWork?.cancel()
        let editor = focusedFieldEditor()
        fieldUndoWork = Task { @MainActor [weak self] in
            // 새 글을 모르면 예전처럼 0.5초만 기다린다
            for _ in 0..<(text == nil ? 20 : 120) {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = self.focusedFieldEditor()
                if now == nil || now !== editor { break }
                if let text, now?.string == text { break }
            }
            guard !Task.isCancelled else { return }
            self?.clearFocusedFieldUndo()
        }
    }

    private var fieldUndoWork: Task<Void, Never>?

    private var settingsUndoWork: Task<Void, Never>?

    /// 설정 창에서 쓰는 글(형광펜 이름 · 저장한 D-day 제목)이 다른 기기의 값으로 바뀌었다: 설정 창의 포커스 칸에 그 새 값이
    /// 들어오면(SwiftUI 가 다음 갱신에서 넣는다) 그 칸의 ⌘Z 기록을 비운다 — 되돌리기가 다른 기기의 값을 옛 값으로 되돌려 퍼뜨리지 않게.
    /// 다른 칸의 값만 바뀌었으면 그대로 둔다 (설정 창의 칸은 쓰는 칸 지키기 밖이라 같은 칸을 두 기기에서 동시에 고치면 나중 값이 이긴다)
    func settingsTextReplaced(_ values: Set<String>) {
        guard let w = SettingsWindowController.shared.window, w.isVisible,
              let editor = w.firstResponder as? NSTextView, !values.isEmpty else { return }
        settingsUndoWork?.cancel()
        settingsUndoWork = Task { @MainActor in
            for _ in 0..<120 {
                guard !Task.isCancelled, w.firstResponder === editor else { return }
                if values.contains(editor.string) {
                    editor.undoManager?.removeAllActions()
                    w.undoManager?.removeAllActions()
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    /// 글 칸에 포커스가 있는 창들의 되돌리기 기록 (필드 편집기의 것 · 창의 것)을 비운다
    private func clearFocusedFieldUndo() {
        for w in NSApplication.shared.windows where !(w is NSPanel) {
            guard let editor = w.firstResponder as? NSTextView else { continue }
            editor.undoManager?.removeAllActions()
            w.undoManager?.removeAllActions()
        }
    }

    /// 포커스가 있는 글 칸의 필드 편집기 (팔레트 · 패널 빼고)
    private func focusedFieldEditor() -> NSTextView? {
        NSApplication.shared.windows.lazy.filter { !($0 is NSPanel) }.compactMap { $0.firstResponder as? NSTextView }.first
    }

    func showNotice(_ text: String) {
        SyncIndicator.shared.notice = SyncNotice(text: text)
        NSAccessibility.post(element: NSApplication.shared as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// 엔진의 지금 상태를 다시 읽는다 (화면이 열려 있을 때 · 저장 뒤)
    func refreshStatus(after seconds: Double = 0) {
        statusWork?.cancel()
        statusWork = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let engine = self.engine else { return }
            let s = SyncViewStatus(await engine.status)
            if s != self.status { self.status = s }
        }
    }

    // MARK: 팔레트 · 메뉴의 표시

    /// 설정 단추 귀퉁이 표시 (동기화가 켜져 있을 때만)
    func gearInfo(now: Date = Date()) -> SyncGearInfo? {
        guard ready, available else { return nil }
        if movedFromOtherMac {
            return SyncGearInfo(tone: .warn, attention: true, spoken: "동기화: 다른 Mac 에서 옮겨 온 동기화 정보를 확인해 주세요")
        }
        guard inGroup else { return nil }
        guard let s = status else {
            guard let p = startProblem else { return nil }
            return SyncGearInfo(tone: .warn, attention: true, spoken: "동기화: \(p)")
        }
        let line = SyncText.statusLine(state: s.state, pending: s.pending, lastSyncAt: s.lastSyncAt, error: s.error, live: s.live, now: now)
        let pending = recoveryPending
        let tone: SyncTone = pending && line.tone == .ok ? .warn : line.tone
        var spoken = "동기화: \(SyncText.statusShort(state: s.state, pending: s.pending, lastSyncAt: s.lastSyncAt, now: now))"
        if pending { spoken += " · 복구 코드를 확인해 주세요" }
        return SyncGearInfo(tone: tone, attention: line.tone == .error || line.tone == .warn || pending, spoken: spoken)
    }

    private func publishIndicator() {
        guard Self.shared === self || qaMode else { return }
        let g = gearInfo()
        if SyncIndicator.shared.gear != g { SyncIndicator.shared.gear = g }
    }

    // MARK: - 하는 일 (설정 → 동기화)

    private func inGroupEngine() throws -> SyncEngine {
        guard let engine, inGroup else { throw SyncEngineError(.notInGroup, "동기화가 꺼져 있어요.") }
        return engine
    }

    private var busyFlow: Bool {
        guard let flow else { return false }
        switch flow {
        case .pair(_, let st):
            switch st {
            case .denied, .withdrawn, .expired, .error, .approved: return false
            default: return true
            }
        case .join(let st, _):
            switch st {
            case .denied, .expired, .error, .done: return false
            default: return true
            }
        case .recovery(_, .working): return true
        default: return false
        }
    }

    private func run(_ ctx: SyncFlowContext = .general, _ body: () async throws -> Void) async -> SyncActionResult {
        do {
            try await body()
            return .done
        } catch {
            return .failed(SyncText.errorText(error, ctx), (error as? SyncEngineError)?.code)
        }
    }

    /// 새로 켜기 전: 이 설치가 쓴 흔적이 없는데 키체인에 남은 예전 자격은 지운다 (예전 설치 · 지운 설정의 것 —
    /// 조용히 예전 그룹에 다시 붙지 않게). 서버에는 아무것도 보내지 않는다
    private func forgetStaleCredentials() async {
        guard !inGroup, engine == nil, groupURL == nil else { return }
        try? await env.credentials.set(nil)
    }

    // MARK: 첫 기기

    /// 이 Mac 에서 시작하기: 그룹을 만들고 이 Mac 의 플래너를 올린 뒤 복구 코드 단계로
    func create(deviceName raw: String) async -> SyncActionResult {
        guard available else { return .failed("이 실행에서는 동기화를 쓸 수 없어요.") }
        guard !starting, !busyFlow else { return .failed("지금 하던 일을 먼저 끝내 주세요.") }
        let name = SyncText.clampDeviceName(raw).isEmpty ? env.suggestedName : SyncText.clampDeviceName(raw)
        starting = true
        defer { starting = false }
        let r = await run {
            await forgetStaleCredentials()
            let e = try await ensureEngine()
            store.saveNow()
            try await e.createGroup(deviceName: name)
        }
        guard r.ok else { return r }
        deviceName = name
        groupURL = engineURL?.absoluteString
        rememberMachine()
        recoveryPending = true
        inGroup = true
        credsUnreadable = false
        localStep = nil
        startWatching()
        refreshStatus()
        return await makeRecovery(.create)
    }

    /// 복구 코드를 만든다 (그룹을 만든 뒤 · 새로 만들기). 적어 두었다고 확인할 때까지 보여 준다
    @discardableResult
    func makeRecovery(_ reason: SyncFlow.RecoveryReason) async -> SyncActionResult {
        guard let e = try? inGroupEngine() else { return .failed(SyncText.errorText(code: .notInGroup, fallback: nil)) }
        flowSeq += 1
        let seq = flowSeq
        flow = .recovery(reason: reason, stage: .working)
        do {
            let code = try await e.setupRecovery()
            recoveryPending = true
            if seq == flowSeq { flow = .recovery(reason: reason, stage: .show(code: code)) }
            return .done
        } catch {
            let msg = SyncText.errorText(error)
            if seq == flowSeq { flow = .recovery(reason: reason, stage: .failed(msg)) }
            return .failed(msg)
        }
    }

    func recoveryRetry() async {
        if case .recovery(let reason, _)? = flow { await makeRecovery(reason) } else { await makeRecovery(.rotate) }
    }

    /// "확인했어요" — 적어 둔 코드의 두 묶음을 맞게 입력했다
    func recoveryConfirmed() {
        recoveryPending = false
        if case .recovery? = flow { flow = nil }
    }

    // MARK: 기기 추가 (이 Mac 이 그룹에 있을 때)

    static let pairTTL: TimeInterval = 600

    func pairStart(_ mode: PairingMode) async {
        guard let e = try? inGroupEngine() else { return }
        // QR ↔ 코드 바꾸기 · 다시 만들기: 예전 것을 거둔다
        let old = offer
        offer = nil
        for t in timers { t.cancel() }
        timers = []
        flowSeq += 1
        let seq = flowSeq
        flow = .pair(mode: mode, stage: .opening)
        if let old { try? await old.cancel() }
        let offer: PairingOffer
        do {
            offer = try await e.startPairing(mode: mode, ttlSec: Int(Self.pairTTL))
        } catch {
            if seq == flowSeq { flow = .pair(mode: mode, stage: .error(SyncText.errorText(error, .pair))) }
            return
        }
        guard seq == flowSeq else {
            try? await offer.cancel()
            return
        }
        self.offer = offer
        // 서버 시계와 이 Mac 시계의 차이 (요청 기한을 이 Mac 시계로)
        let local = env.now().addingTimeInterval(Self.pairTTL)
        let skew = Double(offer.expiresAt) / 1000 - local.timeIntervalSince1970
        flow = .pair(mode: mode, stage: .waiting(qrText: offer.qrText, code: offer.code, deadline: local))
        let interval = env.pollIntervalMs
        let task = Task { [weak self] in
            let req: JoinRequest?
            do {
                if let interval { req = try await offer.wait(intervalMs: interval) } else { req = try await offer.wait() }
            } catch {
                guard let self, seq == self.flowSeq else { return }
                self.flow = .pair(mode: mode, stage: .error(SyncText.errorText(error, .pair)))
                return
            }
            guard let self, seq == self.flowSeq, case .pair? = self.flow else { return }
            guard let req else {
                self.offer = nil
                self.flow = .pair(mode: mode, stage: .expired(wasRequest: false))
                return
            }
            let deadline = max(self.env.now().addingTimeInterval(30), Date(timeIntervalSince1970: Double(req.expiresAt) / 1000 - skew))
            self.flow = .pair(mode: mode, stage: .request(SyncRequestInfo(platform: req.platform, deadline: deadline, triesLeft: offer.triesLeft)))
            self.requestAttention("새 기기(\(SyncText.platformLabel(req.platform)))가 연결을 요청했어요")
            self.later(deadline.timeIntervalSince(self.env.now()) + 1.5) { [weak self] in
                guard let self, seq == self.flowSeq, case .pair(_, .request)? = self.flow else { return }
                let o = self.offer
                self.offer = nil
                self.flow = .pair(mode: mode, stage: .expired(wasRequest: true))
                Task { try? await o?.cancel() }
            }
        }
        timers.append(task)
    }

    /// 새 기기가 요청했다 · 다른 기기가 승인했다: 다른 앱을 쓰는 중이면 Dock 아이콘으로 알리고 VoiceOver 로 읽는다
    private func requestAttention(_ text: String) {
        guard !qaMode else { return }
        NSAccessibility.post(element: NSApplication.shared as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if !NSApplication.shared.isActive { NSApplication.shared.requestUserAttention(.informationalRequest) }
    }

    /// [연결]: 새 기기 화면의 숫자 4자리를 입력했다
    func pairApprove(digits: String) async -> SyncActionResult {
        guard case .pair(let mode, .request(let info))? = flow, let offer else { return .failed("승인할 요청이 없어요.") }
        let seq = flowSeq
        flow = .pair(mode: mode, stage: .approving(info))
        do {
            try await offer.approve(enteredDigits: digits)
        } catch {
            let code = (error as? SyncEngineError)?.code
            let msg = SyncText.errorText(error, .pair)
            guard seq == flowSeq else { return .failed(msg, code) }
            if code == .digitsMismatch {
                // 서버에는 아무것도 가지 않았다: 같은 요청, 한 번 덜
                var next = info
                next.triesLeft = offer.triesLeft
                next.wrong = true
                flow = .pair(mode: mode, stage: .request(next))
                return .failed(msg, code)
            }
            self.offer = nil
            switch code {
            case .pairingExpired: flow = .pair(mode: mode, stage: .expired(wasRequest: true))
            case .pairingDenied: flow = .pair(mode: mode, stage: .denied)
            default: flow = .pair(mode: mode, stage: .error(msg))
            }
            return .failed(msg, code)
        }
        if seq == flowSeq {
            self.offer = nil
            flow = .pair(mode: mode, stage: .approved(platform: info.platform))
        }
        devicesRev += 1
        return .done
    }

    /// [아니에요]
    func pairDeny() async {
        let o = offer
        offer = nil
        guard case .pair(let mode, _)? = flow else { return }
        flowSeq += 1
        flow = .pair(mode: mode, stage: .denied)
        try? await o?.deny()
    }

    // MARK: 다른 기기에 합류하기 (이 Mac 이 들어간다)

    /// 8자 코드나 QR 의 연결 글로 합류를 요청한다 → 확인 숫자를 보여 주고 승인을 기다린다
    func joinStart(_ input: String, deviceName raw: String) async -> SyncActionResult {
        guard available else { return .failed("이 실행에서는 동기화를 쓸 수 없어요.") }
        guard !starting, !busyFlow else { return .failed("지금 하던 일을 먼저 끝내 주세요.") }
        let name = SyncText.clampDeviceName(raw).isEmpty ? env.suggestedName : SyncText.clampDeviceName(raw)
        flowSeq += 1
        let seq = flowSeq
        let books = localBooks
        starting = true
        var pending: PendingJoin?
        let r = await run(.join) {
            await forgetStaleCredentials()
            let e = try await ensureEngine()
            pending = try await e.joinGroup(input, deviceName: name)
        }
        starting = false
        guard r.ok, let join = pending else { return r }
        guard seq == flowSeq else {
            // 그 사이 화면을 닫았다: 아무도 숫자를 보지 않는다
            Task { try? await join.reject() }
            return .failed("")
        }
        self.join = join
        deviceName = name
        localStep = nil
        // 승인 기한은 서버 시계: 화면에는 알맞은 범위로
        let now = env.now()
        let exp = Date(timeIntervalSince1970: Double(join.expiresAt) / 1000)
        let deadline = min(now.addingTimeInterval(15 * 60), max(now.addingTimeInterval(60), exp))
        flow = .join(stage: .waiting(digits: join.confirmDigits, deadline: deadline), localBooks: books)
        let interval = env.pollIntervalMs
        let task = Task { [weak self] in
            do {
                let o: JoinOutcome
                if let interval { o = try await join.waitForApproval(intervalMs: interval) } else { o = try await join.waitForApproval() }
                guard let self, seq == self.flowSeq else { return }
                switch o {
                case .approved(let devices, let acceptBy):
                    let names = devices.map { SyncGroupDeviceName(name: $0.name, platform: $0.platform) }
                    self.flow = .join(stage: .approved(devices: names, deadline: Date(timeIntervalSince1970: Double(acceptBy) / 1000)), localBooks: books)
                    self.requestAttention("다른 기기에서 승인했어요")
                case .denied:
                    self.join = nil
                    self.flow = .join(stage: .denied, localBooks: books)
                case .expired:
                    self.join = nil
                    self.flow = .join(stage: .expired(afterApproval: false), localBooks: books)
                case .cancelled:
                    break
                }
            } catch {
                guard let self, seq == self.flowSeq else { return }
                self.join = nil
                self.flow = .join(stage: .error(SyncText.errorText(error, .join)), localBooks: books)
            }
        }
        timers.append(task)
        return .done
    }

    /// [합치고 시작하기]: 합치기 직전에 이 Mac 의 플래너를 백업하고 그룹에 들어간다.
    /// 백업을 만들지 못하면 (저장 공간 · 쓰기 오류) 들어가지 않고 backupFailed 로 돌아온다 — 화면이 물은 뒤 withoutBackup 으로 다시
    func joinAccept(withoutBackup: Bool = false) async -> SyncActionResult {
        guard case .join(.approved(let devices, let deadline), let books)? = flow, let join else {
            return .failed("연결이 아직 승인되지 않았어요.")
        }
        if env.now() > deadline {
            flow = .join(stage: .expired(afterApproval: true), localBooks: books)
            Task { try? await join.reject() }
            self.join = nil
            return .failed("시간이 지났어요.")
        }
        let seq = flowSeq
        store.saveNow()
        // 겹치는 칸은 그룹 쪽이 이긴다: 합치기 직전의 이 Mac 플래너를 남겨 둔다 ("저절로 백업해 둬요" 약속)
        var backup: SyncBackupSnapshot?
        if !withoutBackup {
            do {
                backup = try SyncBackups.snapshot(store, root: env.backupRoot, now: env.now())
            } catch {
                return .noBackup(error)
            }
        }
        flow = .join(stage: .accepting(devices: devices, deadline: deadline), localBooks: books)
        do {
            try await join.accept()
        } catch {
            self.join = nil
            let msg = SyncText.errorText(error, .join)
            if seq == flowSeq { flow = .join(stage: .error(msg), localBooks: books) }
            return .failed(msg, (error as? SyncEngineError)?.code)
        }
        self.join = nil
        groupURL = engineURL?.absoluteString
        rememberMachine()
        recoveryPending = false
        inGroup = true
        credsUnreadable = false
        startWatching()
        refreshStatus()
        if seq == flowSeq { flow = .join(stage: .done(backup: backup), localBooks: books) }
        return .done
    }

    // MARK: 복구 코드로 되살리기

    /// 복구 코드로 되살리기. 합류와 같이 합치기 직전에 백업하고, 백업을 만들지 못하면 되살리지 않고 backupFailed 로 돌아온다
    func restore(code: String, deviceName raw: String, withoutBackup: Bool = false) async -> SyncActionResult {
        guard available else { return .failed("이 실행에서는 동기화를 쓸 수 없어요.") }
        guard !starting, !busyFlow else { return .failed("지금 하던 일을 먼저 끝내 주세요.") }
        let name = SyncText.clampDeviceName(raw).isEmpty ? env.suggestedName : SyncText.clampDeviceName(raw)
        flowSeq += 1
        let seq = flowSeq
        starting = true
        defer { starting = false }
        var evicted: String?
        var backup: SyncBackupSnapshot?
        var backupError: Error?
        let r = await run(.restore) {
            await forgetStaleCredentials()
            let e = try await ensureEngine()
            store.saveNow()
            if !withoutBackup {
                do {
                    backup = try SyncBackups.snapshot(store, root: env.backupRoot, now: env.now())
                } catch {
                    backupError = error
                    return
                }
            }
            evicted = try await e.restoreFromRecovery(code: code, deviceName: name).evicted
        }
        if let backupError { return .noBackup(backupError) }
        guard r.ok else { return r }
        deviceName = name
        groupURL = engineURL?.absoluteString
        rememberMachine()
        recoveryPending = false
        inGroup = true
        credsUnreadable = false
        localStep = nil
        startWatching()
        refreshStatus()
        if seq == flowSeq { flow = .restore(evicted: evicted != nil, backup: backup) }
        return .done
    }

    // MARK: 그룹에 들어 있을 때

    func syncNow() async {
        guard let e = try? inGroupEngine() else { return }
        store.saveNow()
        try? await e.syncNow()
        status = SyncViewStatus(await e.status)
    }

    func listDevices() async throws -> (devices: [SyncDeviceRow], maxDevices: Int) {
        if qaMode { return (qaDevices, 10) }
        let r = try await inGroupEngine().listDevices()
        return (r.devices.map(SyncDeviceRow.init), r.maxDevices)
    }

    func renameDevice(_ raw: String) async -> SyncActionResult {
        let name = SyncText.clampDeviceName(raw)
        guard !name.isEmpty else { return .failed("이름을 적어 주세요.") }
        let r = await run { try await inGroupEngine().renameThisDevice(name) }
        if r.ok {
            deviceName = name
            devicesRev += 1
        }
        return r
    }

    func removeDevice(_ id: String) async -> SyncActionResult {
        let r = await run { try await inGroupEngine().removeDevice(id) }
        devicesRev += 1
        return r
    }

    /// 이 Mac 만 그룹에서 나온다 (플래너는 그대로)
    func leave() async -> SyncActionResult {
        let r = await run {
            let e = try inGroupEngine()
            await endFlow()
            try await e.leaveGroup()
        }
        if r.ok { afterLeaving() }
        return r
    }

    /// 그룹 지우기 (모든 기기의 동기화가 끊긴다. 플래너는 각 기기에 그대로)
    func wipe() async -> SyncActionResult {
        let r = await run {
            let e = try inGroupEngine()
            await endFlow()
            try await e.wipeGroup()
        }
        if r.ok { afterLeaving() }
        return r
    }

    /// 빠짐 · 그룹 없음 · 열쇠를 읽지 못함 · 시작하지 못함: 이 Mac 의 동기화 정보만 정리한다 (플래너는 지우지 않는다).
    /// 빠짐 · 그룹 없음은 서버에 한 번 더 물어본다 — 서버 사고로 모든 기기가 그룹을 잊지 않게
    func forget() async -> SyncActionResult {
        if let e = engine, inGroup, status?.state == .removed || status?.state == .groupGone {
            switch await e.recheck() {
            case .ok:
                status = SyncViewStatus(await e.status)
                return SyncActionResult(ok: true, message: "서버에 다시 확인해 보니 이 Mac 은 그룹에 그대로 있어요. 다시 맞추기 시작했어요.")
            case .unknown:
                return .failed("서버에 확인하지 못했어요. 인터넷 연결을 확인하고 다시 눌러 주세요.", .offline)
            case .removed, .groupGone:
                break
            }
        }
        let r = await run {
            if let e = engine {
                try await e.forgetGroup()
            } else {
                try await env.credentials.set(nil)
            }
        }
        if r.ok {
            credsUnreadable = false
            afterLeaving()
        }
        return r
    }

    private func afterLeaving() {
        groupURL = nil
        env.defaults.removeObject(forKey: Key.recoveryPending)
        env.defaults.removeObject(forKey: Key.machine)
        inGroup = false
        warnings = []
        startProblem = nil
        flow = nil
        localStep = nil
        stopWatching()
        if let engine { Task { status = SyncViewStatus(await engine.status) } } else { status = nil }
    }

    func dismissWarning(_ id: String) {
        warnings.removeAll { $0.id == id }
    }

    /// 경고 '앱을 업데이트해 주세요' 의 [업데이트 확인] (AppDelegate 가 Sparkle 을 켰을 때만)
    var onCheckForUpdates: (@MainActor () -> Void)?
    var canCheckForUpdates: Bool { onCheckForUpdates != nil }
    func checkForUpdates() { onCheckForUpdates?() }

    // MARK: 이전 버전

    enum HistoryKind: Equatable { case day, week }

    private func recordKey(book: UUID, kind: HistoryKind, date: Date) -> String {
        kind == .week ? RecordKeys.week(book.uuidString, Dates.key(Dates.weekStart(date)))
            : RecordKeys.day(book.uuidString, Dates.key(date))
    }

    func history(book: UUID, kind: HistoryKind, date: Date) async throws -> [SyncText.VersionRow] {
        if qaMode { return qaHistory }
        let entries = try await inGroupEngine().history(recordKey(book: book, kind: kind, date: date))
        return SyncText.versionRows(week: kind == .week, entries.map { ($0.seq, $0.at, $0.current, $0.value) })
    }

    func restoreVersion(book: UUID, kind: HistoryKind, date: Date, seq: Int) async -> SyncActionResult {
        store.saveNow()
        return await run { try await inGroupEngine().restoreVersion(recordKey(book: book, kind: kind, date: date), seq: seq) }
    }

    /// 지금 보는 장의 이전 버전 요청 (메뉴): 펼친 내 플래너의 일간 · 주간 장일 때만
    func historyRequestForCurrentPage() -> SyncHistoryRequest? {
        guard inGroup, let state, let book = store.activeBook, !book.isSample, state.front == nil else { return nil }
        switch state.kind {
        case .daily: return SyncHistoryRequest(book: book.id, kind: .day, date: state.currentDate)
        case .weekly: return SyncHistoryRequest(book: book.id, kind: .week, date: state.currentDate)
        case .home: return nil
        }
    }

    // MARK: 흐름 끝내기

    /// 지금 흐름을 닫는다: 기다리던 페어링은 거두고, 아직 수락하지 않은 합류는 물린다
    func endFlow() async {
        let (o, j, f) = (offer, join, flow)
        endFlowNow()
        localStep = nil
        if let o { try? await o.cancel() }
        if let j {
            if case .join(let st, _)? = f, case .done = st {} else { try? await j.reject() }
        }
    }

    private func endFlowNow() {
        flowSeq += 1
        offer = nil
        join = nil
        // 적어 두었다고 확인하지 않은 복구 코드는 recoveryPending 으로 남는다 (새로 만들라는 안내)
        flow = nil
        for t in timers { t.cancel() }
        timers = []
    }

    /// 한 번만 보여 주는 복구 코드가 화면에 있다 (적어 두었다고 확인하기 전 — 설정 창을 닫기 전에 묻는다)
    var showsOneTimeRecoveryCode: Bool {
        if case .recovery(_, .show)? = flow { return true }
        return false
    }

    /// 설정 창을 닫았다: 아무도 보지 않는 화면에서 기다리지 않는다 (합치는 중이면 그대로 끝까지)
    func settingsClosed() {
        localStep = nil
        guard let f = flow else {
            // 합류 요청을 보내는 중에 닫았다: 돌아온 요청은 버린다 (아무도 숫자를 보지 않는다 — joinStart 가 거둔다)
            if starting { flowSeq += 1 }
            return
        }
        if case .join(.accepting, _) = f { return }
        if case .recovery(_, .working) = f { return }
        Task { await endFlow() }
    }

    private func later(_ seconds: TimeInterval, _ fn: @escaping @MainActor () -> Void) {
        let t = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fn()
        }
        timers.append(t)
    }

    // MARK: 개발자 설정 (디버그 빌드만)

    func setServerOverride(_ s: String?) -> SyncActionResult {
        guard SyncServer.allowsOverride else { return .failed("") }
        guard !inGroup else { return .failed("동기화를 끈 뒤에만 서버를 바꿀 수 있어요.") }
        guard SyncServer.setOverride(s, defaults: env.defaults) else { return .failed("쓸 수 없는 주소예요.") }
        objectWillChange.send()
        return .done
    }

    // MARK: QA (스크린샷: 서버 없이 화면만 — --sync-qa)

    /// 흐름 · 상태를 그대로 놓는다
    func qaPresent(status: SyncViewStatus?, inGroup: Bool, flow: SyncFlow?, local: SyncLocalStep? = nil,
                   warnings: [SyncWarningItem] = [], recoveryPending: Bool = false, deviceName: String? = nil,
                   credsUnreadable: Bool = false, startProblem: String? = nil, available: Bool = true, moved: Bool = false) {
        qaMode = true
        movedFromOtherMac = moved
        self.status = status
        self.inGroup = inGroup
        self.flow = flow
        self.localStep = local
        self.warnings = warnings
        self.credsUnreadable = credsUnreadable
        self.startProblem = startProblem
        if let deviceName { self.deviceName = deviceName }
        env.defaults.set(recoveryPending, forKey: Key.recoveryPending)
        ready = true
        self.available = available
        publishIndicator()
    }

    /// 화면 확인용 (서버에 묻지 않는다)
    private(set) var qaMode = false
    var qaDevices: [SyncDeviceRow] = []
    var qaHistory: [SyncText.VersionRow] = []
    /// 스크린샷: 입력 칸에 미리 넣어 둘 값 ("code" · "link" · "restore" · "digits" · "check0" · "check1" · "checking" · "merge")
    var qaInput: [String: String] = [:]
}

// MARK: - 잠자기 · 깨어남 · 네트워크 · 앱 활성 (그룹에 들어 있을 때만 본다)

@MainActor
final class SyncSystemWatch {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let monitor = NWPathMonitor()
    private var lastPath: (satisfied: Bool, interfaces: [String])?

    init(sleep: @escaping @MainActor () -> Void, wake: @escaping @MainActor () -> Void,
         networkBack: @escaping @MainActor () -> Void, active: @escaping @MainActor () -> Void) {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sleep() }
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { wake() }
        }))
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { active() }
        }))
        // 네트워크: 끊겼다 이어지거나 연결이 바뀌면 (처음 한 번은 지금 상태라 넘긴다)
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let names = path.availableInterfaces.map(\.name)
            DispatchQueue.main.async {
                guard let self else { return }
                let prev = self.lastPath
                self.lastPath = (satisfied, names)
                guard let prev, satisfied, !prev.satisfied || prev.interfaces != names else { return }
                networkBack()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.spiralday.sync.network"))
    }

    func stop() {
        monitor.cancel()
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
    }
}

// MARK: - 이 Mac 의 표시 (옮겨 온 그룹 정보 가르기)

enum SyncMachine {
    /// IOPlatformUUID 의 해시 (그대로 두지 않는다 — 이 Mac 의 설정 파일에만 적고 어디로도 보내지 않는다). 읽지 못하면 nil.
    /// 로그인 키체인 · 설정은 이전 지원 · Time Machine 복원으로 새 Mac 에 그대로 옮겨 가지만 이 값은 Mac 마다 다르다
    static func tag() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("spiralday-sync-machine:\(uuid)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
