// 실시간 쓰기 — 검토 반영: 멈췄다 켠 뒤의 미뤄 둔 칸 · 칸마다 지키기 · 받기만 한 변경의 저장 · 넣기 묶음 · 찬 연결 · 죽은 연결 ·
// live 하위 프로토콜을 받지 않는 서버
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

/// 저절로 도는 엔진 (타이머 · 소켓) — 지키는 시간을 짧게
private func autoOptions(grace: Int = 150) -> (inout SyncEngineOptions) -> Void {
    { o in
        o.auto = true
        o.editingGraceMs = grace
        o.scanDelayMs = 5
        o.pushDelays = .all(30)
        o.liveThrottleMs = 5
        o.liveFlushMs = 10
        o.liveReceiveFlushMs = 10
        o.liveApplyMs = 0
        o.minPullIntervalMs = 0
    }
}

final class LiveHeldLifecycleTests: LiveCase {
    /// 미뤄 둔 칸이 있는 채로 멈췄다(stop) 다시 켜면(start) 지키는 시간이 끝난 뒤 다른 기기의 글이 들어간다 — 멈출 때 지우는 타이머를
    /// 다시 잡지 않으면 미뤄 둔 채로 남고, 돌아와 친 글자가 옛 글과 함께 새 도장을 얻어 그 글을 모든 기기에서 덮는다
    func testHeldFieldIsReleasedAfterWarmStopStart() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2, autoOptions(grace: 400))
        let a = devs[0], b = devs[1]
        let at = FieldAddress(key: key, field: "comment")
        b.engine.setEditing(at)
        setComment(b, book, "회의")
        try await waitUntil { liveComment(a, book) == "회의" }
        setComment(a, book, "회의 준비")
        try await waitUntil { b.live.held.count == 1 }
        XCTAssertEqual(liveComment(b, book), "회의")
        // 지키는 시간 안에 멈춘다 (iOS 뒤로 가기 · Mac 잠자기에서 suspend 를 거치지 않은 멈춤) → 곧 다시 켠다
        await b.engine.stop()
        await b.engine.start()
        // 다시 켜면 쓰던 칸이 아직 미뤄져 있음을 다시 알린다 (앱은 뒤로 가며 힌트를 지웠다)
        try await waitUntil { b.live.held.count >= 2 }
        XCTAssertEqual(b.live.held[1], at)
        // 지키는 시간이 끝나면 다른 기기의 글
        try await waitUntil(timeout: 3) { liveComment(b, book) == "회의 준비" }
        try await waitUntil { b.live.held.last == .some(nil) }
        // 돌아와 이어 친다 → 다른 기기의 글 + 내 글자 (옛 글 + 글자가 아니다)
        setComment(b, book, "회의 준비 자료")
        try await waitUntil { liveComment(a, book) == "회의 준비 자료" }
        await b.engine.setEditingAndSettle(nil)
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual([liveComment(a, book), liveComment(b, book)], ["회의 준비 자료", "회의 준비 자료"])
    }

    /// 뒤로 가기(suspend)는 쓰던 칸에 미뤄 둔 글을 바로 넣는다 (지키는 시간 안이어도 — 사용자는 치는 중이 아니다). held(nil) 이 와서
    /// 앱의 기다림(정리 훅)이 쌓이지 않는다. 앞으로 와서 같은 칸에 바로 이어 쳐도 다른 기기의 글이 남는다
    func testSuspendReleasesHeldTextAndTypingAfterResumeKeepsIt() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let at = FieldAddress(key: key, field: "comment")
        b.engine.setEditing(at)
        setComment(b, book, "회의")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "회의" }
        setComment(a, book, "회의 준비")
        await a.engine.flushLive()
        try await waitUntil { b.live.held.count == 1 }
        XCTAssertEqual(liveComment(b, book), "회의")
        await b.engine.suspend()
        XCTAssertEqual(liveComment(b, book), "회의 준비", "뒤로 갈 때 미뤄 둔 글을 넣는다")
        XCTAssertEqual(b.live.held.last, .some(nil))
        await b.engine.resume()
        try await waitUntil("presence") { await b.engine.presence?.peers == 1 }
        // 첫 응답자 그대로 돌아와 바로 이어 친다
        setComment(b, book, "회의 준비!")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "회의 준비!" }
        await b.engine.setEditingAndSettle(nil)
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual([liveComment(a, book), liveComment(b, book)], ["회의 준비!", "회의 준비!"])
        let pa = await a.engine.status.pending
        let pb = await b.engine.status.pending
        XCTAssertEqual(pa + pb, 0)
    }
}

final class LiveFieldProtectionTests: LiveCase {
    /// 할 일 1 에 치다 ↓ 로 할 일 2 로 옮긴 직후(한 글자도 치지 않음) 다른 기기가 할 일 2 를 고치면 바로 들어간다 — 전역 입력 시각을
    /// 물려받아 지키면, 이어 친 글자가 옛 글 + 글자로 새 도장을 얻어 다른 기기의 글을 모든 기기에서 지운다
    func testFieldMovedToIsNotProtectedByTypingInPreviousField() async throws {
        let server = FakeSyncServer()
        let T1 = "6BA7B820-9DAD-11D1-80B4-00C04FD430C8"
        let T2 = "6BA7B821-9DAD-11D1-80B4-00C04FD430C8"
        let (devs, book, key) = try await liveGroup(server, 2, book: { data in
            var o = data.objectValue!
            var day = emptyDayJSON()
            day["tasks"] = [task(T1, "", row: 0), task(T2, "회의", row: 1)]
            o["days"] = [LiveD: .object(day)]
            return .object(o)
        })
        let a = devs[0], b = devs[1]
        let t1 = FieldAddress(key: key, coll: .tasks, item: T1, field: "text")
        let t2 = FieldAddress(key: key, coll: .tasks, item: T2, field: "text")
        a.engine.setEditing(t1)
        setTasks(a, book, [task(T1, "장보기", row: 0), task(T2, "회의", row: 1)])
        await a.engine.flushLive()
        XCTAssertEqual(a.engine.editingProtected, true)
        // ↓ : 할 일 2 로 (치지 않음)
        a.engine.setEditing(t2)
        XCTAssertEqual(a.engine.editingProtected, false, "옮겨 온 칸은 그 칸에서 칠 때까지 지키지 않는다")
        try await waitUntil { dayTasks(b, book).arrayValue?.first?["text"] == "장보기" }
        setTasks(b, book, [task(T1, "장보기", row: 0), task(T2, "회의 준비", row: 1)])
        await b.engine.flushLive()
        try await waitUntil { dayTasks(a, book).arrayValue?.last?["text"] == "회의 준비" }
        XCTAssertTrue(a.live.held.isEmpty, "포커스만 있는 칸은 미루지 않는다")
        // A 가 이어 친다 → 다른 기기의 글 + A 의 글자
        setTasks(a, book, [task(T1, "장보기", row: 0), task(T2, "회의 준비 자료", row: 1)])
        await a.engine.flushLive()
        XCTAssertEqual(a.engine.editingProtected, true)
        try await waitUntil { dayTasks(b, book).arrayValue?.last?["text"] == "회의 준비 자료" }
        await a.engine.setEditingAndSettle(nil)
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual(dayTasks(a, book).arrayValue?.last?["text"], "회의 준비 자료")
        XCTAssertEqual(dayTasks(b, book).arrayValue?.last?["text"], "회의 준비 자료")
    }

    /// 같은 날의 다른 칸에 치다 옮긴 칸 · 다른 레코드를 바꾼 입력은 지금 칸을 지키지 않는다. 돌아온 칸은 그 칸에서 친 지 grace 안이면 다시 지킨다
    func testProtectionIsPerField() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0]
        let comment = FieldAddress(key: key, field: "comment")
        let memo = FieldAddress(key: key, field: "m0")
        XCTAssertNil(a.engine.editingProtected)
        a.engine.setEditing(comment)
        XCTAssertEqual(a.engine.editingProtected, false)
        setComment(a, book, "글")
        XCTAssertEqual(a.engine.editingProtected, true)
        a.engine.setEditing(memo)
        XCTAssertEqual(a.engine.editingProtected, false)
        // 다른 레코드(한 주)만 바꾼 입력은 이 칸을 지키지 않는다
        a.engine.liveEdit([RecordKeys.week(book, "2026-09-28")])
        XCTAssertEqual(a.engine.editingProtected, false)
        a.engine.setEditing(comment)
        XCTAssertEqual(a.engine.editingProtected, true, "방금 친 칸으로 돌아왔다")
        // 사용자가 치는 중이 아니다 (뒤로 감)
        await a.engine.suspend()
        XCTAssertEqual(a.engine.editingProtected, false)
    }
}

final class LiveCostTests: LiveCase {
    /// 다른 기기가 계속 치는 동안 받기만 하는 기기: 저장소 쓰기는 liveReceiveFlushMs 마다, 앱에 넣기는 liveApplyMs 마다 (초안마다가 아니다).
    /// 마지막 글은 꼭 들어가고 저장된다
    func testReceiverBatchesStorageWritesAndCoalescesApplies() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { o in
            autoOptions()(&o)
            o.liveReceiveFlushMs = 400
            o.liveApplyMs = 100
            o.pushDelays = .all(60_000)
        }
        let a = devs[0], b = devs[1]
        await settle(100)
        let writes0 = await b.storage.writes
        let applied0 = b.host.liveApplied
        let received0 = await b.engine.liveCounters.received
        var text = ""
        let start = Date()
        for ch in "안녕하세요 반갑습니다 오늘 회의는 세 시" {
            text.append(ch)
            setComment(a, book, text)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await waitUntil { liveComment(b, book) == text }
        let elapsed = Date().timeIntervalSince(start)
        await settle(500)
        let received = await b.engine.liveCounters.received - received0
        let writes = await b.storage.writes - writes0
        let applied = b.host.liveApplied - applied0
        XCTAssertGreaterThan(received, 12, "초안이 글자마다 왔다")
        // 넣기: 100 ms 마다 (+ 처음 · 끝)
        XCTAssertLessThanOrEqual(applied, Int(elapsed * 10) + 3, "넣기 \(applied) · 초안 \(received) · \(elapsed)초")
        XCTAssertLessThan(applied, received)
        // 저장: 400 ms 마다 (+ 처음 · 끝)
        XCTAssertLessThanOrEqual(writes, Int(elapsed / 0.4) + 3, "쓰기 \(writes) · \(elapsed)초")
        // 마지막 값이 저장소에 있다 (다시 켜도 남는다)
        let behind = await b.engine.storageBehind
        XCTAssertFalse(behind)
        for d in devs { await d.engine.dispose() }
    }

    /// 쓰기를 마친 뒤의 정리 앞(setEditingAndSettle)은 묶어 두고 기다리는 넣기도 지금 한다 — 정리가 아직 넣지 않은 다른 기기의 글을
    /// 보지 못하고 지우지 않게 (쓰던 칸의 레코드는 미뤄 둔 칸 다시 맞추기가 넣는다 — 여기서는 다른 날)
    func testSettleAppliesDraftsWaitingForTheNextApply() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2) { o in
            autoOptions()(&o)
            o.liveApplyMs = 600
            o.pushDelays = .all(60_000)
        }
        let a = devs[0], b = devs[1]
        let T = "6BA7B830-9DAD-11D1-80B4-00C04FD430C8"
        let other = "2026-10-03"
        func tasksOn(_ d: LDev) -> JSONValue { d.host.book(book)?["days"]?[other]?["tasks"] ?? .array([]) }
        func setOther(_ text: String) {
            a.host.edit(book) { data in
                var o = data.objectValue!
                var days = o["days"]?.objectValue ?? [:]
                var day = emptyDayJSON()
                day["tasks"] = [task(T, text, row: 0)]
                days[other] = .object(day)
                o["days"] = .object(days)
                return .object(o)
            }
            a.engine.liveEdit([RecordKeys.day(book, other)])
        }
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(b, book, "B")
        try await waitUntil { liveComment(a, book) == "B" }
        let r0 = await b.engine.liveCounters.received
        setOther("")
        try await waitUntil { tasksOn(b).arrayValue?.count == 1 }
        setOther("A 가 쓴 할 일")
        try await waitUntil { await b.engine.liveCounters.received >= r0 + 2 }
        XCTAssertEqual(tasksOn(b).arrayValue?.first?["text"], "", "다음 넣기를 기다린다 (600 ms 묶음)")
        await b.engine.setEditingAndSettle(nil)
        XCTAssertEqual(tasksOn(b).arrayValue?.first?["text"], "A 가 쓴 할 일", "정리 앞에서는 받은 글이 이미 앱에 있다")
        for d in devs { await d.engine.dispose() }
    }

    /// 저전력 모드: 받기만 한 변경의 저장 간격을 3배로
    func testLowPowerWidensReceiveFlush() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { o in
            autoOptions()(&o)
            o.liveReceiveFlushMs = 100
            o.liveApplyMs = 0
            o.pushDelays = .all(60_000)
            o.lowPower = { true }
        }
        let a = devs[0], b = devs[1]
        await settle(100)
        let writes0 = await b.storage.writes
        var text = ""
        let start = Date()
        for ch in "저전력 모드에서 받기만 하는 기기" {
            text.append(ch)
            setComment(a, book, text)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await waitUntil { liveComment(b, book) == text }
        let elapsed = Date().timeIntervalSince(start)
        await settle(400)
        let writes = await b.storage.writes - writes0
        XCTAssertLessThanOrEqual(writes, Int(elapsed / 0.3) + 3, "쓰기 \(writes) · \(elapsed)초 (300 ms 간격)")
        for d in devs { await d.engine.dispose() }
    }
}

final class LiveConnectionTests: LiveCase {
    /// 보내기 대기가 찬 연결(반쯤 열린 셀룰러): 봉인하기 전에 보고, 다시 보내 보는 간격을 늘린다 (50 ms 마다 봉인을 버리지 않는다)
    func testFullSendBufferBacksOffBeforeSealing() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { o in
            autoOptions()(&o)
            o.liveThrottleMs = 10
            o.pushDelays = .all(60_000)
        }
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        server.setBuffered(deviceId: aid, bytes: 1 << 20)
        setComment(a, book, "막힌 연결")
        try await Task.sleep(nanoseconds: 800_000_000)
        let c = await a.engine.liveCounters
        XCTAssertEqual(server.draftsSent(by: aid), 0)
        // 10 ms 마다라면 80번 — 늘리는 간격이면 10 · 20 · 40 · 80 · 160 · 320 …
        XCTAssertLessThanOrEqual(c.deferred, 9, "미룬 틱 \(c.deferred)")
        XCTAssertGreaterThanOrEqual(c.deferred, 3)
        // 연결이 풀리면 다음 입력에 바로 (합쳐서)
        server.setBuffered(deviceId: aid, bytes: 0)
        setComment(a, book, "막힌 연결 풀림")
        try await waitUntil { liveComment(b, book) == "막힌 연결 풀림" }
        for d in devs { await d.engine.dispose() }
    }

    /// 반쯤 열린 연결: ping 에 답이 없으면 닫고 다시 연결한다 (presence · 초안이 되살아난다)
    func testUnansweredPingReconnects() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { o in
            autoOptions()(&o)
            o.pingMs = 60
            o.pongTimeoutMs = 60
        }
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        // 답하는 연결은 그대로 (pong 이 온다)
        let n0 = server.socketOffers(deviceId: aid).count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(server.socketOffers(deviceId: aid).count, n0, "답하는 연결을 끊지 않는다")
        server.stallSockets(deviceId: aid)
        try await waitUntil(timeout: 3) { server.socketOffers(deviceId: aid).count > n0 }
        try await waitUntil("presence") { await a.engine.presence?.peers == 1 }
        setComment(a, book, "다시 붙음")
        try await waitUntil { liveComment(b, book) == "다시 붙음" }
        for d in devs { await d.engine.dispose() }
    }

    /// 서버 앞의 무엇이 live 하위 프로토콜을 내민 업그레이드를 받지 않으면: 내밀지 않고 바로 다시 연결 → 연결은 열리고 보통 동기화
    /// (presence 모름 = UNKNOWN). 다시 시작(start)하면 다시 내밀어 본다
    func testRejectedLiveOfferReconnectsWithoutLive() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2, autoOptions())
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        server.rejectLiveOffer = true
        server.dropSockets(deviceId: aid)
        try await waitUntil(timeout: 5) { server.socketOffers(deviceId: aid).suffix(2) == [true, false] }
        try await waitUntil { await a.engine.status.live }
        let p = await a.engine.presence
        XCTAssertNil(p)
        // 보통 동기화로 간다
        setComment(a, book, "레코드로")
        try await waitUntil(timeout: 5) { liveComment(b, book) == "레코드로" }
        // 다시 시작하면 다시 내밀어 본다
        server.rejectLiveOffer = false
        await a.engine.stop()
        await a.engine.start()
        try await waitUntil { server.socketOffers(deviceId: aid).last == true }
        try await waitUntil("presence") { await a.engine.presence?.peers == 1 }
        for d in devs { await d.engine.dispose() }
    }
}
