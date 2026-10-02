// 실시간 쓰기: 보내기 상한 · 합쳐 보내기 · 받는 쪽 검사(재생 · 위조 · 반쪽 항목) · 쓰고 있는 칸 · 죽어도 잃지 않기 · 대신 올리기
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class LiveSendLimitTests: LiveCase {
    func testFullSendBufferHoldsFragmentsAndMergesThem() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        let T = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        server.setBuffered(deviceId: aid, bytes: 1 << 20)
        setTasks(a, book, [task(T, "")])
        await a.engine.flushLive()
        for t in ["장", "장보", "장보기"] {
            setTasks(a, book, [task(T, t)])
            await a.engine.flushLive()
        }
        await settle()
        XCTAssertEqual(server.draftsSent(by: aid), 0)
        let c = await a.engine.liveCounters
        XCTAssertGreaterThan(c.deferred, 0)
        server.setBuffered(deviceId: aid, bytes: 0)
        await a.engine.flushLive()
        try await waitUntil { dayTasks(b, book).arrayValue?.first?["text"] == "장보기" }
        XCTAssertEqual(server.draftsSent(by: aid), 1)
        // 새 할 일의 a 와 모든 필드가 함께 갔다 (반쪽 항목이 아니다)
        XCTAssertEqual(dayTasks(b, book).arrayValue?.first?["mark"], 0)
    }

    func testClientBucketStaysBelowServerLimit() async throws {
        let t0 = 1_759_370_000_000
        let serverClock = TestClock()
        serverClock.set(t0)
        let server = FakeSyncServer(now: { serverClock.now })
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        a.clock.set(t0)
        for i in 0..<30 {
            setComment(a, book, String(repeating: "x", count: i + 1))
            await a.engine.flushLive()
        }
        await settle()
        XCTAssertEqual(server.draftsSent(by: aid), 20)
        let c = await a.engine.liveCounters
        XCTAssertGreaterThan(c.deferred, 0)
        serverClock.advance(1000)
        a.clock.advance(1000)
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == String(repeating: "x", count: 30) }
        XCTAssertEqual(server.draftsSent(by: aid), 21)
        XCTAssertEqual(server.liveDrops, FakeLiveDrops())
    }

    func testTooLargeFragmentGoesByRecordOnly() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let aid = await a.deviceId
        setComment(a, book, String(repeating: "가", count: 9000))
        await a.engine.flushLive()
        await settle()
        XCTAssertEqual(server.draftsSent(by: aid), 0)
        let c = await a.engine.liveCounters
        XCTAssertEqual(c.tooLarge, 1)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(liveComment(b, book).count, 9000)
    }
}

final class LiveReceiveTests: LiveCase {
    func testReplayForgedSelfAndShapeAreDroppedEvenAfterRestartButSkewedClocksAreFine() async throws {
        let server = FakeSyncServer()
        let frames = FrameLog()
        server.relayFilter = { frames.add($0); return true }
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let bid = await b.deviceId
        setComment(a, book, "하나")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "하나" }
        setComment(a, book, "둘")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "둘" }
        let first = frames.all[0], second = frames.all[1]
        // 다시 보냄 · 순서 바꿈
        second.deliver()
        first.deliver()
        try await waitUntil { await b.engine.liveCounters.dropped == 2 }
        XCTAssertEqual(liveComment(b, book), "둘")
        var c = await b.engine.liveCounters
        XCTAssertEqual(c.received, 2)
        // from 을 바꿔 붙임 (서버가 다른 기기 것처럼) → 풀리지 않음
        let forged = try JSONValue.parse(second.frame)
        second.deliver(text: JSONValue.object(["draft": forged["draft"]!, "q": .string(String(repeating: "f", count: 32)), "from": "DDDDDDDDDDDDDDDDDDDDDD"]).canonical)
        // 자기 것
        second.deliver(text: JSONValue.object(["draft": forged["draft"]!, "q": forged["q"]!, "from": .string(bid)]).canonical)
        // 모양이 틀림
        second.deliver(text: JSONValue.object(["draft": "x", "q": forged["q"]!, "from": forged["from"]!]).canonical)
        try await waitUntil { await b.engine.liveCounters.dropped == 5 }
        XCTAssertEqual(liveComment(b, book), "둘")

        // 다시 켠 뒤에도 (liveSeen 은 메타에)
        await b.engine.flushLive()
        await b.engine.stop()
        let b2 = await ldevice(server, "B2", storage: b.storage, host: b.host)
        try await b2.engine.initialize()
        try await waitUntil { await b2.engine.presence?.live == 1 }
        server.push(toDevice: bid, text: first.frame)
        try await waitUntil { await b2.engine.liveCounters.dropped == 1 }
        c = await b2.engine.liveCounters
        XCTAssertEqual(c.received, 0)

        // 받는 기기의 시계가 9시간 앞서도 초안을 받는다 — q 를 벽시계와 견주지 않는다
        setComment(a, book, "셋")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b2, book) == "셋" }
        let late = frames.all.last!
        let q = try JSONValue.parse(late.frame)["q"]!.stringValue!
        b2.clock.set(Int(q.prefix(12), radix: 16)! + 9 * 3_600_000)
        setComment(a, book, "넷")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b2, book) == "넷" }
        c = await b2.engine.liveCounters
        XCTAssertEqual(c.dropped, 1)
        // 그래도 이미 받은 옛 q 는 버린다
        server.push(toDevice: bid, text: late.frame)
        try await waitUntil { await b2.engine.liveCounters.dropped == 2 }
        XCTAssertEqual(liveComment(b2, book), "넷")
    }

    func testMissedNewItemFieldOnlyFragmentMakesNoHalfItem() async throws {
        let server = FakeSyncServer()
        let dropFirst = FrameLog()
        server.relayFilter = { r in
            if dropFirst.count == 0 {
                dropFirst.add(r)
                return false
            }
            return true
        }
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let T = "6BA7B811-9DAD-11D1-80B4-00C04FD430C8"
        setTasks(a, book, [task(T, "운", mark: 2)])
        await a.engine.flushLive()
        setTasks(a, book, [task(T, "운동", mark: 2)])
        await a.engine.flushLive()
        try await waitUntil { await b.engine.liveCounters.received == 1 }
        await settle()
        XCTAssertEqual(dayTasks(b, book), .array([]))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(dayTasks(b, book).arrayValue?.count, 1)
        XCTAssertEqual(dayTasks(b, book).arrayValue?.first?["text"], "운동")
    }
}

final class LiveEditingTests: LiveCase {
    func testEditingFieldIsKeptWithoutPingPongAndLastInputWinsAfter() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let bid = await b.deviceId
        // 책 id 를 소문자로 줘도 같은 칸 (엔진이 맞춘다)
        b.engine.setEditing(FieldAddress(key: key.lowercased(), field: "comment"))
        setComment(b, book, "내 글")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "내 글" }
        let bSent = server.draftsSent(by: bid)
        setComment(a, book, "상대 글")
        await a.engine.flushLive()
        try await waitUntil { b.live.typing.last?.editing == true }
        // B 의 칸은 그대로, "다른 기기에서 쓰는 중"
        XCTAssertEqual(liveComment(b, book), "내 글")
        XCTAssertEqual(b.live.typing.last?.at, [FieldAddress(key: key, field: "comment")])
        // 받은 것 때문에 B 가 다시 보내지 않는다
        await b.engine.flushLive()
        await settle()
        XCTAssertEqual(server.draftsSent(by: bid), bSent)
        // 레코드로 와도 그대로
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(liveComment(b, book), "내 글")
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual(liveComment(a, book), "상대 글")
        // 쓰기를 마침: 상대의 마지막 입력이 더 나중 → 상대 글로 (LWW)
        await b.engine.setEditingAndSettle(nil)
        XCTAssertEqual(liveComment(b, book), "상대 글")
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual(liveComment(a, book), "상대 글")
        XCTAssertEqual(liveComment(b, book), "상대 글")
        let pa = await a.engine.status.pending
        let pb = await b.engine.status.pending
        XCTAssertEqual(pa + pb, 0)
    }

    /// 앱은 쓰기를 마치면 $editingKey 구독이 먼저 setEditing(nil) 을 부르고, 이어서 정리(빈 할 일 지우기) 앞에서 setEditingAndSettle(nil) 을
    /// 기다린다 (Mac · iOS 앱). setEditing 이 먼저 시작한 넣기가 아직 앱 값을 다루는 중이어도 settle 은 그 넣기가 끝날 때까지 기다려야 한다 —
    /// 먼저 돌아오면 정리가 미뤄 둔 상대 글이 들어가기 전의 값을 보고 지운다 (다른 기기가 막 쓴 할 일이 모든 기기에서 사라진다)
    func testSettleWaitsForReleaseStartedBySetEditing() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(b, book, "내 글")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "내 글" }
        setComment(a, book, "상대 글")
        await a.engine.flushLive()
        try await waitUntil { await b.engine.liveCounters.received >= 1 }
        await settle()
        XCTAssertEqual(liveComment(b, book), "내 글")
        // 앱의 메인 스레드가 바빠 넣기가 오래 걸린다
        b.host.liveDelayMs = 40
        b.engine.setEditing(nil)
        try await Task.sleep(nanoseconds: 10_000_000)       // 먼저 시작한 넣기가 앱 값을 읽는 중에
        await b.engine.setEditingAndSettle(nil)
        XCTAssertEqual(liveComment(b, book), "상대 글", "정리 앞에서는 미뤄 둔 상대 글이 이미 앱에 있다")
        b.host.liveDelayMs = 0
    }

    func testTypingMoreWhileEditingWins() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(b, book, "나")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "나" }
        setComment(a, book, "상대")
        await a.engine.flushLive()
        try await waitUntil { await b.engine.liveCounters.received == 1 }
        await settle()
        XCTAssertEqual(liveComment(b, book), "나")
        setComment(b, book, "나!")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "나!" }
        await b.engine.setEditingAndSettle(nil)
        XCTAssertEqual(liveComment(b, book), "나!")
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual([liveComment(a, book), liveComment(b, book)], ["나!", "나!"])
    }

    func testFocusOnlyFieldTakesNewerTextAndOneTypedCharKeepsIt() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2, book: withComment("start"))
        let a = devs[0], b = devs[1]
        // B: 캐럿만 COMMENT 에 두고 다른 기기(A)로 감 (B 는 치지 않았다)
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(a, book, "start + 30 minutes of writing on A")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "start + 30 minutes of writing on A" }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        // B 로 돌아와 한 글자
        setComment(b, book, "start + 30 minutes of writing on A!")
        await b.engine.flushLive()
        await b.engine.setEditingAndSettle(nil)
        for _ in 0..<2 { for d in devs { try await d.engine.syncNow() } }
        XCTAssertEqual([liveComment(a, book), liveComment(b, book)], ["start + 30 minutes of writing on A!", "start + 30 minutes of writing on A!"])
        XCTAssertTrue(b.live.held.isEmpty)
    }

    func testHeldTextComesInAfterGraceWithoutTyping() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2) {
            $0.auto = true
            $0.editingGraceMs = 150
            $0.scanDelayMs = 5
            $0.pushDelays = .all(30)
            $0.liveThrottleMs = 5
            $0.liveFlushMs = 10
            $0.minPullIntervalMs = 0
        }
        let a = devs[0], b = devs[1]
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(b, book, "내가 쓰는 중")
        try await waitUntil { liveComment(a, book) == "내가 쓰는 중" }
        setComment(a, book, "상대가 나중에 고침")
        try await waitUntil { b.live.held.count == 1 }
        XCTAssertEqual(b.live.held[0], FieldAddress(key: key, field: "comment"))
        XCTAssertEqual(liveComment(b, book), "내가 쓰는 중")
        // 150 ms 동안 B 가 치지 않음 → 상대 글 (더 나중 입력)
        try await waitUntil(timeout: 2) { liveComment(b, book) == "상대가 나중에 고침" }
        try await waitUntil { b.live.held.count == 2 }
        XCTAssertNil(b.live.held[1])
        setComment(b, book, "상대가 나중에 고침 + B")
        try await waitUntil { liveComment(a, book) == "상대가 나중에 고침 + B" }
        await b.engine.setEditingAndSettle(nil)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual([liveComment(a, book), liveComment(b, book)], ["상대가 나중에 고침 + B", "상대가 나중에 고침 + B"])
        for d in devs { await d.engine.dispose() }
    }

    func testEditedTaskDeletedElsewhereGoesAway() async throws {
        let server = FakeSyncServer()
        let T = "6BA7B812-9DAD-11D1-80B4-00C04FD430C8"
        let U = "6BA7B813-9DAD-11D1-80B4-00C04FD430C8"
        let (devs, book, key) = try await liveGroup(server, 2, book: { data in
            var o = data.objectValue!
            var day = emptyDayJSON()
            day["tasks"] = [task(T, "하나", row: 0), task(U, "둘", row: 1)]
            o["days"] = [LiveD: .object(day)]
            return .object(o)
        })
        let a = devs[0], b = devs[1]
        b.engine.setEditing(FieldAddress(key: key, coll: .tasks, item: T.lowercased(), field: "text"))
        // B 가 칸에 친다 (아직 liveEdit 전에) — 그 사이 A 가 같은 할 일의 글 · 다른 할 일의 표시를 바꾼다
        b.host.edit(book) { replaceTasks($0, [task(T, "하나 고침", row: 0), task(U, "둘", row: 1)]) }
        a.host.edit(book) { replaceTasks($0, [task(T, "A 가 고침", row: 0), task(U, "둘", mark: 3, row: 1)]) }
        a.engine.liveEdit([key])
        await a.engine.flushLive()
        try await waitUntil { dayTasks(b, book).arrayValue?.last?["mark"] == 3 }
        let got = dayTasks(b, book).arrayValue ?? []
        XCTAssertEqual(got.first?["text"], "하나 고침")
        // B 의 편집은 잃지 않았다 (넣기 전에 비교해 받아들임) → A 로 간다
        try await waitUntil { dayTasks(a, book).arrayValue?.first?["text"] == "하나 고침" }
        // A 가 그 할 일을 지운다 → B 에서도 지워진다 (쓰고 있어도)
        a.host.edit(book) { replaceTasks($0, [task(U, "둘", mark: 3, row: 1)]) }
        a.engine.liveEdit([key])
        await a.engine.flushLive()
        try await waitUntil { dayTasks(b, book).arrayValue?.count == 1 }
        XCTAssertEqual(dayTasks(b, book).arrayValue?.first?["id"]?.stringValue, U)
    }
}

func replaceTasks(_ data: JSONValue, _ tasks: [JSONValue]) -> JSONValue {
    var o = data.objectValue!
    var days = o["days"]?.objectValue ?? [:]
    var day = days[LiveD]?.objectValue ?? emptyDayJSON()
    day["tasks"] = .array(tasks)
    days[LiveD] = .object(day)
    o["days"] = .object(days)
    return .object(o)
}

final class LiveDurabilityTests: LiveCase {
    /// 앱이 저장 전에 죽음: 같은 동기화 저장소 · 옛 앱 파일로 다시 켠다
    func crashAndRestart(_ server: FakeSyncServer, _ d: LDev, file: JSONValue, book: String, flush: Bool = true) async throws -> LDev {
        if flush { await d.engine.flushLive() }
        await d.engine.stop()
        let host = MemoryHost(library: d.host.library)
        host.setBook(book, file)
        host.openBook = book
        let d2 = await ldevice(server, d.name + "'", storage: d.storage, host: host, clock: d.clock)
        try await d2.engine.initialize()
        try await d2.engine.syncNow()
        return d2
    }

    func testSenderCrashBeforeFileSaveRevivesTypedText() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2, book: withComment("처음"))
        let a = devs[0], b = devs[1]
        let file = a.host.book(book)!
        setComment(a, book, "처음 그리고 더")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "처음 그리고 더" }
        let a2 = try await crashAndRestart(server, a, file: file, book: book)
        XCTAssertEqual(liveComment(a2, book), "처음 그리고 더")
        try await b.engine.syncNow()
        try await a2.engine.syncNow()
        XCTAssertEqual(liveComment(b, book), "처음 그리고 더")
        let p1 = await a2.engine.status.pending
        let p2 = await b.engine.status.pending
        XCTAssertEqual(p1 + p2, 0)
    }

    func testReceiverCrashBeforeFileSaveRevivesReceivedText() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2, book: withComment("처음"))
        let a = devs[0], b = devs[1]
        let file = b.host.book(book)!
        setComment(a, book, "받은 글")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "받은 글" }
        let b2 = try await crashAndRestart(server, b, file: file, book: book)
        XCTAssertEqual(liveComment(b2, book), "받은 글")
        try await a.engine.syncNow()
        try await b2.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual(liveComment(a, book), "받은 글")
        XCTAssertEqual(liveComment(b2, book), "받은 글")
    }

    func testHeldTextArrivesAfterRestart() async throws {
        let server = FakeSyncServer()
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        b.engine.setEditing(FieldAddress(key: key, field: "comment"))
        setComment(b, book, "내")
        await b.engine.flushLive()
        try await waitUntil { liveComment(a, book) == "내" }
        setComment(a, book, "상대 글")
        await a.engine.flushLive()
        try await waitUntil { b.live.held.count == 1 }
        XCTAssertEqual(liveComment(b, book), "내")
        // b 의 앱은 더 치지 않은 채 꺼진다 (파일 = 메모리 = '내')
        let b2 = try await crashAndRestart(server, b, file: b.host.book(book)!, book: book)
        XCTAssertEqual(liveComment(b2, book), "상대 글")
        try await a.engine.syncNow()
        try await b2.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual([liveComment(a, book), liveComment(b2, book)], ["상대 글", "상대 글"])
        let p1 = await a.engine.status.pending
        let p2 = await b2.engine.status.pending
        XCTAssertEqual(p1 + p2, 0)
    }

    func testReceiverFileWrittenRightAfterLiveApplyDoesNotOverwriteNewerText() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2, book: withComment("start"))
        let a = devs[0], b = devs[1]
        setComment(a, book, "draft v1")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "draft v1" }
        // 엔진은 받은 즉시 저장했다 (앱 파일 0.6초 묶음보다 먼저)
        try await waitUntil { await !b.engine.storageBehind }
        // B 의 앱이 파일을 쓰고 바로 죽는다 — flushLive 없이
        let bFile = b.host.book(book)!
        await b.engine.stop()
        try await a.engine.syncNow()
        setComment(a, book, "draft v1 + newer edit on A")
        await a.engine.flushLive()
        try await a.engine.syncNow()
        let b2 = try await crashAndRestart(server, b, file: bFile, book: book, flush: false)
        try await a.engine.syncNow()
        try await b2.engine.syncNow()
        XCTAssertEqual([liveComment(a, book), liveComment(b2, book)], ["draft v1 + newer edit on A", "draft v1 + newer edit on A"])
    }

    func testSavedHintEndsTheLead() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0]
        setComment(a, book, "저장함")
        await a.engine.flushLive()
        let saved = a.host.book(book)!
        await a.engine.noteLocalChange(bookId: book, saved: { saved })
        try await a.engine.syncNow()
        let a2 = try await crashAndRestart(server, a, file: saved, book: book)
        XCTAssertEqual(a2.host.applied, 0)
        XCTAssertEqual(a2.host.liveApplied, 0)
        XCTAssertEqual(liveComment(a2, book), "저장함")
    }

    func testReceiverAdoptsUnconfirmedDraftAfter30sAndSenderLaterWritesNothing() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 3)
        let a = devs[0], b = devs[1], c = devs[2]
        c.host.openBook = nil
        a.net.offline = true
        setComment(a, book, "대신 올려 줘")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "대신 올려 줘" }
        try await waitUntil { await c.engine.liveCounters.received == 1 }
        let gid = await b.engine.status.gid!
        let head0 = server.head(gid: gid)
        try await b.engine.syncNow()
        XCTAssertEqual(server.head(gid: gid), head0)
        b.clock.advance(31_000)
        try await b.engine.syncNow()
        var cb = await b.engine.liveCounters
        XCTAssertEqual(cb.adopted, 1)
        XCTAssertEqual(server.head(gid: gid), head0 + 1)
        // c 는 받은 초안을 대신 올리기 전에 b 의 레코드로 확인한다 (c 도 30초 뒤 → 이미 확인됨, 쓰기 없음)
        c.clock.advance(31_000)
        try await c.engine.syncNow()
        let cc = await c.engine.liveCounters
        XCTAssertEqual(cc.adopted, 0)
        XCTAssertEqual(server.head(gid: gid), head0 + 1)
        // a 가 돌아와 올린다 → 409 → 합치면 같다 → 쓰지 않는다
        a.net.offline = false
        try await a.engine.syncNow()
        XCTAssertEqual(server.head(gid: gid), head0 + 1)
        let pa = await a.engine.status.pending
        XCTAssertEqual(pa, 0)
        for d in devs { try await d.engine.syncNow() }
        XCTAssertEqual(devs.map { liveComment($0, book) }, ["대신 올려 줘", "대신 올려 줘", "대신 올려 줘"])
        cb = await b.engine.liveCounters
        XCTAssertEqual(cb.adopted, 1)
    }

    func testPendingConfirmationSurvivesRestart() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        a.net.offline = true
        setComment(a, book, "살아남기")
        await a.engine.flushLive()
        try await waitUntil { liveComment(b, book) == "살아남기" }
        await a.engine.stop()
        let b2 = try await crashAndRestart(server, b, file: b.host.book(book)!, book: book)
        XCTAssertEqual(liveComment(b2, book), "살아남기")
        b2.clock.advance(31_000)
        try await b2.engine.syncNow()
        let c2 = await b2.engine.liveCounters
        XCTAssertEqual(c2.adopted, 1)
        let c = await ldevice(server, "C")
        try await c.engine.initialize()
        try await pairLive(b2, c)
        try await c.engine.syncNow()
        XCTAssertEqual(liveComment(c, book), "살아남기")
    }
}
