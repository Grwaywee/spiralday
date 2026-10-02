// 실시간 쓰기: 보내기 시점 (상황별 지연 FAST · COVERED · OLD-PEER · UNKNOWN · ALONE) · 자기 쓰기 다시 받지 않기 · head 받기 0 ms ·
// sendPending · presence 가 늘면 바로 보내기. 진짜 타이머 (auto) 로 — 지연 값은 줄여서
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

func requests(_ server: FakeSyncServer, _ d: LDev, from: Int = 0) -> [FakeSyncServer.LogEntry] {
    Array(server.log.dropFirst(from)).filter { $0.ip == d.ip }
}

func autoOptions(_ o: inout SyncEngineOptions, covered: Int = 300, alone: Int = 100, aloneMax: Int = 250, oldPeer: Int = 1000, oldPeerMax: Int = 2000) {
    o.auto = true
    o.socket = true
    o.scanDelayMs = 5
    var d = PushDelays()
    d.pushDelayMs = 30
    d.coveredPushDelayMs = covered
    d.alonePushDelayMs = alone
    d.aloneMaxWaitMs = aloneMax
    d.oldPeerPushDelayMs = oldPeer
    d.oldPeerMaxWaitMs = oldPeerMax
    o.pushDelays = d
    o.liveThrottleMs = 10
    o.liveFlushMs = 20
    o.minPullIntervalMs = 0
}

func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

final class LiveTimingTests: LiveCase {
    func testPushModesAndDueTimes() {
        var o = PushDelays()
        o.pushDelayMs = 400
        // presence 를 모르면 (옛 서버 · WebSocket 이 막힘 · LIVE=off) 예전 비용 수준 — 혼자 치는데 0.4초마다 보내지 않는다
        XCTAssertEqual(PushMode.of(nil), .unknown)
        XCTAssertEqual(PushMode.of(LivePresence(relay: false, peers: 0, live: 0)), .unknown)
        XCTAssertEqual(PushMode.of(LivePresence(relay: true, peers: 0, live: 0)), .alone)
        XCTAssertEqual(PushMode.of(LivePresence(relay: true, peers: 2, live: 2)), .covered)
        XCTAssertEqual(PushMode.of(LivePresence(relay: true, peers: 2, live: 1)), .oldPeer)
        XCTAssertEqual(o.dueAt(.fast, firstAt: 1000, lastAt: 5000), 1400)
        XCTAssertEqual(o.dueAt(.covered, firstAt: 1000, lastAt: 5000), 3000)
        XCTAssertEqual(o.dueAt(.oldPeer, firstAt: 1000, lastAt: 1200), 2200)
        XCTAssertEqual(o.dueAt(.oldPeer, firstAt: 1000, lastAt: 2900), 3000)
        XCTAssertEqual(o.dueAt(.unknown, firstAt: 1000, lastAt: 1000), 2500)
        XCTAssertEqual(o.dueAt(.unknown, firstAt: 1000, lastAt: 4000), 5000)
        XCTAssertEqual(o.dueAt(.alone, firstAt: 1000, lastAt: 2000), 4000)
        XCTAssertEqual(o.dueAt(.alone, firstAt: 1000, lastAt: 5000), 6000)
    }

    func testOwnWriteHeadIsNotPulledCoveredRecordIsLateAndAloneIsBatched() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { autoOptions(&$0) }
        let a = devs[0], b = devs[1]
        try await waitUntil {
            let x = await a.engine.status
            let y = await b.engine.status
            return x.state == .idle && y.state == .idle && x.pending == 0 && y.pending == 0
        }
        await settle(150)

        // COVERED: 초안은 바로, 레코드는 300 ms 뒤
        let mark = server.log.count
        let t0 = Date()
        setComment(a, book, "빨리")
        try await waitUntil(timeout: 1) { liveComment(b, book) == "빨리" }
        XCTAssertLessThan(ms(since: t0), 150)
        XCTAssertFalse(requests(server, a, from: mark).contains { $0.method == "POST" })
        try await waitUntil(timeout: 2) {
            let p = await a.engine.status.pending
            return p == 0 && requests(server, a, from: mark).contains { $0.method == "POST" }
        }
        XCTAssertGreaterThanOrEqual(ms(since: t0), 250)
        await settle(200)
        // A 는 자기 쓰기를 다시 받지 않는다 · B 는 바꾸는 것 없이 받는다 (head 를 받고 바로)
        XCTAssertEqual(requests(server, a, from: mark).filter { $0.method == "GET" && $0.path.hasSuffix("/changes") }.count, 0)
        XCTAssertEqual(requests(server, b, from: mark).filter { $0.method == "GET" && $0.path.hasSuffix("/changes") }.count, 1)
        XCTAssertFalse(requests(server, b, from: mark).contains { $0.method == "POST" })

        // ALONE: B 를 끄면 A 는 묶어서 (마지막 변경 + 100 ms, 첫 변경부터 최대 250 ms)
        await b.engine.stop()
        try await waitUntil { await a.engine.presence?.peers == 0 }
        let mark2 = server.log.count
        let t1 = Date()
        for i in 0..<8 {
            setComment(a, book, "혼자 \(i)")
            await settle(40)
        }
        try await waitUntil(timeout: 2) { await a.engine.status.pending == 0 }
        let posts = requests(server, a, from: mark2).filter { $0.method == "POST" }
        XCTAssertGreaterThanOrEqual(posts.count, 1)
        XCTAssertLessThanOrEqual(posts.count, 3)
        XCTAssertGreaterThanOrEqual(ms(since: t1), 240)
    }

    func testCoveredNonDraftChangesGoFast() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2) { autoOptions(&$0, covered: 600, alone: 600, aloneMax: 600) }
        let a = devs[0], b = devs[1]
        try await waitUntil {
            let x = await a.engine.status
            let y = await b.engine.status
            return x.state == .idle && y.state == .idle && x.pending == 0
        }
        await settle(150)
        let pr = await a.engine.presence
        XCTAssertEqual(PushMode.of(pr), .covered)

        // 책 이름 (b/ — 초안이 없다): FAST 지연으로 레코드가 간다
        let mark = server.log.count
        let t0 = Date()
        a.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib).map { bk in
                var x = bk.objectValue!
                x["name"] = "새 이름"
                return .object(x)
            })
            return .object(o)
        }
        a.engine.localChanged(library: true)
        try await waitUntil(timeout: 2) { requests(server, a, from: mark).contains { $0.method == "POST" } }
        XCTAssertLessThan(ms(since: t0), 400)
        try await waitUntil(timeout: 2) { Records.books(b.host.library).first?["name"] == "새 이름" }

        // 초안으로 간 편집만 있으면 그대로 COVERED (레코드는 늦게)
        try await waitUntil { await a.engine.status.pending == 0 }
        await settle(50)
        let mark2 = server.log.count
        let t1 = Date()
        setComment(a, book, "초안으로")
        try await waitUntil(timeout: 1) { liveComment(b, book) == "초안으로" }
        try await waitUntil(timeout: 3) { requests(server, a, from: mark2).contains { $0.method == "POST" } }
        XCTAssertGreaterThanOrEqual(ms(since: t1), 500)
    }

    func testSendPendingWhenAloneAndNothingToSend() async throws {
        let server = FakeSyncServer()
        let a = await ldevice(server, "A") { autoOptions(&$0, alone: 5000, aloneMax: 5000) }
        let bk = newBook("닫기 전")
        let id = bk.info["id"]!.stringValue!
        a.host.library = ["books": [bk.info], "activeID": .string(id)]
        a.host.setBook(id, bk.data)
        a.host.openBook = id
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await waitUntil {
            let st = await a.engine.status
            return st.presence?.peers == 0 && st.pending == 0 && st.state == .idle
        }
        await settle(50)
        var unsent = await a.engine.hasUnsent
        XCTAssertFalse(unsent)
        let before = requests(server, a).count
        await a.engine.sendPending()
        XCTAssertEqual(requests(server, a).count, before)
        setComment(a, id, "마지막 문장")
        unsent = await a.engine.hasUnsent
        XCTAssertTrue(unsent)
        let t0 = Date()
        await a.engine.sendPending()
        XCTAssertLessThan(ms(since: t0), 1000)
        let st = await a.engine.status
        XCTAssertEqual(st.pending, 0)
        unsent = await a.engine.hasUnsent
        XCTAssertFalse(unsent)
        XCTAssertGreaterThan(server.head(gid: st.gid!), 0)
    }

    func testOldPeerPushIsNotPushedBackBySaveNotice() async throws {
        let server = FakeSyncServer()
        let a = await ldevice(server, "A") { autoOptions(&$0, alone: 5000, aloneMax: 5000, oldPeer: 400, oldPeerMax: 2000) }
        let b = await ldevice(server, "B") {
            autoOptions(&$0, alone: 5000, aloneMax: 5000, oldPeer: 400, oldPeerMax: 2000)
            $0.live = false
        }
        let bk = newBook("옛 앱과")
        let id = bk.info["id"]!.stringValue!
        a.host.library = ["books": [bk.info], "activeID": .string(id)]
        a.host.setBook(id, bk.data)
        a.host.openBook = id
        try await a.engine.initialize()
        try await b.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await pairLive(a, b)
        try await waitUntil {
            let x = await a.engine.status
            let y = await b.engine.status
            return PushMode.of(x.presence) == .oldPeer && x.pending == 0 && x.state == .idle && y.state == .idle
        }
        await settle(100)
        let mark = server.log.count
        let t0 = Date()
        setComment(a, id, "옛 앱에게")
        await settle(200)
        // 앱이 파일을 쓰고 알린다 (새 변경 없음)
        let saved = a.host.book(id)!
        a.engine.localChanged(bookId: id, saved: { saved })
        try await waitUntil(timeout: 2) { requests(server, a, from: mark).contains { $0.method == "POST" } }
        let at = ms(since: t0)
        XCTAssertGreaterThanOrEqual(at, 380)
        XCTAssertLessThan(at, 700)
    }

    func testPresenceIncreaseSendsPendingNow() async throws {
        let server = FakeSyncServer()
        let a = await ldevice(server, "A") { autoOptions(&$0, alone: 5000, aloneMax: 5000) }
        let bk = newBook("늦게 켬")
        let id = bk.info["id"]!.stringValue!
        a.host.library = ["books": [bk.info], "activeID": .string(id)]
        a.host.setBook(id, bk.data)
        a.host.openBook = id
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await ldevice(server, "B")
        try await b.engine.initialize()
        try await pairLive(a, b)
        await b.engine.stop()
        try await waitUntil {
            let st = await a.engine.status
            return st.presence?.peers == 0 && st.pending == 0 && st.state == .idle
        }
        setComment(a, id, "밀림")
        await settle(100)
        var st = await a.engine.status
        XCTAssertEqual(st.pending, 1)
        let t0 = Date()
        await b.engine.start()
        try await waitUntil(timeout: 1.5) { await a.engine.status.pending == 0 }
        XCTAssertLessThan(ms(since: t0), 1000)
        st = await a.engine.status
        XCTAssertEqual(st.pending, 0)
    }

    func testUnknownPresenceUsesOldCostDelay() async throws {
        // 옛 서버 (중계 없음): presence 모름 → UNKNOWN (마지막 변경 + 지연) — 혼자 쳐도 FAST 로 보내지 않는다
        let server = FakeSyncServer()
        server.live = false
        let a = await ldevice(server, "A") { o in
            autoOptions(&o)
            o.pushDelays.unknownPushDelayMs = 300
            o.pushDelays.unknownMaxWaitMs = 800
        }
        let bk = newBook("옛 서버")
        let id = bk.info["id"]!.stringValue!
        a.host.library = ["books": [bk.info], "activeID": .string(id)]
        a.host.setBook(id, bk.data)
        a.host.openBook = id
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await waitUntil {
            let st = await a.engine.status
            return st.live && st.pending == 0 && st.state == .idle
        }
        await settle(100)
        let p = await a.engine.presence
        XCTAssertNil(p)
        let mark = server.log.count
        let t0 = Date()
        setComment(a, id, "옛 서버에")
        try await waitUntil(timeout: 2) { requests(server, a, from: mark).contains { $0.method == "POST" } }
        XCTAssertGreaterThanOrEqual(ms(since: t0), 280)
    }
}
