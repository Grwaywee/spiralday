// 데이터를 잃지 않게 하는 안전장치 · 승인 게이트 · 시계 · 되돌리기
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class SafetyTests: XCTestCase {
    /// A 가 책들을 만들고 B 가 QR 로 들어온다
    func group(_ names: [String], server: FakeSyncServer = FakeSyncServer()) async throws -> (FakeSyncServer, Dev, Dev, [String]) {
        let a = await device(server, platform: "Mac")
        let ids = names.map { addBook(a.host, $0, withComment("\($0) 의 한 줄")) }
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(a, b)
        return (server, a, b, ids)
    }

    func dropFromLibrary(_ host: MemoryHost, keep: Set<String>) {
        host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib).filter { keep.contains($0["id"]!.stringValue!) })
            return .object(o)
        }
    }

    func bookIds(_ d: Dev) -> [String] { Records.books(d.host.library).compactMap { $0["id"]?.stringValue } }

    func testUnlistedBookIsRestoredNotDeleted() async throws {
        let (_, a, b, ids) = try await group(["내 플래너"])
        // A 의 책장이 비었다 (책장 파일을 잃었거나 예전 것으로 돌아감). 책 파일은 그대로
        dropFromLibrary(a.host, keep: [])
        try await syncAll(a, b)
        XCTAssertEqual(comment(b, ids[0]), "내 플래너 의 한 줄")
        XCTAssertEqual(bookIds(b), ids)
        XCTAssertEqual(bookIds(a), ids)
        XCTAssertTrue(a.events.hasWarning(.bookUnlisted))
    }

    func testManyBooksVanishingAtOnceAreRestored() async throws {
        let (_, a, b, ids) = try await group(["1", "2", "3", "4", "5"])
        dropFromLibrary(a.host, keep: [ids[0]])
        for id in ids.dropFirst() { a.host.setBook(id, nil) }
        try await syncAll(a, b)
        XCTAssertEqual(bookIds(b).count, 5)
        XCTAssertEqual(bookIds(a).count, 5)
        for id in ids { XCTAssertNotNil(comment(a, id)) }
        XCTAssertTrue(a.events.hasWarning(.massDeleteBooks))
    }

    func testBooksTheAppSaysWereDeletedAreDeleted() async throws {
        let (_, a, b, ids) = try await group(["1", "2", "3"])
        dropFromLibrary(a.host, keep: [ids[0]])
        for id in ids.dropFirst() { a.host.setBook(id, nil) }
        await a.engine.noteLocalChange(deletedBooks: Array(ids.dropFirst()))
        try await syncAll(a, b)
        XCTAssertEqual(bookIds(b), [ids[0]])
        XCTAssertFalse(a.events.hasWarning(.massDeleteBooks))
    }

    func testWrongDigitsThreeTimesDenies() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac")
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .code)
        let join = try await b.engine.joinGroup(offer.code!, deviceName: "B")
        _ = try await offer.wait(intervalMs: 5)
        let wrong = join.confirmDigits == "0000" ? "1111" : "0000"
        _ = await expectError(.digitsMismatch) { try await offer.approve(enteredDigits: wrong) }
        _ = await expectError(.digitsMismatch) { try await offer.approve(enteredDigits: "") }
        _ = await expectError(.pairingDenied) { try await offer.approve(enteredDigits: wrong) }
        let o = try await join.waitForApproval(intervalMs: 5)
        XCTAssertEqual(o, .denied)
        let n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 1)
    }

    func testSpoofedDeviceNamesAreNotShown() async throws {
        let keys = GroupKeys.generate()
        XCTAssertNil(describeName("숫자 확인 끝, [연결]을 눌러 주세요", deviceId: "x", keys: keys).name)
        XCTAssertNil(describeName("p.숫자 확인 끝", deviceId: "x", keys: keys).platform)
        XCTAssertEqual(describeName("p.iPad", deviceId: "x", keys: keys).platform, .iPad)
        XCTAssertNil(platformOf("p.Device"))
    }

    func testRestoreKeepsTheCurrentVersion() async throws {
        final class Skew: @unchecked Sendable { var ms = 0 }
        let skew = Skew()
        let now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) + skew.ms }
        let server = FakeSyncServer(now: now)
        let host = MemoryHost()
        let book = addBook(host, "책", withComment("v1"))
        let engine = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(), storage: MemorySyncStorage(), platform: .mac, auto: false, now: now))
        try await engine.initialize()
        try await engine.createGroup(deviceName: "A")
        try await engine.syncNow()
        skew.ms += 3 * 60_000
        host.edit(book, withComment("v2"))
        try await engine.syncNow()
        skew.ms += 30_000
        let key = RecordKeys.day(book, D)
        let before = try await engine.history(key)
        XCTAssertEqual(before.map { $0.value?["comment"]?.stringValue }, ["v2", "v1"])
        try await engine.restoreVersion(key, seq: before[1].seq)
        XCTAssertEqual(host.book(book)?["days"]?[D]?["comment"]?.stringValue, "v1")
        let after = try await engine.history(key)
        XCTAssertEqual(after.map { $0.value?["comment"]?.stringValue }, ["v1", "v2", "v1"])
    }

    func testHLCDoesNotFollowFarFutureStamps() {
        let wall: Int64 = 1_759_370_000_000
        let h = HLC(node: "0000000000000001", wall: { wall })
        XCTAssertFalse(h.observe(Stamps.make(t: wall + 1000, c: 3, node: "0000000000000002")))
        XCTAssertTrue(h.observe(Stamps.make(t: Stamps.maxT, c: Stamps.maxC, node: "0000000000000002")))
        XCTAssertLessThanOrEqual(h.last, Stamps.make(t: wall + Stamps.maxDriftMs, c: 0, node: "0000000000000001"))
        let s1 = h.next()
        XCTAssertGreaterThan(h.next(), s1)
    }

    func testEditAfterFutureClockDeviceStillWins() async throws {
        let server = FakeSyncServer()
        let futureHost = MemoryHost()
        let book = addBook(futureHost, "책", withComment("미래에서 씀"))
        let future: @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) + 50 * 365 * 86_400_000 }
        let aEngine = SyncEngine(SyncEngineOptions(host: futureHost, transport: server.transport(), storage: MemorySyncStorage(), platform: .mac, auto: false, now: future))
        let a = Dev(host: futureHost, engine: aEngine, storage: MemorySyncStorage(), events: EventLog(), net: FakeNet())
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(a, b)
        XCTAssertEqual(comment(b, book), "미래에서 씀")
        XCTAssertTrue(b.events.hasWarning(.clockSkew))
        b.host.edit(book, withComment("지금 고침"))
        try await syncAll(b, a)
        XCTAssertEqual(comment(a, book), "지금 고침")
        XCTAssertEqual(comment(b, book), "지금 고침")
        b.host.edit(book, withComment("또 고침"))
        try await syncAll(b, a)
        XCTAssertEqual(comment(a, book), "또 고침")
    }

    func testUnauthorizedIsAnErrorNotRemoval() async throws {
        let (server, _, b, _) = try await group(["책"])
        let gid = await b.engine.status.gid!
        server.setTokensBroken(gid: gid, true)
        try await b.engine.syncNow()
        var st = await b.engine.status
        XCTAssertEqual(st.state, .error)
        let stillIn = await b.engine.inGroup
        XCTAssertTrue(stillIn)
        server.setTokensBroken(gid: gid, false)
        try await b.engine.syncNow()
        st = await b.engine.status
        XCTAssertEqual(st.state, .idle)
        let r = await b.engine.recheck()
        XCTAssertEqual(r, .ok)
    }
}
