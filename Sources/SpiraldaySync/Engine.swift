// SyncEngine: 앱 데이터 ↔ 동기화 레코드 ↔ 서버. 다른 언어의 엔진(Windows 앱의 TypeScript 엔진)과 동작이 같아야 한다
//
// 흐름
//   앱이 저장할 때마다 localChanged() → (조금 뒤) 지금 값과 그림자(마지막으로 맞춘 값)를 비교해
//   바뀐 필드에 새 HLC 도장 → 레코드 상태에 합침 → (조금 뒤) 서버로 보냄(baseSeq). 409 면 서버 것과 합쳐 다시.
//   서버 알림(WebSocket {head}) · 주기 확인 → changes 받기 → 합치기 → 앱에 넣기(host.updateBook / updateLibrary).
//   앱에 넣을 때는 그 순간의 앱 값을 먼저 다시 비교해서(사이에 쓴 것) 잃지 않는다.
// 상태를 바꾸는 일은 모두 한 줄로 차례대로 실행된다 (locked).
import Foundation

// MARK: - 내부 상태

enum ImportMode: String, Sendable {
    /// 그룹을 만든 기기: 진짜 도장
    case real
    /// 들어온 기기: 시각 0 도장 (겹치면 그룹 값이 이긴다)
    case zero
}

struct Meta {
    var nodeId: String
    var hlc: Stamp?
    var head = 0
    var imported = false
    var lastSyncAt: Int?
    var creds: Credentials?
    var recovery: (recoveryId: String, at: Int)?
    var importMode: ImportMode?
    /// 서버에 아직 올리지 못한 이 기기 이름 (다음 동기화 때 다시)
    var rename: String?
    /// 모르는 payload 버전이라 건너뛴 레코드가 있을 때, 그때 이 엔진이 알던 버전 (더 새 엔진으로 켜면 처음부터 다시 받는다)
    var skippedBelow: Int?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "v": 1, "nodeId": .string(nodeId), "hlc": hlc.map { .string($0) } ?? .null, "head": JSONValue(head),
            "imported": .bool(imported), "lastSyncAt": lastSyncAt.map { JSONValue($0) } ?? .null,
        ]
        if let creds { o["creds"] = creds.json }
        if let recovery { o["recovery"] = ["recoveryId": .string(recovery.recoveryId), "at": JSONValue(recovery.at)] }
        if let importMode { o["importMode"] = .string(importMode.rawValue) }
        if let rename { o["rename"] = .string(rename) }
        if let skippedBelow { o["skippedBelow"] = JSONValue(skippedBelow) }
        return .object(o)
    }
}

/// 이 엔진이 읽고 쓰는 레코드 payload 버전
let PAYLOAD_VERSION = 1
/// 원래 기기에서 새 기기 화면의 확인 숫자를 틀리게 넣을 수 있는 횟수
let MAX_DIGIT_TRIES = 3
/// 승인 뒤 새 기기가 수락할 수 있는 시간 (서버는 30분 — 시계 차이를 두고 조금 짧게)
let ACCEPT_WINDOW_MS = 25 * 60_000

/// 레코드 하나의 동기화 상태 (값 타입: 앱에 넣는 동안 따로 고치고 끝나면 돌려놓는다)
struct RecData: Sendable {
    /// 상태에 담긴 서버 버전 (다음에 보낼 baseSeq)
    var seq = 0
    var state = RecState()
    /// 앱에 있다고 알고 있는 값 (마지막 비교 · 넣기)
    var shadow: Flat?
    /// 서버에 아직 없는 변경
    var dirty = false
    /// 앱에 아직 넣지 않은 변경
    var apply = false
    /// 넣으려던 값 (넣다가 꺼졌을 때 지난 비교로 오해하지 않게)
    var pend: Flat?
    var ver = 0
    /// 되돌리기로 고쳤다: 다음 보내기에서 서버가 지금 버전을 이전 버전으로 꼭 남기게 (keep)
    var keep = false

    /// 그림자와 지금 값을 비교해 바뀐 것을 상태에 합친다. (바뀌었는지, 저장할 것이 생겼는지)
    mutating func absorb(_ kind: RecordKind, _ cur: Flat, _ clock: StampSource) -> (changed: Bool, touched: Bool) {
        if state.x != nil {
            shadow = nil
            return (false, false)
        }
        if let p = pend, cur == p {
            // 넣으려던 값이 이미 앱에 있다 (넣은 뒤 꺼졌다) → 편집이 아니다
            shadow = p
            pend = nil
            return (false, true)
        }
        var delta = Records.diff(kind, prev: shadow, cur: cur, clock: clock)
        let had = shadow != nil
        shadow = cur
        if CRDT.isEmptyDelta(delta) { return (false, !had) }
        // 이 기기의 편집은 이 기기가 본 그 필드의 값보다 늘 이긴다 (시계가 크게 앞선 기기의 도장 위에서도)
        if let h = clock as? HLC { CRDT.liftDelta(&delta, state, node: h.node) }
        CRDT.mergeInto(&state, delta)
        dirty = true
        ver += 1
        return (true, true)
    }

    var stored: JSONValue {
        var o: [String: JSONValue] = ["seq": JSONValue(seq), "state": CRDT.toJSON(state), "dirty": .bool(dirty), "apply": .bool(apply)]
        if let shadow { o["shadow"] = shadow.json }
        if let pend { o["pend"] = pend.json }
        if keep { o["keep"] = true }
        return .object(o)
    }

    var hasContent: Bool { state.x != nil || !state.f.isEmpty || !state.c.isEmpty }
}

final class RecEntry {
    let key: String
    let pk: ParsedKey
    var rid: String
    var d = RecData()
    /// 서버의 버전을 풀 수 없다 (새 버전 앱 · 손상) → 이번 실행 동안 덮어쓰지 않는다
    var blocked = false
    /// 이 ver 의 암호문이 서버 한도(1 MiB)를 넘었다 → 다시 고칠 때까지 보내지 않는다
    var tooLarge: Int?

    init(key: String, pk: ParsedKey, rid: String) {
        self.key = key
        self.pk = pk
        self.rid = rid
    }
}

enum ScanHints {
    case all
    case some(Set<String>)

    func has(_ k: String) -> Bool {
        if case let .some(s) = self { return s.contains(k) }
        return true
    }

    func merged(_ o: ScanHints?) -> ScanHints {
        guard let o else { return self }
        switch (self, o) {
        case let (.some(a), .some(b)): return .some(a.union(b))
        default: return .all
        }
    }
}

/// 모르는 payload 버전 (새 버전 앱이 쓴 것)
struct UnknownVersion: Error {
    let v: JSONValue?
}

/// 서버가 받는 레코드 암호문 최대 크기
let MAX_RECORD_BYTES = 1024 * 1024
/// 기한을 볼 때 두 기기 시계 차이를 받아 주는 여유
let CLOCK_GRACE_MS = 30_000

// MARK: - 엔진

public actor SyncEngine {
    nonisolated let host: any SyncHost
    nonisolated let transport: any SyncTransport
    nonisolated let storage: any SyncStorage
    nonisolated let credStore: (any CredentialStore)?
    nonisolated let nowFn: @Sendable () -> Int
    nonisolated let auto: Bool
    let scanDelayMs: Int
    let pushDelayMs: Int
    let pollMs: Int
    let safetyPollMs: Int
    let concurrency: Int
    let massDeleteDays: Int
    let logFn: @Sendable (SyncLogLevel, String) -> Void
    public nonisolated let platform: SyncPlatform

    var meta = Meta(nodeId: "0000000000000000")
    var hlc = HLC(node: "0000000000000000", wall: { 0 })
    var creds: Credentials?
    var keys: GroupKeys?
    var recs: [String: RecEntry] = [:]
    var byRid: [String: RecEntry] = [:]
    var byBook: [String: Set<String>] = [:]
    var touched = Set<String>()
    var metaTouched = false

    var initialized = false
    var running = false
    var disposed = false
    var state: SyncState = .off
    var errorText: String?
    var live = false

    var scanHints: ScanHints?
    var scanTimer: Task<Void, Never>?
    var cycleTimer: Task<Void, Never>?
    var cycleAt = Int.max
    var pollTimer: Task<Void, Never>?
    var pingTimer: Task<Void, Never>?
    var wsTimer: Task<Void, Never>?
    var socket: (any SocketHandle)?
    var socketGen = 0
    var socketTask: Task<Void, Never>?
    var backoff = 0
    var wsBackoff = 0
    var wantPull = false
    var wantPush = false
    var retryAt = 0
    var batchOk = true
    /// 파일이 사라져 동기화된 내용으로 되살릴 책
    var restoreBooks = Set<String>()
    var listeners: [UUID: @Sendable (SyncEvent) -> Void] = [:]
    var droppedListeners = Set<UUID>()
    var pairingWakers: [UUID: (pairingId: String, cont: CheckedContinuation<Void, Never>, timer: Task<Void, Never>?)] = [:]
    /// 이번 실행을 시작할 때 이미 맞춰 둔(그림자가 있던) 책 — 책장 파일을 새로 만든 실행에서 "잃은 책" 을 가리는 데 쓴다
    var knownAtStart = Set<String>()
    /// 이번 실행에서 이미 알린 것 (같은 경고를 거듭 내지 않게)
    var warned = Set<String>()
    /// 앱이 "사용자가 지웠다" 고 알려 준 책 — 이것은 몇 권이든 지운 것으로 본다
    var deletedHint = Set<String>()

    /// 앱 수명 순번 (suspend · resume 마다 하나씩): suspend 는 올리기를 마친 뒤 그 사이 resume 이 없었을 때만 멈춘다
    var lifeSeq = 0

    // 한 줄 실행 (작업을 하나씩 차례로)
    var lockHeld = false
    var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public init(_ o: SyncEngineOptions) {
        host = o.host
        transport = o.transport
        storage = o.storage
        credStore = o.credentials
        nowFn = o.now
        auto = o.auto
        scanDelayMs = o.scanDelayMs
        pushDelayMs = o.pushDelayMs
        pollMs = o.pollMs
        safetyPollMs = o.safetyPollMs
        concurrency = max(1, o.concurrency)
        massDeleteDays = o.massDeleteDays
        logFn = o.log
        platform = o.platform
    }

    func now() -> Int { nowFn() }

    func log(_ level: SyncLogLevel, _ msg: String, _ err: (any Error)? = nil) {
        logFn(level, err.map { "\(msg): \($0)" } ?? msg)
    }

    // MARK: 한 줄 실행

    func acquire() async {
        if !lockHeld {
            lockHeld = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    func release() {
        if lockWaiters.isEmpty { lockHeld = false } else { lockWaiters.removeFirst().resume() }
    }

    func locked<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    // MARK: 수명

    /// 저장해 둔 상태를 읽고, 그룹에 들어 있으면 동기화를 시작한다
    public func initialize() async throws {
        if initialized { return }
        SyncCrypto.prepare()
        let stored = try await storage.load()
        let m = stored.meta
        var nodeId = SyncCrypto.newNodeId()
        if let n = m?.optStr("nodeId"), Stamps.isNode(n) { nodeId = n }
        meta = Meta(nodeId: nodeId)
        if let h = m?.optStr("hlc"), Stamps.isStamp(h) { meta.hlc = h }
        if let h = m?["head"]?.numberValue { meta.head = Int(h) }
        meta.imported = m?["imported"] == .bool(true)
        if let t = m?["lastSyncAt"]?.numberValue { meta.lastSyncAt = Int(t) }
        meta.creds = Credentials(json: m?["creds"])
        if let r = m?["recovery"], let id = r.optStr("recoveryId") { meta.recovery = (id, r.optInt("at") ?? 0) }
        meta.importMode = m?.optStr("importMode").flatMap(ImportMode.init(rawValue:))
        meta.rename = m?.optStr("rename")
        if let sb = m?.optInt("skippedBelow") {
            // 예전 엔진이 모르는 버전이라 건너뛴 레코드가 있었다: 이제 읽을 수 있으니 처음부터 다시 받는다 (합치기는 멱등)
            if sb < PAYLOAD_VERSION { meta.head = 0 } else { meta.skippedBelow = sb }
        }
        let nf = nowFn
        hlc = HLC(node: meta.nodeId, last: meta.hlc, wall: { Int64(nf()) })
        for (key, v) in stored.records {
            guard let pk = RecordKeys.parse(key), case .object = v else { continue }
            let e = newRec(key, pk)
            e.d.seq = v.optInt("seq") ?? 0
            do {
                e.d.state = try CRDT.parseState(v["state"])
            } catch {
                log(.warn, "저장된 레코드를 읽지 못함 \(key)", error)
            }
            e.d.shadow = Flat(json: v["shadow"])
            e.d.dirty = v["dirty"] == .bool(true)
            e.d.apply = v["apply"] == .bool(true)
            e.d.pend = Flat(json: v["pend"])
            e.d.keep = v["keep"] == .bool(true)
            if pk.kind == .book, e.d.shadow != nil, e.d.state.x == nil, let b = pk.bookId { knownAtStart.insert(b) }
        }
        creds = credStore != nil ? try await credStore!.get() : meta.creds
        if let c = creds { keys = try GroupKeys(base64: c.key) }
        byRid = [:]
        for e in recs.values {
            if let keys { e.rid = keys.rid(e.key) }
            byRid[e.rid] = e
        }
        initialized = true
        metaTouched = true
        try await flush()
        if creds != nil { start() } else { setState(.off) }
    }

    /// 동기화 돌리기 시작 (그룹에 들어 있을 때)
    public func start() {
        guard initialized, creds != nil, !running, !disposed else { return }
        running = true
        setState(.idle)
        if auto {
            connectSocket()
            schedulePoll()
        }
        kick(scan: .all, pull: true, push: true, delay: 0)
    }

    /// 멈춤 (그룹 정보는 그대로). 빠짐 · 그룹 없음 상태는 그대로 둔다
    public func stop() {
        running = false
        clearTimers()
        closeSocket()
        if creds != nil, state != .removed, state != .groupGone { setState(.idle) }
    }

    /// 다 끝냄 (남은 쓰기를 마친다)
    public func dispose() async {
        stop()
        disposed = true
        await locked {}
        for (_, w) in pairingWakers {
            w.timer?.cancel()
            w.cont.resume()
        }
        pairingWakers = [:]
    }

    public var status: SyncStatus {
        SyncStatus(state: state, pending: initialized ? recs.values.reduce(0) { $0 + ($1.d.dirty ? 1 : 0) } : 0,
                   lastSyncAt: meta.lastSyncAt, error: errorText, gid: creds?.gid, deviceId: creds?.deviceId, live: live)
    }

    public var inGroup: Bool { creds != nil }

    /// 이 기기의 HLC 노드 id
    public var nodeId: String { meta.nodeId }

    /// 이 그룹에 복구 코드를 만든 적이 있는지 (이 기기에서)
    public var hasRecovery: Bool { meta.recovery != nil }

    /// 이벤트 받기. 돌려받은 id 로 끊는다 (removeListener). 콜백은 엔진 쪽에서 불리므로 화면은 MainActor 로 옮겨서 쓴다
    @discardableResult
    public func addListener(_ cb: @escaping @Sendable (SyncEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = cb
        return id
    }

    public func removeListener(_ id: UUID) {
        if listeners.removeValue(forKey: id) == nil { droppedListeners.insert(id) }
    }

    func addListener(id: UUID, _ cb: @escaping @Sendable (SyncEvent) -> Void) {
        // 스트림이 먼저 끝났으면 (removeListener 가 먼저 왔으면) 붙이지 않는다
        if droppedListeners.remove(id) != nil { return }
        listeners[id] = cb
    }

    /// 이벤트를 AsyncStream 으로 (for await e in engine.events() { … }). 붙기 전의 이벤트는 오지 않는다
    public nonisolated func events() -> AsyncStream<SyncEvent> {
        AsyncStream { cont in
            let id = UUID()
            cont.onTermination = { _ in Task { await self.removeListener(id) } }
            Task { await self.addListener(id: id) { cont.yield($0) } }
        }
    }

    func emit(_ e: SyncEvent) {
        for l in listeners.values { l(e) }
        if case let .pairing(id, _) = e { wakePairing(id) }
    }

    func setState(_ s: SyncState, _ error: String? = nil) {
        let changed = s != state || error != errorText
        state = s
        errorText = error
        if changed { emit(.status(status)) }
    }

    func assertInit() throws {
        guard initialized else { throw SyncEngineError(.notInitialized, "SyncEngine.initialize() 를 먼저 불러야 해요") }
    }

    func authOrThrow() throws -> Auth {
        try assertInit()
        guard let c = creds, keys != nil else { throw SyncEngineError(.notInGroup, "동기화 그룹에 들어 있지 않아요.") }
        return Auth(gid: c.gid, token: c.token)
    }

    // MARK: 앱이 부르는 것

    /// 앱이 저장했다 (bookId 를 주면 그 책만, 없으면 책장과 모든 책). 어디서 불러도 된다 (기다리지 않는다).
    /// 사용자가 책을 지웠으면 deletedBooks 로 알려 준다: 엔진은 책장에서 사라진 책을 이 표시가 있을 때 바로 지운 것으로 보고,
    /// 없으면 잃은 것은 아닌지 따져 본다 (scanLibrary)
    public nonisolated func localChanged(bookId: String? = nil, library: Bool = false, deletedBooks: [String] = []) {
        Task { await self.noteLocalChange(bookId: bookId, library: library, deletedBooks: deletedBooks) }
    }

    /// localChanged 와 같고, 알림을 받을 때까지 기다린다 (테스트)
    public func noteLocalChange(bookId: String? = nil, library: Bool = false, deletedBooks: [String] = []) {
        guard initialized, creds != nil else { return }
        for id in deletedBooks { deletedHint.insert(id.uppercased()) }
        let library = library || !deletedBooks.isEmpty
        guard running else { return }
        if bookId == nil, !library {
            scanHints = .all
        } else if case .all? = scanHints {
            // 그대로
        } else {
            var s = Set<String>()
            if case let .some(cur)? = scanHints { s = cur }
            if let bookId { s.insert(bookId.uppercased()) }
            if library { s.insert(RecordKeys.lib) }
            scanHints = .some(s)
        }
        guard auto, scanTimer == nil else { return }
        let ms = scanDelayMs
        scanTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return }
            await self?.scanTimerFired()
        }
    }

    func scanTimerFired() {
        scanTimer = nil
        if let hints = takeHints() { kick(scan: hints, push: true, pushDelay: pushDelayMs, delay: 0) }
    }

    func takeHints() -> ScanHints? {
        let h = scanHints
        scanHints = nil
        return h
    }

    /// 지금 바로: 비교 → 받기 → 넣기 → 보내기. 끝날 때까지 기다린다 (오류는 상태로 알린다)
    public func syncNow() async throws {
        try assertInit()
        guard creds != nil else { return }
        _ = takeHints()
        await locked { await cycle(scan: .all, pull: true, push: true) }
    }

    /// 비교만 (테스트 · 앱을 닫기 전)
    public func scanNow(bookId: String? = nil) async throws {
        try assertInit()
        guard creds != nil else { return }
        try await locked {
            try await scan(bookId.map { .some([$0.uppercased()]) } ?? .all, clock: hlc)
            try await flush()
        }
    }

    /// 받기만
    public func pullNow() async throws {
        try assertInit()
        guard creds != nil else { return }
        await locked { await cycle(scan: nil, pull: true, push: false) }
    }

    /// 보내기만
    public func pushNow() async throws {
        try assertInit()
        guard creds != nil else { return }
        await locked { await cycle(scan: nil, pull: false, push: true) }
    }

    // MARK: 그룹 만들기 · 나오기

    /// 첫 기기: 새 그룹을 만들고 이 기기의 모든 플래너를 올린다
    @discardableResult
    public func createGroup(deviceName: String) async throws -> (gid: String, deviceId: String) {
        try assertInit()
        if creds != nil { throw SyncEngineError(.alreadyInGroup, "이미 동기화 그룹에 들어 있어요.") }
        let keys = GroupKeys.generate()
        // 이름의 암호문은 기기 id 에 묶이므로 (id 는 서버가 정한다) 플랫폼 이름으로 만든 뒤 바로 바꾼다
        let res = try await serverCall { try await self.transport.createGroup(deviceName: "p." + self.platform.rawValue) }
        try await enterGroup(Credentials(gid: res.gid, deviceId: res.deviceId, token: res.token, key: keys.base64), keys, .real)
        await applyName(deviceName)
        return (res.gid, res.deviceId)
    }

    /// 이 기기만 그룹에서 나온다 (서버에서 이 기기를 지우고, 이 기기의 동기화 상태를 지운다. 플래너는 그대로)
    public func leaveGroup() async throws {
        let a = try authOrThrow()
        do {
            try await transport.removeDevice(a, deviceId: "me")
        } catch let e as SyncHTTPError where e.status == 401 || e.status == 404 {
            // 이미 지워졌거나 그룹이 없으면 그대로 나온다
        } catch {
            throw wrap(error)
        }
        try await forgetGroup()
    }

    /// 그룹 전체를 서버에서 바로 지운다 (모든 기기의 동기화가 끊긴다. 각 기기의 플래너는 그대로)
    public func wipeGroup() async throws {
        let a = try authOrThrow()
        do {
            try await transport.deleteGroup(a)
        } catch let e as SyncHTTPError where e.status == 404 {
        } catch {
            throw wrap(error)
        }
        try await forgetGroup()
    }

    /// 이 기기의 동기화 상태만 지운다 (서버에는 묻지 않는다: 이미 빠졌거나 그룹이 사라졌을 때)
    public func forgetGroup() async throws {
        try assertInit()
        stop()
        try await locked {
            creds = nil
            keys = nil
            recs = [:]
            byRid = [:]
            byBook = [:]
            touched = []
            restoreBooks = []
            try await storage.clear()
            if let credStore { try await credStore.set(nil) }
            meta = Meta(nodeId: meta.nodeId, hlc: hlc.last)
            metaTouched = true
            try await flush()
        }
        live = false
        setState(.off)
    }

    func enterGroup(_ c: Credentials, _ keys: GroupKeys, _ importMode: ImportMode) async throws {
        stop()
        try await locked {
            recs = [:]
            byRid = [:]
            byBook = [:]
            touched = []
            restoreBooks = []
            try await storage.clear()
            creds = c
            self.keys = keys
            if let credStore { try await credStore.set(c) } else { meta.creds = c }
            meta.head = 0
            meta.imported = false
            meta.importMode = importMode
            meta.lastSyncAt = nil
            meta.recovery = nil
            meta.rename = nil
            metaTouched = true
            try await flush()
        }
        start()
    }

    /// 이 기기 이름을 K · 기기 id 로 감싸 서버에 둔다 (e1.). 못 올리면 기억해 두었다가 다음 동기화 때 다시 올린다
    func applyName(_ name: String) async {
        guard let c = creds, let keys else { return }
        let stored = keys.encryptName(name, deviceId: c.deviceId)
        var ok = true
        do {
            try await transport.renameDevice(Auth(gid: c.gid, token: c.token), deviceId: "me", name: stored)
        } catch {
            ok = false
            log(.warn, "기기 이름을 올리지 못함 (다음 동기화 때 다시)", error)
        }
        await locked {
            meta.rename = ok ? nil : name
            metaTouched = true
            do { try await flush() } catch { log(.error, "동기화 상태를 저장하지 못함", error) }
        }
    }

    /// 한 바퀴 안에서: 못 올린 기기 이름을 다시 (실패해도 동기화는 계속)
    func retryRename() async {
        guard let name = meta.rename, let c = creds, let keys else { return }
        do {
            try await transport.renameDevice(Auth(gid: c.gid, token: c.token), deviceId: "me", name: keys.encryptName(name, deviceId: c.deviceId))
            if meta.rename == name {
                meta.rename = nil
                metaTouched = true
            }
        } catch {
            log(.debug, "기기 이름을 아직 올리지 못함", error)
        }
    }

    // MARK: 복구 코드

    /// 복구 코드를 새로 만든다 (예전 코드는 못 쓰게 된다). 돌려준 코드는 한 번만 보여 준다
    public func setupRecovery() async throws -> String {
        let a = try authOrThrow()
        let code = Codes.newRecoveryCode()
        let r = try await Task.detached { try RecoverySecret.fromCode(code) }.value
        let wrapped = r.wrap(keys!, gid: a.gid)
        try await serverCall { try await self.transport.putRecovery(a, recoveryId: r.recoveryId, gid: a.gid, wrappedKey: wrapped, authHash: r.authHash) }
        try await locked {
            meta.recovery = (r.recoveryId, now())
            metaTouched = true
            try await flush()
        }
        return Codes.formatRecoveryCode(code)
    }

    /// 모든 기기를 잃었을 때: 복구 코드로 그룹에 다시 들어간다
    @discardableResult
    public func restoreFromRecovery(code: String, deviceName: String) async throws -> (gid: String, deviceId: String, evicted: String?) {
        try assertInit()
        if creds != nil { throw SyncEngineError(.alreadyInGroup, "이미 동기화 그룹에 들어 있어요.") }
        let r: RecoverySecret
        do {
            r = try await Task.detached { try RecoverySecret.fromCode(code) }.value
        } catch {
            throw SyncEngineError(.invalidCode, "복구 코드가 맞지 않아요. 글자를 다시 확인하세요.", underlying: error)
        }
        let v: GetRecoveryRes
        do {
            v = try await transport.getRecovery(recoveryId: r.recoveryId)
        } catch let e as SyncHTTPError where e.status == 404 {
            throw SyncEngineError(.recoveryNotFound, "이 복구 코드로 찾을 수 있는 그룹이 없어요.", underlying: e)
        } catch {
            throw wrap(error)
        }
        let keys: GroupKeys
        do {
            keys = try r.unwrap(v.wrappedKey, gid: v.gid)
        } catch {
            throw SyncEngineError(.wrongKey, "복구 정보를 풀지 못했어요.", underlying: error)
        }
        let res: RecoveryJoinRes
        do {
            // 이름은 기기 id 에 묶어 암호화하므로 들어간 뒤 바꾼다
            res = try await transport.joinByRecovery(recoveryId: r.recoveryId, auth: r.auth, deviceName: "p." + platform.rawValue)
        } catch let e as SyncHTTPError where e.status == 403 || e.status == 404 {
            // 403: 증명이 맞지 않음 (그 사이에 다른 기기가 복구 코드를 새로 만들었다) · 404: 그룹이 사라짐
            throw SyncEngineError(.recoveryNotFound, "이 복구 코드로는 들어갈 수 없어요. 가장 최근에 만든 복구 코드인지 확인하세요.", underlying: e)
        } catch {
            throw wrap(error)
        }
        try await enterGroup(Credentials(gid: res.gid, deviceId: res.deviceId, token: res.token, key: keys.base64), keys, .zero)
        await applyName(deviceName)
        return (res.gid, res.deviceId, res.evicted)
    }

    // MARK: 기기

    /// 그룹의 기기들. name 은 풀어 낸 이름 (못 풀면 nil → "알 수 없는 기기"), platform 은 합류 직후의 플랫폼 이름
    public func listDevices() async throws -> (devices: [DeviceInfo], maxDevices: Int) {
        let a = try authOrThrow()
        let res = try await serverCall { try await self.transport.devices(a) }
        let k = keys!
        return (res.devices.map { d in
            let n = describeDevice(d, keys: k)
            return DeviceInfo(id: d.id, name: n.name, platform: n.platform, created: d.created, lastSeen: d.lastSeen, current: d.current)
        }, res.maxDevices)
    }

    public func renameThisDevice(_ name: String) async throws {
        let a = try authOrThrow()
        let stored = keys!.encryptName(name, deviceId: creds!.deviceId)
        try await serverCall { try await self.transport.renameDevice(a, deviceId: "me", name: stored) }
        if meta.rename != nil {
            try await locked {
                meta.rename = nil
                metaTouched = true
                try await flush()
            }
        }
    }

    /// 다른 기기를 그룹에서 뺀다 (그 기기는 더 이상 받지도 보내지도 못한다)
    public func removeDevice(_ deviceId: String) async throws {
        let a = try authOrThrow()
        if deviceId == creds!.deviceId { return try await leaveGroup() }
        try await serverCall { try await self.transport.removeDevice(a, deviceId: deviceId) }
    }

    public func groupInfo() async throws -> GroupInfo {
        let a = try authOrThrow()
        return try await serverCall { try await self.transport.groupInfo(a) }
    }

    // MARK: 이전 버전

    /// 레코드 하나(예: RecordKeys.day(책, 날짜))의 이전 버전들 (서버가 30일 보관). 값은 앱 모양
    public func history(_ recordKey: String) async throws -> [HistoryEntry] {
        let a = try authOrThrow()
        guard let pk = RecordKeys.parse(recordKey) else { throw SyncEngineError(.invalidArgument, "레코드 키가 아님: \(recordKey)") }
        let rid = keys!.rid(recordKey)
        let res = try await serverCall { try await self.transport.history(a, rid: rid) }
        var out: [HistoryEntry] = []
        for v in res {
            do {
                let st = try decode(rid, v.ct, expectKey: recordKey)
                out.append(HistoryEntry(seq: v.seq, at: v.at, current: v.current, value: Records.materialize(pk, st)))
            } catch {
                log(.warn, "이전 버전을 풀지 못함", error)
            }
        }
        return out
    }

    /// 이전 버전으로 되돌린다 (지금 기기의 편집으로 기록되어 다른 기기로 퍼진다)
    public func restoreVersion(_ recordKey: String, seq: Int) async throws {
        let versions = try await history(recordKey)
        guard let v = versions.first(where: { $0.seq == seq }) else {
            throw SyncEngineError(.invalidArgument, "그 버전이 없어요 (30일이 지났을 수 있어요)")
        }
        let pk = RecordKeys.parse(recordKey)!
        let value = v.value
        // 지금 버전은 서버에 이전 버전으로 꼭 남긴다 (keep — 방금 고친 날을 바로 되돌려도 2분 묶기로 사라지지 않게)
        try await locked {
            let e = rec(recordKey)
            e.d.keep = true
            touch(e)
            try await flush()
        }
        switch pk.kind {
        case .day, .week, .prefs:
            try await host.updateBook(id: pk.bookId!) { cur in
                let d = cur ?? PlannerModel.emptyPlannerData()
                switch pk.kind {
                case .day: return Records.withDay(d, pk.date!, value)
                case .week: return Records.withWeek(d, pk.date!, value)
                default:
                    guard let p = value?.objectValue else { return d }
                    return Records.withPrefs(d, p)
                }
            }
            noteLocalChange(bookId: pk.bookId!)
        case .book:
            guard let info = value, case .object = info else { break }
            try await host.updateLibrary { lib in
                guard case var .object(o) = lib else { return lib }
                o["books"] = .array(Records.books(lib).map { b in
                    guard JS.string(b["id"]).uppercased() == info["id"]?.stringValue, case var .object(bo) = b, case let .object(io) = info else { return b }
                    for (k, x) in io { bo[k] = x }
                    return .object(bo)
                })
                return .object(o)
            }
            noteLocalChange(library: true)
        case .lib:
            break
        }
        if !auto { try await syncNow() }
    }

    // MARK: - 오류 다루기

    func wrap(_ e: any Error) -> any Error {
        if e is SyncEngineError { return e }
        if e is NetworkError { return SyncEngineError(.offline, "인터넷에 연결되어 있지 않아요.", underlying: e) }
        if let h = e as? SyncHTTPError {
            if h.code == "device_limit" { return SyncEngineError(.deviceLimit, h.message, underlying: h) }
            if h.code == "pairing_limit" { return SyncEngineError(.pairingLimit, h.message, underlying: h) }
            if h.code == "code_join_paused" {
                return SyncEngineError(.codeJoinPaused, "지금은 코드로 연결하는 요청이 너무 많아 막아 두었어요. \(waitText(h.retryAfter)) 뒤에 다시 해 주세요.", underlying: h)
            }
            if h.status == 429 { return SyncEngineError(.rateLimited, "요청이 너무 많아요. \(waitText(h.retryAfter)) 뒤에 다시 해 주세요.", underlying: h) }
            return SyncEngineError(.server, serverText(h), underlying: h)
        }
        if let c = e as? CryptoError { return SyncEngineError(.wrongKey, c.message, underlying: c) }
        return e
    }

    func serverCall<T: Sendable>(_ fn: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await fn()
        } catch {
            throw wrap(error)
        }
    }

    // MARK: - 타이머

    func kick(scan: ScanHints? = nil, pull: Bool = false, push: Bool = false, pushDelay: Int? = nil, delay: Int) {
        guard running else { return }
        if let scan { scanHints = scan.merged(scanHints) }
        if pull { wantPull = true }
        if push { wantPush = true }
        guard auto else { return }
        let at = now() + max(delay, pushDelay ?? 0, backoffRemaining())
        if cycleTimer != nil, at >= cycleAt { return }
        cycleTimer?.cancel()
        cycleAt = at
        let wait = max(0, at - now())
        cycleTimer = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            if Task.isCancelled { return }
            await self?.cycleTimerFired()
        }
    }

    func cycleTimerFired() {
        cycleTimer = nil
        cycleAt = Int.max
        let scan = takeHints()
        let pull = wantPull
        let push = wantPush
        wantPull = false
        wantPush = false
        // 타이머의 취소가 진행 중인 동기화에 번지지 않게 따로 돈다
        Task { await self.locked { await self.cycle(scan: scan, pull: pull, push: push) } }
    }

    func backoffRemaining() -> Int { max(0, retryAt - now()) }

    func schedulePoll() {
        guard auto, running else { return }
        pollTimer?.cancel()
        let ms = live ? safetyPollMs : pollMs
        pollTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return }
            await self?.pollFired()
        }
    }

    func pollFired() {
        pollTimer = nil
        kick(pull: true, push: true, delay: 0)
        schedulePoll()
    }

    func clearTimers() {
        for t in [scanTimer, cycleTimer, pollTimer, wsTimer, pingTimer] { t?.cancel() }
        scanTimer = nil
        cycleTimer = nil
        pollTimer = nil
        wsTimer = nil
        pingTimer = nil
        cycleAt = Int.max
    }

    // MARK: - WebSocket

    enum SocketEvent: Sendable {
        case open
        case message(ServerPush)
        case close(Int, String)
    }

    func connectSocket() {
        guard running, let c = creds, socket == nil else { return }
        socketGen += 1
        let gen = socketGen
        let (stream, cont) = AsyncStream<SocketEvent>.makeStream()
        socket = transport.openSocket(Auth(gid: c.gid, token: c.token), handlers: SocketHandlers(
            onOpen: { cont.yield(.open) },
            onMessage: { cont.yield(.message($0)) },
            onClose: { code, reason in
                cont.yield(.close(code, reason))
                cont.finish()
            }))
        socketTask = Task { [weak self] in
            for await ev in stream {
                guard let self else { return }
                await self.onSocket(ev, gen: gen)
            }
        }
    }

    func onSocket(_ ev: SocketEvent, gen: Int) {
        guard gen == socketGen, socket != nil else { return }
        switch ev {
        case .open:
            live = true
            wsBackoff = 0
            emit(.status(status))
            pingTimer?.cancel()
            pingTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    await self?.ping()
                }
            }
            schedulePoll()
        case let .message(m):
            onPush(m)
        case let .close(code, _):
            socket = nil
            live = false
            pingTimer?.cancel()
            pingTimer = nil
            emit(.status(status))
            if code == WSClose.deviceRemoved { return onFatal(.removed, "이 기기는 동기화 그룹에서 빠졌어요.") }
            if code == WSClose.groupDeleted { return onFatal(.groupGone, "동기화 그룹이 지워졌어요.") }
            // 같은 기기가 연결을 너무 많이 열어 서버가 오래된 것을 닫았다 → 다시 열지 않고 주기 확인으로
            if code == WSClose.replaced { return schedulePoll() }
            guard running else { return }
            wsBackoff = min(60_000, wsBackoff > 0 ? wsBackoff * 2 : 1000)
            let ms = Int(Double(wsBackoff) * (0.75 + Double.random(in: 0..<0.5)))
            wsTimer?.cancel()
            wsTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if Task.isCancelled { return }
                await self?.reconnect()
            }
        }
    }

    func ping() { socket?.send("ping") }

    func reconnect() {
        wsTimer = nil
        connectSocket()
    }

    func closeSocket() {
        let s = socket
        socket = nil
        socketGen += 1
        live = false
        socketTask?.cancel()
        socketTask = nil
        s?.close()
    }

    func onPush(_ m: ServerPush) {
        switch m {
        // 닫힘 프레임이 늦게 와도(프록시 · 모바일 망) 바로 멈춘다
        case .removed: onFatal(.removed, "이 기기는 동기화 그룹에서 빠졌어요.")
        case .deleted: onFatal(.groupGone, "동기화 그룹이 지워졌어요.")
        case let .head(h): if h > meta.head { kick(pull: true, delay: 1000) }
        case .devices:
            emit(.devices)
            // 두 번째 기기가 들어오면 그룹 용량이 늘어난다 → 용량 때문에 멈춘 보내기를 바로 다시
            if state == .quota {
                retryAt = 0
                kick(push: true, delay: 500)
            }
        case let .pairing(id, status): emit(.pairing(id: id, status: status))
        case .unknown: break
        }
    }

    func onFatal(_ s: SyncState, _ message: String) {
        running = false
        clearTimers()
        closeSocket()
        setState(s, message)
    }

    // MARK: - 페어링 기다리기 (알림으로 깨운다)

    func sleepOrWake(ms: Int, pairingId: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    cont.resume()
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(1, ms)) * 1_000_000)
                    await self?.wakeWaiter(id)
                }
                pairingWakers[id] = (pairingId, cont, timer)
            }
        } onCancel: {
            Task { await self.wakeWaiter(id) }
        }
    }

    func wakeWaiter(_ id: UUID) {
        guard let w = pairingWakers.removeValue(forKey: id) else { return }
        w.timer?.cancel()
        w.cont.resume()
    }

    func wakePairing(_ pairingId: String) {
        for (id, w) in pairingWakers where w.pairingId == pairingId { wakeWaiter(id) }
    }
}

// MARK: - 도우미

/// 서버에 있는 기기 이름 → (이름, 플랫폼). "e1." 은 K 와 그 기기 id 로 풀고 (못 풀면 nil), "p." 는 플랫폼 이름 (목록에 있을 때만).
/// 그 밖의 글은 보여 주지 않는다 (nil) — 서버나 남이 정한 글이 기기 이름처럼 보이지 않게
func describeName(_ stored: String?, deviceId: String, keys: GroupKeys) -> (name: String?, platform: SyncPlatform?) {
    guard let stored, !stored.isEmpty else { return (nil, nil) }
    if stored.hasPrefix("e1.") { return (keys.decryptName(stored, deviceId: deviceId), nil) }
    return (nil, platformOf(stored))
}

/// 기기 목록의 한 줄 → (풀어 낸 이름, 플랫폼). 이름을 암호화한 기기도 서버가 남긴 플랫폼으로 아이콘을 고른다 (목록에 있을 때만)
func describeDevice(_ d: DeviceRow, keys: GroupKeys) -> (name: String?, platform: SyncPlatform?) {
    let n = describeName(d.name, deviceId: d.id, keys: keys)
    return (n.name, n.platform ?? d.platform.flatMap(SyncPlatform.init(rawValue:)))
}

/// 승인 전 기기 이름("p.<플랫폼>")의 플랫폼. 목록에 없는 글이면 nil (승인 화면에 남이 정한 글이 나오지 않게)
func platformOf(_ stored: String?) -> SyncPlatform? {
    guard let stored, stored.hasPrefix("p.") else { return nil }
    return SyncPlatform(rawValue: String(stored.dropFirst(2)))
}

/// 확인 숫자 비교 (시간 차 없이)
func sameDigits(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var d: UInt8 = 0
    for i in x.indices { d |= x[i] ^ y[i] }
    return d == 0
}

/// 413 quota_exceeded → 안내 (두 번째 기기가 들어오기 전의 작은 용량이면 그것도)
func quotaText(_ h: SyncHTTPError) -> String {
    let err = h.body?["error"]
    let limit = err?["usage"]?.optInt("limit") ?? 50 * 1024 * 1024
    let mb = "\(Int((Double(limit) / (1024 * 1024)).rounded()))MB"
    return err?["provisional"] == .bool(true)
        ? "동기화 저장 공간(\(mb))이 가득 찼어요. 기기를 하나 더 연결하면 50MB 까지 쓸 수 있어요."
        : "동기화 저장 공간(\(mb))이 가득 찼어요."
}

/// 서버 오류 → 앱 말투의 안내 (서버의 message 는 그대로 보여 주지 않는다)
func serverText(_ h: SyncHTTPError) -> String {
    if h.status >= 500 { return "동기화 서버에 잠깐 문제가 있어요." }
    if h.status == 404 { return "동기화 서버에서 찾지 못한 것이 있어요." }
    if h.status == 409 { return "다른 기기와 부딪혀서 다음에 다시 보내요." }
    return "동기화 서버가 요청을 받지 않았어요 (\(h.code))."
}

/// 잠깐 뒤 다시 해 볼 만한 오류 (네트워크 · 5xx · 429)
func isTransient(_ e: any Error) -> Bool {
    if e is NetworkError { return true }
    if let h = e as? SyncHTTPError { return h.status >= 500 || h.status == 429 }
    return false
}

/// 다시 묻기까지 (429 면 Retry-After, 아니면 조금씩 늘려서)
func retryPause(_ e: any Error, _ base: Int) -> Int {
    if let h = e as? SyncHTTPError, h.status == 429, let ra = h.retryAfter, ra > 0 { return min(60_000, Int(ra * 1000)) }
    return min(10_000, base * 2)
}

/// Retry-After (초) → "30초" · "5분" · "2시간"
func waitText(_ sec: Double?) -> String {
    let n = max(1, Int((sec ?? 60).rounded(.up)))
    if n < 60 { return "\(n)초" }
    if n < 3600 { return "\(Int((Double(n) / 60).rounded(.up)))분" }
    return "\(Int((Double(n) / 3600).rounded(.up)))시간"
}

/// ms 만큼 기다린다 (Task 가 취소되면 바로)
func sleepMs(_ ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
}
