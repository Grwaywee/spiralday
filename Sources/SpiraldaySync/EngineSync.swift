// SyncEngine 의 한 바퀴: 비교(앱 → 상태) · 받기(서버 → 상태) · 보내기(상태 → 서버) · 넣기(상태 → 앱).
// cycle · scan · pull · pushAll · applyPending (모든 엔진이 같은 순서 · 같은 안전장치)
import Foundation

extension SyncEngine {
    // MARK: - 한 바퀴

    func cycle(scan: ScanHints?, pull: Bool, push: Bool, headPull: Bool = false) async {
        guard creds != nil, keys != nil else { return }
        if state == .removed || state == .groupGone { return }
        var scan = scan
        var pull = pull
        var push = push
        // {"head"} 로 온 받기는 그 사이 내 쓰기(ownSeqs)나 다른 받기로 이미 따라잡았으면 하지 않는다
        if headPull, !pull, headSeen > meta.head { pull = true }
        do {
            if !meta.imported {
                try await importAll()
                scan = .all
                pull = true
                push = true
            }
            if let scan { try await self.scan(scan, clock: hlc) }
            try await flush()
            let touchesServer = pull || push
            if touchesServer { setState(.syncing) }
            if pull { try await self.pull() }
            try await applyPending()
            // 확인되지 않은 초안을 대신 올릴 때가 됐으면 (받기가 먼저 확인해 준다)
            if adoptLive(), !touchesServer { requestPush() }
            if touchesServer { try await pushAll() }
            if touchesServer, meta.rename != nil { await retryRename() }
            try await applyPending()
            try await flush()
            if touchesServer {
                meta.lastSyncAt = now()
                metaTouched = true
                try await flush()
                backoff = 0
                retryAt = 0
                setState(.idle)
            }
            // 보내지 않은 바퀴(비교만)가 찾은 변경 → 상황별 지연 뒤에 보낸다. 새 변경을 찾지 못한 비교(저장 알림 · 주기 비교)는
            // "마지막 변경" 을 뒤로 밀지 않는다 (OLD-PEER · UNKNOWN · ALONE 이 저장 알림마다 늦어지지 않게)
            if !push, recs.values.contains(where: pushable) {
                if localDirty || pushFirstAt == nil { requestPush() } else { armPush() }
            }
            localDirty = false
            // 비교 · 넣기가 찾은 이 기기의 편집도 듣는 기기에 초안으로
            sendUnsent()
        } catch {
            try? await flush()
            onCycleError(error)
        }
    }

    func onCycleError(_ e: any Error) {
        if let h = e as? SyncHTTPError {
            // 빠짐은 서버가 "이 기기를 뺐다" 고 분명히 말할 때만 (device_removed · WS 4401). 그 밖의 401 은 서버 사고일 수
            // 있다 (배포 실수 등) → 자격을 지우지 않고 오류로 두고 다시 해 본다
            if h.status == 401, h.code == "device_removed" { return onFatal(.removed, "이 기기는 동기화 그룹에서 빠졌어요.") }
            if h.status == 401 {
                log(.error, "인증 실패 \(h.code)", h)
                setState(.error, "동기화 서버가 이 기기를 알아보지 못했어요.")
                return retryLater(max(60_000, backoff * 2))
            }
            // 경로가 없음(not_found)은 서버 주소 · 프록시 문제일 수 있다 → 그룹이 지워진 것으로 보지 않는다
            if h.status == 404, h.code == "group_not_found" {
                return onFatal(.groupGone, "서버에서 이 동기화 그룹을 찾지 못했어요.")
            }
            if h.status == 413 {
                if h.code == "quota_exceeded" { setState(.quota, quotaText(h)) } else { setState(.error, "보내려는 기록이 너무 커요.") }
                return retryLater(30 * 60_000)
            }
            if h.status == 429 {
                setState(.error, "요청이 많아 잠깐 쉬고 있어요.")
                return retryLater(Int((h.retryAfter ?? 60) * 1000))
            }
            log(.error, "서버 오류 \(h.status) \(h.code)", h)
            setState(.error, serverText(h))
            return retryLater()
        }
        if e is NetworkError {
            setState(.offline, nil)
            return retryLater()
        }
        log(.error, "동기화 중 오류", e)
        setState(.error, (e as? SyncEngineError)?.message ?? "동기화하다가 문제가 생겼어요.")
        retryLater()
    }

    /// 빠짐 · 그룹 없음 상태에서 동기화 정보를 지우기 전에 서버에 다시 묻는다.
    /// .ok 면 다시 동기화를 시작했다 (그 사이 서버가 돌아왔다). .removed · .groupGone 이면 확실하다. .unknown 은 서버에 닿지 못함
    public enum Recheck: Sendable { case ok, removed, groupGone, unknown }

    public func recheck() async -> Recheck {
        guard initialized, let c = creds else { return .unknown }
        do {
            _ = try await transport.groupInfo(Auth(gid: c.gid, token: c.token))
        } catch let h as SyncHTTPError where h.status == 401 && h.code == "device_removed" {
            return .removed
        } catch let h as SyncHTTPError where h.status == 404 && h.code == "group_not_found" {
            return .groupGone
        } catch {
            return .unknown
        }
        if state == .removed || state == .groupGone {
            state = .off
            running = false
            start()
        }
        return .ok
    }

    func retryLater(_ ms: Int? = nil) {
        backoff = ms ?? min(5 * 60_000, backoff > 0 ? backoff * 2 : 2000)
        retryAt = now() + backoff
        kick(pull: true, push: true, delay: backoff)
    }

    // MARK: - 레코드 장부

    func newRec(_ key: String, _ pk: ParsedKey) -> RecEntry {
        let e = RecEntry(key: key, pk: pk, rid: keys?.rid(key) ?? key)
        recs[key] = e
        byRid[e.rid] = e
        if let b = pk.bookId { byBook[b, default: []].insert(key) }
        return e
    }

    func rec(_ key: String) -> RecEntry {
        if let e = recs[key] { return e }
        guard let pk = RecordKeys.parse(key) else { preconditionFailure("레코드 키가 아님: \(key)") }
        return newRec(key, pk)
    }

    func touch(_ e: RecEntry) { touched.insert(e.key) }

    /// 바뀐 것을 동기화 저장소에. 쓰기는 부른 순서대로 하나씩 (flushLock) — 실시간 길과 바퀴가 함께 불러도 옛 값이 새 값을 덮지 않게
    func flush() async throws {
        guard initialized else { return }
        writing += 1
        await acquireFlush()
        defer {
            releaseFlush()
            writing -= 1
        }
        var put: [(String, JSONValue)] = []
        for k in touched {
            guard let e = recs[k] else { continue }
            put.append((k, e.stored))
        }
        let last = hlc.last
        if meta.hlc != last {
            meta.hlc = last
            metaTouched = true
        }
        if put.isEmpty, !metaTouched { return }
        touched = []
        let m = metaTouched ? meta.json : nil
        metaTouched = false
        try await storage.write(StorageBatch(meta: m, put: put))
    }

    // MARK: - 비교 (앱 → 상태)

    /// 한 레코드: 그림자와 지금 값을 비교해 바뀐 것을 상태에 합친다. 합친 조각(이 기기의 편집, 도장을 올린 뒤) 또는 nil.
    /// 이 기기의 진짜 편집(clock = HLC)이고 초안으로 오가는 레코드면 듣는 기기에 보낼 조각에 더한다
    @discardableResult
    func absorb(_ e: RecEntry, _ kind: RecordKind, _ cur: Flat, _ clock: StampSource) -> RecState? {
        let r = e.d.absorb(kind, cur, clock)
        if r.touched { touch(e) }
        guard let delta = r.delta else { return nil }
        localDirty = true
        draftOrUncovered(e.key, kind, delta, real: (clock as AnyObject) === hlc)
        return delta
    }

    /// 비교 하나. live = 실시간 길 (앱 메모리 값: 저장된 그림자를 남긴다), 아니면 바퀴의 비교 (앱이 저장했다고 알린 값)
    func diffKey(_ key: String, _ kind: RecordKind, _ cur: Flat, _ clock: StampSource, live: Bool = false) {
        guard let e0 = recs[key] else {
            // 처음 보는 레코드: 비어 있으면 만들지 않는다
            let delta = Records.diff(kind, prev: nil, cur: cur, clock: clock)
            if CRDT.isEmptyDelta(delta) { return }
            let e = rec(key)
            CRDT.mergeInto(&e.d.state, delta)
            e.d.shadow = cur
            e.d.dirty = true
            e.d.ver += 1
            if live { e.d.saved = .empty }
            touch(e)
            localDirty = true
            draftOrUncovered(key, kind, delta, real: (clock as AnyObject) === hlc)
            reconcile(e, kind, cur)
            return
        }
        let hadPend = e0.d.pend != nil
        let before = e0.d.shadow
        let delta = absorb(e0, kind, cur, clock)
        if live {
            if delta != nil, e0.d.saved == nil {
                e0.d.saved = SavedShadow(before)
                touch(e0)
            }
        } else if !savedHints, e0.d.saved != nil {
            // 저장 알림을 주지 않는 앱: 비교한 값이 파일 값이다 (예전 동작)
            e0.d.saved = nil
            touch(e0)
        }
        // 넣으려던 값(pend)과 앱 값이 다르다 = 넣기 전에 꺼졌거나 앱 파일이 실시간 상태보다 뒤처졌다 (저장 전에 꺼짐) →
        // 상태를 앱에 다시 넣는다 (그 값을 새 편집으로 올리지 않는다). pend 는 다음 넣기가 새로 적는다
        let stalePend = hadPend && e0.d.pend != nil
        if delta != nil || stalePend { reconcile(e0, kind, cur) }
        if stalePend {
            e0.d.pend = nil
            touch(e0)
        }
    }

    /// 앱의 편집을 상태에 합친 뒤: 상태로 만든 값이 앱 값과 뜻이 다르면 앱에 다시 넣는다.
    /// 쓰고 있는 칸은 양쪽 모두 앱 값으로 (그 칸 하나 때문에 넣지 않는다)
    func reconcile(_ e: RecEntry, _ kind: RecordKind, _ cur: Flat) {
        if e.d.state.x != nil || e.d.apply { return }
        let mine = Records.materialize(e.pk, Records.stateOfFlat(kind, cur))
        let want = Records.materialize(e.pk, protectedState(e.d.state, key: e.key, kind: kind, cur: cur, at: protectedAddress()).0)
        if mine == want { return }
        e.d.apply = true
        touch(e)
    }

    func scan(_ hints: ScanHints, clock: StampSource) async throws {
        guard let lib = await host.readLibrary() else {
            emit(.warning(.libraryUnreadable, message: "책장(library.json)을 읽을 수 없어 동기화 비교를 쉬어요."))
            return
        }
        let books = Records.syncedBooks(lib)
        if hints.has(RecordKeys.lib) { await scanLibrary(lib, clock) }
        for b in books {
            let id = JS.string(b["id"]).uppercased()
            if case .some = hints, !hints.has(id) { continue }
            if let brec = recs[RecordKeys.book(id)], brec.d.state.x != nil {
                // 다른 기기에서 지운 책 (곧 앱에서도 지운다). 이미 지웠는데 다시 나타났으면(백업에서 되살림 등) 알린다:
                // 지운 책은 되살아나지 않으므로 이 책은 이 기기에만 남는다
                if !brec.d.apply, warned.insert("gone:\(id)").inserted {
                    emit(.warning(.bookDeletedElsewhere, message: "‘\(JS.string(b["name"]))’ 플래너는 다른 기기에서 지운 플래너라 동기화하지 않아요. 이 기기에만 남아 있어요.", bookId: id))
                }
                continue
            }
            // 앱 값을 읽고 비교하는 동안 실시간 길이 이 책을 맞추지 않게 (옛 값으로 비교하면 방금 넣은 초안을 되돌린다)
            await acquireApp()
            let data = await host.readBook(id: id)
            if data != .unreadable { scanBook(id, data, clock) }
            releaseApp()
        }
        if hints.has(RecordKeys.lib), host.supportsSharedSettings, let s = await host.readSharedSettings() {
            diffKey(RecordKeys.lib, .lib, Records.flattenLib(s), clock)
        }
    }

    /// 책장 비교. 책장에서 사라진 책은 "지운 책" 일 때만 지움 표시(되살아나지 않고 모든 기기에서 지워진다)를 올린다.
    /// 앱은 책을 지울 때 책장에서 빼고 책 파일도 지우며, 한 번에 한 권씩 지운다. 그래서 아래는 잃은 것으로 보고 되살린다:
    /// 책 파일이 아직 있다 · 이번 실행에서 책장 파일을 새로 만들었고 그 전부터 알던 책 · 한 번에 두 권 넘게 사라짐
    func scanLibrary(_ lib: JSONValue, _ clock: StampSource) async {
        let books = Records.syncedBooks(lib)
        let ids = Set(books.map { JS.string($0["id"]).uppercased() })
        for b in books { diffKey(RecordKeys.book(JS.string(b["id"])), .book, Records.flattenBook(b), clock) }
        let known = recs.values.filter { $0.pk.kind == .book && $0.d.shadow != nil && $0.d.state.x == nil }
        let gone = known.filter { !ids.contains($0.pk.bookId!) }.sorted { $0.key < $1.key }
        if gone.isEmpty { return }
        let recreated = await host.libraryRecreated()
        var told: [RecEntry] = []
        var lost: [RecEntry] = []
        var deleted: [RecEntry] = []
        for e in gone {
            let id = e.pk.bookId!
            if deletedHint.contains(id) {
                told.append(e)
            } else if recreated, knownAtStart.contains(id) {
                lost.append(e)
            } else if await host.readBook(id: id) == .missing {
                // 'missing' 만 앱이 지운 것. 읽히거나(파일이 있음) 읽을 수 없는 것은 지운 것이 아니다
                deleted.append(e)
            } else {
                lost.append(e)
            }
        }
        if deleted.count >= 2 {
            lost += deleted
            deleted = []
        }
        if !lost.isEmpty {
            emit(lost.count >= 2
                ? .warning(.massDeleteBooks, message: "플래너 \(lost.count)권이 한꺼번에 책장에서 사라져서 지우지 않고 동기화된 내용으로 되살려요.")
                : .warning(.bookUnlisted, message: "책장에서 플래너 한 권이 사라졌는데 지운 것 같지 않아서 동기화된 내용으로 되살려요."))
            for e in lost { restoreBook(e.pk.bookId!) }
        }
        for e in told + deleted {
            deletedHint.remove(e.pk.bookId!)
            deleteBookLocal(e.pk.bookId!, clock)
        }
    }

    /// 책의 모든 레코드를 앱에 다시 넣도록 표시
    func restoreBook(_ bookId: String) {
        for k in byBook[bookId] ?? [] {
            guard let e = recs[k] else { continue }
            e.d.apply = true
            e.d.shadow = nil
            e.d.saved = nil
            touch(e)
        }
    }

    func deleteBookLocal(_ bookId: String, _ clock: StampSource) {
        var entries = (byBook[bookId] ?? []).sorted().compactMap { recs[$0] }
        // 서버에 간 적이 없어 보여도 지움 표시를 올린다: 응답만 잃은 쓰기가 서버에 닿았을 수 있다
        let x = clock.next()
        if recs[RecordKeys.book(bookId)] == nil { entries.append(rec(RecordKeys.book(bookId))) }
        for e in entries {
            CRDT.mergeInto(&e.d.state, RecState(x: x))
            e.d.shadow = nil
            e.d.saved = nil
            e.d.pend = nil
            e.d.apply = false
            e.d.dirty = true
            e.d.ver += 1
            touch(e)
        }
        pushUncovered = true
    }

    func scanBook(_ bookId: String, _ read: BookRead, _ clock: StampSource) {
        let keys = byBook[bookId] ?? []
        var data: JSONValue
        switch read {
        case let .ok(v): data = v
        case .unreadable: return
        case .missing:
            // 사용자가 지우는 중 (파일은 지웠고 책장은 곧 쓴다): 되살리지 않는다
            if deletedHint.contains(bookId) { return }
            let hasContent = keys.contains { k in
                guard let e = recs[k], e.pk.kind != .book, let sh = e.d.shadow else { return false }
                return !sh.s.isEmpty || sh.c.values.contains { !$0.isEmpty }
            }
            if hasContent {
                emit(.warning(.bookMissing, message: "플래너 파일이 사라져서 동기화된 내용으로 되살려요."))
                restoreBooks.insert(bookId)
                for k in keys {
                    guard let e = recs[k], e.pk.kind != .book else { continue }
                    e.d.apply = true
                    e.d.shadow = nil
                    e.d.saved = nil
                    touch(e)
                }
                return
            }
            data = PlannerModel.emptyPlannerData()
        }
        diffKey(RecordKeys.prefs(bookId), .prefs, Records.flattenPrefs(data["prefs"]), clock)
        let days = data["days"]?.objectValue ?? [:]
        let weeks = data["weeks"]?.objectValue ?? [:]
        // 사라진 날이 너무 많으면 지우지 않고 되살린다
        var vanished: [RecEntry] = []
        for k in keys.sorted() {
            guard let e = recs[k], e.pk.kind == .day, days[e.pk.date!] == nil, let sh = e.d.shadow, !Records.isEmptyFlat(sh) else { continue }
            vanished.append(e)
        }
        let guarded = vanished.count >= massDeleteDays
        if guarded {
            emit(.warning(.massDeleteDays, message: "하루 기록 \(vanished.count)개가 한꺼번에 사라져서 지우지 않고 되살려요."))
            for e in vanished {
                e.d.apply = true
                e.d.shadow = nil
                e.d.saved = nil
                touch(e)
            }
        }
        let skip = Set(guarded ? vanished.map(\.key) : [])
        var dates = Set(days.keys)
        for k in keys { if let e = recs[k], e.pk.kind == .day { dates.insert(e.pk.date!) } }
        for date in dates.sorted() {
            guard RecordKeys.isDateKey(date) else { continue }
            let key = RecordKeys.day(bookId, date)
            if skip.contains(key) { continue }
            diffKey(key, .day, Records.flattenDay(days[date]), clock)
        }
        var wdates = Set(weeks.keys)
        for k in keys { if let e = recs[k], e.pk.kind == .week { wdates.insert(e.pk.date!) } }
        for date in wdates.sorted() {
            guard RecordKeys.isDateKey(date) else { continue }
            diffKey(RecordKeys.week(bookId, date), .week, Records.flattenWeek(weeks[date]), clock)
        }
    }

    /// 그룹에 들어간 직후: 이 기기에 있던 것을 시각 0 도장으로 (그룹에 이미 있는 값이 이긴다)
    func importAll() async throws {
        guard await host.readLibrary() != nil else {
            throw SyncEngineError(.libraryUnavailable, "책장을 읽을 수 없어 동기화를 시작하지 못했어요.")
        }
        // 그룹을 만든 기기는 진짜 도장 (그룹의 첫 내용), 들어온 기기는 시각 0 도장
        let clock: StampSource = meta.importMode == .real ? hlc : ZeroClock(node: meta.nodeId)
        try await scan(.all, clock: clock)
        meta.imported = true
        metaTouched = true
        try await flush()
        syncLiveActive()
    }

    // MARK: - 받기 (서버 → 상태)

    /// 암호문 → (레코드 키, 상태). 모르는 payload 버전이면 UnknownVersion
    func decodeWithKey(_ rid: String, _ ct: String) throws -> (key: String, state: RecState) {
        guard let keys else { throw CryptoError("그룹 키가 없음") }
        let p = try keys.decryptRecord(rid: rid, ct: ct)
        guard case .object = p else { throw CryptoError("레코드 모양이 틀림") }
        guard p["v"] == .number(1) else { throw UnknownVersion(v: p["v"]) }
        guard case let .string(k)? = p["k"] else { throw CryptoError("레코드 모양이 틀림") }
        guard keys.rid(k) == rid else { throw CryptoError("레코드 키와 rid 가 맞지 않음") }
        return (k, try CRDT.parseState(p["s"]))
    }

    func decode(_ rid: String, _ ct: String, expectKey: String? = nil) throws -> RecState {
        let r = try decodeWithKey(rid, ct)
        if let expectKey, r.key != expectKey { throw CryptoError("다른 레코드") }
        return r.state
    }

    func pull() async throws {
        let a = try authOrThrow()
        lastPullAt = now()
        var since = meta.head
        // 서버에서 본 가장 큰 순번 (내가 쓴 것 포함). 서버 head 가 이보다 작으면 서버가 되돌려진 것
        var known = since
        for e in recs.values where e.d.seq > known { known = e.d.seq }
        for _ in 0..<10_000 {
            let res = try await transport.changes(a, since: since, limit: 500)
            if res.head < max(since, known) {
                known = 0
                // 서버가 되돌려졌다 (백업에서 복원 등): 처음부터 다시 받고, 서버에 없을 수 있는 것은 모두 다시 올린다
                log(.warn, "서버 head(\(res.head)) 가 내가 본 순번보다 작음 → 처음부터 다시")
                for e in recs.values {
                    e.d.seq = 0
                    if e.d.hasContent { e.d.dirty = true }
                    touch(e)
                }
                ownSeqs = []
                since = 0
                meta.head = 0
                metaTouched = true
                continue
            }
            for ch in res.changes { ingest(ch.rid, ch.seq, ch.ct) }
            let last = res.changes.last?.seq
            let more = res.more ?? (res.changes.count >= 500 && last != nil && last! < res.head)
            if let last { since = last }
            if !more || last == nil {
                meta.head = res.head
                metaTouched = true
                ownSeqs = ownSeqs.filter { $0 > res.head }
                advanceHead()
                break
            }
            meta.head = since
            metaTouched = true
            try await flush()
        }
    }

    func ingest(_ rid: String, _ seq: Int, _ ct: String) {
        let known = byRid[rid]
        if let known, known.d.seq >= seq { return }
        let key: String
        let remote: RecState
        do {
            (key, remote) = try decodeWithKey(rid, ct)
        } catch is UnknownVersion {
            emit(.warning(.updateRequired, message: "다른 기기의 새 버전 앱이 쓴 기록이 있어요. 앱을 업데이트해 주세요."))
            // 커서는 지나간다 → 이 엔진보다 새 엔진으로 켜면 처음부터 다시 받아 이 레코드를 읽는다
            if meta.skippedBelow == nil {
                meta.skippedBelow = PAYLOAD_VERSION
                metaTouched = true
            }
            known?.blocked = true
            return
        } catch {
            log(.error, "레코드를 풀지 못함 (\(rid.prefix(8))…)", error)
            emit(.warning(.undecryptable, message: "풀 수 없는 동기화 레코드가 있어 건너뛰었어요."))
            known?.blocked = true
            return
        }
        guard RecordKeys.parse(key) != nil else { return }
        observeRemote(remote)
        let e = known ?? rec(key)
        let wasDirty = e.d.dirty
        let changed = CRDT.mergeInto(&e.d.state, remote)
        e.d.seq = seq
        // 받은 초안 중 이 서버 버전이 확인해 준 것 (남은 것은 "올릴 이유" 가 아니다 — 보낸 기기가 올린다)
        let target = confirmLive(e, remote)
        if changed {
            e.d.apply = true
            e.d.ver += 1
            if !wasDirty, e.d.state != target { e.d.dirty = true }
        } else if wasDirty, e.d.state == target {
            // 서버의 지금 버전이 내 상태와 같다 (응답만 잃은 쓰기가 서버에 닿았던 것) → 다시 쓰지 않는다
            e.d.dirty = false
        }
        touch(e)
    }

    // MARK: - 보내기 (상태 → 서버)

    func encrypt(_ e: RecEntry) -> String {
        keys!.encryptRecord(rid: e.rid, payload: ["v": 1, "k": .string(e.key), "s": CRDT.toJSON(e.d.state)])
    }

    /// 보낼 레코드를 모두 보낸다: 여러 개면 batch(100개씩), 서버가 batch 를 모르면 하나씩 (동시에 몇 개)
    func pushAll() async throws {
        let a = try authOrThrow()
        for round in 0..<12 {
            let dirty = recs.values.filter(pushable).sorted { $0.key < $1.key }
            // 지금 밀린 것은 모두 이 보내기에 실린다: 그 뒤의 변경만 FAST · COVERED 를 다시 정한다
            if round == 0 { pushUncovered = false }
            if dirty.isEmpty { return }
            if dirty.count == 1 || !batchOk {
                try await pushEach(dirty.map(\.key))
                continue
            }
            // 100개 · 6 MiB 씩 묶기
            var quota: SyncHTTPError?
            var i = 0
            chunks: while i < dirty.count {
                var chunk: [(e: RecEntry, ver: Int, ct: String, sent: RecState?)] = []
                var bytes = 0
                while i < dirty.count, chunk.count < 100 {
                    let e = dirty[i]
                    let ct = encrypt(e)
                    if rejectTooLarge(e, ct) {
                        i += 1
                        continue
                    }
                    if !chunk.isEmpty, bytes + ct.utf8.count > 6 * 1024 * 1024 { break }
                    chunk.append((e, e.d.ver, ct, e.liveFrag != nil ? e.d.state : nil))
                    bytes += ct.utf8.count
                    i += 1
                }
                if chunk.isEmpty { continue }
                guard let res = try await transport.putRecords(a, chunk.map { RecordWrite(rid: $0.e.rid, baseSeq: $0.e.d.seq, ct: $0.ct, keep: $0.e.d.keep) }) else {
                    batchOk = false
                    break chunks
                }
                for (k, r) in res.results.enumerated() {
                    guard k < chunk.count, r.rid == chunk[k].e.rid else { continue }
                    let w = chunk[k]
                    switch r {
                    case let .error(_, code, limit, provisional):
                        if code == "quota_exceeded", quota == nil {
                            var err: [String: JSONValue] = ["code": "quota_exceeded", "provisional": .bool(provisional)]
                            if let limit { err["usage"] = ["limit": JSONValue(limit)] }
                            quota = SyncHTTPError(status: 413, code: "quota_exceeded", message: "그룹 저장 용량을 넘었습니다.", body: ["error": .object(err)])
                        }
                    case let .conflict(_, seq, ct):
                        onConflict(w.e, seq, ct)
                    case let .ok(_, seq):
                        w.e.d.seq = seq
                        if w.e.d.ver == w.ver { w.e.d.dirty = false }
                        w.e.d.keep = false
                        if let sent = w.sent { _ = confirmLive(w.e, sent) }
                        noteOwnSeq(seq)
                        touch(w.e)
                    }
                }
                if let quota { throw quota }
            }
        }
        if recs.values.contains(where: pushable) {
            throw SyncHTTPError(status: 409, code: "conflict", message: "계속 부딪혀서 다음에 다시 보내요")
        }
    }

    /// 보낼 수 있는 레코드: 바뀌었고, 서버 버전을 읽을 수 있고, 한도를 넘지 않는 것
    func pushable(_ e: RecEntry) -> Bool {
        e.d.dirty && !e.blocked && e.tooLarge != e.d.ver
    }

    /// 암호문이 서버 한도를 넘으면 이 ver 는 보내지 않는다 (서버는 413 으로 묶음 전체를 거절한다)
    func rejectTooLarge(_ e: RecEntry, _ ct: String) -> Bool {
        if ct.utf8.count * 3 / 4 <= MAX_RECORD_BYTES { return false }
        if e.tooLarge != e.d.ver {
            e.tooLarge = e.d.ver
            log(.warn, "레코드가 너무 큼 (\(e.key.split(separator: "/").first ?? ""), \(ct.utf8.count)자)")
            emit(.warning(.recordTooLarge, message: "하루 기록 하나가 너무 커서(1MB 넘음) 동기화하지 못했어요. 글을 줄이면 다시 보내요."))
        }
        return true
    }

    func pushEach(_ keys: [String]) async throws {
        var firstError: (any Error)?
        await withTaskGroup(of: (any Error)?.self) { group in
            var it = keys.makeIterator()
            for _ in 0..<min(concurrency, keys.count) {
                guard let k = it.next() else { break }
                group.addTask { await self.pushOneCatching(k) }
            }
            while let r = await group.next() {
                if let r, firstError == nil { firstError = r }
                if firstError == nil, let k = it.next() { group.addTask { await self.pushOneCatching(k) } }
            }
        }
        if let firstError { throw firstError }
    }

    func pushOneCatching(_ key: String) async -> (any Error)? {
        do {
            try await pushOne(key)
            return nil
        } catch {
            return error
        }
    }

    func pushOne(_ key: String) async throws {
        let a = try authOrThrow()
        for _ in 0..<12 {
            guard let e = recs[key], pushable(e) else { return }
            let ver = e.d.ver
            let ct = encrypt(e)
            if rejectTooLarge(e, ct) { return }
            // 보내는 동안 받은 초안은 이 쓰기에 없다 → 확인은 보낸 상태로만
            let sent = e.liveFrag != nil ? e.d.state : nil
            let r = try await transport.putRecord(a, RecordWrite(rid: e.rid, baseSeq: e.d.seq, ct: ct, keep: e.d.keep))
            switch r {
            case let .ok(seq):
                e.d.seq = seq
                if e.d.ver == ver { e.d.dirty = false }
                e.d.keep = false
                if let sent { _ = confirmLive(e, sent) }
                noteOwnSeq(seq)
                touch(e)
                return
            case let .conflict(seq, ct):
                onConflict(e, seq, ct)
            }
        }
        throw SyncHTTPError(status: 409, code: "conflict", message: "계속 부딪혀서 다음에 다시 보내요")
    }

    /// 409: 서버의 지금 버전과 합친다 (다음에 그 seq 위에 다시 보낸다)
    func onConflict(_ e: RecEntry, _ seq: Int, _ ct: String?) {
        e.d.seq = seq
        touch(e)
        guard let ct else { return }
        let remote: RecState
        do {
            remote = try decode(e.rid, ct, expectKey: e.key)
        } catch {
            // 풀 수 없는 서버 버전(새 버전 앱 · 손상)은 덮어쓰지 않는다
            e.blocked = true
            if error is UnknownVersion {
                emit(.warning(.updateRequired, message: "다른 기기의 새 버전 앱이 쓴 기록이 있어요. 앱을 업데이트해 주세요."))
            } else {
                emit(.warning(.undecryptable, message: "서버의 동기화 기록 하나를 풀 수 없어 그 기록은 보내지 않아요."))
            }
            return
        }
        observeRemote(remote)
        if CRDT.mergeInto(&e.d.state, remote) {
            e.d.apply = true
            e.d.ver += 1
        }
        if e.d.state == confirmLive(e, remote) { e.d.dirty = false }
    }

    /// 받은 상태의 도장을 시계에 알린다. 시계보다 하루 넘게 앞선 도장이면 (한 번) 알린다
    func observeRemote(_ remote: RecState) {
        guard let st = CRDT.maxStamp(in: remote), hlc.observe(st), warned.insert("clock-skew").inserted else { return }
        emit(.warning(.clockSkew, message: "다른 기기의 시계가 하루 넘게 앞서 있어요. 그 기기의 날짜와 시간을 확인해 주세요."))
    }

    // MARK: - 넣기 (상태 → 앱)

    func applyPending() async throws {
        var pending = recs.values.filter { $0.d.apply }.sorted { $0.key < $1.key }
        if pending.isEmpty { return }
        guard let lib = await host.readLibrary() else { return }
        // 아직 비교하지 않은 책장 편집(방금 지운 책 등)을 먼저 받아 둔다 — 지운 책을 다시 만들지 않게
        await scanLibrary(lib, hlc)
        var local: [String: JSONValue] = [:]
        for b in Records.books(lib) {
            guard case let .string(id)? = b["id"] else { continue }
            local[id.uppercased()] = b // 같은 id 가 둘이면 뒤의 것
        }
        let seen = Set(pending.map(\.key))
        for e in recs.values.sorted(by: { $0.key < $1.key }) where e.d.apply && !seen.contains(e.key) { pending.append(e) }
        var libRec: RecEntry?
        var order: [String] = []
        var byBookPending: [String: [RecEntry]] = [:]
        for e in pending {
            if e.pk.kind == .lib {
                libRec = e
            } else {
                let id = e.pk.bookId!
                if byBookPending[id] == nil { order.append(id) }
                byBookPending[id, default: []].append(e)
            }
        }
        var infoUpdates: [(String, JSONValue)] = []
        var removals: [String] = []
        var changedBooks: [String] = []
        for bookId in order {
            let entries = byBookPending[bookId]!
            let localBook = local[bookId]
            if localBook?["isSample"] == .bool(true) {
                for e in entries { e.d.apply = false }
                continue
            }
            let brec = recs[RecordKeys.book(bookId)]
            let info = brec.flatMap { Records.buildBook(bookId, $0.d.state) }
            if info == .deleted {
                if localBook != nil { removals.append(bookId) }
                for k in byBook[bookId] ?? [] {
                    guard let e = recs[k] else { continue }
                    e.d.apply = false
                    e.d.shadow = nil
                    e.d.saved = nil
                    e.d.pend = nil
                    touch(e)
                }
                continue
            }
            if localBook == nil, info == nil { continue } // 책 정보가 올 때까지 기다린다
            // 넣기 전에 다시 본다: 실시간 길이 그 사이 넣었을 수 있다
            let dataRecs = entries.filter { $0.pk.kind != .book && $0.d.apply }
            if !dataRecs.isEmpty || localBook == nil {
                // 앱 값을 읽고 넣는 동안 실시간 길이 이 책을 맞추지 않게
                await acquireApp()
                do {
                    // 넣으려는 값을 먼저 적어 둔다 (넣다가 꺼져도 편집으로 오해하지 않게)
                    for e in dataRecs {
                        e.d.pend = Records.flattenOf(e.pk, Records.materialize(e.pk, e.d.state))
                        touch(e)
                    }
                    try await flush()
                    let job = BookApplyJob(
                        bookId: bookId,
                        entries: dataRecs.map { EntrySnap(key: $0.key, pk: $0.pk, d: $0.d) },
                        deleteIfMissing: localBook != nil && !restoreBooks.contains(bookId),
                        prefsKnown: recs[RecordKeys.prefs(bookId)] != nil,
                        clock: hlc,
                        protection: protectionProbe())
                    try await host.updateBook(id: bookId) { cur in job.run(cur) }
                    let needsRescan = commit(job)
                    releaseApp()
                    changedBooks.append(bookId)
                    restoreBooks.remove(bookId)
                    if needsRescan { kick(scan: .some([bookId]), push: true, delay: 50) }
                } catch {
                    releaseApp()
                    throw error
                }
            }
            if let brec, case let .book(v)? = info, brec.d.apply || localBook == nil { infoUpdates.append((bookId, v)) }
        }
        var libraryChanged = false
        if !infoUpdates.isEmpty || !removals.isEmpty {
            let job = LibraryApplyJob(
                updates: infoUpdates,
                entries: infoUpdates.compactMap { recs[RecordKeys.book($0.0)] }.map { EntrySnap(key: $0.key, pk: $0.pk, d: $0.d) },
                removals: removals,
                clock: hlc)
            try await host.updateLibrary { cur in job.run(cur) }
            if let out = job.output() {
                for (key, o) in out { if let e = recs[key] { commitApplied(e, o, live: false) } }
            }
            libraryChanged = true
            for id in removals { try await host.updateBook(id: id) { _ in nil } }
        }
        if let e = libRec, host.supportsSharedSettings {
            let job = SettingsApplyJob(entry: EntrySnap(key: e.key, pk: e.pk, d: e.d), clock: hlc)
            try await host.updateSharedSettings { cur in job.run(cur) }
            if let o = job.output() { commitApplied(e, o, live: false) }
        } else if let e = libRec {
            e.d.apply = false
            touch(e)
        }
        try await flush()
        if !changedBooks.isEmpty || libraryChanged {
            var seenB = Set<String>()
            let books = (changedBooks + removals).filter { seenB.insert($0).inserted }
            emit(.applied(books: books, library: libraryChanged))
        }
    }

    /// 앱에 넣은 결과를 장부에 돌려놓는다. 다시 비교할 책이면 true
    func commit(_ job: BookApplyJob) -> Bool {
        guard let out = job.output() else { return false }
        for (key, o) in out.entries { if let e = recs[key] { commitApplied(e, o, live: false) } }
        if let sh = out.newPrefsShadow {
            let e = rec(RecordKeys.prefs(job.bookId))
            e.d.shadow = sh
            touch(e)
        }
        return out.rescan
    }
}

// MARK: - 앱에 넣는 일 (호스트가 자기 차례에 부르는 순수 계산)

struct EntrySnap: Sendable {
    let key: String
    let pk: ParsedKey
    var d: RecData
}

/// 책 한 권에 넣기: 넣는 순간의 앱 값을 먼저 비교(그 사이의 편집을 상태에 합침) → 상태(쓰고 있는 칸은 앱 값) → 앱 값 → 그림자 = 넣은 값.
/// 엔진의 장부는 바꾸지 않는다 — 결과(AppliedRec)를 엔진이 돌려놓는다 (그 사이 온 초안 · 받기를 덮지 않게)
final class BookApplyJob: @unchecked Sendable {
    struct Output {
        var entries: [(String, AppliedRec)]
        var rescan: Bool
        var newPrefsShadow: Flat?
    }

    let bookId: String
    let entries: [EntrySnap]
    let deleteIfMissing: Bool
    let prefsKnown: Bool
    let clock: HLC
    let protection: @Sendable () -> FieldAddress?
    private let lock = NSLock()
    private var out: Output?

    init(bookId: String, entries: [EntrySnap], deleteIfMissing: Bool, prefsKnown: Bool, clock: HLC, protection: @escaping @Sendable () -> FieldAddress?) {
        self.bookId = bookId
        self.entries = entries
        self.deleteIfMissing = deleteIfMissing
        self.prefsKnown = prefsKnown
        self.clock = clock
        self.protection = protection
    }

    func output() -> Output? { lock.withLock { out } }

    func run(_ cur: JSONValue?) -> JSONValue? {
        lock.withLock {
            // 있던 책인데 파일이 없어졌다 = 그 사이에 지운 것 (되살리기로 한 책이 아니면 만들지 않는다)
            if cur == nil, deleteIfMissing { return nil }
            var data = cur ?? PlannerModel.emptyPlannerData()
            var results: [(String, AppliedRec)] = []
            var rescan = false
            let at = protection()
            for w in entries {
                var d = w.d
                let pk = w.pk
                let (value, o) = d.applyTo(pk, key: w.key, appValue: recordValue(pk, inBook: data), clock: clock, protectedAt: at)
                if o.applied {
                    switch pk.kind {
                    case .day: data = Records.withDay(data, pk.date!, value)
                    case .week: data = Records.withWeek(data, pk.date!, value)
                    case .prefs: if case let .object(p)? = value { data = Records.withPrefs(data, p) }
                    default: break
                    }
                }
                if o.rescan { rescan = true }
                results.append((w.key, o))
            }
            var o = Output(entries: results, rescan: rescan, newPrefsShadow: nil)
            // 새로 만든 책의 기본 설정은 편집이 아니다
            if cur == nil, !prefsKnown { o.newPrefsShadow = Records.flattenPrefs(data["prefs"]) }
            out = o
            return data
        }
    }
}

/// 책장에 넣기: 책 정보 바꾸기 · 새 책 더하기 (만든 때 순서로, 예시 플래너 앞에) · 지운 책 빼기
final class LibraryApplyJob: @unchecked Sendable {
    let updates: [(String, JSONValue)]
    let entries: [EntrySnap]
    let removals: [String]
    let clock: HLC
    private let lock = NSLock()
    private var out: [(String, AppliedRec)]?

    init(updates: [(String, JSONValue)], entries: [EntrySnap], removals: [String], clock: HLC) {
        self.updates = updates
        self.entries = entries
        self.removals = removals
        self.clock = clock
    }

    func output() -> [(String, AppliedRec)]? { lock.withLock { out } }

    func run(_ cur: JSONValue) -> JSONValue {
        lock.withLock {
            var results: [(String, AppliedRec)] = []
            var books = Records.books(cur)
            for (id, info0) in updates {
                guard var w = entries.first(where: { $0.key == RecordKeys.book(id) }) else { continue }
                var o = AppliedRec()
                o.before = w.d.shadow
                o.real = true
                var info = info0
                if let idx = books.firstIndex(where: { JS.string($0["id"]).uppercased() == id }) {
                    o.delta = w.d.absorb(.book, Records.flattenBook(books[idx]), clock).delta
                    guard case let .book(b)? = Records.buildBook(id, w.d.state) else { continue }
                    info = b
                    var next = info.objectValue ?? [:]
                    if let s = books[idx]["isSample"], JS.truthy(s) { next["isSample"] = s }
                    books[idx] = .object(next)
                } else {
                    // 만든 때 순서로, 예시 플래너 앞에
                    func rank(_ b: JSONValue) -> String { JS.string(b["created"]) + "\u{0}" + JS.string(b["id"]).uppercased() }
                    let r = rank(info)
                    let at = books.firstIndex { JS.truthy($0["isSample"]) || JS.less(r, rank($0)) } ?? books.count
                    books.insert(info, at: at)
                }
                o.shadow = Records.flattenBook(info)
                o.applied = true
                o.builtFrom = w.d.state
                results.append((w.key, o))
            }
            if !removals.isEmpty {
                let gone = Set(removals)
                books = books.filter { !gone.contains(JS.string($0["id"]).uppercased()) }
            }
            out = results
            var o = cur.objectValue ?? [:]
            o["books"] = .array(books)
            return .object(o)
        }
    }
}

/// 책장 수준 공유 설정 넣기
final class SettingsApplyJob: @unchecked Sendable {
    let entry: EntrySnap
    let clock: HLC
    private let lock = NSLock()
    private var out: AppliedRec?

    init(entry: EntrySnap, clock: HLC) {
        self.entry = entry
        self.clock = clock
    }

    func output() -> AppliedRec? { lock.withLock { out } }

    func run(_ cur: JSONValue) -> JSONValue {
        lock.withLock {
            var d = entry.d
            var o = AppliedRec()
            o.before = d.shadow
            o.delta = d.absorb(.lib, Records.flattenLib(cur), clock).delta
            let built = Records.buildLib(d.state)
            o.shadow = Records.flattenLib(built)
            o.applied = true
            o.builtFrom = d.state
            out = o
            return built
        }
    }
}
