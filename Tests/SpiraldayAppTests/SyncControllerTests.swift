import XCTest
import AppKit
import SwiftUI
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// 자격을 몇 번 읽고 썼는지 센다 (꺼져 있으면 키체인을 건드리지 않는지 보려고)
actor CountingCredentials: CredentialStore {
    private var c: Credentials?
    private(set) var reads = 0
    private(set) var writes = 0
    var failRead: Error?

    init(_ c: Credentials? = nil) { self.c = c }

    func get() async throws -> Credentials? {
        reads += 1
        if let failRead { throw failRead }
        return c
    }

    func set(_ c: Credentials?) async throws {
        writes += 1
        self.c = c
    }

    func failReads(_ e: Error?) { failRead = e }
    func peek() -> Credentials? { c }
}

/// 설정 → 동기화의 흐름을 컨트롤러로 끝까지: 시작 → 복구 코드 → 기기 추가(QR · 승인 게이트) → 합류(합치기 전 백업)
/// → 저장 알림만으로 오감 → 기기 이름 · 빼기 → 이전 버전 → 끄기 · 복구 코드로 되살리기. 가짜 서버 · 메모리 열쇠 · 임시 폴더.
/// Mac 의 수명(잠자기 · 깨어남 · 끝내기)과 "꺼져 있으면 키체인 · 네트워크를 건드리지 않는다" 도.
@MainActor
final class SyncControllerTests: XCTestCase {
    private var dirs: [URL] = []
    private var controllers: [SyncController] = []

    override func tearDown() async throws {
        for c in controllers { await c.dispose() }
        controllers = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        SyncIndicator.shared.notice = nil
        SyncIndicator.shared.gear = nil
    }

    final class Counter { var n = 0 }

    struct Device {
        let store: PlannerStore
        let state: AppState
        let sync: SyncController
        let creds: CountingCredentials
        let defaults: UserDefaults
        let dir: URL
        let engines: Counter
    }

    private func freshDefaults() -> UserDefaults { SyncMemoryDefaults() }

    private func device(_ server: FakeSyncServer, ip: String, name: String, creds: CountingCredentials = CountingCredentials(),
                        defaults: UserDefaults? = nil, backupRoot: URL? = nil, net: FakeNet = FakeNet(), start: Bool = true) async -> Device {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ctl-sync-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir.appendingPathComponent("planner"))
        let state = AppState(kind: .daily)
        state.store = store
        let engines = Counter()
        let d = defaults ?? freshDefaults()
        let env = SyncController.Environment(
            suggestedName: name, credentials: creds, defaults: d,
            makeEngine: { host, _, credentials in
                engines.n += 1
                return SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: ip, net: net), storage: MemorySyncStorage(),
                                                    credentials: credentials, platform: .mac, scanDelayMs: 10, pushDelayMs: 10,
                                                    pollMs: 200, safetyPollMs: 1000))
            },
            pollIntervalMs: 20,
            backupRoot: backupRoot ?? dir.appendingPathComponent("backups"),
            watchesSystem: false)
        let sync = SyncController(store: store, env: env)
        controllers.append(sync)
        if start { await sync.start(state: state) }
        return Device(store: store, state: state, sync: sync, creds: creds, defaults: d, dir: dir, engines: engines)
    }

    private func until(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("기다림: \(what)")
        throw CancellationError()
    }

    private let today = Dates.day(Date())

    // MARK: 꺼져 있을 때

    func testOffByDefaultTouchesNeitherKeychainNorNetwork() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        XCTAssertTrue(a.sync.ready)
        XCTAssertFalse(a.sync.inGroup)
        XCTAssertNil(a.sync.status, "그룹이 없으면 엔진을 만들지 않는다")
        a.store.createBook(name: "내 플래너", start: today, end: nil)
        a.store.editDay(today) { $0.comment = "켜기 전" }
        a.store.saveNow()
        a.sync.appBecameActive()
        a.sync.didWake()
        a.sync.networkChanged()
        a.sync.willSleep()
        await a.sync.syncNow()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(server.log.isEmpty, "켜기 전에는 서버에 아무것도 보내지 않는다")
        XCTAssertEqual(a.engines.n, 0, "엔진도 만들지 않는다")
        let reads = await a.creds.reads
        let writes = await a.creds.writes
        XCTAssertEqual(reads + writes, 0, "키체인도 읽지 않는다 (예전에 남은 항목이 있어도 묻지 않는다)")
        XCTAssertNil(a.sync.gearInfo(), "팔레트의 설정 단추는 예전 그대로")
        var done = false
        a.sync.prepareToQuit { done = true }
        XCTAssertTrue(done, "끝낼 때도 기다리지 않는다")
    }

    // MARK: 끝까지

    func testCreatePairJoinAndSyncEndToEnd() async throws {
        var limits = FakeServerLimits()
        limits.historyCoalesceMs = 0          // 잇단 편집도 버전마다 남게 (이전 버전 되돌리기를 보려고)
        let server = FakeSyncServer(limits: limits)
        // 서재 Mac: 내 플래너가 있고 동기화를 시작한다
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        let book = a.store.createBook(name: "서재 플래너", start: Dates.add(days: -3, to: today), end: nil)
        a.store.editDay(today) { $0.comment = "서재에서" }
        let created = await a.sync.create(deviceName: "  서재 Mac  ")
        XCTAssertTrue(created.ok, created.message ?? "")
        XCTAssertTrue(a.sync.inGroup)
        XCTAssertEqual(a.sync.deviceName, "서재 Mac")
        XCTAssertNotNil(a.defaults.string(forKey: SyncController.Key.groupURL), "다음에 켤 때 키체인을 읽을 표시")
        guard case .recovery(.create, .show(let code))? = a.sync.flow else { return XCTFail("복구 코드 단계: \(String(describing: a.sync.flow))") }
        XCTAssertEqual(Codes.checkRecoveryCode(code), .ok)
        XCTAssertTrue(a.sync.recoveryPending)
        XCTAssertEqual(a.sync.gearInfo()?.tone, .warn, "복구 코드를 확인하기 전에는 주황")
        a.sync.recoveryConfirmed()
        XCTAssertNil(a.sync.flow)
        XCTAssertFalse(a.sync.recoveryPending)

        // 거실 Mac: 다른 플래너가 있는 채로 합류 (연결 글을 붙여 넣어서)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac")
        b.store.createBook(name: "거실 플래너", start: today, end: nil)
        b.store.editDay(today) { $0.comment = "거실에서" }
        b.store.saveNow()

        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, nil, let deadline))? = a.sync.flow else { return XCTFail("QR 기다림") }
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 590)
        XCTAssertTrue(a.sync.flow?.showsSecret == true, "설정 창을 화면 공유에서 가린다")

        // 화면은 붙여 넣은 글에서 연결 글만 골라 넘긴다 (SyncText.pastedPairingLink)
        let joined = await b.sync.joinStart(SyncText.pastedPairingLink("붙여 넣은 글: \(qr) 끝")!, deviceName: "거실 Mac")
        XCTAssertTrue(joined.ok, joined.message ?? "")
        guard case .join(.waiting(let digits, _), let books)? = b.sync.flow else { return XCTFail("확인 숫자") }
        XCTAssertEqual(books, ["거실 플래너"])
        XCTAssertEqual(digits.count, 4)

        // 원래 Mac: 요청이 오고, 틀린 숫자는 서버에 아무것도 보내지 않고 한 번 덜
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        let wrong = String(digits.map { $0 == "9" ? "0" : Character(String(Int(String($0))! + 1)) })
        let w = await a.sync.pairApprove(digits: wrong)
        XCTAssertEqual(w.code, .digitsMismatch)
        guard case .pair(_, .request(let info))? = a.sync.flow else { return XCTFail("같은 요청") }
        XCTAssertTrue(info.wrong)
        XCTAssertEqual(info.triesLeft, 2)
        XCTAssertEqual(info.platform, .mac)
        let ok = await a.sync.pairApprove(digits: digits)
        XCTAssertTrue(ok.ok, ok.message ?? "")
        XCTAssertEqual(a.sync.flow, .pair(mode: .qr, stage: .approved(platform: .mac)))

        // 새 Mac: 승인 → 합치기 설명 → 합치고 시작하기 (합치기 직전 백업)
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        guard case .join(.approved(let groupDevices, _), _)? = b.sync.flow else { return XCTFail() }
        XCTAssertEqual(groupDevices.map(\.name), ["서재 Mac"])
        let accepted = await b.sync.joinAccept()
        XCTAssertTrue(accepted.ok, accepted.message ?? "")
        guard case .join(.done(let backup?), _)? = b.sync.flow else { return XCTFail("백업과 함께 끝") }
        XCTAssertEqual(backup.files.map { $0.lastPathComponent }, ["Spiralday 백업 - 거실 플래너 \(Dates.key(Date())).json"],
                       "설정 → 데이터의 백업 가져오기가 책 이름을 되찾는 이름")
        let saved = try PlannerStore.decodeFile(PlannerData.self, from: Data(contentsOf: backup.files[0]))
        XCTAssertEqual(saved.days[Dates.key(today)]?.comment, "거실에서")
        XCTAssertTrue(b.sync.inGroup)
        await b.sync.endFlow()
        await a.sync.endFlow()

        // 두 Mac 이 같은 책장 · 같은 기록 (저장 알림과 엔진 타이머만으로)
        try await until("책장이 합쳐짐") {
            Set(a.store.userBooks.map(\.name)) == ["서재 플래너", "거실 플래너"]
                && Set(b.store.userBooks.map(\.name)) == ["서재 플래너", "거실 플래너"]
        }
        b.store.activate(book)
        try await until("서재의 글이 거실에") { b.store.day(today).comment == "서재에서" }
        b.store.dayField(today, \.comment).wrappedValue = "거실이 고침"
        try await until("거실의 편집이 서재에") { a.store.day(today).comment == "거실이 고침" }
        try await until("상태가 동기화됨") { a.sync.status?.state == .idle && b.sync.status?.state == .idle }
        XCTAssertEqual(a.sync.gearInfo()?.tone, .ok)
        XCTAssertEqual(a.sync.gearInfo()?.attention, false)

        // 기기 목록 · 이름 바꾸기
        let list = try await a.sync.listDevices()
        XCTAssertEqual(list.devices.count, 2)
        XCTAssertEqual(Set(list.devices.compactMap(\.name)), ["서재 Mac", "거실 Mac"])
        XCTAssertEqual(list.devices.first { $0.current }?.platform, .mac)
        let renamed = await a.sync.renameDevice("서재 iMac")
        XCTAssertTrue(renamed.ok)
        XCTAssertEqual(a.sync.deviceName, "서재 iMac")
        let seenByB = try await b.sync.listDevices().devices.first { !$0.current }?.name
        XCTAssertEqual(seenByB, "서재 iMac")
        let blank = await a.sync.renameDevice("   ")
        XCTAssertFalse(blank.ok)

        // 이전 버전: 오늘의 버전들 → 옛 버전으로 되돌리면 다른 Mac 으로 퍼진다
        let versions = try await a.sync.history(book: book, kind: .day, date: today)
        XCTAssertGreaterThanOrEqual(versions.count, 2, "\(versions)")
        XCTAssertTrue(versions.contains { $0.current })
        let old = try XCTUnwrap(versions.first { !$0.current && $0.preview.contains("“서재에서”") })
        let back = await a.sync.restoreVersion(book: book, kind: .day, date: today, seq: old.seq)
        XCTAssertTrue(back.ok, back.message ?? "")
        XCTAssertEqual(a.store.day(today).comment, "서재에서")
        try await until("되돌린 것이 거실에") { b.store.day(today).comment == "서재에서" }

        // 다른 Mac 을 뺀다 → 그 Mac 은 빠짐 상태 → 정리하기 (서버에 다시 물어본 뒤)
        let bID = try await a.sync.listDevices().devices.first { !$0.current }!.id
        let removed = await a.sync.removeDevice(bID)
        XCTAssertTrue(removed.ok)
        await b.sync.syncNow()
        try await until("빠짐") { b.sync.status?.state == .removed }
        XCTAssertNil(b.sync.flow)
        XCTAssertEqual(b.sync.gearInfo()?.attention, true, "설정 단추가 동기화로 바로 연다")
        let forgot = await b.sync.forget()
        XCTAssertTrue(forgot.ok, forgot.message ?? "")
        XCTAssertFalse(b.sync.inGroup)
        let bCreds = await b.creds.peek()
        XCTAssertNil(bCreds, "자격을 지운다")
        XCTAssertNil(b.defaults.string(forKey: SyncController.Key.groupURL), "다음에 켤 때 키체인을 읽지 않는다")
        XCTAssertEqual(b.store.userBooks.count, 2, "플래너는 그대로")

        // 복구 코드로 되살리기 (거실 Mac 이 다시 들어온다)
        let restored = await b.sync.restore(code: code.lowercased(), deviceName: "되살린 Mac")
        XCTAssertTrue(restored.ok, restored.message ?? "")
        guard case .restore(false, _)? = b.sync.flow else { return XCTFail("되살림") }
        XCTAssertTrue(b.sync.inGroup)

        // 이 Mac 에서 끄기 · 그룹 지우기
        let left = await b.sync.leave()
        XCTAssertTrue(left.ok)
        XCTAssertFalse(b.sync.inGroup)
        XCTAssertNil(b.sync.flow)
        let wiped = await a.sync.wipe()
        XCTAssertTrue(wiped.ok)
        XCTAssertFalse(a.sync.inGroup)
        XCTAssertEqual(a.store.userBooks.count, 2, "그룹을 지워도 플래너는 남는다")
        XCTAssertNil(a.sync.gearInfo())
    }

    func testDenyAndWrongCodeAndThreeWrongDigits() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        a.store.createBook(name: "A", start: today, end: nil)
        _ = await a.sync.create(deviceName: "서재 Mac")
        a.sync.recoveryConfirmed()

        // 8자리 코드로 → [아니에요]
        await a.sync.pairStart(.code)
        guard case .pair(.code, .waiting(nil, let code?, _))? = a.sync.flow else { return XCTFail("코드") }
        XCTAssertEqual(code.count, 9)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac")
        let r = await b.sync.joinStart(code.lowercased().replacingOccurrences(of: "-", with: ""), deviceName: "거실 Mac")
        XCTAssertTrue(r.ok, r.message ?? "")
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        await a.sync.pairDeny()
        XCTAssertEqual(a.sync.flow, .pair(mode: .code, stage: .denied))
        try await until("거절") { if case .join(.denied, _)? = b.sync.flow { return true } else { return false } }
        XCTAssertFalse(b.sync.inGroup)
        await b.sync.endFlow()

        // 틀린 코드
        let bad = await b.sync.joinStart("ZZZZ-ZZZZ", deviceName: "거실 Mac")
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.code, .invalidCode)
        XCTAssertTrue(bad.message?.contains("코드가 맞지 않거나") ?? false)

        // 숫자를 세 번 틀리면 거절
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, _, _))? = a.sync.flow else { return XCTFail("QR") }
        let r2 = await b.sync.joinStart(qr, deviceName: "거실 Mac")
        XCTAssertTrue(r2.ok)
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail() }
        let wrong = digits == "0000" ? "1111" : "0000"
        _ = await a.sync.pairApprove(digits: wrong)
        _ = await a.sync.pairApprove(digits: wrong)
        let third = await a.sync.pairApprove(digits: wrong)
        XCTAssertEqual(third.code, .pairingDenied)
        XCTAssertEqual(a.sync.flow, .pair(mode: .qr, stage: .denied))
        try await until("새 Mac 도 거절") { if case .join(.denied, _)? = b.sync.flow { return true } else { return false } }

        // 설정 창을 닫으면: 기다리던 페어링을 거둔다
        await a.sync.pairStart(.qr)
        XCTAssertNotNil(a.sync.flow)
        a.sync.settingsClosed()
        try await until("흐름이 닫힘") { a.sync.flow == nil }
    }

    /// 서재 Mac 이 시작하고 거실 Mac 이 QR 연결 글로 들어온 두 Mac (흐름 화면은 닫은 채로)
    private func pairedMacs(_ server: FakeSyncServer) async throws -> (a: Device, b: Device) {
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac")
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
        return (a, b)
    }

    func testOpenBookDeletedOnAnotherMacOpensAnotherWithANotice() async throws {
        let server = FakeSyncServer()
        let (a, b) = try await pairedMacs(server)
        let keep = a.store.createBook(name: "남길 플래너", start: today, end: nil)
        let gone = a.store.createBook(name: "지울 플래너", start: today, end: nil)
        let other = a.store.createBook(name: "덤 플래너", start: today, end: nil)
        a.store.activate(gone)
        a.store.editDay(today) { $0.comment = "곧 지움" }
        try await until("세 권이 거실에") { Set(b.store.userBooks.map(\.id)) == [keep, gone, other] }
        b.store.activate(gone)
        XCTAssertNil(SyncIndicator.shared.notice)
        b.state.editingKey = "c|\(Dates.key(today))"   // 지울 책의 COMMENT 를 쓰는 중

        // 서재에서 지운다 (사용자가 지움 → onDeleted → 엔진이 지운 것으로 올린다)
        a.store.deleteBook(gone)
        try await until("거실에서도 빠짐") { !b.store.books.contains { $0.id == gone } }
        XCTAssertNotEqual(b.store.library.activeID, gone, "남은 책을 편다")
        XCTAssertEqual(SyncIndicator.shared.notice?.text, "다른 기기에서 지운 플래너라 다른 플래너를 펼쳤어요.")
        XCTAssertNil(b.state.editingKey, "지운 책의 칸을 쓰던 편집은 끝낸다 (새로 편 책의 같은 칸을 가리키지 않게)")

        // 펼치지 않은 책을 지우면 그 이름으로 알린다
        SyncIndicator.shared.notice = nil
        b.store.activate(keep)
        a.store.deleteBook(other)
        try await until("덤 플래너도 빠짐") { !b.store.books.contains { $0.id == other } }
        XCTAssertEqual(SyncIndicator.shared.notice?.text, "다른 기기에서 ‘덤 플래너’ 플래너를 지웠어요.")
        // 엔진이 몇 바퀴 더 도는 동안에도 되살아나지 않는다
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(a.store.books.contains { $0.id == gone || $0.id == other })
        XCTAssertFalse(b.store.books.contains { $0.id == gone || $0.id == other })
    }

    /// 쓰던 칸(포커스만)의 글이 다른 Mac 의 글로 바뀌면 그 칸의 ⌘Z 기록을 비운다 — 되돌리기가 다른 Mac 의 글을 지우지 않게.
    /// 앱과 같이 SwiftUI 글 칸(InlineField)을 NSHostingView 에 두고 키보드로 친 것처럼 쓴다: 필드 편집기의 되돌리기 기록은
    /// 창의 undoManager 가 아니라 호스팅 뷰의 것이고, ⌘Z(undo:)는 응답자 사슬로 그 기록을 되돌린다
    func testRemoteEditOfTheFocusedFieldClearsItsUndo() async throws {
        let server = FakeSyncServer()
        let (a, b) = try await pairedMacs(server)
        let book = a.store.createBook(name: "같이 쓰는 플래너", start: today, end: nil)
        try await until("거실에 책") { b.store.books.contains { $0.id == book } }
        b.store.activate(book)
        let key = "c|\(Dates.key(today))"
        // 거실 Mac 의 플래너 창: COMMENT 칸 (화면 밖 창)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CommentField(day: today).environmentObject(b.store).environmentObject(b.state))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        b.state.editingKey = key
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }
        try await until("글 칸에 포커스") { editor() != nil }
        func type(_ text: String) {
            for ch in text {
                let s = String(ch)
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                    editor()?.interpretKeyEvents([e])
                }
            }
        }
        func canUndo() -> Bool { editor()?.undoManager?.canUndo ?? false }
        func undo() { _ = editor()?.tryToPerform(Selector(("undo:")), with: nil) }

        type("거실")
        try await until("서재가 받음") { a.store.day(today).comment == "거실" }
        try await until("되돌릴 수 있음") { canUndo() }
        b.store.editingGrace = 0
        a.store.editDay(today) { $0.comment = "서재의 새 글" }
        try await until("거실이 받음") { b.store.day(today).comment == "서재의 새 글" && editor()?.string == "서재의 새 글" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(canUndo(), "⌘Z 로 서재의 글을 지우고 옛 글로 돌아가지 않는다")
        undo()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(b.store.day(today).comment, "서재의 새 글")
        XCTAssertEqual(editor()?.string, "서재의 새 글")

        // 다른 칸의 편집은 ⌘Z 기록을 그대로 둔다: 이어 친 것만 되돌린다 (다른 기기의 다른 칸은 그대로)
        b.store.editingGrace = 5
        type("!")
        try await until("서재도 받음") { a.store.day(today).comment == "서재의 새 글!" }
        try await until("되돌릴 수 있음") { canUndo() }
        a.store.editDay(today) { $0.memos[0] = "다른 칸" }
        try await until("거실이 받음") { b.store.day(today).memos[0] == "다른 칸" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(canUndo(), "다른 칸이 바뀌어도 이 칸의 ⌘Z 기록은 그대로")
        undo()
        XCTAssertEqual(editor()?.string, "서재의 새 글", "이어 친 것만 되돌림")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(b.store.day(today).memos[0], "다른 칸")
        XCTAssertEqual(a.store.day(today).memos[0], "다른 칸")
    }

    func testGearInfoOnlyWhileOnAndPointsToSyncWhenSomethingNeedsAttention() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.9", name: "서재 Mac")
        XCTAssertNil(a.sync.gearInfo(), "꺼져 있으면 설정 단추는 예전 그대로")
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)

        a.sync.qaPresent(status: SyncViewStatus(state: .idle, lastSyncAt: ms - 180_000, live: true), inGroup: true, flow: nil)
        var g = try XCTUnwrap(a.sync.gearInfo(now: now))
        XCTAssertEqual(g.tone, .ok)
        XCTAssertFalse(g.attention)
        XCTAssertEqual(g.spoken, "동기화: 동기화됨 · 3분 전")
        try await until("팔레트 표시") { SyncIndicator.shared.gear?.tone == .ok }

        a.sync.qaPresent(status: SyncViewStatus(state: .offline, pending: 2), inGroup: true, flow: nil)
        g = try XCTUnwrap(a.sync.gearInfo(now: now))
        XCTAssertEqual(g.tone, .offline)
        XCTAssertFalse(g.attention, "오프라인은 저절로 풀린다")
        XCTAssertEqual(g.spoken, "동기화: 오프라인 · 기다리는 기록 2개")

        a.sync.qaPresent(status: SyncViewStatus(state: .idle, lastSyncAt: ms), inGroup: true, flow: nil, recoveryPending: true)
        g = try XCTUnwrap(a.sync.gearInfo(now: now))
        XCTAssertEqual(g.tone, .warn)
        XCTAssertTrue(g.attention)
        XCTAssertTrue(g.spoken.hasSuffix("복구 코드를 확인해 주세요"), g.spoken)

        for state in [SyncState.error, .quota, .removed, .groupGone] {
            a.sync.qaPresent(status: SyncViewStatus(state: state, lastSyncAt: ms), inGroup: true, flow: nil)
            XCTAssertEqual(a.sync.gearInfo(now: now)?.attention, true, "\(state)")
        }
        a.sync.qaPresent(status: nil, inGroup: true, flow: nil, startProblem: "이 Mac 의 동기화 그룹은 다른 서버(x)에 있어요.")
        XCTAssertEqual(a.sync.gearInfo(now: now)?.tone, .warn)
        a.sync.qaPresent(status: nil, inGroup: false, flow: nil)
        XCTAssertNil(a.sync.gearInfo(now: now))
        try await until("팔레트 표시 지움") { SyncIndicator.shared.gear == nil }
    }

    // MARK: 켤 때 (키체인)

    func testLaunchReadsKeychainOnlyAfterThisInstallJoined() async throws {
        let server = FakeSyncServer()
        let (a, _) = try await pairedMacs(server)
        let c = await a.creds.peek()
        // 같은 설정 · 같은 자격으로 다시 켠다 → 엔진을 띄우고 그룹에 그대로
        let again = await device(server, ip: "10.0.0.1", name: "서재 Mac", creds: CountingCredentials(c), defaults: a.defaults)
        XCTAssertTrue(again.sync.inGroup)
        XCTAssertEqual(again.engines.n, 1)
        let reads = await again.creds.reads
        XCTAssertGreaterThan(reads, 0, "그룹에 들어간 설치만 키체인을 읽는다")
        try await until("다시 동기화") { again.sync.status?.state == .idle }

        // 그룹 주소는 있는데 키체인 항목이 없다 (사용자가 지움): 꺼짐으로 돌아가고 표시도 지운다
        let d = freshDefaults()
        d.set("https://sync.spiralday.com", forKey: SyncController.Key.groupURL)
        let empty = await device(server, ip: "10.0.0.5", name: "x", defaults: d)
        XCTAssertFalse(empty.sync.inGroup)
        XCTAssertNil(d.string(forKey: SyncController.Key.groupURL))
        XCTAssertEqual(empty.engines.n, 0)

        // 키체인을 열지 못했다 (접근 거절): 그룹 주소는 두고 알린다 → [다시 해 보기]
        let d2 = freshDefaults()
        d2.set(a.defaults.string(forKey: SyncController.Key.groupURL), forKey: SyncController.Key.groupURL)
        let denied = CountingCredentials(c)
        await denied.failReads(KeychainError(status: errSecAuthFailed))
        let blocked = await device(server, ip: "10.0.0.6", name: "x", creds: denied, defaults: d2)
        XCTAssertFalse(blocked.sync.inGroup)
        XCTAssertEqual(blocked.sync.startProblem, "키체인에서 동기화 열쇠를 읽지 못했어요. 잠시 뒤 다시 해 볼게요.")
        XCTAssertNotNil(d2.string(forKey: SyncController.Key.groupURL))
        await denied.failReads(nil)
        await blocked.sync.retryStart()
        XCTAssertTrue(blocked.sync.inGroup)
        XCTAssertNil(blocked.sync.startProblem)

        // 키체인 항목이 손상: 조용히 "그룹 없음" 으로 보지 않고 알린다 → 정리하기
        let d3 = freshDefaults()
        d3.set("https://sync.spiralday.com", forKey: SyncController.Key.groupURL)
        let broken = CountingCredentials(c)
        await broken.failReads(CredentialsUnreadable())
        let bad = await device(server, ip: "10.0.0.7", name: "x", creds: broken, defaults: d3)
        XCTAssertTrue(bad.sync.credsUnreadable)
        XCTAssertFalse(bad.sync.inGroup)
        XCTAssertEqual(bad.engines.n, 0)
        let f = await bad.sync.forget()
        XCTAssertTrue(f.ok)
        XCTAssertFalse(bad.sync.credsUnreadable)
        let left = await broken.peek()
        XCTAssertNil(left)
        XCTAssertNil(d3.string(forKey: SyncController.Key.groupURL))
    }

    func testGroupOnAnotherServerIsNotStartedHere() async throws {
        let server = FakeSyncServer()
        let (a, _) = try await pairedMacs(server)
        let c = await a.creds.peek()
        let d = freshDefaults()
        d.set("http://127.0.0.1:9000", forKey: SyncController.Key.groupURL)   // 디버그 빌드의 개발 서버에서 만든 그룹
        let x = await device(server, ip: "10.0.0.8", name: "x", creds: CountingCredentials(c), defaults: d)
        if SyncServer.allowsOverride {
            XCTAssertTrue(x.sync.inGroup, "디버그 빌드는 http 개발 서버의 그룹도 띄운다")
        } else {
            XCTAssertEqual(x.sync.startProblem, "이 Mac 의 동기화 그룹은 다른 서버(http://127.0.0.1:9000)에 있어요.")
            XCTAssertEqual(x.engines.n, 0)
        }
    }

    func testStaleCredentialsAreForgottenOnlyWhenStartingFresh() async throws {
        let server = FakeSyncServer()
        let (a, _) = try await pairedMacs(server)
        let old = await a.creds.peek()
        // 설정을 지운 Mac: 키체인에는 예전 자격이 남았다. 켤 때는 읽지 않는다
        let left = CountingCredentials(old)
        let before = server.log.count
        let fresh = await device(server, ip: "10.0.0.3", name: "새로 깐 Mac", creds: left)
        XCTAssertFalse(fresh.sync.inGroup)
        let reads = await left.reads
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(server.log.count, before, "켜기 전에는 서버에 아무것도 보내지 않는다")
        // [동기화 켜기]: 예전 자격으로 조용히 예전 그룹에 붙지 않고 새 그룹을 만든다
        fresh.store.createBook(name: "새 플래너", start: today, end: nil)
        let r = await fresh.sync.create(deviceName: "새로 깐 Mac")
        XCTAssertTrue(r.ok, r.message ?? "")
        let now = await left.peek()
        XCTAssertNotNil(now)
        XCTAssertNotEqual(now?.gid, old?.gid, "새 그룹")
    }

    // MARK: Mac 수명 (잠자기 · 깨어남 · 네트워크 · 끝내기)

    func testSleepStopsAndWakeResumes() async throws {
        let server = FakeSyncServer()
        let (a, b) = try await pairedMacs(server)
        let book = a.store.createBook(name: "같이 쓰는 플래너", start: today, end: nil)
        try await until("거실에 책") { b.store.books.contains { $0.id == book } }
        b.store.activate(book)
        // 잠들기 직전의 편집은 올리고 잔다
        b.store.editDay(today) { $0.comment = "잠들기 직전" }
        b.sync.willSleep()
        try await until("서재가 받음") { a.store.day(today).comment == "잠들기 직전" }
        try await Task.sleep(nanoseconds: 300_000_000)
        // 자는 동안에는 받지 않는다 (연결 · 주기 확인을 닫았다)
        a.store.editDay(today) { $0.comment = "거실이 자는 동안" }
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(b.store.day(today).comment, "잠들기 직전")
        b.sync.networkChanged()
        b.sync.appBecameActive()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(b.store.day(today).comment, "잠들기 직전", "자는 동안의 네트워크 · 활성 알림으로는 깨우지 않는다")
        // 깨어나면 다시 붙어 받는다
        b.sync.didWake()
        try await until("깨어나서 받음") { b.store.day(today).comment == "거실이 자는 동안" }
        b.store.editDay(today) { $0.memos[0] = "깨어나서 씀" }
        try await until("서재가 받음") { a.store.day(today).memos[0] == "깨어나서 씀" }

        // 잠들다가 곧바로 깨어남 (올리는 중에): 깨어 있는 동안 계속 맞춘다
        b.sync.willSleep()
        b.sync.didWake()
        try await Task.sleep(nanoseconds: 400_000_000)
        a.store.editDay(today) { $0.memos[1] = "그 뒤에 서재가 씀" }
        try await until("거실이 받음") { b.store.day(today).memos[1] == "그 뒤에 서재가 씀" }
    }

    func testQuitUploadsWhatIsLeftWithoutWaitingLong() async throws {
        let server = FakeSyncServer()
        let (a, b) = try await pairedMacs(server)
        let book = a.store.createBook(name: "같이 쓰는 플래너", start: today, end: nil)
        try await until("거실에 책") { b.store.books.contains { $0.id == book } }
        b.store.activate(book)
        b.store.editDay(today) { $0.comment = "끄기 직전" }   // 아직 저장 전 (0.6초 뒤 저장)
        var done = false
        b.sync.prepareToQuit(timeout: 3) { done = true }
        try await until("끝낼 준비", timeout: 4) { done }
        await a.sync.syncNow()
        try await until("서재가 받음") { a.store.day(today).comment == "끄기 직전" }

        // 오프라인이면 오래 기다리지 않는다
        let net = FakeNet()
        net.offline = true
        let c = await a.creds.peek()
        let off = await device(server, ip: "10.0.0.1", name: "서재 Mac", creds: CountingCredentials(c), defaults: a.defaults, net: net)
        XCTAssertTrue(off.sync.inGroup)
        var done2 = false
        let t0 = Date()
        off.sync.prepareToQuit(timeout: 1) { done2 = true }
        try await until("끝낼 준비", timeout: 3) { done2 }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
    }

    // MARK: 백업

    func testJoinStopsWhenTheBackupBeforeMergingFails() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        a.store.createBook(name: "서재 플래너", start: today, end: nil)
        // 백업 폴더를 만들 수 없게 (그 자리에 파일) — 디스크 가득 참 · 쓰기 오류 흉내
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ctl-blocker-\(UUID().uuidString)")
        dirs.append(blocker)
        try Data("x".utf8).write(to: blocker)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac", backupRoot: blocker.appendingPathComponent("backups"))
        b.store.createBook(name: "거실 플래너", start: today, end: nil)
        b.store.editDay(today) { $0.comment = "거실에서" }
        _ = await a.sync.create(deviceName: "서재 Mac")
        a.sync.recoveryConfirmed()
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, _, _))? = a.sync.flow else { return XCTFail("QR") }
        _ = await b.sync.joinStart(qr, deviceName: "거실 Mac")
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail("확인 숫자") }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        _ = await a.sync.pairApprove(digits: digits)
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }

        let r = await b.sync.joinAccept()
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.backupFailed, "백업 없이 합치지 않고 묻는다")
        XCTAssertEqual(r.message, "합치기 전 백업 파일을 쓰지 못했어요.")
        XCTAssertFalse(b.sync.inGroup)
        guard case .join(.approved, _)? = b.sync.flow else { return XCTFail("승인 화면에 그대로: \(String(describing: b.sync.flow))") }
        // 사용자가 [백업 없이 합치기]
        let r2 = await b.sync.joinAccept(withoutBackup: true)
        XCTAssertTrue(r2.ok, r2.message ?? "")
        XCTAssertTrue(b.sync.inGroup)
        XCTAssertEqual(b.sync.flow, .join(stage: .done(backup: nil), localBooks: ["거실 플래너"]))

        // 되살리기도 같다
        let other = await device(server, ip: "10.0.0.4", name: "작업실 Mac", backupRoot: blocker.appendingPathComponent("b2"))
        other.store.createBook(name: "또 다른 플래너", start: today, end: nil)
        let rr = await other.sync.restore(code: Codes.newRecoveryCode(), deviceName: "작업실 Mac")
        XCTAssertTrue(rr.backupFailed)
        XCTAssertFalse(other.sync.inGroup)
        // 틀린 복구 코드 (백업 없이)
        let wrong = await other.sync.restore(code: Codes.newRecoveryCode(), deviceName: "작업실 Mac", withoutBackup: true)
        XCTAssertFalse(wrong.ok)
        XCTAssertEqual(wrong.code, .recoveryNotFound)
        XCTAssertNil(other.sync.flow)
    }

    func testBackupSnapshotKeepsTheLatestTenAndUsesBackupNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ctl-backups-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir.appendingPathComponent("planner"))
        XCTAssertNil(try SyncBackups.snapshot(store, root: dir.appendingPathComponent("b")), "내 플래너가 없으면 만들지 않는다")
        store.createBook(name: "회사/일", start: today, end: nil)
        store.editDay(today) { $0.comment = "백업할 글" }
        for i in 0..<12 {
            _ = try SyncBackups.snapshot(store, root: dir.appendingPathComponent("b"), now: Date().addingTimeInterval(Double(i)))
        }
        let list = SyncBackups.list(root: dir.appendingPathComponent("b"))
        XCTAssertEqual(list.count, 10)
        let file = try XCTUnwrap(list.first?.files.first)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("Spiralday 백업 - 회사-일 "), file.lastPathComponent)
        let data = try PlannerStore.decodeFile(PlannerData.self, from: Data(contentsOf: file))
        XCTAssertEqual(data.days[Dates.key(today)]?.comment, "백업할 글", "저장 전 편집까지")
    }

    // MARK: 메뉴 · 쓸 수 없는 실행

    func testHistoryMenuFollowsTheCurrentPage() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        let book = a.store.createBook(name: "내 플래너", start: Dates.add(days: -30, to: today), end: nil)
        XCTAssertNil(a.sync.historyRequestForCurrentPage(), "꺼져 있으면 없다")
        _ = await a.sync.create(deviceName: "서재 Mac")
        a.sync.recoveryConfirmed()
        let day = try XCTUnwrap(a.sync.historyRequestForCurrentPage())
        XCTAssertEqual(day.book, book)
        XCTAssertEqual(day.kind, .day)
        XCTAssertEqual(Dates.key(day.date), Dates.key(a.state.currentDate))
        a.state.switchKind(.weekly)
        try await until("주간") { a.state.kind == .weekly }
        XCTAssertEqual(a.sync.historyRequestForCurrentPage()?.kind, .week)
        a.state.switchKind(.home)
        try await until("홈") { a.state.kind == .home }
        XCTAssertNil(a.sync.historyRequestForCurrentPage(), "홈에는 이전 버전이 없다")
    }

    func testSuggestedNameIsThisMacsNameReadLocally() {
        let n = SyncController.defaultDeviceName()
        XCTAssertFalse(n.isEmpty)
        XCTAssertLessThanOrEqual(n.count, 40)
        XCTAssertFalse(n.contains("\n"))
    }

    func testDemoRunIsUnavailableAndNeverMakesAnEngine() async throws {
        let store = PlannerStore(inMemory: true)
        XCTAssertNil(SyncController.Environment.live(store: store), "메모리 저장소는 동기화하지 않는다")
        let c = SyncController.unavailable(store: store, defaults: freshDefaults())
        XCTAssertTrue(c.ready)
        XCTAssertFalse(c.available)
        let r = await c.create(deviceName: "x")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(c.inGroup)
        XCTAssertNil(c.gearInfo())
    }
}

/// 플래너 종이의 COMMENT 칸 (일간 장처럼 저장소를 보고 다시 그린다)
private struct CommentField: View {
    let day: Date
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        InlineField(text: store.dayField(day, \.comment), font: .body, key: "c|\(Dates.key(day))")
    }
}
