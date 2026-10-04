// 회귀: 기기가 "기본값으로 채운" 값(앱 기본 형광펜)이 다른 기기의 진짜 값을 이기면 안 된다 (2026-10-04 형광펜 사고).
//
// 처음 켠 기기가 합류해 받은 책을 처음 넣을 때 (이 기기에 그 책 파일이 없음 → cur = nil → PlannerModel.emptyPlannerData()),
// BookApplyJob.run → RecData.applyTo(.prefs) 가 기본 prefs 를 그림자 없이 비교(absorb)했다 → 기본 형광펜 7개가 이 기기의
// 새 항목으로 진짜 HLC 도장을 받아(liftDelta) 그룹을 만든 기기의 형광펜을 이겼다.
//
// 고친 것 (비공개 docs/sync-engine.md §4.1 · §6.4 · §7 — TS 엔진 sync/engine/test/default-fill.test.ts 와 같은 시험):
//   - 이 기기에 없던 책을 만들 때(cur = nil)는 넣기 직전의 비교를 하지 않는다 (BookApplyJob fresh)
//   - 그림자 없이 넣기 직전에 비교하면(되살리기) 시각 0 도장 → 동기화된 값이 이긴다 (RecData.absorbBeforeApply)
//   - 기본 형광펜 그대로인 목록은 "설정 안 됨" — 도장을 받지 않는다. 처음 바꿀 때 기본 항목은 기본값 도장(Stamps.defaultStamp)으로,
//     목록에 없는 기본 id 는 지움 표시 → 다른 기기가 채운 기본 형광펜이 지운 형광펜을 되살리지 못한다 (Records.diff)
//   - 이 기기에 없는 책은 서버 head 까지 다 받은 뒤에 만든다 (pulledAll)
//   - 파일 없이 연 펼친 책은 호스트가 .missing 으로 알린다 → 엔진이 되살린다 (missingNoted)
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

extension SyncEngine {
    /// 시험용: 예전 엔진이 쓴 레코드처럼 그 항목을 상태에서 걷어 낸다
    func _testDropItem(_ key: String, _ col: String, _ id: String) {
        recs[key]?.d.state.c[col]?[id] = nil
    }
}

/// 앱 저장소처럼: 파일 없이 연 책은 .missing 으로 알리다가 엔진이 받아들이면(missingNoted) · 넣으면 메모리 값을 준다
final class FileLossHost: SyncHost, @unchecked Sendable {
    let inner: MemoryHost
    private let lock = NSLock()
    private var _missing = Set<String>()
    private var _noted: [String] = []

    init(_ inner: MemoryHost) { self.inner = inner }

    func setMissing(_ id: String) { lock.withLock { _ = _missing.insert(id.uppercased()) } }
    var noted: [String] { lock.withLock { _noted } }
    private func isMissing(_ id: String) -> Bool { lock.withLock { _missing.contains(id.uppercased()) } }

    func readLibrary() async -> JSONValue? { await inner.readLibrary() }
    func readBook(id: String) async -> BookRead { isMissing(id) ? .missing : await inner.readBook(id: id) }
    func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        try await inner.updateBook(id: id, transform)
        lock.withLock { _ = _missing.remove(id.uppercased()) }
    }
    func updateLibrary(_ transform: @Sendable (JSONValue) -> JSONValue) async throws { try await inner.updateLibrary(transform) }
    func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? {
        isMissing(bookId) ? nil : await inner.readLive(bookId: bookId, keys: keys)
    }
    func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool {
        isMissing(bookId) ? false : await inner.applyLive(bookId: bookId, keys: keys, transform)
    }
    func missingNoted(bookId: String) async {
        lock.withLock {
            _noted.append(bookId.uppercased())
            _ = _missing.remove(bookId.uppercased())
        }
    }
}

/// 잠금 안의 셈 (FakeNet.fail 닫개에서)
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

final class DefaultFillTests: XCTestCase {
    /// 그룹을 만든 기기의 형광펜 (이름을 바꾸고 id 5 를 지운 7개 — 그룹을 만들기 전에 지워 지움 표시가 없었다)
    static let ownerCats: JSONValue = [
        ["id": 0, "name": "개발 업무", "hex": "8EDCD2", "counts": true],
        ["id": 1, "name": "외부 일정", "hex": "F8B38A", "counts": true],
        ["id": 2, "name": "일반 업무", "hex": "A9CFF3", "counts": true],
        ["id": 3, "name": "개인 일정", "hex": "F3DB78", "counts": false],
        ["id": 4, "name": "운동", "hex": "CDB6EF", "counts": false],
        ["id": 6, "name": "휴식·이동", "hex": "CFCFD4", "counts": false],
        ["id": 7, "name": "비 계획", "hex": "B9E4A8", "counts": true],
    ]
    static let defaults = JSONValue.array(PlannerModel.defaultCategories)
    static let book = "40BBE1E5-3BB7-49D8-A3A5-A25FFF2F3829"
    static let other = "6C0E3F7A-1F7B-4C59-9E1B-0A7B3C2D4E5F"
    static let sample = "0074794E-5D66-48D9-BE05-28A48B3B1DB2"
    static let info: JSONValue = ["id": .string(book), "name": "나의 업무 일지", "start": "2026-09-28T15:00:00Z", "cover": 4, "created": "2026-09-29T05:19:13Z"]
    static let d1 = "2026-10-01"
    static let d2 = "2026-10-02"
    static let task = "91F559D2-FB91-4E57-A8E8-4849D72C5C76"

    static func obj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(Dictionary(uniqueKeysWithValues: pairs)) }

    static func day(_ patch: [String: JSONValue]) -> JSONValue {
        var o = PlannerModel.emptyDay()
        for (k, v) in patch { o[k] = v }
        return .object(o)
    }

    static func ownerData() -> JSONValue {
        var d = PlannerModel.emptyPlannerData().objectValue!
        var p = d["prefs"]!.objectValue!
        p["categories"] = ownerCats
        p["defaultTheme"] = 4
        p["mottoText"] = "회귀 시험의 첫 장 글"
        p["ddays"] = [["id": "A1B2C3D4-0000-4000-8000-000000000001", "title": "출시", "date": "2026-12-01T15:00:00Z"]]
        d["prefs"] = .object(p)
        d["days"] = obj([
            (d1, day(["tasks": [["id": .string(task), "text": "할 일", "mark": 0, "cat": 0, "row": 0]], "theme": 2, "comment": "Mac 의 글"])),
            (d2, day(["dayOff": true])),
        ])
        d["weeks"] = ["2026-09-28": ["goal": "이번 주 목표", "review": "", "stars": 3]]
        return .object(d)
    }

    static func withCats(_ data: JSONValue, _ c: JSONValue) -> JSONValue {
        var d = data.objectValue!
        var p = d["prefs"]!.objectValue!
        p["categories"] = c
        d["prefs"] = .object(p)
        return .object(d)
    }

    static func renamed(_ list: JSONValue, _ id: Int, _ field: String, _ value: JSONValue) -> JSONValue {
        .array(list.arrayValue!.map { c in
            guard c["id"] == JSONValue(id), var o = c.objectValue else { return c }
            o[field] = value
            return .object(o)
        })
    }

    private func cats(_ d: Dev, _ id: String = book) -> JSONValue? { d.host.book(id)?["prefs"]?["categories"] }

    /// 필드 [값, 도장] 의 도장
    static func stamp(_ e: JSONValue) -> String? {
        guard let a = e.arrayValue, a.count == 2 else { return nil }
        return a[1].stringValue
    }

    /// 저장소에 적힌 모든 레코드 상태에서 이 노드의 도장이 있는 경로
    private func allStampsBy(_ d: Dev, node: String, only: String? = nil) async -> [String] {
        var out: [String] = []
        for (key, rec) in await d.storage.records {
            if let only, key != only { continue }
            guard let st = rec["state"] else { continue }
            for (k, v) in st["f"]?.objectValue ?? [:] where Self.stamp(v)?.hasSuffix(node) == true { out.append("\(key): \(k)") }
            for (col, items) in st["c"]?.objectValue ?? [:] {
                for (id, it) in items.objectValue ?? [:] {
                    if it["a"]?.stringValue?.hasSuffix(node) == true { out.append("\(key): \(col)/\(id)/a") }
                    if it["d"]?.stringValue?.hasSuffix(node) == true { out.append("\(key): \(col)/\(id)/d") }
                    for (k, v) in it["f"]?.objectValue ?? [:] where Self.stamp(v)?.hasSuffix(node) == true { out.append("\(key): \(col)/\(id)/\(k)") }
                }
            }
            if st["x"]?.stringValue?.hasSuffix(node) == true { out.append("\(key): x") }
        }
        return out.sorted()
    }

    private func prefsState(_ d: Dev) async -> JSONValue? { await d.storage.records["p/\(Self.book)"]?["state"] }

    private func owner(_ server: FakeSyncServer, _ data: JSONValue = ownerData(), sync: Bool = true, net: FakeNet = FakeNet()) async throws -> Dev {
        let mac = await device(server, platform: "Mac", ip: "10.0.0.1", net: net)
        mac.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        mac.host.setBook(Self.book, data)
        try await mac.engine.initialize()
        try await mac.engine.createGroup(deviceName: "Mac")
        if sync { try await mac.engine.syncNow() }
        return mac
    }

    /// 처음 켠 기기: 예시 플래너만 (isSample — 동기화하지 않는다)
    private static func freshLibrary(_ h: MemoryHost) {
        h.library = ["books": [["id": .string(sample), "name": "예시 플래너", "start": "2026-09-16T15:00:00Z", "cover": 3,
                                "created": "2026-09-29T16:08:58Z", "isSample": true]],
                     "activeID": .string(sample), "sampleSeeded": true]
        h.setBook(sample, PlannerModel.emptyPlannerData())
    }

    private func freshJoiner(_ server: FakeSyncServer, _ mac: Dev, ip: String = "10.0.0.2", net: FakeNet = FakeNet()) async throws -> Dev {
        let d = await device(server, platform: "iPhone", ip: ip, net: net)
        Self.freshLibrary(d.host)
        try await d.engine.initialize()
        try await pairQr(mac, d, name: "iPhone")
        return d
    }

    private func hasBook(_ d: Dev, _ id: String = book) -> Bool {
        Records.books(d.host.library).contains { $0["id"]?.stringValue == id }
    }

    // MARK: - 사고 경로

    func testFreshJoinerDoesNotStampDefaultCategoriesOfABookItMaterialises() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone, mac)
        let node = await phone.engine.nodeId
        let byPhone = await allStampsBy(phone, node: node, only: "p/\(Self.book)")
        XCTAssertEqual(byPhone, [], "들어온 기기는 p 레코드에 도장을 찍지 않는다 (사용자가 아무것도 고치지 않았다)")
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats, "그룹을 만든 기기의 형광펜이 되돌아가지 않는다")
        XCTAssertEqual(phone.host.book(Self.book)?["prefs"]?["defaultTheme"], 4)
        XCTAssertEqual(phone.host.book(Self.book)?["prefs"]?["mottoText"], "회귀 시험의 첫 장 글")
    }

    func testFreshJoinerStampsNoRecordOfTheBook() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone, mac)
        let node = await phone.engine.nodeId
        let onPhone = await allStampsBy(phone, node: node)
        let onMac = await allStampsBy(mac, node: node)
        XCTAssertEqual(onPhone, [], "들어온 기기 엔진: b · p · d · w 모두")
        XCTAssertEqual(onMac, [], "그룹을 만든 기기 엔진")
        let mine = Self.ownerData()
        XCTAssertEqual(phone.host.book(Self.book)?["prefs"]?["ddays"], mine["prefs"]?["ddays"])
        XCTAssertEqual(phone.host.book(Self.book)?["days"], mine["days"])
        XCTAssertEqual(phone.host.book(Self.book)?["weeks"], mine["weeks"])
        XCTAssertEqual(mac.host.book(Self.book), mine)
    }

    func testCreatorsFirstImportTombstonesTheMissingDefaultAndUsesTheDefaultStamp() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let st = await prefsState(mac)
        let c = st?["c"]?["categories"]
        XCTAssertNotNil(c?["5"]?["d"], "지운 기본 형광펜")
        XCTAssertEqual(c?["5"]?["a"], "")
        XCTAssertEqual(c?["0"]?["a"]?.stringValue, Stamps.defaultStamp)
        XCTAssertEqual(c?["0"]?["f"]?["hex"].flatMap(Self.stamp), Stamps.defaultStamp)
        XCTAssertNotEqual(c?["0"]?["f"]?["name"].flatMap(Self.stamp), Stamps.defaultStamp)
        XCTAssertNotEqual(c?["7"]?["a"]?.stringValue, Stamps.defaultStamp)
        XCTAssertEqual(st?["f"]?["o:categories"]?.arrayValue?.first, ["0", "1", "2", "3", "4", "6", "7"])
    }

    func testRecoveryRestoreDoesNotStampDefaultCategories() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let code = try await mac.engine.setupRecovery()
        let restored = await device(server, platform: "iPhone", ip: "10.0.0.4")
        Self.freshLibrary(restored.host)
        try await restored.engine.initialize()
        _ = try await restored.engine.restoreFromRecovery(code: code, deviceName: "새 iPhone")
        try await syncAll(restored, mac)
        XCTAssertEqual(cats(restored), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        let node = await restored.engine.nodeId
        let stamps = await allStampsBy(restored, node: node)
        XCTAssertEqual(stamps, [])
    }

    /// 같은 뿌리: restoreBook 이 그림자를 지우고 넣기 직전의 비교가 앱 파일 값 전체를 이 기기의 새 편집(HLC)으로 올렸다
    func testRestoringAnUnlistedBookDoesNotRevertNewerEditsFromAnotherDevice() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac", ip: "10.0.0.1")
        a.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        var start = PlannerModel.emptyPlannerData().objectValue!
        start["days"] = Self.obj([(Self.d1, Self.day(["comment": "처음 글"]))])
        a.host.setBook(Self.book, .object(start))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server, platform: "Windows", ip: "10.0.0.2")
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(a, b)
        a.host.edit(Self.book) { d in
            var o = Self.withCats(d, Self.ownerCats).objectValue!
            o["days"] = Self.obj([(Self.d1, Self.day(["comment": "나중 글"]))])
            return .object(o)
        }
        try await a.engine.syncNow()
        // b 는 아직 받지 않았고, b 의 책장에서만 그 책이 빠졌다 (파일은 그대로 — 잃은 것 → 되살린다)
        b.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = []
            return .object(o)
        }
        try await syncAll(b, a)
        XCTAssertEqual(Records.books(b.host.library).compactMap { $0["id"]?.stringValue }, [Self.book])
        XCTAssertEqual(cats(b), Self.ownerCats, "되살린 책")
        XCTAssertEqual(cats(a), Self.ownerCats, "다른 기기의 편집이 되돌아가지 않는다")
        XCTAssertEqual(a.host.book(Self.book)?["days"]?[Self.d1]?["comment"], "나중 글", "날 기록도")
        XCTAssertEqual(b.host.book(Self.book)?["days"]?[Self.d1]?["comment"], "나중 글")
    }

    func testRestoringAMissingBookFileKeepsTheGroupsCategories() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac", ip: "10.0.0.1")
        a.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        a.host.setBook(Self.book, PlannerModel.emptyPlannerData())
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server, platform: "Windows", ip: "10.0.0.2")
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(a, b)
        a.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try await syncAll(a, b)
        XCTAssertEqual(cats(b), Self.ownerCats)
        b.host.setBook(Self.book, nil)                          // 파일만 사라짐 (책장에는 그대로)
        try await syncAll(b, a)
        XCTAssertEqual(cats(b), Self.ownerCats, "되살린 책")
        XCTAssertEqual(cats(a), Self.ownerCats, "다른 기기")
    }

    func testZeroStampedDefaultsDoNotResurrectACategoryTheGroupDeleted() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let other = await device(server, platform: "iPad", ip: "10.0.0.3")
        other.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        other.host.setBook(Self.book, PlannerModel.emptyPlannerData())
        try await other.engine.initialize()
        try await pairQr(mac, other, name: "iPad")
        try await syncAll(other, mac)
        XCTAssertEqual(cats(other), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
    }

    func testAGroupWrittenByAnOldEngineWithoutTheTombstoneStillKeeps5Deleted() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server, sync: false)
        // 예전 엔진의 첫 가져오기처럼: 5 의 지움 표시가 없는 p 레코드를 올린다
        try await mac.engine.importAll()
        await mac.engine._testDropItem("p/\(Self.book)", "categories", "5")
        try await mac.engine.syncNow()
        let st = await prefsState(mac)
        XCTAssertNil(st?["c"]?["categories"]?["5"])
        let other = await device(server, platform: "iPad", ip: "10.0.0.3")
        other.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        other.host.setBook(Self.book, PlannerModel.emptyPlannerData())
        try await other.engine.initialize()
        try await pairQr(mac, other, name: "iPad")
        try await syncAll(other, mac)
        XCTAssertEqual(cats(other), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
    }

    // MARK: - 순서 · 끊김 변형

    func testPrefsChangedAfterTheBookWasMaterialised() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server, Self.withCats(Self.ownerData(), Self.defaults))
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone, mac)
        XCTAssertEqual(cats(phone), Self.defaults)
        mac.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try await syncAll(mac, phone)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        let node = await phone.engine.nodeId
        let onMac = await allStampsBy(mac, node: node)
        XCTAssertEqual(onMac, [])
    }

    func testPrefsFirstDaysLater() async throws {
        let server = FakeSyncServer()
        var start = Self.ownerData().objectValue!
        start["days"] = [:]
        start["weeks"] = [:]
        let mac = try await owner(server, .object(start))
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone, mac)
        mac.host.edit(Self.book) { d in
            var o = d.objectValue!
            o["days"] = Self.ownerData()["days"]
            return .object(o)
        }
        try await syncAll(mac, phone)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(phone.host.book(Self.book)?["days"], Self.ownerData()["days"])
        XCTAssertEqual(cats(mac), Self.ownerCats)
    }

    func testAnInterruptedPullDoesNotMaterialiseHalfABook() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server, Self.withCats(Self.ownerData(), Self.defaults))
        mac.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) } // 책 설정 레코드가 서버에서 가장 뒤 (가장 큰 순번)
        try await mac.engine.syncNow()
        let net = FakeNet()
        let phone = try await freshJoiner(server, mac, net: net)
        server.changesPageLimit = 1
        let pages = Counter()
        net.fail = { _, path in path.hasSuffix("/changes") && pages.next() > 2 } // 두 쪽만 받고 끊긴다
        try? await phone.engine.syncNow()
        try? await phone.engine.pushNow()                         // 받기 없는 바퀴도 그 책을 만들지 않는다
        XCTAssertFalse(hasBook(phone), "반쪽 책은 아직 책장에 없다")
        net.fail = nil
        try await syncAll(phone, mac)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        let node = await phone.engine.nodeId
        let stamps = await allStampsBy(phone, node: node)
        XCTAssertEqual(stamps, [])
    }

    func testAppOpensTheReceivedBookAndAddsATaskBeforeThePrefsChange() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server, Self.withCats(Self.ownerData(), Self.defaults))
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone)
        XCTAssertNotNil(phone.host.book(Self.book))
        phone.host.openBook = Self.book
        phone.host.edit(Self.book) { d in
            var o = d.objectValue!
            var days = o["days"]?.objectValue ?? [:]
            days[Self.d2] = Self.day(["tasks": [["id": "B7C8D9E0-1111-4222-8333-444455556666", "text": "iPhone 에서 더함", "mark": 0, "row": 0]], "dayOff": true])
            o["days"] = .object(days)
            return .object(o)
        }
        mac.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try await syncAll(mac, phone)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        XCTAssertEqual(mac.host.book(Self.book)?["days"]?[Self.d2]?["tasks"]?.arrayValue?.first?["text"], "iPhone 에서 더함")
        let node = await phone.engine.nodeId
        let onMac = await allStampsBy(mac, node: node, only: "p/\(Self.book)")
        XCTAssertEqual(onMac, [])
    }

    func testAJoinersRealEditOfOneDefaultWinsOnlyThatField() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server, Self.withCats(Self.ownerData(), Self.defaults))
        let phone = try await freshJoiner(server, mac)
        try await syncAll(phone)
        mac.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try await mac.engine.syncNow()
        try await Task.sleep(nanoseconds: 5_000_000)            // 더 나중의 진짜 편집 (다른 밀리초에)
        phone.host.edit(Self.book) { Self.withCats($0, Self.renamed($0["prefs"]!["categories"]!, 2, "name", "iPhone 이 고침")) }
        try await syncAll(phone, mac)
        let want = Self.renamed(Self.ownerCats, 2, "name", "iPhone 이 고침")
        XCTAssertEqual(cats(phone), want)
        XCTAssertEqual(cats(mac), want)
    }

    func testOfflineJoiner() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let net = FakeNet()
        let phone = try await freshJoiner(server, mac, net: net)
        net.offline = true
        try? await phone.engine.syncNow()
        try? await phone.engine.syncNow()
        XCTAssertFalse(hasBook(phone))
        net.offline = false
        try await syncAll(phone, mac)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        let node = await phone.engine.nodeId
        let onMac = await allStampsBy(mac, node: node)
        XCTAssertEqual(onMac, [])
    }

    func testCreatorOfflineBeforeItsFirstUpload() async throws {
        let server = FakeSyncServer()
        let net = FakeNet()
        let mac = try await owner(server, Self.withCats(Self.ownerData(), Self.defaults), sync: false, net: net)
        let phone = try await freshJoiner(server, mac)
        net.offline = true
        mac.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try? await mac.engine.syncNow()
        try await syncAll(phone)
        XCTAssertFalse(hasBook(phone))
        net.offline = false
        try await syncAll(mac, phone)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        let node = await phone.engine.nodeId
        let stamps = await allStampsBy(phone, node: node)
        XCTAssertEqual(stamps, [])
    }

    func testJoinerWithItsOwnEditsBeforeJoining() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let other = await device(server, platform: "iPad", ip: "10.0.0.3")
        let ownInfo: JSONValue = ["id": .string(Self.other), "name": "iPad 의 책", "start": "2026-09-28T15:00:00Z", "cover": 2, "created": "2026-09-30T01:00:00Z"]
        other.host.library = ["books": [Self.info, ownInfo], "activeID": .string(Self.book), "sampleSeeded": true]
        var copy = Self.withCats(PlannerModel.emptyPlannerData(), Self.renamed(Self.defaults, 2, "name", "iPad 사본의 이름")).objectValue!
        var cp = copy["prefs"]!.objectValue!
        cp["defaultTheme"] = 1
        copy["prefs"] = .object(cp)
        let ipadTask = "C1C2C3C4-0000-4000-8000-000000000009"
        copy["days"] = Self.obj([(Self.d1, Self.day(["tasks": [["id": .string(ipadTask), "text": "iPad 사본의 할 일", "mark": 0, "row": 3]], "comment": "iPad 사본의 글"]))])
        other.host.setBook(Self.book, .object(copy))
        let ownCats: JSONValue = [["id": 0, "name": "iPad 형광펜", "hex": "111111", "counts": true], ["id": 1, "name": "둘", "hex": "222222", "counts": false]]
        other.host.setBook(Self.other, Self.withCats(PlannerModel.emptyPlannerData(), ownCats))
        try await other.engine.initialize()
        try await pairQr(mac, other, name: "iPad")
        try await syncAll(other, mac)
        XCTAssertEqual(cats(other), Self.ownerCats, "같은 책: 그룹 값")
        XCTAssertEqual(cats(mac), Self.ownerCats)
        for d in [mac, other] {
            let b = d.host.book(Self.book)
            XCTAssertEqual(b?["prefs"]?["defaultTheme"], 4)
            XCTAssertEqual(b?["days"]?[Self.d1]?["comment"], "Mac 의 글")
            XCTAssertEqual(Set(b?["days"]?[Self.d1]?["tasks"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []), [Self.task, ipadTask])
        }
        XCTAssertEqual(cats(mac, Self.other), ownCats, "들어온 기기의 자기 책")
    }

    // MARK: - 기본 형광펜 = 설정 안 됨

    func testDefaultCategoriesAreNotUploadedAndConcurrentFirstEditsBothSurvive() async throws {
        let server = FakeSyncServer()
        let a = try await owner(server, PlannerModel.emptyPlannerData())
        let pa = await prefsState(a)
        XCTAssertNil(pa, "기본 설정뿐인 책은 p 레코드가 없다")
        let b = try await freshJoiner(server, a)
        try await syncAll(b, a)
        XCTAssertEqual(cats(b), Self.defaults)
        a.host.edit(Self.book) { Self.withCats($0, Self.renamed($0["prefs"]!["categories"]!, 0, "name", "A 가 고침")) }
        b.host.edit(Self.book) { Self.withCats($0, Self.renamed($0["prefs"]!["categories"]!, 3, "hex", "000000")) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await syncAll(a, b)
        let want = Self.renamed(Self.renamed(Self.defaults, 0, "name", "A 가 고침"), 3, "hex", "000000")
        XCTAssertEqual(cats(a), want)
        XCTAssertEqual(cats(b), want)
    }

    func testAllCategoriesDeletedShowsDefaultsWithoutUploadingThem() async throws {
        let server = FakeSyncServer()
        let oc = Self.ownerCats.arrayValue!
        let two: JSONValue = [oc[0], oc[1]]
        let a = try await owner(server, Self.withCats(PlannerModel.emptyPlannerData(), two))
        let b = try await freshJoiner(server, a)
        try await syncAll(b, a)
        a.host.edit(Self.book) { Self.withCats($0, [oc[1]]) }
        b.host.edit(Self.book) { Self.withCats($0, [oc[0]]) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        try await syncAll(a, b)
        XCTAssertEqual(cats(a), Self.defaults)
        XCTAssertEqual(cats(b), Self.defaults)
        let st = await prefsState(a)
        let alive = (st?["c"]?["categories"]?.objectValue ?? [:]).values.contains { it in
            guard let d = it["d"]?.stringValue else { return true }
            return JS.less(d, it["a"]?.stringValue ?? "")
        }
        XCTAssertFalse(alive, "올라간 기본 형광펜이 없다")
        a.host.edit(Self.book) { Self.withCats($0, Self.renamed($0["prefs"]!["categories"]!, 0, "name", "다시")) }
        try await syncAll(a, b)
        XCTAssertEqual(cats(b)?.arrayValue?.first?["name"], "다시")
        XCTAssertEqual(cats(b)?.arrayValue?.count, 7)
    }

    func testRepairAfterTheIncident() async throws {
        let server = FakeSyncServer()
        let a = try await owner(server, Self.withCats(Self.ownerData(), .array(PlannerModel.defaultCategories + [Self.ownerCats.arrayValue![6]])))
        let b = try await freshJoiner(server, a)
        try await syncAll(b, a)
        a.host.edit(Self.book) { Self.withCats($0, Self.ownerCats) }
        try await syncAll(a, b)
        XCTAssertEqual(cats(b), Self.ownerCats)
        let st = await prefsState(a)
        XCTAssertNotNil(st?["c"]?["categories"]?["5"]?["d"])
        let later = try await freshJoiner(server, a, ip: "10.0.0.9")
        try await syncAll(later, a, b)
        XCTAssertEqual(cats(later), Self.ownerCats)
        XCTAssertEqual(cats(a), Self.ownerCats)
    }

    // MARK: - 펼친 책 파일이 꺼진 동안 사라짐

    private func lossPair() async throws -> (a: Dev, b: Dev, host: FileLossHost, server: FakeSyncServer) {
        let server = FakeSyncServer()
        let a = try await owner(server)
        let inner = MemoryHost()
        Self.freshLibrary(inner)
        let host = FileLossHost(inner)
        let st = MemorySyncStorage(), net = FakeNet(), ev = EventLog()
        let engine = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: "10.0.0.2", net: net), storage: st,
                                                  platform: .windows, auto: false, scanDelayMs: 5, pushDelayMs: 5))
        let b = Dev(host: inner, engine: engine, storage: st, events: ev, net: net)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(b, a)
        XCTAssertEqual(cats(b), Self.ownerCats)
        return (a, b, host, server)
    }

    func testAMissingOpenBookFileIsRestoredNotUploadedAsAnEmptyBook() async throws {
        let (a, b, host, _) = try await lossPair()
        b.host.setBook(Self.book, PlannerModel.emptyPlannerData())   // 다시 켬: 파일이 없어 앱이 빈 책을 폈다
        host.setMissing(Self.book)
        b.host.openBook = Self.book
        try await syncAll(b, a)
        XCTAssertEqual(host.noted, [Self.book])
        XCTAssertEqual(a.host.book(Self.book), Self.ownerData())
        XCTAssertEqual(b.host.book(Self.book), Self.ownerData())
    }

    func testWhatTheUserWritesIntoTheEmptyBookBeforeTheRestoreStays() async throws {
        let (a, b, host, _) = try await lossPair()
        b.host.setBook(Self.book, PlannerModel.emptyPlannerData())
        host.setMissing(Self.book)
        b.host.openBook = Self.book
        try await b.engine.scanNow()                                    // 엔진이 .missing 을 받아들인다 (그림자를 비움)
        XCTAssertEqual(host.noted, [Self.book])
        b.host.edit(Self.book) { d in
            var o = d.objectValue!
            o["days"] = Self.obj([(Self.d2, Self.day(["tasks": [["id": "D0D0D0D0-1111-4222-8333-444455556666", "text": "빈 책에 쓴 것", "mark": 0, "row": 0]]]))])
            return .object(o)
        }
        try await syncAll(b, a)
        for d in [a, b] {
            let book = d.host.book(Self.book)
            XCTAssertEqual(book?["prefs"]?["categories"], Self.ownerCats)
            XCTAssertEqual(book?["days"]?[Self.d1], Self.ownerData()["days"]?[Self.d1])
            XCTAssertEqual(book?["days"]?[Self.d2]?["tasks"]?.arrayValue?.first?["text"], "빈 책에 쓴 것")
            XCTAssertEqual(book?["days"]?[Self.d2]?["dayOff"], true)
        }
    }

    // MARK: - 비교 규칙 (TS diffFlat 과 같은 바이트)

    static let ownerPrefs: JSONValue = {
        var p = PlannerModel.defaultPrefs()
        p["categories"] = ownerCats
        p["defaultTheme"] = 4
        return .object(p)
    }()

    /// 교차 언어 벡터: 기본 형광펜 → 사고 때의 형광펜, ZeroClock("0123456789abcdef"), 빈 상태 (TS default-fill.test.ts 와 같은 글자)
    static let vector =
        #"{"c":{"categories":{"0":{"a":"00000000000000000000000000000000","f":{"counts":[true,"00000000000000000000000000000000"],"hex":["8EDCD2","00000000000000000000000000000000"],"name":["개발 업무","00000000000000020123456789abcdef"]}},"1":{"a":"00000000000000000000000000000000","f":{"counts":[true,"00000000000000000000000000000000"],"hex":["F8B38A","00000000000000000000000000000000"],"name":["외부 일정","00000000000000030123456789abcdef"]}},"2":{"a":"00000000000000000000000000000000","f":{"counts":[true,"00000000000000000000000000000000"],"hex":["A9CFF3","00000000000000000000000000000000"],"name":["일반 업무","00000000000000040123456789abcdef"]}},"3":{"a":"00000000000000000000000000000000","f":{"counts":[false,"00000000000000060123456789abcdef"],"hex":["F3DB78","00000000000000000000000000000000"],"name":["개인 일정","00000000000000050123456789abcdef"]}},"4":{"a":"00000000000000000000000000000000","f":{"counts":[false,"00000000000000080123456789abcdef"],"hex":["CDB6EF","00000000000000000000000000000000"],"name":["운동","00000000000000070123456789abcdef"]}},"5":{"a":"","d":"000000000000000a0123456789abcdef","f":{}},"6":{"a":"00000000000000000000000000000000","f":{"counts":[false,"00000000000000000000000000000000"],"hex":["CFCFD4","00000000000000000000000000000000"],"name":["휴식·이동","00000000000000000000000000000000"]}},"7":{"a":"00000000000000090123456789abcdef","f":{"counts":[true,"00000000000000090123456789abcdef"],"hex":["B9E4A8","00000000000000090123456789abcdef"],"name":["비 계획","00000000000000090123456789abcdef"]}}}},"f":{"defaultTheme":[4,"00000000000000010123456789abcdef"],"o:categories":[["0","1","2","3","4","6","7"],"000000000000000b0123456789abcdef"]}}"#

    func testDefaultsToDefaultsIsNoChange() {
        let clock = ZeroClock(node: "0123456789abcdef")
        let def = Records.flattenPrefs(.object(PlannerModel.defaultPrefs()))
        var emptyP = PlannerModel.defaultPrefs()
        emptyP["categories"] = []
        let empty = Records.flattenPrefs(.object(emptyP))
        for prev in [nil, empty, def] as [Flat?] {
            XCTAssertTrue(CRDT.isEmptyDelta(Records.diff(.prefs, prev: prev, cur: def, clock: clock, base: RecState())))
        }
        var moved = PlannerModel.defaultPrefs()
        moved["categories"] = .array(Array(PlannerModel.defaultCategories.dropFirst()) + [PlannerModel.defaultCategories[0]])
        XCTAssertFalse(CRDT.isEmptyDelta(Records.diff(.prefs, prev: def, cur: Records.flattenPrefs(.object(moved)), clock: clock, base: RecState())))
    }

    func testCrossLanguageVectorForTheFirstChangeFromDefaults() {
        var st = RecState()
        _ = CRDT.mergeInto(&st, Records.diff(.prefs, prev: Records.flattenPrefs(.object(PlannerModel.defaultPrefs())), cur: Records.flattenPrefs(Self.ownerPrefs),
                                             clock: ZeroClock(node: "0123456789abcdef"), base: RecState()))
        XCTAssertEqual(CRDT.toJSON(st).canonical, Self.vector)
        XCTAssertEqual(Records.materialize(RecordKeys.parse("p/\(Self.book)")!, st)?["categories"], Self.ownerCats)
    }

    /// 기본 형광펜을 보던 기기(그림자 = 빈 목록)가 하나를 고치면, 상태에 이미 있는 다른 기기의 형광펜은 기본값에 지지 않는다 (지운 5 도)
    func testAStaleDefaultViewDoesNotBeatTheGroupsCategories() {
        var st = RecState()
        _ = CRDT.mergeInto(&st, Records.diff(.prefs, prev: nil, cur: Records.flattenPrefs(Self.ownerPrefs), clock: ZeroClock(node: "00000000000000b1"), base: st))
        var emptyP = PlannerModel.defaultPrefs()
        emptyP["categories"] = []
        var cur = PlannerModel.defaultPrefs()
        cur["categories"] = Self.renamed(Self.defaults, 1, "name", "내가 고침")
        let hlc = HLC(node: "00000000000000a1", wall: { 2_000 })
        var d = Records.diff(.prefs, prev: Records.flattenPrefs(.object(emptyP)), cur: Records.flattenPrefs(.object(cur)), clock: hlc, base: st)
        CRDT.liftDelta(&d, st, node: "00000000000000a1")
        _ = CRDT.mergeInto(&st, d)
        XCTAssertEqual(Records.materialize(RecordKeys.parse("p/\(Self.book)")!, st)?["categories"], Self.renamed(Self.ownerCats, 1, "name", "내가 고침"))
    }

    func testDefaultStampIsNotLiftedAndCannotResurrectADeletedDefault() {
        let hlc = HLC(node: "00000000000000a1", wall: { 1_000 })
        var cur = PlannerModel.defaultPrefs()
        cur["categories"] = Self.renamed(Self.defaults, 0, "name", "Z")
        var delta = Records.diff(.prefs, prev: nil, cur: Records.flattenPrefs(.object(cur)), clock: hlc, base: RecState())
        var state = RecState()
        state.c["categories"] = ["6": ItemState(a: "", d: "000000000001000000000000000000b2")]
        CRDT.liftDelta(&delta, state, node: "00000000000000a1")
        XCTAssertEqual(delta.c["categories"]?["6"]?.a, Stamps.defaultStamp)
        _ = CRDT.mergeInto(&state, delta)
        XCTAssertEqual(state.c["categories"]?["6"]?.isAlive, false)
        XCTAssertEqual(state.c["categories"]?["6"]?.f.isEmpty, true)
    }

    func testMaterialisedPrefsWithoutCategoriesAreTheDefaults() {
        XCTAssertEqual(Records.materialize(RecordKeys.parse("p/\(Self.book)")!, RecState())?["categories"], Self.defaults)
    }
}
