import XCTest
import AppKit
import SwiftUI
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// Mac 앱의 실시간 쓰기 (Sync/SyncLive.swift · PlannerSyncHost 의 readLive · applyLive): 두 Mac 이 가짜 서버(중계 · presence)로
/// 이어져 있을 때 친 글자 · 한글 조합 단계 · 칠한 칸이 레코드를 올리기 전에 상대 종이에 바로 보이는지, 쓰는 칸 · 조합 · ⌘Z ·
/// 정리(빈 할 일 지우기)를 건드리지 않는지, 중계 없는 서버에서는 예전처럼 레코드로 가는지. 앱의 진짜 종이(RootView)를 화면 밖 창에 둔다.
@MainActor
final class SyncLiveTests: XCTestCase {
    private var dirs: [URL] = []
    private var controllers: [SyncController] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for w in windows { w.orderOut(nil) }
        windows = []
        for c in controllers { await c.dispose() }
        controllers = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        SyncIndicator.shared.notice = nil
        SyncIndicator.shared.gear = nil
    }

    struct Mac {
        let store: PlannerStore
        let state: AppState
        let sync: SyncController
        @MainActor var live: SyncLiveBridge { sync.live! }
    }

    private let today = Dates.day(Date())
    private var dayKey: String { Dates.key(today) }

    /// 레코드 보내기는 늦게 (COVERED 10초 · 연결 중 안전 확인 1분 — 받기가 밀린 것을 함께 보내므로): 그 안에 상대 종이에 보이는 것은 초안으로 온 것이다
    private func mac(_ server: FakeSyncServer, ip: String, name: String, graceMs: Int = 5000) async -> Mac {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-live-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir.appendingPathComponent("planner"))
        let state = AppState(kind: .daily)
        state.store = store
        var delays = PushDelays()
        delays.coveredPushDelayMs = 10_000
        let env = SyncController.Environment(
            suggestedName: name, credentials: MemoryCredentialStore(), defaults: SyncMemoryDefaults(),
            makeEngine: { host, _, credentials in
                SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: ip), storage: MemorySyncStorage(),
                                             credentials: credentials, platform: .mac, scanDelayMs: 10, pushDelays: delays,
                                             editingGraceMs: graceMs, pollMs: 200, safetyPollMs: 60_000))
            },
            pollIntervalMs: 20,
            backupRoot: dir.appendingPathComponent("backups"),
            watchesSystem: false)
        let sync = SyncController(store: store, env: env)
        controllers.append(sync)
        await sync.start(state: state)
        return Mac(store: store, state: state, sync: sync)
    }

    private func until(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("기다림: \(what)")
        throw CancellationError()
    }

    /// 서재 Mac 이 그룹을 만들고 거실 Mac 이 QR 로 들어온 뒤, 둘 다 같은 플래너를 펴고 서로를 실시간 기기로 본다
    private func pairedMacs(_ server: FakeSyncServer, graceA: Int = 5000, graceB: Int = 5000) async throws -> (a: Mac, b: Mac, book: UUID) {
        let a = await mac(server, ip: "10.0.0.1", name: "서재 Mac", graceMs: graceA)
        let b = await mac(server, ip: "10.0.0.2", name: "거실 Mac", graceMs: graceB)
        let book = a.store.createBook(name: "같이 쓰는 플래너", start: Dates.add(days: -3, to: today), end: nil)
        let created = await a.sync.create(deviceName: "서재 Mac")
        XCTAssertTrue(created.ok, created.message ?? "")
        a.sync.recoveryConfirmed()
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, _, _))? = a.sync.flow else { XCTFail("QR"); throw CancellationError() }
        let joined = await b.sync.joinStart(qr, deviceName: "거실 Mac")
        XCTAssertTrue(joined.ok, joined.message ?? "")
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { XCTFail("확인 숫자"); throw CancellationError() }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        let approved = await a.sync.pairApprove(digits: digits)
        XCTAssertTrue(approved.ok, approved.message ?? "")
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        let accepted = await b.sync.joinAccept()
        XCTAssertTrue(accepted.ok, accepted.message ?? "")
        await b.sync.endFlow()
        await a.sync.endFlow()
        try await until("거실에 책") { b.store.books.contains { $0.id == book } }
        b.store.activate(book)
        try await until("서로를 실시간 기기로") {
            a.sync.live?.presence?.live == 1 && b.sync.live?.presence?.live == 1
        }
        return (a, b, book)
    }

    /// 앱의 플래너 종이(RootView)를 화면 밖 창에 (앱 · --sync-drive 와 같은 글 칸 · 필드 편집기)
    private func paper(_ m: Mac) -> NSWindow {
        let size = CGSize(width: 640, height: 640 * PageKind.daily.design.height / PageKind.daily.design.width)
        let w = TestPaperWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RootView().environmentObject(m.store).environmentObject(m.state))
        w.orderFrontRegardless()
        w.makeKey()
        windows.append(w)
        m.sync.plannerWindow = { [weak w] in w }
        return w
    }

    private func editor(_ w: NSWindow) -> NSTextView? { w.firstResponder as? NSTextView }

    private func recordWrites(_ server: FakeSyncServer) -> Int {
        server.log.filter { $0.method == "POST" && $0.path.contains("/records") }.count
    }

    // MARK: 칸 주소 · 바뀐 레코드

    func testEditingKeysBecomeTheEnginesFieldAddresses() {
        let book = UUID(uuidString: "6D3A0B8E-7A55-4E0C-9D59-2F6A3E7C1B11")!
        let t = UUID()
        let d = "2026-10-02"
        let day = RecordKeys.day(book.uuidString, d)
        XCTAssertEqual(SyncLiveBridge.address("t|\(d)|\(t.uuidString.lowercased())", book: book),
                       FieldAddress(key: day, coll: .tasks, item: t.uuidString, field: "text"))
        XCTAssertEqual(SyncLiveBridge.address("tn|\(d)|\(t.uuidString)", book: book), FieldAddress(key: day, coll: .notes, item: t.uuidString, field: "text"))
        XCTAssertEqual(SyncLiveBridge.address("c|\(d)", book: book), FieldAddress(key: day, field: "comment"))
        XCTAssertEqual(SyncLiveBridge.address("m|\(d)|0", book: book), FieldAddress(key: day, field: "m0"))
        XCTAssertEqual(SyncLiveBridge.address("m|\(d)|2", book: book), FieldAddress(key: day, field: "m2"))
        XCTAssertEqual(SyncLiveBridge.address("m|\(d)|3", book: book), FieldAddress(key: day, field: "m+"))
        XCTAssertEqual(SyncLiveBridge.address("mt|\(d)|1", book: book), FieldAddress(key: day, field: "mt1"))
        XCTAssertEqual(SyncLiveBridge.address("mt|\(d)|5", book: book), FieldAddress(key: day, field: "mt+"))
        XCTAssertEqual(SyncLiveBridge.address("wg|2026-09-28", book: book), FieldAddress(key: RecordKeys.week(book.uuidString, "2026-09-28"), field: "goal"))
        XCTAssertEqual(SyncLiveBridge.address(FrontPage.mottoKey, book: book), FieldAddress(key: RecordKeys.prefs(book.uuidString), field: "mottoText"))
        XCTAssertNil(SyncLiveBridge.address(nil, book: book))
        XCTAssertNil(SyncLiveBridge.address("c|\(d)", book: nil))
        XCTAssertNil(SyncLiveBridge.address("nonsense", book: book))
        XCTAssertNil(SyncLiveBridge.address("t|\(d)|not-a-uuid", book: book))
        XCTAssertNil(SyncLiveBridge.address("c|2026-13-45", book: book))
    }

    func testOnlyTheChangedRecordsAreTold() {
        let book = UUID()
        func day(_ c: String) -> DayRecord {
            var r = DayRecord()
            r.comment = c
            return r
        }
        var a = PlannerData()
        a.days["2026-10-01"] = day("그대로")
        a.days["2026-10-02"] = day("고칠 날")
        a.weeks["2026-09-28"] = WeekRecord(goal: "목표")
        var b = a
        XCTAssertEqual(SyncLiveBridge.changedKeys(book: book, from: a, to: b), [])
        b.days["2026-10-02"]?.comment = "고친 날"
        b.days["2026-10-03"] = day("새 날")
        b.weeks["2026-09-28"] = nil
        b.prefs.motto = "첫 장"
        let id = book.uuidString
        XCTAssertEqual(Set(SyncLiveBridge.changedKeys(book: book, from: a, to: b)),
                       [RecordKeys.day(id, "2026-10-02"), RecordKeys.day(id, "2026-10-03"), RecordKeys.week(id, "2026-09-28"), RecordKeys.prefs(id)])
    }

    // MARK: 호스트 (readLive · applyLive)

    func testReadLiveGivesEachRecordInTheAppFileFormat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-live-host-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let book = store.createBook(name: "책", start: today, end: nil)
        let other = store.createBook(name: "다른 책", start: today, end: nil)
        store.activate(book)
        store.editDay(today) { $0.comment = "조합 중인 ㅎ"; $0.tasks = [PlanTask(text: "할 일", row: 0)] }
        store.editWeek(Dates.weekStart(today)) { $0.goal = "주 목표" }
        let host = PlannerSyncHost(store: store)
        let id = book.uuidString
        let dk = RecordKeys.day(id, dayKey), wk = RecordKeys.week(id, Dates.key(Dates.weekStart(today)))
        let missing = RecordKeys.day(id, Dates.key(Dates.add(days: 1, to: today))), pk = RecordKeys.prefs(id)
        let v = await host.readLive(bookId: id.lowercased(), keys: [dk, wk, missing, pk])
        // 책 파일(앱 형식)의 그 부분과 같다
        let file = try JSONValue.parse(PlannerStore.encodeFile(store.data))
        XCTAssertEqual(v?[dk], file["days"]?[dayKey])
        XCTAssertEqual(v?[wk], file["weeks"]?[Dates.key(Dates.weekStart(today))])
        XCTAssertEqual(v?[pk], file["prefs"])
        XCTAssertEqual(v?[missing], .null, "없는 날은 .null")
        let notOpen = await host.readLive(bookId: other.uuidString, keys: [RecordKeys.day(other.uuidString, dayKey)])
        XCTAssertNil(notOpen, "펼치지 않은 책은 nil (엔진은 readBook 으로)")
    }

    func testApplyLivePutsRecordsInMemoryAsAnOutsideChangeAndSavesLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-live-host-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let book = store.createBook(name: "책", start: today, end: nil)
        let other = store.createBook(name: "다른 책", start: today, end: nil)
        store.activate(book)
        let task = PlanTask(text: "쓰던 할 일", row: 0)
        store.editDay(today) { $0.comment = "포커스만"; $0.tasks = [task] }
        store.saveNow()
        let editedBefore = store.lastLocalEdit
        let host = PlannerSyncHost(store: store)
        var replaced: [String?] = []
        var removed = 0
        host.onEditedFieldReplaced = { replaced.append($0) }
        host.onEditedItemRemoved = { removed += 1 }
        var key = "c|\(dayKey)"
        host.editingKey = { key }
        var sawExternal: [Bool] = []
        let watch = store.$data.dropFirst().sink { [weak store] _ in sawExternal.append(store?.isApplyingExternalChange ?? false) }
        defer { watch.cancel() }
        let id = book.uuidString, dk = RecordKeys.day(id, dayKey)

        // 열지 않은 책 · 모르는 책: transform 을 부르지 않고 false
        let called = CalledFlag()
        let no1 = await host.applyLive(bookId: other.uuidString, keys: [RecordKeys.day(other.uuidString, dayKey)]) { called.value = true; return $0 }
        let no2 = await host.applyLive(bookId: "책 아님", keys: [dk]) { called.value = true; return $0 }
        XCTAssertFalse(no1 || no2)
        XCTAssertFalse(called.value)

        // 다른 기기의 COMMENT: 지금 값을 받아 고친 값을 그대로 넣는다
        let ok = await host.applyLive(bookId: id, keys: [dk]) { cur in
            var day = cur[dk]!.objectValue!
            day["comment"] = "다른 기기의 글"
            return [dk: .object(day)]
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(store.day(today).comment, "다른 기기의 글")
        XCTAssertEqual(sawExternal, [true], "밖에서 온 변경으로 넣는다 (되돌리기 · liveEdit 가 사용자의 편집으로 보지 않게)")
        XCTAssertEqual(store.lastLocalEdit, editedBefore, "사용자의 편집으로 세지 않는다")
        XCTAssertEqual(replaced, ["다른 기기의 글"], "쓰던 칸(포커스만)의 글이 바뀌었다 → 그 칸의 ⌘Z 기록을 비우게")
        let raw = try Data(contentsOf: dir.appendingPathComponent("books/\(id).json"))
        XCTAssertEqual(try PlannerStore.decodeFile(PlannerData.self, from: raw).days[dayKey]?.comment, "포커스만", "파일은 바로 쓰지 않는다")
        try await until("묶음 저장", timeout: 3) {
            (try? PlannerStore.decodeFile(PlannerData.self, from: Data(contentsOf: dir.appendingPathComponent("books/\(id).json"))))?.days[dayKey]?.comment == "다른 기기의 글"
        }

        // 쓰던 할 일이 다른 기기에서 지워졌다 → 편집을 끝내게
        key = AppState.taskKey(today, task.id)
        _ = await host.applyLive(bookId: id, keys: [dk]) { cur in
            var day = cur[dk]!.objectValue!
            day["tasks"] = .array([])
            return [dk: .object(day)]
        }
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(store.day(today).tasks.isEmpty)

        // 그 날을 없앤다 (.null)
        _ = await host.applyLive(bookId: id, keys: [dk]) { _ in [dk: .null] }
        XCTAssertNil(store.data.days[dayKey])

        // 앱 모델로 읽을 수 없는 값은 넣지 않고 false (엔진은 다음 바퀴의 updateBook 으로)
        store.editDay(today) { $0.comment = "그대로" }
        let bad = await host.applyLive(bookId: id, keys: [dk]) { _ in [dk: .object(["slots": .string("칸이 아님")])] }
        XCTAssertFalse(bad)
        XCTAssertEqual(store.day(today).comment, "그대로")
    }

    /// 조합 중인 글자는 엔진이 보는 값(readLive · readBook · updateBook · applyLive 의 지금 값)에만 얹고, 넣을 때 그 칸이 조합 중인 글
    /// 그대로면 저장소에는 조합 전 글을 둔다 (저장소 · 바인딩에 조합 중인 글을 넣으면 SwiftUI 글 칸의 조합이 깨진다)
    func testComposingTextIsOnlyInWhatTheEngineSees() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-live-host-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir)
        let book = store.createBook(name: "책", start: today, end: nil)
        store.editDay(today) { $0.comment = "한" }
        let host = PlannerSyncHost(store: store)
        let key = "c|\(dayKey)"
        host.editingKey = { key }
        host.composing = { (key, "한그") }
        let id = book.uuidString, dk = RecordKeys.day(id, dayKey)
        let live = await host.readLive(bookId: id, keys: [dk])
        XCTAssertEqual(live?[dk]?["comment"], .string("한그"), "엔진은 조합 중인 글을 본다")
        guard case let .ok(whole) = await host.readBook(id: id) else { return XCTFail("readBook") }
        XCTAssertEqual(whole["days"]?[dayKey]?["comment"], .string("한그"))

        // 엔진이 쓰는 칸을 지켰다(앱 값 그대로) + 다른 칸이 바뀜 → 저장소에는 조합 전 글 그대로
        let seen = CalledFlag()
        _ = await host.applyLive(bookId: id, keys: [dk]) { cur in
            seen.value = cur[dk]?["comment"] == .string("한그")
            var day = cur[dk]!.objectValue!
            day["memos"] = .array([.string("다른 칸"), .string(""), .string("")])
            return [dk: .object(day)]
        }
        XCTAssertTrue(seen.value, "transform 의 지금 값에도 조합 중인 글")
        XCTAssertEqual(store.day(today).comment, "한", "저장소는 조합을 모른다")
        XCTAssertEqual(store.day(today).memos.first, "다른 칸")

        // 바퀴의 updateBook 도 같다
        let k = dayKey
        let sawComposing = CalledFlag()
        try await host.updateBook(id: id) { cur in
            guard case var .object(o)? = cur, case var .object(days)? = o["days"], case var .object(day)? = days[k] else { return cur }
            sawComposing.value = day["comment"] == .string("한그")
            day["memoTags"] = .array([.string("태그"), .string(""), .string("")])
            days[k] = .object(day)
            o["days"] = .object(days)
            return .object(o)
        }
        XCTAssertTrue(sawComposing.value)
        XCTAssertEqual(store.day(today).comment, "한")
        XCTAssertEqual(store.day(today).memoTags.first, "태그")

        // 엔진이 다른 글을 넣으면(쓰는 칸이 아님 · 지키지 않음) 그 글이 들어간다
        _ = await host.applyLive(bookId: id, keys: [dk]) { cur in
            var day = cur[dk]!.objectValue!
            day["comment"] = "다른 기기의 글"
            return [dk: .object(day)]
        }
        XCTAssertEqual(store.day(today).comment, "다른 기기의 글")
    }

    // MARK: 두 Mac

    /// 서재 Mac 이 할 일을 한 글자씩 치면(레코드를 올리기 전에) 거실 Mac 의 종이에 글자마다 나타난다. 칠한 칸도 칸마다
    func testLettersAndPaintedCellsReachTheOtherMacBeforeAnyRecordUpload() async throws {
        let server = FakeSyncServer()
        let (a, b, _) = try await pairedMacs(server)
        let id = a.store.addTask(today, row: 0)
        await a.sync.syncNow()
        try await until("거실에 빈 할 일") { b.store.day(today).tasks.contains { $0.id == id } }
        let writes = recordWrites(server)
        let bEdited = b.store.lastLocalEdit
        var seen: [String] = []
        let text = "견적서 비교하기"
        for n in 1...text.count {
            a.store.taskText(today, id: id).wrappedValue = String(text.prefix(n))
            let want = String(text.prefix(n))
            try await until("거실에 ‘\(want)’", timeout: 2) { b.store.day(today).tasks.first { $0.id == id }?.text == want }
            seen.append(want)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(seen.count, text.count, "글자마다")

        // 끌어 칠하기: 칸이 바뀔 때마다 (SlotPainter 와 같은 걸음 — 지금 칸 위에 이번 범위만)
        let before = a.store.day(today).slots
        var painted: ClosedRange<Int>?
        for end in 12...17 {
            let cur = a.store.day(today).slots
            let next = DayRecord.repainted(cur, before: before, previous: painted, range: 12...end, value: 2)
            painted = 12...end
            a.store.editDay(today) { $0.slots = next }
            try await until("거실에 \(end) 칸까지", timeout: 2) { b.store.day(today).slots[12...end].allSatisfy { $0 == 2 } }
        }
        XCTAssertEqual(recordWrites(server), writes, "그동안 레코드는 올리지 않았다 (초안으로만 — COVERED)")
        XCTAssertGreaterThan(b.live.appliedCount, 0)
        XCTAssertEqual(b.store.lastLocalEdit, bEdited, "받은 글자는 거실의 편집이 아니다")

        // 받은 기기는 아무것도 올리지 않고, 보낸 기기의 레코드가 오면 둘이 같다
        await a.sync.syncNow()
        await b.sync.syncNow()
        try await until("같은 하루") { a.store.day(today) == b.store.day(today) }
    }

    /// 앱의 진짜 글 칸에서 한글을 조합하면 조합 단계마다(ㅎ → 하 → 한) 상대 종이에 보이고, 조합 · 캐럿 · 되돌리기는 그대로다.
    /// 조합하는 동안 다른 기기가 같은 날의 다른 칸을 고쳐도 조합이 깨지지 않는다
    func testComposingKoreanSendsEveryStageWithoutBreakingTheComposition() async throws {
        let server = FakeSyncServer()
        let (a, b, _) = try await pairedMacs(server)
        let w = paper(a)
        let key = "c|\(dayKey)"
        a.state.editingKey = key
        try await until("COMMENT 칸에 포커스") { editor(w) != nil }
        let tv = editor(w)!
        var stages: [String] = []
        let watch = b.store.$data.sink { d in
            let c = d.days[Dates.key(Date())]?.comment ?? ""
            if stages.last != c { stages.append(c) }
        }
        defer { watch.cancel() }
        func mark(_ s: String) { tv.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        func commit(_ s: String) { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let steps: [(String, Bool, String)] = [("ㅎ", false, "ㅎ"), ("하", false, "하"), ("한", false, "한"), ("한", true, "한"),
                                              ("ㄱ", false, "한ㄱ"), ("그", false, "한그"), ("글", false, "한글"), ("글", true, "한글")]
        for (i, (s, isCommit, want)) in steps.enumerated() {
            if isCommit { commit(s) } else { mark(s) }
            XCTAssertEqual(tv.hasMarkedText(), !isCommit, "조합 \(i)")
            XCTAssertEqual(tv.string, want)
            // 저장소 · 바인딩에는 조합이 끝난 글만 (조합 중인 글자는 엔진이 보는 값에만 얹는다 — 화면 갱신이 조합을 깨지 않게)
            XCTAssertEqual(a.store.day(today).comment, isCommit || i < 3 ? (isCommit ? want : "") : "한", "저장소에는 조합이 끝난 글만")
            try await until("거실에 ‘\(want)’", timeout: 2) { b.store.day(today).comment == want }
            if i == 5 {
                // 조합하는 동안 거실 Mac 이 같은 날의 메모를 고친다 → 서재의 조합은 그대로
                b.store.memo(today, 0).wrappedValue = "거실의 메모"
                try await until("서재에 메모", timeout: 2) { a.store.day(today).memos.first == "거실의 메모" }
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertTrue(tv.hasMarkedText(), "조합이 깨지지 않는다")
                XCTAssertTrue(w.firstResponder === tv, "포커스 그대로")
                XCTAssertEqual(tv.string, "한그")
            }
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        XCTAssertEqual(stages.filter { !$0.isEmpty }, ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"], "조합 단계마다 차례로")
        XCTAssertGreaterThan(a.live.composedEdits, 0)
        XCTAssertEqual(tv.string, "한글")
        XCTAssertTrue(tv.undoManager?.canUndo ?? false, "되돌리기 기록은 필드 편집기의 것 그대로")
    }

    /// 거실 Mac 이 쓰는 중인 칸은 서재의 글로 덮지 않고 "다른 기기에서 쓰는 중" · "다른 기기의 글이 있어요" 를 보인다.
    /// 거실이 쓰기를 마치면 나중 글(서재)이 둘 다에 (LWW)
    func testTheFieldBeingTypedKeepsItsTextAndShowsTheHint() async throws {
        let server = FakeSyncServer()
        let (a, b, _) = try await pairedMacs(server)
        let w = paper(b)
        let key = "c|\(dayKey)"
        b.state.editingKey = key
        try await until("거실 COMMENT 칸에 포커스") { editor(w) != nil }
        let tv = editor(w)!
        tv.insertText("거실이 쓰는 중", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until("서재에 거실의 글", timeout: 2) { a.store.day(today).comment == "거실이 쓰는 중" }
        // 서재가 같은 칸을 고친다 (거실은 방금 쳤다 — 쓰는 중)
        a.store.dayField(today, \.comment).wrappedValue = "서재의 더 새 글"
        try await until("거실에 알림", timeout: 2) { b.live.hints.shown == SyncLiveHints.typingText }
        XCTAssertNotNil(b.live.hints.visiblePanel, "글 칸 위의 작은 패널")
        XCTAssertFalse(b.live.hints.visiblePanel?.canBecomeKey ?? true, "포커스를 가져가지 않는다")
        XCTAssertEqual(b.store.day(today).comment, "거실이 쓰는 중", "쓰는 칸은 거실의 글 그대로")
        XCTAssertEqual(tv.string, "거실이 쓰는 중")
        XCTAssertTrue(w.firstResponder === tv)
        try await until("3초 뒤 ‘다른 기기의 글이 있어요’", timeout: 5) { b.live.hints.shown == SyncLiveHints.heldText }
        // 거실이 쓰기를 마친다 → 나중 글이 들어온다
        b.state.endEditing()
        try await until("거실에 서재의 글", timeout: 3) { b.store.day(today).comment == "서재의 더 새 글" }
        XCTAssertNil(b.live.hints.shown)
        await a.sync.syncNow()
        await b.sync.syncNow()
        try await until("둘이 같다") { a.store.day(today).comment == "서재의 더 새 글" && b.store.day(today).comment == "서재의 더 새 글" }
    }

    /// 포커스만 있는 칸(치지 않은 지 grace 넘음)은 더 새 글을 바로 받고 그 칸의 ⌘Z 기록을 비운다 (⌘Z 가 다른 기기의 글을 지우지 않게)
    func testAFocusOnlyFieldTakesNewerTextAndForgetsItsUndo() async throws {
        let server = FakeSyncServer()
        let (a, b, _) = try await pairedMacs(server, graceB: 300)
        b.store.editingGrace = 0.3
        let w = paper(b)
        b.state.editingKey = "c|\(dayKey)"
        try await until("포커스") { editor(w) != nil }
        let tv = editor(w)!
        tv.insertText("거실", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until("되돌릴 수 있음") { tv.undoManager?.canUndo ?? false }
        try await until("서재에", timeout: 2) { a.store.day(today).comment == "거실" }
        try await Task.sleep(nanoseconds: 500_000_000)   // 거실은 이제 포커스만
        a.store.dayField(today, \.comment).wrappedValue = "서재의 새 글"
        try await until("거실 칸에 바로", timeout: 2) { b.store.day(today).comment == "서재의 새 글" && tv.string == "서재의 새 글" }
        try await until("⌘Z 기록을 비움", timeout: 4) { !(tv.undoManager?.canUndo ?? false) }
        _ = tv.tryToPerform(Selector(("undo:")), with: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(b.store.day(today).comment, "서재의 새 글", "⌘Z 로 서재의 글을 지우지 않는다")
    }

    /// 쓰기를 마친 뒤의 정리(빈 할 일 지우기)는 미뤄 둔 다른 기기의 글을 넣은 뒤에 한다: 거실이 할 일을 지우개로 비우는 사이 서재가
    /// 그 할 일에 더 새 글을 쳤으면, 거실이 칸을 떠날 때 할 일을 지우지 않고 서재의 글이 남는다
    func testCleanupAfterEditingWaitsForTheHeldNewerText() async throws {
        let server = FakeSyncServer()
        let (a, b, _) = try await pairedMacs(server)
        let id = b.store.addTask(today, row: 0)
        b.store.taskText(today, id: id).wrappedValue = "지울 할 일"
        await b.sync.syncNow()
        try await until("서재에 할 일") { a.store.day(today).tasks.contains { $0.id == id } }
        let w = paper(b)
        b.state.editingKey = AppState.taskKey(today, id)
        try await until("포커스") { editor(w) != nil }
        let tv = editor(w)!
        tv.selectAll(nil)
        tv.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until("거실 할 일이 비었다") { b.store.day(today).tasks.first { $0.id == id }?.text == "" }
        try await until("서재에도 빈 할 일", timeout: 2) { a.store.day(today).tasks.first { $0.id == id }?.text == "" }
        a.store.taskText(today, id: id).wrappedValue = "서재가 다시 씀"
        try await until("거실은 쓰는 칸이라 미뤄 둠", timeout: 2) { b.live.hints.shown != nil }
        XCTAssertEqual(b.store.day(today).tasks.first { $0.id == id }?.text, "")
        b.state.endEditing()
        try await until("거실에 서재의 글", timeout: 3) { b.store.day(today).tasks.first { $0.id == id }?.text == "서재가 다시 씀" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(b.store.day(today).tasks.map(\.id), [id], "정리가 할 일을 지우지 않았다")
        await a.sync.syncNow()
        await b.sync.syncNow()
        try await until("둘이 같다") { a.store.day(today) == b.store.day(today) }
        XCTAssertEqual(a.store.day(today).tasks.first?.text, "서재가 다시 씀")
    }

    /// 엔진이 있을 때만 저장소에 무언가를 건다 — 그룹을 떠나면 모두 걷는다. 꺼져 있으면 처음부터 아무것도 걸지 않는다
    func testNothingIsHookedWhileSyncIsOff() async throws {
        let server = FakeSyncServer()
        let off = await mac(server, ip: "10.0.0.9", name: "꺼진 Mac")
        XCTAssertNil(off.sync.live)
        XCTAssertNil(off.store.settleBeforeCleanup)
        XCTAssertNil(off.store.beforeScheduledSave)
        off.store.createBook(name: "책", start: today, end: nil)
        off.store.editDay(today) { $0.comment = "꺼진 채로" }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(server.log.isEmpty)

        let (a, _, _) = try await pairedMacs(server)
        XCTAssertNotNil(a.store.settleBeforeCleanup)
        XCTAssertNotNil(a.store.beforeScheduledSave)
        let left = await a.sync.leave()
        XCTAssertTrue(left.ok, left.message ?? "")
        try await until("걷어 냄") { a.sync.live == nil && a.store.settleBeforeCleanup == nil && a.store.beforeScheduledSave == nil }
    }

    /// 묶어 둔 저장은 엔진 저장소를 먼저 맞춘 뒤 파일을 쓴다 (쓴 값은 저장된 그림자로 엔진에)
    func testScheduledSaveStillWritesTheFile() async throws {
        let server = FakeSyncServer()
        let (a, _, book) = try await pairedMacs(server)
        a.store.dayField(today, \.comment).wrappedValue = "저장될 글"
        let url = a.store.folder!.appendingPathComponent("books/\(book.uuidString).json")
        try await until("파일에", timeout: 3) {
            (try? PlannerStore.decodeFile(PlannerData.self, from: Data(contentsOf: url)))?.days[dayKey]?.comment == "저장될 글"
        }
    }

    /// 중계를 모르는 서버(지금 운영 · LIVE=off): 초안 없이 예전처럼 레코드로 (그래도 같아진다)
    func testServerWithoutRelayFallsBackToRecords() async throws {
        let server = FakeSyncServer()
        server.live = false
        let a = await mac(server, ip: "10.0.0.1", name: "서재 Mac")
        let b = await mac(server, ip: "10.0.0.2", name: "거실 Mac")
        let book = a.store.createBook(name: "같이 쓰는 플래너", start: today, end: nil)
        _ = await a.sync.create(deviceName: "서재 Mac")
        a.sync.recoveryConfirmed()
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, _, _))? = a.sync.flow else { return XCTFail("QR") }
        _ = await b.sync.joinStart(qr, deviceName: "거실 Mac")
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail("확인 숫자") }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        _ = await a.sync.pairApprove(digits: digits)
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        _ = await b.sync.joinAccept()
        try await until("거실에 책") { b.store.books.contains { $0.id == book } }
        b.store.activate(book)
        a.store.dayField(today, \.comment).wrappedValue = "레코드로 가는 글"
        try await until("거실에 (레코드로)", timeout: 8) { b.store.day(today).comment == "레코드로 가는 글" }
        XCTAssertNil(a.live.presence, "presence 없음")
        XCTAssertEqual(server.relayed, 0, "초안 없음")
        XCTAssertEqual(b.live.appliedCount, 0)
    }
}

/// 화면 밖 플래너 창 (키 창이 될 수 있는 테두리 없는 창 — --sync-drive 의 창과 같다)
private final class TestPaperWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
