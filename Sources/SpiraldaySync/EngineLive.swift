// 실시간 쓰기 (live drafts, Docs/SpiraldaySync.md §7): 글자 하나 · 칠한 칸 하나 단위로 다른 기기에 바로.
//
//   앱 입력마다 liveEdit(keys) → (50 ms 앞·뒤 묶음) 그 레코드만 앱 메모리 값으로 비교 → 바뀐 조각에 HLC 도장 → 상태에 합침(보낼 것)
//   → 듣는 기기가 있으면 봉인한 초안 {"draft","q"} 을 WebSocket 으로. 서버는 저장하지 않고 같은 그룹의 다른 기기에만 건넨다.
//   받은 초안은 보낸 기기의 도장 그대로 상태에 합치고(올릴 이유가 아니다 — dirty 없음) 열린 책에 바로 넣는다 (host.applyLive).
//   나중에 보낸 기기의 레코드가 오면 같은 도장이라 바뀌는 것이 없다. 30초 안에 확인되지 않으면 받은 기기가 대신 올린다.
// 이 길은 바퀴(locked) 밖에서 돈다 (네트워크 중인 바퀴 뒤에 서면 초안이 몇 초 늦는다). 앱 값을 읽고 비교하거나 앱에 넣는 일은
// appLock 으로 하나씩 — 그림자가 앱 값과 어긋나지 않게 (바퀴의 비교 · 넣기도 같은 잠금을 쓴다).
import Foundation

/// 초안으로 오가는 레코드 종류
let LIVE_KINDS: Set<RecordKind> = [.day, .week, .prefs]
/// 클라이언트 버킷 (서버 25/초 · 40, 128 Ki자/초 · 256 Ki 보다 늘 작게 — Docs/SpiraldaySync.md §7.6)
let LIVE_MSG_RATE = 20.0
let LIVE_MSG_BURST = 20.0
let LIVE_CHAR_RATE = 96.0 * 1024
let LIVE_CHAR_BURST = 192.0 * 1024
/// 초안 하나의 remote-typing 주소 최대 수
let LIVE_MAX_ADDRESSES = 64
/// 보내기 대기가 찬 연결에 다시 보내 보는 간격의 상한 (ms)
let LIVE_SEND_BACKOFF_MAX = 2000

extension SyncEngine {
    // MARK: - 잠금

    func acquireApp() async {
        if !appLock.held {
            appLock.held = true
            return
        }
        await withCheckedContinuation { appLock.waiters.append($0) }
    }

    func releaseApp() {
        if appLock.waiters.isEmpty { appLock.held = false } else { appLock.waiters.removeFirst().resume() }
    }

    func acquireFlush() async {
        if !flushLock.held {
            flushLock.held = true
            return
        }
        await withCheckedContinuation { flushLock.waiters.append($0) }
    }

    func releaseFlush() {
        if flushLock.waiters.isEmpty { flushLock.held = false } else { flushLock.waiters.removeFirst().resume() }
    }

    // MARK: - 앱이 부르는 것 (Docs/SpiraldaySync.md §7.1)

    /// 앱의 메모리 값이 방금 바뀌었다 (키 입력 · IME 조합 한 단계 · 칠하기 한 칸 · 표시 바꾸기 …). 메인 스레드에서 기다리지 않고 부른다.
    /// keys = 바뀐 레코드 키 — 열린 책의 RecordKeys.day · week · prefs (다른 종류는 무시). 엔진은 그 레코드만 host.readLive 로 읽어
    /// 그림자와 비교 → 바뀐 조각에 도장 → 상태에 합침(보낼 것) → 듣는 기기가 있으면 봉인한 초안으로 보낸다.
    /// 첫 입력은 바로, 그 뒤는 liveThrottleMs(50 ms) 묶음 (마지막 값은 꼭). 그룹 밖 · 멈춤 · 처음 가져오기 전이면 아무것도 하지 않는다 (네트워크 0).
    /// 이 부름이 곧 "사용자가 치는 중" 이다: 쓰고 있는 칸(setEditing)은 **그 칸의 레코드를 바꾼** 마지막 liveEdit 부터 editingGraceMs 동안만
    /// 지킨다 (칸마다 — 다른 칸에서 치다 옮겨 온 칸은 그 칸에서 칠 때까지 지키지 않는다)
    public nonisolated func liveEdit(_ keys: [String]) {
        let ks = keys.compactMap { k -> String? in
            guard let n = normalizeKey(k), let pk = RecordKeys.parse(n), LIVE_KINDS.contains(pk.kind) else { return nil }
            return n
        }
        if liveBox.noteEdit(ks, now: nowFn()) { Task { await self.drainLive() } }
    }

    /// 사용자가 쓰고 있는 칸 (캐럿이 있는 곳, 없으면 nil). 메인 스레드에서 기다리지 않고 부른다.
    /// 사용자가 그 칸에 쓰는 중인 동안(그 칸에서의 마지막 liveEdit 부터 editingGraceMs) 그 칸은 들어오는 변경(초안 · 레코드)으로 덮지 않고,
    /// 그림자도 앱 값으로 둔다 (그래서 다시 올리지 않는다 — 핑퐁 없음). 포커스만 있는 칸(그 칸에서 치지 않았거나 그 뒤 editingGraceMs 가 지남)은
    /// 지키지 않는다: 다른 기기의 더 새 글이 바로 들어간다. 다른 칸 · nil 로 바뀌거나 지키는 시간이 끝나면 미뤄 둔 레코드를 다시 맞춘다
    /// (상대의 마지막 입력이 더 나중이면 상대 글).
    /// 쓰기를 마친 뒤 정리(빈 할 일 지우기 등)를 하는 앱은 setEditingAndSettle(nil) 을 기다린 뒤 정리한다 — 미뤄 둔 상대 글을 보고 정리하게
    public nonisolated func setEditing(_ at: FieldAddress?) {
        if liveBox.setEditing(normalizeAddress(at)) { Task { await self.drainLive() } }
    }

    /// setEditing 과 같고, 미뤄 둔 칸을 다시 맞춰 앱에 넣을 때까지 기다린다 (쓰기를 마친 뒤의 정리 앞에).
    /// 앞서 부른 setEditing 이 시작한 다시 맞추기가 아직 앱 값을 다루는 중이면 그것도 끝날 때까지 기다린다 — 앱은 $editingKey 구독이
    /// setEditing(nil) 을 먼저 부르고 이어서 이것을 기다리는데, 그때 먼저 돌아오면 정리가 미뤄 둔 상대 글이 들어가기 전의 값을 보고 지운다
    public func setEditingAndSettle(_ at: FieldAddress?) async {
        _ = liveBox.setEditing(normalizeAddress(at))
        await drainLive()
        while releasing > 0 { await withCheckedContinuation { releaseWaiters.append($0) } }
        // 묶어 둔 넣기(liveApplyMs)를 기다리는 받은 초안도 지금 — 정리가 아직 넣지 않은 상대 글(빈 할 일에 막 쓴 글)을 보지 못하고 지우지 않게
        await applyLiveNow()
    }

    /// 쓰고 있는 칸(setEditing)을 지금 지키는지 (그 칸에서의 마지막 liveEdit 부터 editingGraceMs 가 지나지 않았다). 쓰고 있는 칸이 없으면 nil.
    /// 앱이 엔진 밖에서 칸을 지키는 안전망은 이 값을 따라야 한다 — 엔진보다 더 지키면 옛 글이 새 도장을 얻어 더 새 글을 덮는다
    public nonisolated var editingProtected: Bool? {
        guard liveBox.currentEditing != nil else { return nil }
        return liveBox.protected(now: nowFn(), grace: editingGraceMs) != nil
    }

    /// 실시간 편집을 지금 바로: 남은 liveEdit 를 처리하고, 못 보낸 초안을 보내고, 동기화 저장소에 쓴다 (앱이 파일을 쓰기 전 · 닫기 전 · 테스트)
    public func flushLive() async {
        guard initialized else { return }
        await drainLive()
        if !liveKeys.isEmpty { await liveTick() } else { sendUnsent() }
        do { try await flush(durable: false) } catch { log(.warn, "실시간 편집을 저장하지 못함", error) }
    }

    /// 동기화 저장소가 메모리보다 뒤처져 있는지 (아직 비교하지 않은 liveEdit · 쓰지 않았거나 쓰는 중인 상태). 그렇다면 앱은 책 파일을
    /// 쓰기 전에 flushLive() 를 기다린다 — 파일이 엔진 저장소보다 앞선 채 꺼지면 다시 켤 때 그 값(받은 초안 · 친 글)을 이 기기의 새
    /// 도장으로 올려 다른 기기의 더 새 글을 덮는다 (Docs/SpiraldaySync.md §7.7). false 면 기다릴 것 없이 바로 쓴다
    public var storageBehind: Bool {
        initialized && (!liveKeys.isEmpty || liveBox.hasKeys || !touched.isEmpty || writing > 0 || liveFlushTask != nil
            || !liveApplyQueue.isEmpty || liveApplyTask != nil)
    }

    /// 아직 서버로 가지 않은 이 기기의 편집이 있는지 (비교 전인 것 포함) — 창을 닫기 · 뒤로 가기 전에 sendPending 을 기다릴지
    public var hasUnsent: Bool {
        guard initialized, creds != nil, running else { return false }
        return !liveKeys.isEmpty || liveBox.hasKeys || scanHints != nil || pushFirstAt != nil || recs.values.contains(where: pushable)
    }

    /// 밀린 변경을 지금 보낸다 (창을 닫기 전 · 앱이 뒤로 갈 때): 남은 liveEdit · 저장 알림을 비교하고, 보낼 것이 있으면 바로 보낸다.
    /// 보낼 것이 없으면 네트워크 0. 오류는 상태로 (다음에 다시 보낸다 — 엔진 저장소에 남아 있다)
    public func sendPending() async {
        guard initialized, creds != nil, running else { return }
        await flushLive()
        let hints = takeHints()
        scanTimer?.cancel()
        scanTimer = nil
        if let hints { await locked { await cycle(scan: hints, pull: false, push: false) } }
        guard recs.values.contains(where: pushable) else { return }
        pushTimer?.cancel()
        pushTimer = nil
        pushFirstAt = nil
        pushLastAt = 0
        pushUncovered = false
        await locked { await cycle(scan: nil, pull: false, push: true) }
    }

    // MARK: - 상태

    /// (테스트) 실시간 길에 남은 일이 없다: 가져가지 않은 liveEdit · 도는 틱 · 넣을 초안 · 저장 예약이 없다
    var liveQuiet: Bool {
        liveKeys.isEmpty && !liveBox.hasKeys && liveTickTask == nil && liveApplyTask == nil && liveApplyQueue.isEmpty && liveFlushTask == nil && writing == 0
    }

    /// (테스트) 레코드 하나의 장부를 글로
    func debugRecord(_ key: String) -> String {
        guard let e = recs[key] else { return "(없음)" }
        return "state=\(CRDT.toJSON(e.d.state).canonical) shadow=\(e.d.shadow?.json.canonical ?? "nil") pend=\(e.d.pend?.json.canonical ?? "nil") saved=\(String(describing: e.d.saved)) dirty=\(e.d.dirty) apply=\(e.d.apply) held=\(e.d.held) frag=\(e.liveFrag.map { CRDT.toJSON($0).canonical } ?? "nil") seq=\(e.d.seq)"
    }

    /// 실시간 길을 돌릴 수 있는지: 그룹 안 · 돌고 있음 · 처음 가져오기를 마침
    func liveReady() -> Bool {
        initialized && creds != nil && keys != nil && running && meta.imported && state != .removed && state != .groupGone
    }

    /// LiveBox 가 키를 모을지 맞춘다 (돌지 않으면 네트워크 0)
    func syncLiveActive() { liveBox.setActive(liveReady()) }

    /// 초안을 들을 기기가 있는지 (이 연결에서 서버가 중계하고, 초안을 받는 다른 기기가 있다)
    func listening() -> Bool {
        guard liveOn, socket != nil, live, let p = presenceV else { return false }
        return p.relay && p.live > 0
    }

    /// 실시간으로 다루는 책: 이 기기에서 동기화하는 책 (예시 플래너 · 지운 책 · 아직 비교하지 않은 새 책은 바퀴의 비교로)
    func liveBookOk(_ bookId: String) -> Bool {
        guard let b = recs[RecordKeys.book(bookId)] else { return false }
        return b.d.state.x == nil && b.d.shadow != nil && !deletedHint.contains(bookId)
    }

    /// 그룹이 바뀔 때: 실시간 · 보내기 기억을 비운다
    func resetLive() {
        liveKeys = []
        liveUnsent = [:]
        liveUnsentOrder = []
        liveApplyQueue = []
        ownSeqs = []
        headSeen = 0
        pushFirstAt = nil
        pushLastAt = 0
        pushUncovered = false
        editingSeen = nil
        heldAt = nil
        liveSendBackoff = 0
        liveBox.reset()
        syncLiveActive()
    }

    /// 지금 지키는 칸 (쓰고 있고 editingGraceMs 안에 쳤다)
    func protectedAddress() -> FieldAddress? { liveBox.protected(now: now(), grace: editingGraceMs) }

    // MARK: - liveEdit · setEditing 가져오기

    func drainLive() async {
        let t = liveBox.take()
        if t.editing != editingSeen {
            // 쓰고 있는 칸이 바뀌었다: 그 전 칸의 레코드에 미뤄 둔 상대 글이 있으면 상태의 승자로 (LWW)
            let prev = editingSeen
            editingSeen = t.editing
            if let prev { await releaseHeld(prev.key) }
            noteHeld()
        }
        if heldAt != nil { armHeldRelease() }
        guard liveReady() else { return }
        liveKeys.formUnion(t.keys)
        if !liveKeys.isEmpty { scheduleLiveTick() }
    }

    func scheduleLiveTick() {
        guard liveTickTask == nil else { return }
        // 앞 묶음: 첫 입력은 바로 · 뒤 묶음: 마지막 값은 꼭
        let wait = auto ? liveLastTick + liveThrottleMs - now() : 0
        liveTickTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            if Task.isCancelled { return }
            await self?.runLiveTick()
        }
    }

    func runLiveTick() async {
        await liveTick()
        liveTickTask = nil
        if !liveKeys.isEmpty { scheduleLiveTick() }
    }

    /// 묶음 하나: 모인 레코드 키를 책마다 읽어 비교 → 보내기 예약 · 초안
    func liveTick() async {
        liveLastTick = now()
        let ks = liveKeys
        liveKeys = []
        guard liveReady(), !ks.isEmpty else { return }
        var byBookKeys: [String: [String]] = [:]
        for k in ks.sorted() {
            guard let id = RecordKeys.parse(k)?.bookId else { continue }
            byBookKeys[id, default: []].append(k)
        }
        for bookId in byBookKeys.keys.sorted() {
            guard liveBookOk(bookId) else { continue }
            await acquireApp()
            if liveReady(), let values = await readLiveValues(bookId, byBookKeys[bookId]!), liveReady() {
                await liveAbsorb(bookId, byBookKeys[bookId]!, values)
            }
            releaseApp()
        }
        afterLive()
    }

    /// 열린 책의 레코드 값 (호스트의 메모리 값). 레코드 키 → 앱 값 (없는 날 · 주는 .null). 읽을 수 없으면 nil
    func readLiveValues(_ bookId: String, _ ks: [String]) async -> [String: JSONValue]? {
        if let v = await host.readLive(bookId: bookId, keys: ks) {
            var out: [String: JSONValue] = [:]
            for k in ks { out[k] = v[k] ?? v[k.lowercased()] ?? .null }
            return out
        }
        guard case let .ok(data) = await host.readBook(id: bookId) else { return nil }
        var out: [String: JSONValue] = [:]
        for k in ks {
            guard let pk = RecordKeys.parse(k) else { continue }
            out[k] = recordValue(pk, inBook: data) ?? .null
        }
        return out
    }

    /// 앱 메모리 값 → 그 레코드들 비교 (저장된 그림자를 남긴다). appLock 안에서
    func liveAbsorb(_ bookId: String, _ ks: [String], _ values: [String: JSONValue]) async {
        var apply: [RecEntry] = []
        for key in ks {
            guard let pk = RecordKeys.parse(key) else { continue }
            diffKey(key, pk.kind, Records.flattenOf(pk, liveValue(values[key])), hlc, live: true)
            // 숨겨진 상태 값 때문에 앱 값을 다시 맞춰야 한다 (reconcile) → 바로
            if let e = recs[key], e.d.apply { apply.append(e) }
        }
        for e in apply { await applyLiveLocked(e) }
    }

    /// 실시간 길 끝: 보내기 예약 · 저장 예약 · 초안
    func afterLive() {
        if localDirty {
            localDirty = false
            requestPush()
            scheduleLiveFlush()
        }
        sendUnsent()
    }

    // MARK: - 초안 보내기 (Docs/SpiraldaySync.md §7.5)

    /// 이 기기의 편집 조각: 듣는 기기가 있으면 초안으로, 아니면 "초안으로 가지 않은 변경" (FAST 로 보낸다)
    func draftOrUncovered(_ key: String, _ kind: RecordKind, _ delta: RecState, real: Bool) {
        if real, LIVE_KINDS.contains(kind), listening() { queueDraft(key, delta) } else { pushUncovered = true }
    }

    /// 이 기기의 편집 조각을 그 레코드의 안 보낸 조각에 합친다 (듣는 기기가 있을 때만)
    func queueDraft(_ key: String, _ delta: RecState) {
        guard listening() else { return }
        if liveUnsent[key] == nil {
            liveUnsent[key] = RecState()
            liveUnsentOrder.append(key)
        }
        CRDT.mergeInto(&liveUnsent[key]!, delta)
    }

    /// 안 보낸 조각을 봉인해 보낸다 (레코드 하나 = 프레임 하나). 버킷 · 보내기 대기가 허락하지 않으면 남겨 두고 다음 틱에
    /// 그 뒤 조각과 합쳐 다시 (새 항목의 a 를 건너뛰고 글자 조각만 가는 일이 없게). 너무 크면 버린다 (레코드가 가져간다).
    /// 버킷 · 보내기 대기는 봉인하기 전에 본다 (찬 연결에 봉인 · 도장을 버리지 않게). 보내기 대기가 찬 채로 이어지면(반쯤 열린 셀룰러
    /// 연결 — 보내기 완료가 오지 않는다) 다시 보내 보는 간격을 50 ms → 100 → … 2초로 늘린다
    func sendUnsent() {
        if liveUnsent.isEmpty { return }
        guard listening(), let sock = socket, let keys, let creds else {
            liveUnsent = [:]
            liveUnsentOrder = []
            return
        }
        refillBucket()
        var bufferFull = false
        for key in liveUnsentOrder {
            guard let st = liveUnsent[key] else { continue }
            if bucket.msgs < 1 {
                counters.deferred += 1
                break
            }
            if !sock.canSendDraft {
                counters.deferred += 1
                bufferFull = true
                break
            }
            let q = hlc.next()
            guard let c = keys.sealDraft(key: key, state: st, gid: creds.gid, from: creds.deviceId, q: q) else {
                removeUnsent(key)
                counters.tooLarge += 1
                pushUncovered = true
                armPush()
                log(.debug, "초안이 너무 커서 레코드로만 보냄")
                continue
            }
            let cost = Double(c.utf8.count + q.utf8.count + 16)
            if bucket.chars < cost {
                counters.deferred += 1
                break
            }
            if !sock.sendDraft(c, q: q) {
                counters.deferred += 1
                bufferFull = true
                break
            }
            bucket.msgs -= 1
            bucket.chars -= cost
            removeUnsent(key)
            counters.sent += 1
            liveSendBackoff = 0
        }
        if liveUnsent.isEmpty {
            liveSendBackoff = 0
            return
        }
        guard auto, liveSendTimer == nil else { return }
        var ms = liveThrottleMs
        if bufferFull {
            liveSendBackoff = min(LIVE_SEND_BACKOFF_MAX, max(liveThrottleMs, liveSendBackoff * 2))
            ms = liveSendBackoff
        }
        liveSendTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return }
            await self?.liveSendFired()
        }
    }

    func liveSendFired() {
        liveSendTimer = nil
        sendUnsent()
    }

    func removeUnsent(_ key: String) {
        liveUnsent[key] = nil
        liveUnsentOrder.removeAll { $0 == key }
    }

    func refillBucket() {
        let t = now()
        let dt = Double(max(0, t - bucket.at)) / 1000
        bucket.at = t
        bucket.msgs = min(LIVE_MSG_BURST, bucket.msgs + dt * LIVE_MSG_RATE)
        bucket.chars = min(LIVE_CHAR_BURST, bucket.chars + dt * LIVE_CHAR_RATE)
    }

    /// 실시간으로 바뀐 상태를 곧 저장소에 (앱이 죽어도 엔진에 남게 — 오프라인 대기열). 첫 변경은 바로, 그 뒤는 간격을 두고
    /// (마지막 것은 꼭): 이 기기의 편집은 liveFlushMs, 받기만 한 변경(받은 조각 · 재생 거르기 표 · 저장된 그림자)은 liveReceiveFlushMs —
    /// 받은 것은 보낸 기기의 레코드가 다시 가져오므로 늦게 써도 잃지 않는다. 저전력 모드면 3배. 실시간 묶음은 fsync 하지 않는다.
    /// 앱 파일(0.6초 묶음 저장)이 엔진 저장소보다 앞서면 안 된다 — 앞선 채 꺼지면 다시 켤 때 그 파일 값(받은 초안 · 친 글)을 이 기기의
    /// 새 도장으로 올려 그 사이 다른 기기의 더 새 글을 덮는다. 간격을 늘리는 앱은 파일을 쓰기 전에 storageBehind → flushLive() 를 꼭 기다린다
    /// (Docs/SpiraldaySync.md §7.7)
    func scheduleLiveFlush(received: Bool = false) {
        guard initialized, running else { return }
        let gap = (received ? liveReceiveFlushMs : liveFlushMs) * (lowPower() ? 3 : 1)
        let t = now()
        let due = auto ? max(t, lastLiveFlushAt + gap) : t
        if liveFlushTask != nil, liveFlushDue <= due { return }
        liveFlushTask?.cancel()
        liveFlushDue = due
        let wait = due - t
        liveFlushTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            if Task.isCancelled { return }
            await self?.liveFlushFired()
        }
    }

    func liveFlushFired() async {
        liveFlushTask = nil
        liveFlushDue = Int.max
        lastLiveFlushAt = now()
        // 바퀴(locked)를 기다리지 않는다 (느린 네트워크 바퀴 뒤에 서지 않게). 쓰기는 부른 순서대로 간다 (flushLock)
        do { try await flush(durable: false) } catch { log(.warn, "실시간 편집을 저장하지 못함", error) }
        // 쓰는 동안 바뀌었는데 예약이 없다: 받기만 한 것으로 (이 기기의 편집은 그때 afterLive 가 그 간격으로 예약했다)
        if liveFlushTask == nil, !touched.isEmpty || metaTouched { scheduleLiveFlush(received: true) }
    }

    // MARK: - presence

    func setPresence(_ next: LivePresence?) {
        let prev = presenceV
        if prev == next { return }
        presenceV = next
        if !listening() {
            liveUnsent = [:]
            liveUnsentOrder = []
        }
        emitLive(.presence(next))
        emit(.status(status))
        if pushFirstAt != nil {
            // 기기가 새로 켜졌다 → 밀린 것을 바로 (곧바로 최신을 받게). 아니면 새 상황의 지연으로
            if let next, next.peers > (prev?.peers ?? 0) { firePush() } else { armPush() }
        }
    }

    // MARK: - 보내기 시점 (Docs/SpiraldaySync.md §7.4)

    /// 이 기기의 변경을 상태에 합쳤다 → 상황별 지연 뒤에 보낸다
    func requestPush() {
        guard auto, running else { return }
        let t = now()
        if pushFirstAt == nil { pushFirstAt = t }
        pushLastAt = t
        armPush()
    }

    func armPush() {
        guard let first = pushFirstAt, auto, running else { return }
        let mode = PushMode.of(presenceV)
        // COVERED 는 밀린 변경이 모두 초안으로 갔을 때만 (초안으로 가지 않은 변경은 레코드가 처음 알린다 → FAST)
        let at = delays.dueAt(mode == .covered && pushUncovered ? .fast : mode, firstAt: first, lastAt: pushLastAt)
        if pushTimer != nil, pushTimerAt == at { return }
        pushTimer?.cancel()
        pushTimerAt = at
        let wait = max(0, at - now())
        pushTimer = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            if Task.isCancelled { return }
            await self?.firePush()
        }
    }

    func firePush() {
        pushTimer?.cancel()
        pushTimer = nil
        pushFirstAt = nil
        pushLastAt = 0
        pushUncovered = false
        kick(push: true, delay: 0)
    }

    /// 서버 head 가 내가 본 것보다 크다 → 곧 받기 (받기 시작 사이 최소 간격)
    func kickHeadPull() {
        let wait = max(headPullDelayMs, lastPullAt + minPullIntervalMs - now())
        kick(headPull: true, delay: max(0, wait))
    }

    /// 내가 쓴 순번 → head + 1 이 내 것인 동안 head 를 올린다 (그 사이에 남의 쓰기는 없다 — 순번은 빈틈없이 오른다)
    func noteOwnSeq(_ seq: Int) {
        if seq <= meta.head { return }
        ownSeqs.insert(seq)
        advanceHead()
    }

    func advanceHead() {
        var moved = false
        while ownSeqs.contains(meta.head + 1) {
            ownSeqs.remove(meta.head + 1)
            meta.head += 1
            moved = true
        }
        if moved { metaTouched = true }
    }

    // MARK: - 초안 받기 (Docs/SpiraldaySync.md §7.6 · §7.7)

    /// {draft, q, from}: 받는 쪽 검사 (Docs/SpiraldaySync.md §7.6 — 하나라도 틀리면 조용히 버린다, 레코드 경로가 남는다)
    func onDraft(draft: String, q: String, from: String) {
        func drop(_ why: String) {
            counters.dropped += 1
            log(.debug, "초안을 버림 (\(why))")
        }
        guard Draft.isDraft(draft), Stamps.isStamp(q), isId22(from) else { return drop("shape") }
        guard liveOn, liveReady(), let creds, let keys else { return drop("not-ready") }
        if from == creds.deviceId { return drop("self") }
        // 재생 거르기: 기기마다 마지막으로 받아들인 q (저장된다) 보다 커야 한다. q 의 시각을 이 기기의 벽시계와 견주지 않는다 —
        // 시계가 다른 기기(듀얼부트의 현지시각 RTC 등)의 초안을 모두 버리게 된다. 처음 보는 기기의 옛 초안은 옛 도장이라
        // 상태를 되돌리지 못한다 (LWW). Docs/SpiraldaySync.md §7.6
        if let seen = meta.liveSeen[from], !JS.less(seen, q) { return drop("replay") }
        let d: (key: String, state: RecState)
        do {
            d = try keys.openDraft(draft, gid: creds.gid, from: from, q: q)
        } catch {
            return drop("open")
        }
        noteSeen(from, q)
        counters.received += 1
        applyDraft(d.key, d.state, from: from)
    }

    func noteSeen(_ from: String, _ q: Stamp) {
        meta.liveSeen[from] = q
        if meta.liveSeen.count > LIVE_SEEN_MAX {
            let drop = meta.liveSeen.sorted { JS.less($0.value, $1.value) }.prefix(meta.liveSeen.count - LIVE_SEEN_MAX)
            for (id, _) in drop { meta.liveSeen[id] = nil }
        }
        metaTouched = true
        scheduleLiveFlush(received: true)
    }

    /// 받은 초안 = 다른 기기의 진짜 편집: 보낸 기기의 도장 그대로 상태에 합친다. dirty · ver 는 건드리지 않는다
    /// (올릴 이유가 아니다 — 보낸 기기가 레코드로 올리고, 같은 도장이라 그때 바뀌는 것이 없다). 확인 대기(liveFrag)에 적고 앱에 바로 넣는다
    func applyDraft(_ key: String, _ s0: RecState, from: String) {
        guard let pk = RecordKeys.parse(key), let bookId = pk.bookId else { return }
        if let brec = recs[RecordKeys.book(bookId)], brec.d.state.x != nil { return } // 지운 책
        let known = recs[key]
        if let known, known.d.state.x != nil || known.blocked { return }
        // 이 기기가 모르는 항목의 필드만 온 것(그 항목을 더한 초안을 놓쳤다)은 버린다 — 반쪽 항목을 보이지 않게. 레코드가 가져온다
        var s = s0
        dropOrphans(&s, have: known?.d.state)
        if CRDT.isEmptyDelta(s) { return }
        let e = known ?? rec(key)
        observeRemote(s)
        guard CRDT.mergeInto(&e.d.state, s) else { return } // 중복 · 더 옛것
        // 앱에 넣을 것으로 적어 둔다 (넣기는 곧 따로 — 그 전에 저장되고 꺼져도 다시 켤 때 넣는다). 넣으면 commitApplied 가 내린다
        e.d.apply = true
        if e.liveFrag == nil { e.liveFrag = RecState() }
        CRDT.mergeInto(&e.liveFrag!, s)
        let t = now()
        for p in fragPaths(s) { e.liveTimes[p] = t }
        touch(e)
        scheduleLiveFlush(received: true)
        armAdopt(known: true)
        let at = addressesOf(key, s)
        let editing = liveBox.currentEditing.map { ed in at.contains { overlaps(ed, $0) } } ?? false
        emitLive(.remoteTyping(from: from, at: at, editing: editing))
        enqueueLiveApply(key)
    }

    /// 넣을 레코드로 적고 넣기를 예약한다: 첫 초안은 바로, 그 뒤는 liveApplyMs 간격으로 (저전력 모드면 2배) — 그 사이에 온 초안은
    /// 상태에 이미 합쳐져 다음 넣기에 함께 간다 (초당 20번 오는 초안마다 메인 스레드가 JSON 왕복 · 종이 다시 그리기를 하지 않게)
    func enqueueLiveApply(_ key: String) {
        if !liveApplyQueue.contains(key) { liveApplyQueue.append(key) }
        guard liveApplyTask == nil else { return }
        let gap = liveApplyMs * (lowPower() ? 2 : 1)
        let wait = auto ? lastLiveApplyAt + gap - now() : 0
        liveApplyTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            if Task.isCancelled { return }
            await self?.drainLiveApply()
        }
    }

    /// 묶어 두고 기다리는 넣기를 지금 (쓰기를 마친 뒤의 정리 앞)
    func applyLiveNow() async {
        guard !liveApplyQueue.isEmpty else { return }
        liveApplyTask?.cancel()
        liveApplyTask = nil
        await drainLiveApply()
    }

    /// 받은 초안을 앱에 넣는다 (레코드마다 한 번 — 그 사이 더 온 초안은 함께)
    func drainLiveApply() async {
        lastLiveApplyAt = now()
        while !liveApplyQueue.isEmpty {
            let key = liveApplyQueue.removeFirst()
            // 다 끝낸 엔진은 앱에 넣지 않는다 (넣을 것은 apply 로 저장소에 남아 다음 실행이 넣는다)
            guard !disposed, let e = recs[key] else { continue }
            await acquireApp()
            if recs[key] === e { await applyLiveLocked(e) }
            releaseApp()
            afterLive()
        }
        liveApplyTask = nil
    }

    /// 레코드 하나를 앱에 바로 (appLock 안에서): 열린 책이면 host.applyLive (메모리에만, 파일은 앱이 보통처럼). 열려 있지 않거나
    /// 호스트가 받지 않으면 보통 넣기(updateBook)로 미룬다 — 닫힌 책 파일을 초당 20번 쓰지 않게 (대개 그 전에 레코드가 와서 한 번에 넣는다)
    func applyLiveLocked(_ e: RecEntry) async {
        guard let bookId = e.pk.bookId else { return }
        if liveBookOk(bookId), LIVE_KINDS.contains(e.pk.kind) {
            let job = LiveApplyJob(entry: EntrySnap(key: e.key, pk: e.pk, d: e.d), clock: hlc, protection: protectionProbe())
            let ok = await host.applyLive(bookId: bookId, keys: [e.key]) { cur in job.run(cur) }
            guard recs[e.key] === e else { return }
            if ok, let out = job.output() {
                commitApplied(e, out, live: true)
                touch(e)
                // 앱 메모리가 앞섰다 (저장된 그림자 · pend) → 앱 파일보다 먼저 엔진 저장소에 (이 기기의 편집을 함께 받아들였으면 그 간격으로)
                scheduleLiveFlush(received: out.delta == nil)
                emitLive(.applied(bookId: bookId))
                return
            }
        }
        e.d.apply = true
        touch(e)
        kick(delay: 2000)
    }

    /// 앱에 넣는 일(호스트의 차례)이 그 순간 지킬 칸을 묻는 함수
    nonisolated func protectionProbe() -> @Sendable () -> FieldAddress? {
        let box = liveBox
        let nowFn = nowFn
        let grace = editingGraceMs
        return { box.protected(now: nowFn(), grace: grace) }
    }

    /// 앱에 넣은 결과를 장부에 돌려놓는다 — 넣는 동안 바뀐 것(그 사이 온 초안 · 받기)을 덮지 않게 변경분만:
    /// 넣기 직전에 받아들인 이 기기의 편집은 합치고, 그림자 = 넣은 값, 상태가 그 사이 더 나아갔으면 다시 넣을 것으로
    func commitApplied(_ e: RecEntry, _ out: AppliedRec, live: Bool) {
        if let delta = out.delta {
            CRDT.mergeInto(&e.d.state, delta)
            e.d.dirty = true
            e.d.ver += 1
            localDirty = true
            draftOrUncovered(e.key, e.pk.kind, delta, real: out.real)
        }
        if out.applied {
            e.d.shadow = out.shadow
            if live {
                if e.d.saved == nil { e.d.saved = SavedShadow(out.before) }
            } else {
                e.d.saved = nil
            }
            if e.d.held != out.held {
                e.d.held = out.held
                noteHeld()
            }
        }
        e.d.pend = nil
        e.d.apply = e.d.state != out.builtFrom
        touch(e)
    }

    // MARK: - 확인 대기 · 대신 올리기 (Docs/SpiraldaySync.md §7.7)

    /// 확인 대기가 있는 동안 5초마다: 대신 올릴 때가 된 레코드가 있으면 받기 → (확인되지 않았으면) 대신 올리기
    func armAdopt(known: Bool = false) {
        guard auto, running, liveAdoptTimer == nil else { return }
        if !known, !recs.values.contains(where: { $0.liveFrag != nil }) { return }
        liveAdoptTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                guard let self, await self.adoptTick() else { return }
            }
        }
    }

    func adoptTick() -> Bool {
        let frags = recs.values.filter { $0.liveFrag != nil }
        if frags.isEmpty {
            liveAdoptTimer = nil
            return false
        }
        let t = now()
        if frags.contains(where: { adoptDue($0, t) }) { kick(pull: true, push: true, delay: 0) }
        return true
    }

    /// 보낸 기기가 liveAdoptMs 안에 레코드로 확인해 주지 않은 초안 (저장 전에 죽었거나 HTTP 가 막혔다) → 이 기기가 대신 올린다:
    /// 가진 상태(보낸 기기의 원래 도장 그대로)를 dirty 로. 이미 올렸으면 409 → 합치기 → 같으면 쓰기 없음
    func adoptLive() -> Bool {
        let t = now()
        var any = false
        for e in recs.values {
            guard let f = e.liveFrag else { continue }
            if CRDT.isEmptyDelta(f) {
                e.liveFrag = nil
                e.liveTimes = [:]
                touch(e)
                continue
            }
            guard adoptDue(e, t) else { continue }
            e.liveFrag = nil
            e.liveTimes = [:]
            if e.d.state.x == nil, !e.blocked {
                e.d.dirty = true
                e.d.ver += 1
                any = true
                counters.adopted += 1
            }
            touch(e)
        }
        return any
    }

    /// 확인되지 않은 경로 중 하나라도 liveAdoptMs 넘게 새 초안이 없었다
    func adoptDue(_ e: RecEntry, _ t: Int) -> Bool {
        guard let f = e.liveFrag else { return false }
        for p in fragPaths(f) where (e.liveTimes[p] ?? 0) + liveAdoptMs <= t { return true }
        return false
    }

    /// R(서버 버전 · 내가 올린 상태)이 덮는 초안 조각을 지운다. 돌려주는 값 = R ∪ 아직 확인되지 않은 조각 —
    /// 상태가 이것과 같으면 이 기기가 올릴 것은 없다 (남은 것은 다른 기기의 초안뿐)
    func confirmLive(_ e: RecEntry, _ r: RecState) -> RecState {
        guard var f = e.liveFrag else { return r }
        CRDT.dropCovered(&f, by: r)
        if CRDT.isEmptyDelta(f) {
            e.liveFrag = nil
            e.liveTimes = [:]
            return r
        }
        e.liveFrag = f
        // 확인된 경로의 시각은 버린다
        let keep = Set(fragPaths(f))
        e.liveTimes = e.liveTimes.filter { keep.contains($0.key) }
        return CRDT.merge(r, f)
    }

    // MARK: - 쓰고 있는 칸 (Docs/SpiraldaySync.md §7.7)

    /// 미뤄 둔(held) 레코드를 상태의 승자로 다시 맞춘다: 마지막 내 글을 받아들이고 (더 나중이면 내 글), 다르면 앱에 넣는다
    func releaseHeld(_ key: String) async {
        guard let e = recs[key], liveReady(), let bookId = e.pk.bookId, liveBookOk(bookId) else { return }
        releasing += 1
        defer {
            releasing -= 1
            if releasing == 0, !releaseWaiters.isEmpty {
                let w = releaseWaiters
                releaseWaiters = []
                for c in w { c.resume() }
            }
        }
        await acquireApp()
        if liveReady(), recs[key] === e, let values = await readLiveValues(bookId, [key]), recs[key] === e {
            let cur = Records.flattenOf(e.pk, liveValue(values[key]))
            await liveAbsorb(bookId, [key], values)
            if e.d.held {
                e.d.held = false
                touch(e)
            }
            reconcile(e, e.pk.kind, cur)
            if e.d.apply { await applyLiveLocked(e) }
        }
        releaseApp()
        afterLive()
        noteHeld()
    }

    /// 미뤄 둔 레코드 (쓰던 칸 · 멈춘 동안 다시 맞추지 못한 것)
    func heldKeys() -> [String] { recs.values.filter { $0.d.held }.map(\.key).sorted() }

    /// 미뤄 둔 레코드를 모두 다시 맞춘다 (지키는 칸이 있으면 그 레코드는 빼고)
    func releaseAllHeld() async {
        let p = protectedAddress()
        for key in heldKeys() where key != p?.key { await releaseHeld(key) }
    }

    /// 지키는 시간이 끝날 때 미뤄 둔 칸을 다시 맞춘다 (그 사이에 또 치면 다시 잰다)
    func armHeldRelease() {
        guard auto, running else { return }
        heldTimer?.cancel()
        let t = now()
        let wait = max(0, (liveBox.protectedUntil(now: t, grace: editingGraceMs) ?? t) - t) + 20
        heldTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            if Task.isCancelled { return }
            await self?.heldTimerFired()
        }
    }

    func heldTimerFired() async {
        heldTimer = nil
        await releaseAllHeld()
        // 아직 지키는 칸의 레코드가 미뤄져 있다 (그 사이에 또 쳤다) → 지키는 시간이 끝날 때 다시 (다시 맞추지 못한 것 — 책이 닫힘 ·
        // 멈춤 — 은 칸이 바뀔 때 · 다시 켤 때 맞춘다: 여기서 되풀이하지 않는다)
        if let p = protectedAddress(), recs[p.key]?.d.held == true { armHeldRelease() }
    }

    /// 다시 돌기 시작할 때 (start · resume): 멈춘 동안(앱이 뒤로 감 · 잠자기) 지키는 시간을 잴 타이머가 없었다 → 미뤄 둔 칸을 다시 맞춘다
    /// (지키는 시간이 끝났으면 바로). 쓰던 칸이 아직 미뤄져 있으면 held 를 다시 알린다 — 앱은 뒤로 가며 힌트를 지웠다.
    /// 그대로 두면 돌아와 같은 칸에 친 글자가 옛 글과 함께 새 도장을 얻어 그 사이 다른 기기의 글을 덮는다
    func resumeHeld() {
        guard recs.values.contains(where: { $0.d.held }) else { return }
        if let h = heldAt { emitLive(.held(h)) }
        armHeldRelease()
    }

    /// held 이벤트: 쓰고 있는 칸의 레코드가 미뤄져 있는지가 바뀌면
    func noteHeld() {
        let ed = liveBox.currentEditing
        let at: FieldAddress? = ed.flatMap { recs[$0.key]?.d.held == true ? $0 : nil }
        if at == heldAt { return }
        heldAt = at
        if at != nil {
            armHeldRelease()
        } else {
            heldTimer?.cancel()
            heldTimer = nil
        }
        emitLive(.held(at))
    }

    // MARK: - 저장 알림 (Docs/SpiraldaySync.md §7.7)

    /// 앱이 파일에 다 쓴 값 → 앞서 있던 레코드의 저장된 그림자를 앞으로 (같아지면 앞섬 끝)
    func noteSaved(_ bookId: String, _ saved: @Sendable () -> JSONValue?) {
        savedHints = true
        let ahead = (byBook[bookId] ?? []).sorted().compactMap { recs[$0] }.filter { $0.d.saved != nil }
        guard !ahead.isEmpty, let data = saved() else { return }
        for e in ahead {
            guard LIVE_KINDS.contains(e.pk.kind) else { continue }
            let flat = Records.flattenOf(e.pk, recordValue(e.pk, inBook: data))
            e.d.saved = e.d.shadow == flat ? nil : .value(flat)
            touch(e)
        }
        scheduleLiveFlush(received: true)
    }
}

// MARK: - 실시간으로 앱에 넣는 일 (호스트가 자기 차례에 부르는 순수 계산)

/// 레코드 하나를 앱에 넣은 결과 (엔진은 이것으로 장부를 고친다 — commitApplied)
struct AppliedRec: Sendable {
    /// 넣기 직전 앱 값에서 받아들인 이 기기의 편집 (도장을 올린 뒤)
    var delta: RecState?
    /// 그 편집이 진짜 시계의 것 (초안으로 보낼 수 있다)
    var real = true
    /// 앱 값을 넣었다 (지운 레코드 · 모르는 종류는 넣지 않는다)
    var applied = false
    /// 넣은 값의 평평한 모양 (= 새 그림자)
    var shadow: Flat?
    /// 넣기 전 그림자 (저장된 그림자를 처음 남길 때)
    var before: Flat?
    /// 보호 칸 때문에 상태와 다른 값을 두었다
    var held = false
    /// 넣은 값을 만든 상태 (넣는 동안 엔진의 상태가 더 나아갔으면 다시 넣는다)
    var builtFrom = RecState()
}

extension RecData {
    /// 레코드 하나를 앱 값으로: 그 순간의 앱 값을 먼저 비교해(그 사이의 편집을 잃지 않게 — absorbBeforeApply) 상태에 합치고,
    /// 쓰고 있는 칸(protectedAt)은 앱 값 그대로 둔다 (그림자도 앱 값 — 다시 올리지 않는다). fresh = 이 기기에 없던 책 (비교하지 않는다).
    /// 돌려주는 값: 넣을 앱 값 (하루 · 한 주 = 레코드 JSON 또는 nil, 설정 = 상태로 만든 prefs)
    mutating func applyTo(_ pk: ParsedKey, key: String, appValue: JSONValue?, clock: StampSource, protectedAt: FieldAddress?, fresh: Bool = false) -> (value: JSONValue?, out: AppliedRec) {
        var out = AppliedRec()
        out.before = shadow
        out.real = clock is HLC
        var value: JSONValue?
        switch pk.kind {
        case .day, .week:
            let app = Records.flattenOf(pk, appValue)
            (out.delta, out.real) = absorbBeforeApply(pk.kind, app, clock, fresh: fresh)
            let (st, held) = protectedState(state, key: key, kind: pk.kind, cur: app, at: protectedAt)
            value = pk.kind == .day ? Records.buildDay(st) : Records.buildWeek(st)
            out.shadow = Records.flattenOf(pk, value)
            out.held = held
            out.applied = true
        case .prefs:
            if state.x == nil {
                let app = Records.flattenPrefs(appValue)
                (out.delta, out.real) = absorbBeforeApply(.prefs, app, clock, fresh: fresh)
                let (st, held) = protectedState(state, key: key, kind: .prefs, cur: app, at: protectedAt)
                let built = Records.buildPrefs(st)
                value = .object(built)
                // 형광펜이 없으면(설정 안 됨) 그림자도 빈 목록 — 앱이 채운 기본 형광펜은 비교가 설정 안 됨으로 본다 (§4.1)
                out.shadow = Records.flattenPrefs(.object(built))
                out.held = held
                out.applied = true
            }
        default:
            break
        }
        apply = false
        pend = nil
        out.builtFrom = state
        return (value, out)
    }
}

/// 열린 책의 레코드 하나에 실시간으로 넣기 (host.applyLive 의 transform)
final class LiveApplyJob: @unchecked Sendable {
    let entry: EntrySnap
    let clock: HLC
    let protection: @Sendable () -> FieldAddress?
    private let lock = NSLock()
    private var out: AppliedRec?

    init(entry: EntrySnap, clock: HLC, protection: @escaping @Sendable () -> FieldAddress?) {
        self.entry = entry
        self.clock = clock
        self.protection = protection
    }

    func output() -> AppliedRec? { lock.withLock { out } }

    func run(_ cur: [String: JSONValue]) -> [String: JSONValue] {
        lock.withLock {
            var d = entry.d
            let app = liveValue(cur[entry.key])
            let (value, o) = d.applyTo(entry.pk, key: entry.key, appValue: app, clock: clock, protectedAt: protection())
            out = o
            var next = cur
            guard o.applied else { return next }
            if entry.pk.kind == .prefs, case let .object(p)? = value {
                // 기기마다 따로인 값(lastKind · ddaysPerDay)은 지금 것 · 형광펜이 없으면 앱의 기본값 (updateBook 과 같은 규칙)
                next[entry.key] = Records.withPrefs(["prefs": app ?? .object([:])], p)["prefs"] ?? .object(p)
            } else {
                next[entry.key] = value ?? .null
            }
            return next
        }
    }
}

// MARK: - 도우미

/// 앱 값 하나 (.null = 없음)
func liveValue(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
}

/// 책 JSON(PlannerData) 에서 레코드 하나의 앱 값 (하루 · 한 주 · 설정만)
func recordValue(_ pk: ParsedKey, inBook data: JSONValue) -> JSONValue? {
    switch pk.kind {
    case .day: return liveValue(data["days"]?[pk.date!])
    case .week: return liveValue(data["weeks"]?[pk.date!])
    case .prefs: return liveValue(data["prefs"])
    default: return nil
    }
}

/// 기기 id · 그룹 id 모양 (base64url 22자)
func isId22(_ s: String) -> Bool {
    let u = s.utf8
    return u.count == 22 && u.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }
}

/// 레코드 키 (책 id 의 대소문자를 맞춘다). 모양이 틀리면 nil
func normalizeKey(_ k: String) -> String? {
    if k == RecordKeys.lib { return k }
    let u = Array(k.utf8)
    guard u.count == 38 || u.count == 49 else { return nil }
    let fixed = String(decoding: u[0..<2], as: UTF8.self) + String(decoding: u[2..<38], as: UTF8.self).uppercased() + String(decoding: u[38...], as: UTF8.self)
    return RecordKeys.parse(fixed) != nil ? fixed : nil
}

/// 앱이 넘긴 칸 주소를 맞춘다 (하루 · 한 주 · 책 설정의 단일 필드 · 항목만). 모르는 모양이면 nil
func normalizeAddress(_ at: FieldAddress?) -> FieldAddress? {
    guard let at, let key = normalizeKey(at.key), let pk = RecordKeys.parse(key), LIVE_KINDS.contains(pk.kind) else { return nil }
    if let coll = at.coll {
        guard let item0 = at.item, !item0.isEmpty else { return nil }
        let item = RecordKeys.isUuid(item0) ? item0.uppercased() : item0
        if let f = at.field, !f.isEmpty { return FieldAddress(key: key, coll: coll, item: item, field: f) }
        return FieldAddress(key: key, coll: coll, item: item)
    }
    guard let f = at.field, !f.isEmpty else { return nil }
    return FieldAddress(key: key, field: f)
}

/// 내가 쓰고 있는 칸(ed)과 초안이 바꾼 곳(a)이 겹치는지
func overlaps(_ ed: FieldAddress, _ a: FieldAddress) -> Bool {
    if ed.key != a.key { return false }
    guard let coll = ed.coll else { return a.coll == nil && a.field == ed.field }
    return a.coll == coll && a.item == ed.item && (ed.field == nil || a.field == nil || a.field == ed.field)
}

/// 조각이 바꾼 곳 (remote-typing). 너무 많으면 앞의 것만
func addressesOf(_ key: String, _ s: RecState) -> [FieldAddress] {
    var out: [FieldAddress] = []
    for f in JS.sortedKeys(s.f) {
        if out.count >= LIVE_MAX_ADDRESSES { return out }
        out.append(FieldAddress(key: key, field: f))
    }
    for name in JS.sortedKeys(s.c) {
        guard let coll = FieldAddress.ItemCollection(rawValue: name) else { continue }
        let items = s.c[name]!
        for id in JS.sortedKeys(items) {
            let it = items[id]!
            if it.f.isEmpty {
                if out.count >= LIVE_MAX_ADDRESSES { return out }
                out.append(FieldAddress(key: key, coll: coll, item: id))
            }
            for f in JS.sortedKeys(it.f) {
                if out.count >= LIVE_MAX_ADDRESSES { return out }
                out.append(FieldAddress(key: key, coll: coll, item: id, field: f))
            }
        }
    }
    return out
}

/// 이 기기 상태에 없는 항목의 필드만 담긴 조각 항목 (더한 a · 지운 d 가 없음)을 뺀다
func dropOrphans(_ s: inout RecState, have: RecState?) {
    for name in Array(s.c.keys) {
        var items = s.c[name]!
        for (id, it) in items where it.a.isEmpty && it.d == nil && have?.c[name]?[id] == nil {
            items[id] = nil
        }
        if items.isEmpty { s.c[name] = nil } else { s.c[name] = items }
    }
}

/// 조각의 경로들 (확인 대기의 단위): f:<필드> · c:<모음>/<id>/@a · @d · <필드>
func fragPaths(_ s: RecState) -> [String] {
    var out: [String] = []
    for k in JS.sortedKeys(s.f) { out.append("f:\(k)") }
    for name in JS.sortedKeys(s.c) {
        let items = s.c[name]!
        for id in JS.sortedKeys(items) {
            let it = items[id]!
            if !it.a.isEmpty { out.append("c:\(name)/\(id)/@a") }
            if it.d != nil { out.append("c:\(name)/\(id)/@d") }
            for k in JS.sortedKeys(it.f) { out.append("c:\(name)/\(id)/\(k)") }
        }
    }
    return out
}

/// 쓰고 있는 칸(at)이 이 레코드에 있으면 그 칸만 앱 값으로 바꾼 상태 (넣기 · 비교용 복사본)와 바꿨는지. 아니면 상태 그대로.
/// 상태에서 지워진 항목은 지워진 대로 (그 칸을 쓰고 있어도)
func protectedState(_ state: RecState, key: String, kind: RecordKind, cur: Flat, at p: FieldAddress?) -> (RecState, Bool) {
    guard let p, p.key == key, state.x == nil else { return (state, false) }
    let schema = Records.schema(kind)
    guard let coll = p.coll else {
        guard let f = p.field else { return (state, false) }
        let appV = cur.s[f] ?? schema.scalarDefault(f)
        let entry = state.f[f]
        if appV == (entry?.value ?? schema.scalarDefault(f)) { return (state, false) }
        var st = state
        st.f[f] = FieldEntry(appV, entry?.stamp ?? "")
        return (st, true)
    }
    guard let item = p.item, let it = state.c[coll.rawValue]?[item], it.isAlive,
          let appItem = cur.c[coll.rawValue]?.first(where: { $0.id == item }) else { return (state, false) }
    let defs = schema.items.first(where: { $0.0 == coll.rawValue })?.1 ?? [:]
    var st: RecState?
    let fields = p.field.map { [$0] } ?? JS.sortedKeys(appItem.f)
    for f in fields {
        let appV = appItem.f[f] ?? defs[f] ?? .null
        let entry = it.f[f]
        if appV == (entry?.value ?? defs[f] ?? .null) { continue }
        if st == nil { st = state }
        st!.c[coll.rawValue]![item]!.f[f] = FieldEntry(appV, entry?.stamp ?? it.a)
    }
    return st.map { ($0, true) } ?? (state, false)
}
