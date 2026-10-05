import XCTest
import AppKit
import SpiraldayKit
import SpiraldaySync
import SpiraldaySyncTesting
@testable import Spiralday

/// Mac 처음 안내에서 동기화로 합류하기 (사장님 피드백 I · P · O, 사장님 결정 2 (가)+(나)).
/// - (가) 처음 안내 1 · 2 단계의 "다른 기기의 플래너를 동기화로 가져오기" → 합류 → 책을 억지로 만들지 않고 3–6 사용법 → 7 준비 끝의 모양
///   (가져왔어요 · 되찾았어요 · 받는 중) → 둘러보기. iOS · Android 와 같은 상태 기계 (FirstRunFlow, 공유 벡터 Tests/Fixtures/mobile-tour.json)
/// - (나) 합류 · 복구 코드로 합칠 때 막 만든 그대로인 내 플래너(처음 켤 때 만든 빈 '내 플래너')는 그룹에 올리지 않고 이 Mac 에서 지운다
///   (합치기 설명의 스위치, 기본 켬) — 새 Mac 이 합류할 때마다 모든 기기에 빈 '내 플래너' 가 생기던 것
/// 가짜 서버 · 메모리 열쇠 · 임시 폴더 (앱의 데이터 · 설정 · 키체인을 건드리지 않는다).
@MainActor
final class FirstRunJoinTests: XCTestCase {
    private var dirs: [URL] = []
    private var controllers: [SyncController] = []
    private var models: [OnboardingModel] = []

    override func tearDown() async throws {
        for m in models { m.stop() }
        models = []
        for c in controllers { await c.dispose() }
        controllers = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        SyncIndicator.shared.notice = nil
        SyncIndicator.shared.gear = nil
    }

    struct Device {
        let store: PlannerStore
        let state: AppState
        let sync: SyncController
    }

    /// 엔진의 시계를 앞으로 돌린다 (승인 기한이 지난 합류 — 앱 화면의 시계는 그대로)
    final class EngineClock: @unchecked Sendable {
        private let lock = NSLock()
        private var skewMs = 0
        func jump(_ ms: Int) { lock.lock(); skewMs += ms; lock.unlock() }
        func now() -> Int {
            lock.lock(); defer { lock.unlock() }
            return Int(Date().timeIntervalSince1970 * 1000) + skewMs
        }
    }

    private func device(_ server: FakeSyncServer, ip: String, name: String, firstRun: Bool = false,
                        clock: EngineClock? = nil) async -> Device {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-firstrun-\(UUID().uuidString)")
        dirs.append(dir)
        let store = PlannerStore(folder: dir.appendingPathComponent("planner"))
        // 처음 켠 Mac: 앱처럼 예시 플래너를 꽂아 둔다 (펼치지는 않는다)
        if firstRun { store.seedSampleBookIfNeeded() }
        let state = AppState(kind: .daily)
        state.store = store
        let env = SyncController.Environment(
            suggestedName: name, credentials: MemoryCredentialStore(), defaults: SyncMemoryDefaults(),
            makeEngine: { host, _, credentials in
                SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: ip), storage: MemorySyncStorage(),
                                             credentials: credentials, platform: .mac,
                                             now: { clock?.now() ?? Int(Date().timeIntervalSince1970 * 1000) },
                                             scanDelayMs: 10, pushDelayMs: 10, pollMs: 200, safetyPollMs: 1000))
            },
            pollIntervalMs: 20,
            backupRoot: dir.appendingPathComponent("backups"),
            watchesSystem: false)
        let sync = SyncController(store: store, env: env)
        controllers.append(sync)
        await sync.start(state: state)
        return Device(store: store, state: state, sync: sync)
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

    /// 그룹을 만든 기기 (서재 Mac) — 플래너 한 권과 바꾼 형광펜
    private func creator(_ server: FakeSyncServer, books: Bool = true) async throws -> Device {
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        if books {
            a.store.createBook(name: "서재 플래너", start: Dates.add(days: -10, to: today), end: nil)
            a.store.editDay(today) { $0.comment = "서재에서" }
            a.store.saveNow()
        }
        let created = await a.sync.create(deviceName: "서재 Mac")
        XCTAssertTrue(created.ok, created.message ?? "")
        a.sync.recoveryConfirmed()
        return a
    }

    /// b 가 a 의 그룹에 합류한다 (연결 글 → 확인 숫자 → 승인 → 합치기 설명 → 합치고 시작하기). 끝나면 b 의 흐름은 .join(.done)
    private func join(_ b: Device, to a: Device) async throws {
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, nil, _))? = a.sync.flow else { return XCTFail("QR 기다림") }
        let started = await b.sync.joinStart(SyncText.pastedPairingLink(qr)!, deviceName: "새 Mac")
        XCTAssertTrue(started.ok, started.message ?? "")
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail("확인 숫자") }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        let ok = await a.sync.pairApprove(digits: digits)
        XCTAssertTrue(ok.ok, ok.message ?? "")
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        let accepted = await b.sync.joinAccept()
        XCTAssertTrue(accepted.ok, accepted.message ?? "")
        guard case .join(.done, _)? = b.sync.flow else { return XCTFail("합류 끝") }
        await a.sync.endFlow()
    }

    // MARK: 공유 벡터 (iOS · Android 와 같은 상태 기계)

    /// 벡터의 단계 {"step": "ready", "variant": "joined"} → FirstRunStage
    private func stage(_ v: Any?) throws -> FirstRunStage {
        let o = try XCTUnwrap(v as? [String: Any], "\(String(describing: v))")
        switch try XCTUnwrap(o["step"] as? String) {
        case "welcome": return .welcome
        case "planner": return .planner
        case "ready": return .ready(try XCTUnwrap(FirstRunReady(rawValue: XCTUnwrap(o["variant"] as? String)), "\(o)"))
        case let s: throw XCTSkip("모르는 단계 \(s)")
        }
    }

    private func outcome(_ v: Any?) -> FirstRunSyncOutcome? { (v as? String).flatMap(FirstRunSyncOutcome.init(rawValue:)) }

    static let sharedVectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mobile-tour.json")

    /// Tests/Fixtures/mobile-tour.json 은 비공개 저장소 web/tests/fixtures/mobile-tour.json 을 바이트 그대로 복사한 것이다
    /// (그 파일의 about: "The SAME FILE, byte for byte"). 형식이 바뀌면 (version) 이 시험이 먼저 알려 준다
    func testTheMacFollowsTheSharedFirstRunVectors() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.sharedVectors)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2, "공유 벡터 형식이 바뀌었다 — 이 시험의 읽기를 맞춘다")
        let fr = try XCTUnwrap(root["firstRun"] as? [String: Any])
        var n = 0
        for r in try XCTUnwrap(fr["start"] as? [[String: Any]]) {
            let got = FirstRunFlow.startStage(hasUserBook: r["userBook"] as! Bool, inGroup: r["inGroup"] as! Bool)
            XCTAssertEqual(got, try stage(r["expect"]), "start \(r)")
            n += 1
        }
        for r in try XCTUnwrap(fr["afterJoin"] as? [[String: Any]]) {
            let how = try XCTUnwrap(r["how"] as? String)
            XCTAssertTrue(["join", "restore"].contains(how), how)
            let got = FirstRunFlow.afterJoin(restored: how == "restore", hasUserBook: r["userBook"] as! Bool)
            XCTAssertEqual(got, try stage(r["expect"]), "afterJoin \(r)")
            n += 1
        }
        for r in try XCTUnwrap(fr["sheetClosed"] as? [[String: Any]]) {
            let got = FirstRunFlow.sheetClosed(try stage(r["from"]), inGroup: r["inGroup"] as! Bool,
                                               hasUserBook: r["userBook"] as! Bool, outcome: outcome(r["outcome"]))
            XCTAssertEqual(got, try stage(r["expect"]), "sheetClosed \(r)")
            n += 1
        }
        for r in try XCTUnwrap(fr["bookArrived"] as? [[String: Any]]) {
            let got = FirstRunFlow.bookArrived(try stage(r["from"]), inGroup: r["inGroup"] as! Bool, outcome: outcome(r["outcome"]))
            XCTAssertEqual(got, try stage(r["expect"]), "bookArrived \(r)")
            n += 1
        }
        // 마치기: 실제 Mac 의 기록(OnboardingController.recordFinished)으로 — Mac 의 T 는 plannerTourDone (없음 · false = due)
        let suite = "spiralday.firstrun.vectors.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for r in try XCTUnwrap(fr["finish"] as? [[String: Any]]) {
            let given = (r["status"] as? String).map { FirstRunTourStatus(rawValue: $0)! }
            let expect = try XCTUnwrap(r["expect"] as? [String: Any])
            let want = try XCTUnwrap(FirstRunTourStatus(rawValue: XCTUnwrap(expect["status"] as? String)))
            let f = FirstRunFlow.finish(tour: given)
            XCTAssertEqual(f.onboardingDone, expect["onboardingDone"] as? Bool, "finish \(r)")
            XCTAssertEqual(f.tour, want, "finish \(r)")
            defaults.removePersistentDomain(forName: suite)
            if let given { defaults.set(given.startedOnMac, forKey: TourController.doneKey) }
            OnboardingController.recordFinished(defaults)
            XCTAssertTrue(defaults.bool(forKey: OnboardingController.doneKey), "finish \(r)")
            let after = FirstRunTourStatus.mac(plannerTourDone: defaults.object(forKey: TourController.doneKey) as? Bool)
            XCTAssertEqual(after.startedOnMac, want.startedOnMac, "finish \(r): Mac 의 plannerTourDone")
            n += 1
        }
        // 옮기기(한 번)는 Android 만: O 를 적지 않던 예전 판이 있었다. Mac 은 첫 판(1.0)부터 O 를 적어서, O 가 없으면 늘 처음 안내를 띄운다
        // (내 플래너를 만든 뒤 [시작하기] 전에 꺼진 Mac — §3.3 ready(created)). 줄은 읽어서 형식만 확인한다
        for r in try XCTUnwrap(fr["migrate"] as? [[String: Any]]) {
            XCTAssertNotNil(r["userBookAtLaunch"] as? Bool, "migrate \(r)")
            if let o = r["onboardingDone"] as? Bool, o, r["userBookAtLaunch"] as? Bool == true {
                XCTAssertFalse(FirstRunFlow.needsFirstRun(onboardingDone: o, hasUserBook: true), "migrate \(r)")
            }
        }
        XCTAssertGreaterThanOrEqual(n, 22)
        XCTAssertEqual(FirstRunFlow.waitingPatience, 30, "받는 중 30초 뒤에만 [새 플래너 만들기]")
    }

    /// 준비 끝의 문구도 공유 벡터와 같다 (Mac 은 "이 기기" 대신 "이 Mac")
    func testTheReadyCopyMatchesTheSharedVectors() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.sharedVectors)) as? [String: Any])
        let ready = try XCTUnwrap(root["ready"] as? [String: [String: String]])
        func mac(_ s: String?) -> String? { s?.replacingOccurrences(of: "이 기기에도", with: "이 Mac 에도") }
        for v in FirstRunReady.allCases {
            XCTAssertEqual(OnboardingCopy.headline(v, late: false), ready[v.rawValue]?["title"], "\(v)")
            XCTAssertEqual(OnboardingCopy.message(v, late: false), mac(ready[v.rawValue]?["body"]), "\(v)")
        }
        XCTAssertEqual(OnboardingCopy.headline(.waiting, late: true), ready["waitedOut"]?["title"])
        XCTAssertEqual(OnboardingCopy.message(.waiting, late: true), ready["waitedOut"]?["body"])
    }

    // MARK: (가) 처음 안내에서 합류

    /// 처음 켠 Mac 이 처음 안내에서 합류: 책을 억지로 만들지 않고, 사용법(3–6)을 지나 "플래너를 가져왔어요!" 로 — 그룹에는 빈 책이 없다
    func testFirstRunJoinKeepsTheTutorialAndCreatesNoBook() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        XCTAssertTrue(b.store.userBooks.isEmpty)
        XCTAssertTrue(b.store.hasSampleBook)
        let tourBefore = UserDefaults.standard.object(forKey: TourController.doneKey) as? Bool

        let m = OnboardingModel(store: b.store, sync: b.sync)
        models.append(m)
        XCTAssertEqual(m.step, .welcome)
        XCTAssertTrue(m.canJoin, "처음 켬 · 그룹 밖 · 동기화 준비됨: 합류 길이 보인다")
        XCTAssertTrue(m.blocking)
        XCTAssertFalse(m.canVisit(.turn), "만들거나 합류하기 전에는 사용법으로 못 간다")
        m.go(.planner)
        try await until("플래너 단계") { m.step == .planner }
        XCTAssertTrue(m.isCreating)
        m.openJoin()
        XCTAssertTrue(m.showsSyncSheet)
        XCTAssertEqual(b.sync.localStep, .join, "시트는 설정 → 동기화의 합류 화면")

        try await join(b, to: a)
        XCTAssertEqual(m.outcome, .joined)
        XCTAssertTrue(m.showsSyncSheet, "[확인] 을 누르기 전에는 시트가 그대로")
        // [확인]: 흐름이 끝나 시트가 닫힌다 → 사용법으로 (책을 만들지 않는다)
        await b.sync.endFlow()
        try await until("사용법으로") { m.step == .turn }
        XCTAssertFalse(m.showsSyncSheet)
        XCTAssertTrue([FirstRunReady.joined, .waiting].contains(m.readyVariant), "\(m.readyVariant)")
        XCTAssertFalse(m.blocking, "그룹에 들어왔으니 플래너가 오는 동안 사용법을 본다")
        XCTAssertTrue(m.canVisit(.ready))
        XCTAssertFalse(b.store.userBooks.contains { $0.name == BookDraft.defaultName }, "합류하면 '내 플래너' 를 만들지 않는다")

        // 그룹의 플래너가 들어온다 → 준비 끝은 "플래너를 가져왔어요!"
        try await until("서재 플래너가 새 Mac 에") { b.store.userBooks.map(\.name) == ["서재 플래너"] }
        try await until("가져왔어요") { m.readyVariant == .joined }
        m.skip()
        try await until("준비 끝") { m.step == .ready }
        XCTAssertTrue(m.canPrimary)
        XCTAssertEqual(m.primaryTitle, "시작하기")
        XCTAssertEqual(m.myBook?.name, "서재 플래너")

        // 시작하기 (OnboardingController.finish 가 하는 책 정리): 이미 받은 책이 있으니 아무것도 만들지 않는다
        OnboardingController.settleBooksOnFinish(store: b.store, sync: b.sync, joining: m.isJoining)
        XCTAssertEqual(b.store.userBooks.map(\.name), ["서재 플래너"])
        // 둘러보기는 그대로 남아 있다 (동기화 · 합류는 둘러보기 표시를 건드리지 않는다)
        XCTAssertEqual(UserDefaults.standard.object(forKey: TourController.doneKey) as? Bool, tourBefore)

        // 그룹에도 빈 책이 없다
        b.store.saveNow()
        await b.sync.syncNow()
        await a.sync.syncNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(a.store.userBooks.map(\.name), ["서재 플래너"], "새 Mac 의 합류가 그룹에 빈 '내 플래너' 를 퍼뜨리지 않는다")
    }

    /// 플래너가 없는 그룹에 합류: "받는 중" — [시작하기] 는 막혀 있고 30초 뒤에만 [새 플래너 만들기]. 그 사이 플래너가 오면 "가져왔어요"
    func testWaitingForThePlannerThenItArrives() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server, books: false)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        let m = OnboardingModel(store: b.store, sync: b.sync)
        models.append(m)
        m.go(.planner)
        try await until("플래너 단계") { m.step == .planner }
        m.openJoin()
        try await join(b, to: a)
        await b.sync.endFlow()
        try await until("사용법으로") { m.step == .turn }
        XCTAssertEqual(m.readyVariant, .waiting)
        XCTAssertTrue(m.waitingForBook)
        m.skip()
        try await until("준비 끝") { m.step == .ready }
        XCTAssertFalse(m.canPrimary, "받는 중에는 시작하지 못한다 (빈 책을 만들지 않는다)")
        XCTAssertFalse(m.waitingLate)
        XCTAssertEqual(m.primaryTitle, "시작하기")
        // 창을 닫아도 (합류 중) 기본 책을 만들지 않는다 — 예시 플래너를 펴 두고, 들어오는 첫 권을 편다
        XCTAssertTrue(m.isJoining)

        // 30초가 지났다 → [새 플래너 만들기]
        m.startWaiting(late: true)
        XCTAssertTrue(m.canPrimary)
        XCTAssertEqual(m.primaryTitle, "새 플래너 만들기")
        m.keepWaiting()
        XCTAssertFalse(m.waitingLate, "[계속 기다리기]")

        // 그룹에 플래너가 생긴다 → 들어오면 그 자리에서 "가져왔어요"
        a.store.createBook(name: "늦게 만든 플래너", start: today, end: nil)
        a.store.saveNow()
        try await until("플래너가 도착", timeout: 15) { b.store.userBooks.map(\.name) == ["늦게 만든 플래너"] }
        try await until("가져왔어요") { m.readyVariant == .joined }
        XCTAssertFalse(m.waitingForBook)
        XCTAssertTrue(m.canPrimary)
        XCTAssertEqual(m.step, .ready)
    }

    /// 받는 중에 30초가 지나 [새 플래너 만들기] → 플래너 만들기 → 사용법을 다시 거치지 않고 준비 끝 "준비 끝!"
    func testCreateInsteadAfterWaitingTooLong() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server, books: false)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        let m = OnboardingModel(store: b.store, sync: b.sync)
        models.append(m)
        m.go(.planner)
        try await until("플래너 단계") { m.step == .planner }
        m.openJoin()
        try await join(b, to: a)
        await b.sync.endFlow()
        try await until("사용법으로") { m.step == .turn }
        m.skip()
        try await until("준비 끝") { m.step == .ready }
        m.startWaiting(late: true)
        m.primary()
        try await until("플래너 만들기") { m.step == .planner }
        XCTAssertTrue(m.isCreating)
        m.primary()
        try await until("준비 끝으로 바로") { m.step == .ready }
        XCTAssertEqual(m.readyVariant, .created)
        XCTAssertEqual(b.store.userBooks.count, 1, "사용자가 고른 새 플래너 한 권")
    }

    /// 받는 중에 [이전] · Esc · 점으로 플래너 단계에 와도 30초 전에는 만들기 양식이 없다 — 받는 중 카드 · [다음] 뿐 (2026-10-05 검토:
    /// 예전에는 바로 '플래너 만들기' 가 켜져 있어서 빈 '내 플래너' 가 그룹의 모든 기기에 퍼졌다). 30초 뒤에만 [새 플래너 만들기]
    func testThePlannerStepWhileWaitingOffersNoCreateBefore30s() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server, books: false)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        let m = OnboardingModel(store: b.store, sync: b.sync)
        models.append(m)
        m.go(.planner)
        try await until("플래너 단계") { m.step == .planner }
        m.openJoin()
        try await join(b, to: a)
        await b.sync.endFlow()
        try await until("사용법으로") { m.step == .turn }
        XCTAssertEqual(m.readyVariant, .waiting)
        XCTAssertFalse(m.waitingLate)

        // [이전] (Esc · ← 도 같은 back) → 플래너 단계: 받는 중 카드
        m.back()
        try await until("플래너 단계로 돌아감") { m.step == .planner }
        XCTAssertEqual(m.plannerMode, .waiting)
        XCTAssertFalse(m.isCreating, "30초 전에는 만들기 양식이 없다")
        XCTAssertEqual(m.primaryTitle, "다음")
        XCTAssertTrue(m.canPrimary)
        m.composeAnother()
        XCTAssertEqual(m.plannerMode, .waiting, "받는 중에는 '한 권 더 만들기' 도 없다")
        m.createInstead()
        XCTAssertEqual(m.plannerMode, .waiting, "[새 플래너 만들기] 는 30초 뒤에만")
        m.primary()
        try await until("[다음] 은 사용법으로") { m.step == .turn }
        XCTAssertTrue(b.store.userBooks.isEmpty, "만든 책이 없다")

        // 점(준비 끝 → 플래너)도 같다
        m.go(.ready)
        try await until("준비 끝") { m.step == .ready }
        m.go(.planner)
        try await until("점으로 플래너 단계") { m.step == .planner }
        XCTAssertEqual(m.plannerMode, .waiting)
        XCTAssertFalse(m.isCreating)

        // 30초가 지났다 → 카드에 [새 플래너 만들기] → 만들기 양식 ([취소] 는 받는 중으로)
        m.startWaiting(late: true)
        m.createInstead()
        XCTAssertTrue(m.isCreating)
        XCTAssertTrue(m.isCreatingInsteadOfWaiting)
        XCTAssertEqual(m.backTitle, "취소")
        m.back()
        try await until("취소하면 준비 끝(받는 중)으로") { m.step == .ready }
        XCTAssertTrue(m.waitingForBook)
        m.go(.planner)
        try await until("다시 플래너 단계") { m.step == .planner }
        XCTAssertEqual(m.plannerMode, .waiting, "취소한 뒤에는 다시 받는 중 카드")

        // 그 사이 그룹에 빈 책이 퍼지지 않았다
        b.store.saveNow()
        await b.sync.syncNow()
        await a.sync.syncNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(a.store.userBooks.isEmpty, "받는 중의 플래너 단계가 그룹에 빈 '내 플래너' 를 만들지 않는다")

        // 받는 중 카드에 플래너가 도착하면 그 책으로 바뀐다
        a.store.createBook(name: "늦게 만든 플래너", start: today, end: nil)
        a.store.saveNow()
        try await until("플래너가 도착", timeout: 15) { b.store.userBooks.map(\.name) == ["늦게 만든 플래너"] }
        try await until("받은 플래너") { m.plannerMode == .existing }
        XCTAssertEqual(m.readyVariant, .joined)
    }

    /// 켤 때 (내 플래너 없음, 그룹 있음) = 받는 중에서 시작: 점으로 플래너 단계에 가도 받는 중 카드
    func testStartingWhileWaitingKeepsThePlannerStepWaiting() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server, books: false)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        try await join(b, to: a)
        await b.sync.endFlow()
        let m = OnboardingModel(store: b.store, sync: b.sync)
        models.append(m)
        XCTAssertEqual(m.step, .ready)
        XCTAssertEqual(m.readyVariant, .waiting)
        m.go(.planner)
        try await until("플래너 단계") { m.step == .planner }
        XCTAssertEqual(m.plannerMode, .waiting)
        XCTAssertFalse(m.isCreating)
        m.primary()
        try await until("[다음]") { m.step == .turn }
        XCTAssertTrue(b.store.userBooks.isEmpty)
    }

    /// 창을 닫을 때의 책 정리: 합류 중이면 만들지 않고 (예시를 펴 두고 들어오는 첫 권을 편다), 아니면 예전처럼 '내 플래너'
    func testClosingTheWindowWhileJoiningCreatesNoBook() async throws {
        let server = FakeSyncServer()
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        OnboardingController.settleBooksOnFinish(store: b.store, sync: b.sync, joining: true)
        XCTAssertTrue(b.store.userBooks.isEmpty, "합류 중에는 기본 책을 억지로 만들지 않는다")
        XCTAssertEqual(b.store.activeBook?.isSample, true, "빈 종이 대신 예시 플래너를 펴 둔다 (빈 종이에 쓴 것은 어디에도 저장되지 않는다)")
        XCTAssertTrue(b.sync.openArrivingBook)

        let c = await device(server, ip: "10.0.0.3", name: "다른 Mac", firstRun: true)
        OnboardingController.settleBooksOnFinish(store: c.store, sync: c.sync, joining: false)
        XCTAssertEqual(c.store.userBooks.map(\.name), [BookDraft.defaultName], "합류하지 않았으면 예전처럼")
        XCTAssertFalse(c.sync.openArrivingBook)
    }

    /// 처음 안내를 받는 중에 창을 닫았다 (받는 중) → 그룹의 플래너가 들어오면 예시 대신 그 책을 편다
    func testThePlannerArrivingAfterTheWindowClosedIsOpened() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server, books: false)
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        try await join(b, to: a)
        await b.sync.endFlow()
        OnboardingController.settleBooksOnFinish(store: b.store, sync: b.sync, joining: true)
        XCTAssertEqual(b.store.activeBook?.isSample, true)
        a.store.createBook(name: "서재 플래너", start: today, end: nil)
        a.store.saveNow()
        try await until("들어온 책을 편다", timeout: 15) { b.store.activeBook?.name == "서재 플래너" }
        XCTAssertFalse(b.sync.openArrivingBook, "한 번만")
    }

    // MARK: (나) 막 만든 그대로인 내 플래너는 그룹에 올리지 않는다

    /// 예전 처음 안내가 만든 빈 '내 플래너' 가 있는 Mac 이 설정 → 동기화로 합류: 합치기 설명에 빼기 스위치(기본 켬) — 빈 책은 지우고
    /// 내용이 있는 책은 합친다. 그룹을 만든 기기의 책장에 빈 '내 플래너' 가 생기지 않는다
    func testAnUntouchedLocalPlannerIsNotSpreadWhenJoining() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac", firstRun: true)
        let blank = b.store.createBook(name: BookDraft.defaultName, start: today, end: nil)
        // 펼쳐 보기만 한 것 (쪽 바꾸기)은 고친 것이 아니다
        b.store.editPrefs { $0.lastKind = .weekly }
        let used = b.store.createBook(name: "거실 플래너", start: today, end: nil)
        b.store.editDay(today) { $0.comment = "거실에서" }
        b.store.activate(blank)
        b.store.saveNow()
        XCTAssertEqual(b.store.untouchedUserBooks().map(\.id), [blank], "내용이 있는 책은 막 만든 그대로가 아니다")

        try await join(b, to: a)
        XCTAssertFalse(b.store.userBooks.contains { $0.id == blank }, "빈 '내 플래너' 는 이 Mac 에서 지웠다")
        XCTAssertTrue(b.store.userBooks.contains { $0.id == used })
        await b.sync.endFlow()
        try await until("책장이 합쳐짐") {
            Set(a.store.userBooks.map(\.name)) == ["서재 플래너", "거실 플래너"]
                && Set(b.store.userBooks.map(\.name)) == ["서재 플래너", "거실 플래너"]
        }
        b.store.saveNow()
        await b.sync.syncNow()
        await a.sync.syncNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(a.store.userBooks.contains { $0.name == BookDraft.defaultName }, "그룹에 빈 '내 플래너' 가 퍼지지 않는다")
        XCTAssertFalse(b.store.activeBook?.isSample ?? true, "남은 내 책을 편다")
    }

    /// 빈 책만 있던 Mac: 빼고 나면 내 플래너가 없다 → 들어오는 그룹의 첫 권을 편다 (예시 플래너에 머물지 않는다)
    func testOnlyTheBlankPlannerDroppedOpensTheGroupsPlanner() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac", firstRun: true)
        b.store.createBook(name: BookDraft.defaultName, start: today, end: nil)
        b.store.saveNow()
        try await join(b, to: a)
        XCTAssertTrue(b.store.userBooks.isEmpty || b.store.userBooks.map(\.name) == ["서재 플래너"])
        await b.sync.endFlow()
        try await until("그룹의 책을 편다") { b.store.activeBook?.name == "서재 플래너" }
        XCTAssertEqual(b.store.userBooks.map(\.name), ["서재 플래너"])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(a.store.userBooks.map(\.name), ["서재 플래너"])
    }

    /// 스위치를 끄면 사용자가 고른 대로 빈 책도 합친다
    func testTurningTheSwitchOffKeepsTheBlankPlanner() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server)
        let b = await device(server, ip: "10.0.0.2", name: "거실 Mac", firstRun: true)
        let blank = b.store.createBook(name: BookDraft.defaultName, start: today, end: nil)
        b.store.saveNow()
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, nil, _))? = a.sync.flow else { return XCTFail("QR 기다림") }
        _ = await b.sync.joinStart(SyncText.pastedPairingLink(qr)!, deviceName: "거실 Mac")
        XCTAssertEqual(b.sync.untouchedLocalBooks.map(\.id), [blank], "합치기 설명이 보여 줄 빈 책")
        XCTAssertTrue(b.sync.dropUntouchedBooks, "기본은 빼기")
        b.sync.dropUntouchedBooks = false
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail("확인 숫자") }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        _ = await a.sync.pairApprove(digits: digits)
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        _ = await b.sync.joinAccept()
        XCTAssertTrue(b.store.userBooks.contains { $0.id == blank })
        await b.sync.endFlow()
        await a.sync.endFlow()
        try await until("빈 책도 합쳐짐") { Set(a.store.userBooks.map(\.name)) == ["서재 플래너", BookDraft.defaultName] }
    }

    /// 복구 코드로 되살릴 때도 같은 규칙 (합치기 설명이 같다)
    func testRestoringWithTheRecoveryCodeAlsoDropsTheBlankPlanner() async throws {
        let server = FakeSyncServer()
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        a.store.createBook(name: "서재 플래너", start: today, end: nil)
        a.store.saveNow()
        _ = await a.sync.create(deviceName: "서재 Mac")
        guard case .recovery(.create, .show(let code))? = a.sync.flow else { return XCTFail("복구 코드") }
        a.sync.recoveryConfirmed()
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        let blank = b.store.createBook(name: BookDraft.defaultName, start: today, end: nil)
        b.store.saveNow()
        let r = await b.sync.restore(code: code, deviceName: "새 Mac")
        XCTAssertTrue(r.ok, r.message ?? "")
        XCTAssertFalse(b.store.userBooks.contains { $0.id == blank })
        await b.sync.endFlow()
        try await until("그룹의 책을 편다") { b.store.activeBook?.name == "서재 플래너" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(a.store.userBooks.map(\.name), ["서재 플래너"])
    }

    /// 되살리기가 실패하면 (지난 · 다른 그룹의 복구 코드 — 글자 모양은 맞아 화면이 받아들인다) 뺀 빈 플래너를 그대로 되돌린다:
    /// 같은 id · 같은 자리 · 다시 펼침 (2026-10-05 검토: 합치지도 않았는데 지워져서 SyncBackups 에만 남았다)
    func testAFailedRestoreKeepsTheBlankPlanner() async throws {
        let other = FakeSyncServer()
        let o = await device(other, ip: "10.0.0.9", name: "다른 그룹")
        o.store.createBook(name: "다른 플래너", start: today, end: nil)
        o.store.saveNow()
        _ = await o.sync.create(deviceName: "다른 그룹")
        guard case .recovery(.create, .show(let code))? = o.sync.flow else { return XCTFail("복구 코드") }
        XCTAssertTrue(SyncText.recoveryInputHint(code).ok, "화면은 이 코드를 받아들인다")

        let server = FakeSyncServer()
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true)
        let used = b.store.createBook(name: "쓰던 플래너", start: today, end: nil)
        b.store.editDay(today) { $0.comment = "적은 것" }
        let blank = b.store.createBook(name: "2027 계획", start: Dates.add(days: 3, to: today), end: nil, cover: 4)
        b.store.saveNow()
        let before = b.store.library
        XCTAssertEqual(b.store.untouchedUserBooks().map(\.id), [blank])

        let r = await b.sync.restore(code: code, deviceName: "새 Mac")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(b.sync.inGroup)
        XCTAssertEqual(b.store.library.books, before.books, "뺀 빈 플래너가 같은 id · 같은 자리 · 같은 표지로 돌아온다")
        XCTAssertEqual(b.store.activeBook?.id, blank, "펼쳐 있던 책을 다시 편다")
        XCTAssertFalse(b.sync.openArrivingBook)
        XCTAssertEqual(b.store.untouchedUserBooks().map(\.id), [blank])
        XCTAssertEqual(b.sync.untouchedLocalBooks.map(\.id), [blank], "다시 시도하면 합치기 설명이 또 보여 준다")
        if case .data = b.store.readBookRaw(blank) {} else { XCTFail("책 파일도 돌아온다") }
        XCTAssertTrue(b.store.userBooks.contains { $0.id == used })

        // 맞는 복구 코드로 다시 하면 그때 뺀다
        let a = await device(server, ip: "10.0.0.1", name: "서재 Mac")
        a.store.createBook(name: "서재 플래너", start: today, end: nil)
        a.store.saveNow()
        _ = await a.sync.create(deviceName: "서재 Mac")
        guard case .recovery(.create, .show(let good))? = a.sync.flow else { return XCTFail("복구 코드") }
        a.sync.recoveryConfirmed()
        await b.sync.endFlow()
        let ok = await b.sync.restore(code: good, deviceName: "새 Mac")
        XCTAssertTrue(ok.ok, ok.message ?? "")
        XCTAssertFalse(b.store.userBooks.contains { $0.id == blank })
        await b.sync.endFlow()
        try await until("책장이 합쳐짐") { Set(a.store.userBooks.map(\.name)) == ["서재 플래너", "쓰던 플래너"] }
        XCTAssertFalse(a.store.userBooks.contains { $0.name == "2027 계획" })
    }

    /// 합류의 [합치고 시작하기] 가 실패해도 (승인 기한이 지남 — 엔진의 시계) 뺀 빈 플래너를 되돌린다
    func testAFailedJoinAcceptKeepsTheBlankPlanner() async throws {
        let server = FakeSyncServer()
        let a = try await creator(server)
        let clock = EngineClock()
        let b = await device(server, ip: "10.0.0.2", name: "새 Mac", firstRun: true, clock: clock)
        let blank = b.store.createBook(name: BookDraft.defaultName, start: today, end: nil)
        b.store.saveNow()
        await a.sync.pairStart(.qr)
        guard case .pair(.qr, .waiting(let qr?, nil, _))? = a.sync.flow else { return XCTFail("QR 기다림") }
        _ = await b.sync.joinStart(SyncText.pastedPairingLink(qr)!, deviceName: "새 Mac")
        guard case .join(.waiting(let digits, _), _)? = b.sync.flow else { return XCTFail("확인 숫자") }
        try await until("요청") { if case .pair(_, .request)? = a.sync.flow { return true } else { return false } }
        _ = await a.sync.pairApprove(digits: digits)
        try await until("승인") { if case .join(.approved, _)? = b.sync.flow { return true } else { return false } }
        clock.jump(24 * 3_600_000)
        let r = await b.sync.joinAccept()
        XCTAssertFalse(r.ok, "승인 기한이 지나 들어가지 못한다")
        XCTAssertFalse(b.sync.inGroup)
        XCTAssertEqual(b.store.userBooks.map(\.id), [blank], "합치지 않았으니 빈 플래너는 그대로")
        XCTAssertEqual(b.store.activeBook?.id, blank)
        XCTAssertFalse(b.sync.openArrivingBook)
        await b.sync.endFlow()
        await a.sync.endFlow()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(a.store.userBooks.map(\.name), ["서재 플래너"])
    }

    /// "막 만든 그대로" 의 뜻: 무엇이든 하나 적거나 칠하거나 고르면 아니다
    func testWhatCountsAsUntouched() {
        XCTAssertTrue(PlannerData().isUntouched)
        var d = PlannerData()
        d.prefs.lastKind = .weekly
        d.days[Dates.key(today)] = DayRecord()
        XCTAssertTrue(d.isUntouched, "쪽 바꾸기 · 빈 날 기록은 고친 것이 아니다")
        let edits: [(String, (inout PlannerData) -> Void)] = [
            ("할 일", { $0.days[Dates.key(self.today)] = { var r = DayRecord(); r.tasks = [PlanTask(text: "a")]; return r }() }),
            ("칠한 칸", { $0.days[Dates.key(self.today)] = { var r = DayRecord(); r.slots[3] = 1; return r }() }),
            ("DAY OFF", { $0.days[Dates.key(self.today)] = { var r = DayRecord(); r.dayOff = true; return r }() }),
            ("주간 목표", { $0.weeks["2026-10-05"] = WeekRecord(goal: "목표") }),
            ("별점", { $0.weeks["2026-10-05"] = WeekRecord(stars: 3) }),
            ("형광펜 이름", { $0.prefs.categories[0].name = "개발" }),
            ("기본 컬러", { $0.prefs.defaultTheme = 2 }),
            ("저장한 D-day", { $0.prefs.ddays = [DDay(title: "시험", date: self.today)] }),
            ("첫 장의 말", { $0.prefs.motto = "하루하루" }),
        ]
        for (name, edit) in edits {
            var e = PlannerData()
            edit(&e)
            XCTAssertFalse(e.isUntouched, name)
        }
    }
}
