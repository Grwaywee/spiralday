// 엔진 + 가짜 서버: 그룹 만들기 · 페어링(승인 게이트) · 주고받기 · 지우기 · 복구 · 오류
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SyncEvent] = []
    func add(_ e: SyncEvent) { lock.withLock { list.append(e) } }
    var all: [SyncEvent] { lock.withLock { list } }
    func hasWarning(_ w: SyncWarning) -> Bool {
        all.contains { if case let .warning(x, _, _) = $0 { return x == w } else { return false } }
    }
}

struct Dev {
    let host: MemoryHost
    let engine: SyncEngine
    let storage: MemorySyncStorage
    let events: EventLog
    let net: FakeNet
}

let D = "2026-10-02"

func device(_ server: FakeSyncServer, storage: MemorySyncStorage? = nil, host: MemoryHost? = nil, platform: String = "Windows", ip: String = "10.0.0.1",
            auto: Bool = false, credentials: (any CredentialStore)? = nil, net: FakeNet = FakeNet()) async -> Dev {
    let h = host ?? MemoryHost()
    let st = storage ?? MemorySyncStorage()
    let ev = EventLog()
    let engine = SyncEngine(SyncEngineOptions(host: h, transport: server.transport(ip: ip, net: net), storage: st, credentials: credentials,
                                              platform: SyncPlatform(rawValue: platform)!, auto: auto, scanDelayMs: 5, pushDelayMs: 5))
    await engine.addListener { ev.add($0) }
    return Dev(host: h, engine: engine, storage: st, events: ev, net: net)
}

@discardableResult
func addBook(_ host: MemoryHost, _ name: String, _ edit: ((JSONValue) -> JSONValue)? = nil) -> String {
    let b = newBook(name)
    let id = b.info["id"]!.stringValue!
    host.editLibrary { lib in
        var o = lib.objectValue!
        o["books"] = .array(Records.books(lib) + [b.info])
        if o["activeID"] == nil { o["activeID"] = .string(id) }
        return .object(o)
    }
    host.setBook(id, edit.map { $0(b.data) } ?? b.data)
    return id
}

func withComment(_ text: String) -> (JSONValue) -> JSONValue { { applyOp($0, ["t": "comment", "date": 1, "text": .string(text)]) } }

func comment(_ d: Dev, _ book: String, _ date: String = D) -> String? { d.host.book(book)?["days"]?[date]?["comment"]?.stringValue }

func view(_ d: Dev) -> String { syncedView(d.host.library, d.host.books) }

func syncAll(_ devs: Dev...) async throws {
    for _ in 0..<3 { for d in devs { try await d.engine.syncNow() } }
}

/// 원래 기기 a 가 QR 을 보여 주고 → b 가 요청 → 두 화면의 숫자가 같음 → a 가 승인 → b 가 키를 받아 들어간다
@discardableResult
func pairQr(_ a: Dev, _ b: Dev, name: String = "거실 노트북", file: StaticString = #filePath, line: UInt = #line) async throws -> PendingJoin {
    let offer = try await a.engine.startPairing(mode: .qr)
    XCTAssertTrue(offer.qrText!.hasPrefix("SPIRALDAY-PAIR:1:"), file: file, line: line)
    let join = try await b.engine.joinGroup(offer.qrText!, deviceName: name)
    let req = try await offer.wait(intervalMs: 5)
    XCTAssertNotNil(req, file: file, line: line)
    XCTAssertEqual(req?.deviceId, join.deviceId, file: file, line: line)
    XCTAssertEqual(req?.platform, b.engine.platform, file: file, line: line)
    // 원래 기기는 숫자를 모른다 — 새 기기 화면의 숫자를 입력받아 승인한다
    try await offer.approve(enteredDigits: join.confirmDigits)
    let o = try await join.waitForApproval(intervalMs: 5)
    guard case .approved = o else {
        XCTFail("승인되지 않음 \(o)", file: file, line: line)
        return join
    }
    try await join.accept()
    return join
}

/// 승인까지 (accept 는 부르는 쪽이)
func requestAndApprove(_ a: Dev, _ b: Dev, mode: PairingMode = .qr) async throws -> (PairingOffer, PendingJoin, JoinRequest) {
    let offer = try await a.engine.startPairing(mode: mode)
    let join = try await b.engine.joinGroup(mode == .qr ? offer.qrText! : offer.code!, deviceName: "B")
    let req = try await offer.wait(intervalMs: 5)
    XCTAssertNotNil(req)
    try await offer.approve(enteredDigits: join.confirmDigits)
    return (offer, join, req!)
}

func expectError(_ code: SyncEngineError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async -> SyncEngineError? {
    do {
        try await body()
        XCTFail("오류가 나야 함: \(code.rawValue)", file: file, line: line)
        return nil
    } catch let e as SyncEngineError {
        XCTAssertEqual(e.code, code, "\(e.message)", file: file, line: line)
        return e
    } catch {
        XCTFail("다른 오류: \(error)", file: file, line: line)
        return nil
    }
}

final class EnginePairingTests: XCTestCase {
    func testCreateGroupAndPairByQrServerSeesNoPlaintext() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac")
        let book = addBook(a.host, "2026 플래너", withComment("비밀 일기"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "서재 Mac")
        try await a.engine.syncNow()
        var st = await a.engine.status
        XCTAssertEqual(st.state, .idle)
        XCTAssertEqual(st.pending, 0)

        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "비밀 일기")
        XCTAssertEqual(view(b), view(a))
        st = await b.engine.status
        XCTAssertEqual(st.state, .idle)

        // 서버가 본 것: 평문 · 책 id · 날짜 · 기기 이름이 없다
        let seen = server.dump()
        XCTAssertFalse(seen.contains("비밀 일기"))
        XCTAssertFalse(seen.contains(book))
        XCTAssertFalse(seen.contains(D))
        XCTAssertFalse(seen.contains("서재") || seen.contains("거실"))

        // 기기 목록: 이름은 K 로 풀린다
        let list = try await a.engine.listDevices()
        XCTAssertEqual(list.devices.compactMap(\.name).sorted(), ["거실 노트북", "서재 Mac"])
        XCTAssertEqual(list.devices.filter(\.current).count, 1)
    }

    func testPairByCodeAndRejectWrongExpiredUsed() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        addBook(a.host, "A")
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let offer = try await a.engine.startPairing(mode: .code)
        XCTAssertNotNil(offer.code!.range(of: "^[0-9A-Z]{4}-[0-9A-Z]{4}$", options: .regularExpression))

        let b = await device(server)
        try await b.engine.initialize()
        _ = await expectError(.invalidCode) { _ = try await b.engine.joinGroup("ZZZZ-ZZZZ", deviceName: "B") }
        _ = await expectError(.invalidCode) { _ = try await b.engine.joinGroup("nope", deviceName: "B") }
        let join = try await b.engine.joinGroup(offer.code!.lowercased().replacingOccurrences(of: "-", with: " "), deviceName: "B")
        XCTAssertEqual(join.confirmDigits.count, 4)
        XCTAssertEqual(join.mode, .code)
        let req = try await offer.wait(intervalMs: 5)
        XCTAssertNotNil(req)
        try await offer.approve(enteredDigits: join.confirmDigits)
        try await join.accept() // 승인을 기다려 키를 받고 들어간다
        try await b.engine.syncNow()
        let inGroup = await b.engine.inGroup
        XCTAssertTrue(inGroup)

        let c = await device(server)
        try await c.engine.initialize()
        _ = await expectError(.invalidCode) { _ = try await c.engine.joinGroup(offer.code!, deviceName: "C") }
    }

    func testGroupKeyLeavesServerOnlyAfterApproval() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let gid = await a.engine.status.gid!
        let b = await device(server)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .code)
        let wrappedKey = server.pairings(gid: gid)[0].wrappedKey!
        let join = try await b.engine.joinGroup(offer.code!, deviceName: "B")
        // 요청에 감싼 키가 없다, 새 기기는 아직 기기가 아니다
        let claims = server.log.filter { $0.path == "/v1/pairings/claim" }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims[0].body?.objectValue?.keys.sorted(), ["codeHash", "deviceName", "mode", "nonce"])
        XCTAssertFalse(server.dump().contains(wrappedKey) && server.log.contains { $0.path.hasSuffix("/claim") && $0.status == 200 && ($0.body?.canonical.contains(wrappedKey) ?? false) })
        XCTAssertEqual(server.deviceCount(gid: gid), 1)
        // 승인 전에는 기다린다 (그만두면 cancelled, 다시 기다릴 수 있다)
        let waiting = Task { try await join.waitForApproval(intervalMs: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        let w = try await waiting.value
        XCTAssertEqual(w, .cancelled)
        XCTAssertTrue(server.log.filter { $0.path.hasSuffix("/join") }.allSatisfy { $0.status == 200 })
        // 원래 기기: 요청 · 숫자 → 승인
        let req = try await offer.wait(intervalMs: 5)
        XCTAssertEqual(req?.pairingId, offer.pairingId)
        XCTAssertEqual(req?.deviceId, join.deviceId)
        XCTAssertEqual(req?.platform, .windows)
        // 숫자가 다르면 서버에 아무것도 보내지 않는다
        let wrong = join.confirmDigits == "0000" ? "1111" : "0000"
        _ = await expectError(.digitsMismatch) { try await offer.approve(enteredDigits: wrong) }
        XCTAssertEqual(offer.triesLeft, 2)
        try await offer.approve(enteredDigits: " " + join.confirmDigits.prefix(2) + "-" + join.confirmDigits.suffix(2) + " ")
        try await offer.approve(enteredDigits: join.confirmDigits) // 두 번 눌러도 된다
        let o = try await join.waitForApproval(intervalMs: 5)
        let aId = await a.engine.status.deviceId!
        guard case let .approved(devices, acceptBy) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(devices, [GroupDevice(id: aId, name: "A", platform: .windows)])
        XCTAssertGreaterThan(acceptBy - Int(Date().timeIntervalSince1970 * 1000), 20 * 60_000)
        let again = try await join.waitForApproval()
        XCTAssertEqual(again, o)
        try await join.accept()
        let inGroup = await b.engine.inGroup
        XCTAssertTrue(inGroup)
        // 감싼 키는 새 기기가 수락하면(첫 그룹 요청) 서버에서 지워진다
        XCTAssertNil(server.pairings(gid: gid)[0].wrappedKey)
        let names = try await a.engine.listDevices().devices.compactMap(\.name).sorted()
        XCTAssertEqual(names, ["A", "B"])
    }

    func testOriginalDeviceDeniesNothingLeaks() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .qr)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        let req = try await offer.wait(intervalMs: 5)
        XCTAssertNotNil(req)
        try await offer.deny()
        let o = try await join.waitForApproval(intervalMs: 5)
        XCTAssertEqual(o, .denied)
        _ = await expectError(.pairingDenied) { try await join.accept() }
        let inGroup = await b.engine.inGroup
        XCTAssertFalse(inGroup)
        let n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 1)
    }

    func testNewDeviceWithdrawsBeforeApproval() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let offer = try await a.engine.startPairing(mode: .qr)
        let b = await device(server)
        try await b.engine.initialize()
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        let req = try await offer.wait(intervalMs: 5)
        try await join.reject()
        let inGroup = await b.engine.inGroup
        XCTAssertFalse(inGroup)
        XCTAssertNotNil(req)
        _ = await expectError(.pairingExpired) { try await offer.approve(enteredDigits: join.confirmDigits) }
        let n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 1)
        let o = try await join.waitForApproval()
        XCTAssertEqual(o, .cancelled)
    }

    func testNewDeviceRejectsAfterApprovalIsRemoved() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        let (_, join, _) = try await requestAndApprove(a, b)
        let o = try await join.waitForApproval(intervalMs: 5)
        guard case .approved = o else { return XCTFail("\(o)") }
        var n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 2)
        try await join.reject()
        let inGroup = await b.engine.inGroup
        XCTAssertFalse(inGroup)
        n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 1)
    }

    func testApprovalDeadlinePasses() async throws {
        final class Skew: @unchecked Sendable { var ms = 0 }
        let skew = Skew()
        let server = FakeSyncServer(now: { Int(Date().timeIntervalSince1970 * 1000) + skew.ms })
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .qr, ttlSec: 60)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        // 페어링은 60초짜리지만 요청이 오면 승인할 시간 180초를 준다
        XCTAssertGreaterThan(join.expiresAt - Int(Date().timeIntervalSince1970 * 1000), 170_000)
        _ = try await offer.wait(intervalMs: 5)
        skew.ms = 200_000 // 승인 기한을 넘긴다
        let o = try await join.waitForApproval(intervalMs: 5)
        XCTAssertEqual(o, .expired)
        _ = await expectError(.pairingExpired) { try await offer.approve(enteredDigits: join.confirmDigits) }
        _ = await expectError(.pairingExpired) { try await join.accept() }
    }

    func testRemovedAfterApprovalBecomesRemoved() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        let join = try await pairQr(a, b)
        try await a.engine.removeDevice(join.deviceId)
        try await b.engine.syncNow()
        var st = await b.engine.status
        XCTAssertEqual(st.state, .removed)
        try await b.engine.forgetGroup()
        st = await b.engine.status
        XCTAssertEqual(st.state, .off)
    }

    func testCancelledPairingCannotBeUsed() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let offer = try await a.engine.startPairing(mode: .qr)
        try await offer.cancel()
        let r = try await offer.wait()
        XCTAssertNil(r)
        let b = await device(server)
        try await b.engine.initialize()
        _ = await expectError(.invalidCode) { _ = try await b.engine.joinGroup(offer.qrText!, deviceName: "B") }
        do {
            try await offer.approve(enteredDigits: "1234")
            XCTFail("승인되면 안 됨")
        } catch {}
    }

    func testWrongCodesRateLimitedButQrStillWorks() async throws {
        var limits = FakeServerLimits()
        limits.codeFailPerHour = 2
        let server = FakeSyncServer(limits: limits)
        let a = await device(server)
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server, ip: "10.9.9.9")
        try await b.engine.initialize()
        _ = await expectError(.invalidCode) { _ = try await b.engine.joinGroup("AAAA-AAAA", deviceName: "B") }
        _ = await expectError(.invalidCode) { _ = try await b.engine.joinGroup("BBBB-BBBB", deviceName: "B") }
        let offer = try await a.engine.startPairing(mode: .code)
        let err = await expectError(.rateLimited) { _ = try await b.engine.joinGroup(offer.code!, deviceName: "B") }
        XCTAssertTrue(err?.message.contains("QR") ?? false)
        XCTAssertNotNil(err?.message.range(of: "[0-9]+(분|시간)", options: .regularExpression))
        try await offer.cancel()
        let (_, join, _) = try await requestAndApprove(a, b, mode: .qr)
        try await join.accept()
        let inGroup = await b.engine.inGroup
        XCTAssertTrue(inGroup)
    }

    func testDeviceNamesBoundToIds() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "Mac")
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "서재 Mac")
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        let gid = await a.engine.status.gid!
        let names = server.deviceNames(gid: gid)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("e1.") })
        server.swapDeviceNames(gid: gid)
        let list = try await a.engine.listDevices()
        XCTAssertEqual(list.devices.map(\.name), [nil, nil])
    }

    func testRenameRetriedOnNextSync() async throws {
        let server = FakeSyncServer()
        let net = FakeNet()
        let a = await device(server, platform: "Mac", net: net)
        try await a.engine.initialize()
        net.fail = { m, _ in m == "PATCH" }
        try await a.engine.createGroup(deviceName: "서재 Mac")
        let gid = await a.engine.status.gid!
        XCTAssertEqual(server.deviceNames(gid: gid), ["p.Mac"])
        var first = try await a.engine.listDevices().devices[0]
        XCTAssertNil(first.name)
        XCTAssertEqual(first.platform, .mac)
        // 껐다 켜도 기억한다
        await a.engine.dispose()
        net.fail = nil
        let again = await device(server, storage: a.storage, host: a.host, platform: "Mac", net: net)
        try await again.engine.initialize()
        try await again.engine.syncNow()
        first = try await again.engine.listDevices().devices[0]
        XCTAssertEqual(first.name, "서재 Mac")
        // the platform stays known after the name is encrypted (icons in the device list)
        XCTAssertEqual(first.platform, .mac)
        let meta = await again.storage.meta
        XCTAssertNil(meta?["rename"])
    }
}

final class EngineExchangeTests: XCTestCase {
    func pair() async throws -> (FakeSyncServer, Dev, Dev, String) {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책") { applyOp(withComment("처음")($0), ["t": "addTask", "date": 1, "id": "AAAAAAAA-0000-4000-8000-000000000001", "text": "회의", "cat": 1]) }
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        return (server, a, b, book)
    }

    func testEditsFlowAndDifferentFieldsBothSurvive() async throws {
        let (_, a, b, book) = try await pair()
        a.host.edit(book) { applyOp($0, ["t": "paint", "date": 1, "start": 0, "len": 6, "cat": 2]) }
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "B 가 씀"]) }
        b.host.edit(book) { applyOp($0, ["t": "markTask", "date": 1, "i": 0, "mark": 1]) }
        a.host.edit(book) { applyOp($0, ["t": "editTask", "date": 1, "i": 0, "text": "팀 회의"]) }
        try await syncAll(a, b)
        for dev in [a, b] {
            let r = dev.host.book(book)!["days"]![D]!
            XCTAssertEqual(Array(r["slots"]!.arrayValue!.prefix(6)), [2, 2, 2, 2, 2, 2])
            XCTAssertEqual(r["comment"], "B 가 씀")
            let t = r["tasks"]!.arrayValue![0]
            XCTAssertEqual(t["text"], "팀 회의")
            XCTAssertEqual(t["mark"], 1)
            XCTAssertEqual(t["cat"], 1)
        }
        XCTAssertEqual(view(a), view(b))
        XCTAssertTrue(b.events.all.contains { if case .applied = $0 { return true } else { return false } })
    }

    func testEditBetweenPullAndApplyIsKept() async throws {
        let (_, a, b, book) = try await pair()
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "A 의 새 글"]) }
        try await a.engine.syncNow()
        // B 는 아직 비교하지 않은 편집이 있다 (다른 필드)
        b.host.edit(book) { applyOp($0, ["t": "memo", "date": 1, "i": 0, "text": "B 메모"]) }
        try await b.engine.pullNow()
        let r = b.host.book(book)!["days"]![D]!
        XCTAssertEqual(r["comment"], "A 의 새 글")
        XCTAssertEqual(r["memos"]?.arrayValue?[0], "B 메모")
        try await syncAll(a, b)
        XCTAssertEqual(a.host.book(book)!["days"]![D]!["memos"]?.arrayValue?[0], "B 메모")
    }

    func testNewBookRenameDeleteSpreadSampleStaysLocal() async throws {
        let (_, a, b, book) = try await pair()
        let sample = newBook("예시 플래너")
        var sinfo = sample.info.objectValue!
        sinfo["isSample"] = true
        a.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib) + [.object(sinfo)])
            return .object(o)
        }
        a.host.setBook(sample.info["id"]!.stringValue!, sample.data)
        let second = addBook(a.host, "두 번째", withComment("둘"))
        a.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib).map { b in
                guard b["id"]?.stringValue == book, case var .object(bo) = b else { return b }
                bo["name"] = "고친 이름"
                return .object(bo)
            })
            return .object(o)
        }
        try await syncAll(a, b)
        XCTAssertEqual(Records.books(b.host.library).compactMap { $0["name"]?.stringValue }.sorted(), ["고친 이름", "두 번째"])
        XCTAssertEqual(comment(b, second), "둘")
        XCTAssertNil(b.host.book(sample.info["id"]!.stringValue!))

        b.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib).filter { $0["id"]?.stringValue != second })
            return .object(o)
        }
        b.host.setBook(second, nil)
        try await syncAll(b, a)
        XCTAssertFalse(Records.books(a.host.library).contains { $0["id"]?.stringValue == second })
        XCTAssertNil(a.host.book(second))
        XCTAssertTrue(Records.books(a.host.library).contains { $0["id"] == sample.info["id"] })
    }

    func testDeletedBookEditedElsewhereDoesNotResurrect() async throws {
        let (_, a, b, book) = try await pair()
        a.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = []
            return .object(o)
        }
        a.host.setBook(book, nil)
        try await a.engine.syncNow()
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "늦은 편집"]) }
        try await syncAll(b, a)
        XCTAssertEqual(Records.books(b.host.library).count, 0)
        XCTAssertEqual(Records.books(a.host.library).count, 0)
    }

    func testJoiningDevicePlannersJoinGroupValuesWin() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let shared = addBook(a.host, "같은 책", withComment("그룹 값"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()

        let b = await device(server)
        let own = addBook(b.host, "B 의 책", withComment("B 만"))
        // 같은 책의 사본 (같은 id) — 겹치는 필드는 그룹이, 없는 필드는 B 것이 남는다
        let copy = Records.books(a.host.library)[0]
        b.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = .array(Records.books(lib) + [copy])
            return .object(o)
        }
        b.host.setBook(shared, applyOp(applyOp(a.host.book(shared)!, ["t": "comment", "date": 1, "text": "B 의 옛 값"]), ["t": "memo", "date": 1, "i": 1, "text": "B 의 메모"]))
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await syncAll(b, a, b)
        for dev in [a, b] {
            XCTAssertEqual(Records.books(dev.host.library).compactMap { $0["name"]?.stringValue }.sorted(), ["B 의 책", "같은 책"])
            XCTAssertEqual(comment(dev, shared), "그룹 값")
            XCTAssertEqual(dev.host.book(shared)!["days"]![D]!["memos"]?.arrayValue?[1], "B 의 메모")
            XCTAssertEqual(comment(dev, own), "B 만")
        }
    }

    func testOfflineQueueSurvivesRestart() async throws {
        let (server, a, b, book) = try await pair()
        a.net.offline = true
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "비행기에서"]) }
        try await a.engine.syncNow()
        var st = await a.engine.status
        XCTAssertEqual(st.state, .offline)
        XCTAssertGreaterThan(st.pending, 0)
        await a.engine.dispose()

        // 같은 저장소 · 같은 앱으로 다시 켠다
        let a2 = await device(server, storage: a.storage, host: a.host)
        try await a2.engine.initialize()
        st = await a2.engine.status
        XCTAssertGreaterThan(st.pending, 0)
        try await a2.engine.syncNow()
        st = await a2.engine.status
        XCTAssertEqual(st.pending, 0)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "비행기에서")
    }

    func testServerWithoutBatchWorksOneByOne() async throws {
        let server = FakeSyncServer()
        server.batch = false
        let a = await device(server)
        let book = addBook(a.host, "책") { applyOp(applyOp($0, ["t": "comment", "date": 0, "text": "1"]), ["t": "comment", "date": 2, "text": "3"]) }
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        XCTAssertTrue(server.log.contains { $0.path.hasSuffix("/records/batch") })
        XCTAssertGreaterThan(server.log.filter { $0.path.hasSuffix("/records") && $0.status == 200 }.count, 3)
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book, "2026-10-03"), "3")
    }

    func testConcurrentWritesConflictAndMerge() async throws {
        let (server, a, b, book) = try await pair()
        a.host.edit(book) { applyOp($0, ["t": "paint", "date": 1, "start": 60, "len": 6, "cat": 3]) }
        b.host.edit(book) { applyOp($0, ["t": "paint", "date": 1, "start": 66, "len": 6, "cat": 4]) }
        try await a.engine.syncNow()
        // B 는 받지 않고 바로 올린다 → 409 → 서버 것과 합쳐 다시
        try await b.engine.scanNow()
        try await b.engine.pushNow()
        XCTAssertTrue(server.log.contains { $0.status == 409 })
        let st = await b.engine.status
        XCTAssertEqual(st.pending, 0)
        XCTAssertEqual(st.state, .idle)
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        for dev in [a, b] {
            let s = dev.host.book(book)!["days"]![D]!["slots"]!.arrayValue!
            XCTAssertEqual(Array(s[60..<66]), [3, 3, 3, 3, 3, 3])
            XCTAssertEqual(Array(s[66..<72]), [4, 4, 4, 4, 4, 4])
        }
    }

    func testLostResponseIsNotWrittenTwice() async throws {
        let (server, a, b, book) = try await pair()
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "응답을 잃음"]) }
        a.net.dropResponse = { m, p in m == "POST" && p.hasSuffix("/records") }
        try await a.engine.syncNow()
        var st = await a.engine.status
        XCTAssertEqual(st.state, .offline)
        let head = server.head(gid: st.gid!)
        try await a.engine.syncNow()
        st = await a.engine.status
        XCTAssertEqual(st.pending, 0)
        XCTAssertEqual(server.head(gid: st.gid!), head) // 같은 내용을 다시 쓰지 않았다
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "응답을 잃음")
    }
}

final class EngineSafetyTests: XCTestCase {
    func testUnreadableLibraryDeletesNothing() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        addBook(a.host, "하나")
        addBook(a.host, "둘")
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        a.host.libraryUnreadable = true
        try await a.engine.syncNow()
        XCTAssertTrue(a.events.hasWarning(.libraryUnreadable))
        a.host.libraryUnreadable = false
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(Records.books(b.host.library).count, 2)
    }

    func testEmptiedLibraryIsRestored() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let b1 = addBook(a.host, "하나", withComment("1"))
        addBook(a.host, "둘", withComment("2"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        a.host.library = ["books": [], "sampleSeeded": true]
        a.host.books = [:]
        try await a.engine.syncNow()
        XCTAssertTrue(a.events.hasWarning(.massDeleteBooks))
        XCTAssertEqual(Records.books(a.host.library).count, 2)
        XCTAssertEqual(comment(a, b1), "1")
    }

    func testManyVanishedDaysAreRestored() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책") { d in
            var o = d.objectValue!
            var days: [String: JSONValue] = [:]
            for i in 1...25 {
                var day = PlannerModel.emptyDay()
                day["comment"] = .string("day \(i)")
                days[String(format: "2026-08-%02d", i)] = .object(day)
            }
            o["days"] = .object(days)
            return .object(o)
        }
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        a.host.edit(book) { d in
            var o = d.objectValue!
            o["days"] = [:]
            return .object(o)
        }
        try await a.engine.syncNow()
        XCTAssertTrue(a.events.hasWarning(.massDeleteDays))
        XCTAssertEqual(a.host.book(book)?["days"]?.objectValue?.count, 25)
    }

    func testMissingBookFileIsRestored() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("살아 있다"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        a.host.setBook(book, nil)
        try await a.engine.syncNow()
        XCTAssertEqual(comment(a, book), "살아 있다")
        XCTAssertTrue(a.events.hasWarning(.bookMissing))
    }

    func testUnreadableBookIsLeftAlone() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("그대로"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        a.host.setUnreadable(book, true)
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "B 가 고침"]) }
        try await syncAll(b, a)
        XCTAssertEqual(comment(a, book), "그대로") // 읽을 수 없는 파일은 건드리지 않는다
        a.host.setUnreadable(book, false)
        try await a.engine.syncNow()
        XCTAssertEqual(comment(a, book), "B 가 고침")
    }

    func testServerRollbackRecovers() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("하나"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let gid = await a.engine.status.gid!
        // 백업에서 되돌린 것처럼: 레코드를 모두 잃고 head 가 0
        server.rollback(gid: gid)
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 2, "text": "둘"]) }
        try await a.engine.syncNow()
        try await a.engine.syncNow()
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "하나")
        XCTAssertEqual(comment(b, book, "2026-10-03"), "둘")
    }

    func testHiddenMemoSlotsDoNotDiverge() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let b = await device(server)
        let bk = addBook(a.host, "책") { applyOp($0, ["t": "comment", "date": 2, "text": "운동"]) }
        try await a.engine.initialize()
        try await b.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let offer = try await a.engine.startPairing(mode: .qr)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        _ = try await offer.wait(intervalMs: 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        try await join.accept()
        try await b.engine.syncNow()
        // A: 넷째 메모 칸을 열고 비워 둠 (메모 4칸) · B: 그 날을 비움 → 합치면 "빈 날" 이라 두 앱에서 사라진다
        a.host.edit(bk) { applyOp($0, ["t": "memo", "date": 2, "i": 3, "text": ""]) }
        try await a.engine.scanNow()
        b.host.edit(bk) { applyOp($0, ["t": "clearDay", "date": 2]) }
        try await b.engine.scanNow()
        for _ in 0..<2 { for d in [a, b] { try await d.engine.syncNow() } }
        // A 가 그 날에 색 테마를 고른다 (앱은 빈 날을 새로 만든다: 메모 3칸)
        a.host.edit(bk) { applyOp($0, ["t": "theme", "date": 2, "theme": 0]) }
        for _ in 0..<2 { for d in [a, b] { try await d.engine.syncNow() } }
        XCTAssertEqual(view(a), view(b))
        let st = await a.engine.status
        XCTAssertEqual(st.pending, 0)
    }

    func testRecordTooLargeIsSkippedOthersContinue() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        // 압축해도 1MiB 를 넘는 글 (난수)
        var rng = Rng(7)
        let big = String((0..<1_600_000).map { _ in Character(UnicodeScalar(UInt8(33 + rng.nat(90)))) })
        let book = addBook(a.host, "책") { applyOp(applyOp($0, ["t": "comment", "date": 0, "text": .string(big)]), ["t": "comment", "date": 1, "text": "작은 글"]) }
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        XCTAssertTrue(a.events.hasWarning(.recordTooLarge))
        let st = await a.engine.status
        XCTAssertEqual(st.state, .idle)
        XCTAssertEqual(st.pending, 1)
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "작은 글")
        XCTAssertNil(comment(b, book, "2026-10-01"))
    }
}

final class EngineLifecycleTests: XCTestCase {
    func testRecoveryAfterLosingAllDevices() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("잃으면 안 되는 것"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let code = try await a.engine.setupRecovery()
        XCTAssertNotNil(code.range(of: "^([0-9A-Z]{5}-){4}[0-9A-Z]{5}$", options: .regularExpression))
        let has = await a.engine.hasRecovery
        XCTAssertTrue(has)

        let c = await device(server)
        try await c.engine.initialize()
        let chars = Array(code)
        var typo = chars
        typo[3] = chars[3] == "0" ? "1" : "0"
        _ = await expectError(.invalidCode) { try await c.engine.restoreFromRecovery(code: String(typo), deviceName: "C") }
        let r = try await c.engine.restoreFromRecovery(code: code.lowercased(), deviceName: "새 노트북")
        XCTAssertNil(r.evicted)
        try await c.engine.syncNow()
        XCTAssertEqual(comment(c, book), "잃으면 안 되는 것")
        let names = try await c.engine.listDevices().devices.compactMap(\.name).sorted()
        XCTAssertEqual(names, ["A", "새 노트북"])

        // 새 복구 코드를 만들면 예전 코드는 못 쓴다
        _ = try await a.engine.setupRecovery()
        let d = await device(server)
        try await d.engine.initialize()
        _ = await expectError(.recoveryNotFound) { try await d.engine.restoreFromRecovery(code: code, deviceName: "D") }
    }

    func testWipeGroupLeavesDataOthersGroupGone() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("남는다"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        try await a.engine.wipeGroup()
        let inGroup = await a.engine.inGroup
        XCTAssertFalse(inGroup)
        XCTAssertEqual(server.groupCount, 0)
        try await b.engine.syncNow()
        let st = await b.engine.status
        XCTAssertEqual(st.state, .groupGone)
        XCTAssertEqual(comment(b, book), "남는다")
        XCTAssertEqual(comment(a, book), "남는다")
    }

    func testLeaveGroupOnlyThisDevice() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        addBook(a.host, "책")
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.leaveGroup()
        let inGroup = await b.engine.inGroup
        XCTAssertFalse(inGroup)
        let n = try await a.engine.listDevices().devices.count
        XCTAssertEqual(n, 1)
        try await a.engine.syncNow()
        let st = await a.engine.status
        XCTAssertEqual(st.state, .idle)
    }

    func testHistoryAndRestoreVersion() async throws {
        var limits = FakeServerLimits()
        limits.historyCoalesceMs = 0
        let server = FakeSyncServer(limits: limits)
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("첫 글"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "실수로 지움"]) }
        try await a.engine.syncNow()
        let versions = try await a.engine.history(RecordKeys.day(book, D))
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(versions[0].current)
        XCTAssertEqual(versions[0].value?["comment"], "실수로 지움")
        XCTAssertEqual(versions[1].value?["comment"], "첫 글")
        try await a.engine.restoreVersion(RecordKeys.day(book, D), seq: versions[1].seq)
        XCTAssertEqual(comment(a, book), "첫 글")
        let b = await device(server)
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(comment(b, book), "첫 글")
    }

    func testClearErrorsOutsideGroup() async throws {
        let server = FakeSyncServer()
        let net = FakeNet()
        let a = await device(server, net: net)
        try await a.engine.initialize()
        _ = await expectError(.notInGroup) { _ = try await a.engine.startPairing(mode: .qr) }
        _ = await expectError(.notInGroup) { _ = try await a.engine.listDevices() }
        net.offline = true
        _ = await expectError(.offline) { try await a.engine.createGroup(deviceName: "A") }
        let fresh = await device(server)
        _ = await expectError(.notInitialized) { try await fresh.engine.syncNow() }
    }

    func testEventsStream() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        addBook(a.host, "책", withComment("이벤트"))
        try await a.engine.initialize()
        let stream = a.engine.events()
        let collector = Task { () -> [SyncState] in
            var states: [SyncState] = []
            for await e in stream {
                if case let .status(st) = e { states.append(st.state) }
                if states.contains(.idle), states.contains(.syncing), states.last == .idle { break }
            }
            return states
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let states = await collector.value
        XCTAssertTrue(states.contains(.syncing))
        XCTAssertEqual(states.last, .idle)
    }

    func testCredentialsInSeparateStore() async throws {
        let server = FakeSyncServer()
        let creds = MemoryCredentialStore()
        let a = await device(server, credentials: creds)
        addBook(a.host, "책", withComment("비밀"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let stored = try await creds.get()
        XCTAssertNotNil(stored)
        let meta = await a.storage.meta
        XCTAssertNil(meta?["creds"]) // 토큰 · 키는 동기화 상태 저장소에 두지 않는다
        try await a.engine.forgetGroup()
        let after = try await creds.get()
        XCTAssertNil(after)
    }
}

final class EngineCompatTests: XCTestCase {
    func testUnknownPayloadVersionIsNotOverwritten() async throws {
        let server = FakeSyncServer()
        let a = await device(server)
        let book = addBook(a.host, "책", withComment("v1"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let meta = await a.storage.meta
        let creds = meta!["creds"]!
        let keys = try GroupKeys(base64: creds["key"]!.stringValue!)
        let key = RecordKeys.day(book, D)
        let rid = keys.rid(key)
        let gid = creds["gid"]!.stringValue!
        let future = keys.encryptRecord(rid: rid, payload: ["v": 2, "k": .string(key), "s": ["새로운": "모양"]])
        let t = server.transport()
        let r = try await t.putRecord(Auth(gid: gid, token: creds["token"]!.stringValue!), RecordWrite(rid: rid, baseSeq: server.recordCiphertext(gid: gid, rid: rid)!.seq, ct: future))
        guard case .ok = r else { return XCTFail("\(r)") }
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "내 편집"]) }
        try await a.engine.syncNow()
        try await a.engine.syncNow()
        XCTAssertEqual(server.recordCiphertext(gid: gid, rid: rid)?.ct, future)
        XCTAssertTrue(a.events.hasWarning(.updateRequired))
        XCTAssertEqual(comment(a, book), "내 편집")
    }

    func testSharedLibrarySettingsSync() async throws {
        let server = FakeSyncServer()
        let a = await device(server, host: MemoryHost(sharedSettings: ["weekStart": "monday", "units": ["time": "24h"]]))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await a.engine.syncNow()
        let b = await device(server, host: MemoryHost(sharedSettings: [:]))
        try await b.engine.initialize()
        try await pairQr(a, b)
        try await b.engine.syncNow()
        XCTAssertEqual(b.host.sharedSettings, ["weekStart": "monday", "units": ["time": "24h"]])
    }
}

final class EngineAutoTests: XCTestCase {
    func until(_ what: String, timeout: TimeInterval = 10, _ f: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await f() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("기다렸지만 안 됨: \(what)")
    }

    func testSaveNotifyPushAndWebSocketDelivery() async throws {
        let server = FakeSyncServer()
        let a = await device(server, platform: "iPad", auto: true)
        let book = addBook(a.host, "책", withComment("처음"))
        try await a.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        let b = await device(server, platform: "iPhone", auto: true)
        try await b.engine.initialize()
        let offer = try await a.engine.startPairing(mode: .qr)
        let join = try await b.engine.joinGroup(offer.qrText!, deviceName: "B")
        // 원래 기기는 WebSocket {pairing} 알림으로 바로 깨어난다 (폴링 간격이 길어도)
        let t0 = Date()
        let req = try await offer.wait(intervalMs: 60_000)
        XCTAssertEqual(req?.deviceId, join.deviceId)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        try await join.accept()
        await until("B 가 처음 받음") { comment(b, book) == "처음" }
        await until("둘 다 실시간") {
            let x = await a.engine.status.live
            let y = await b.engine.status.live
            return x && y
        }
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "실시간"]) }
        a.engine.localChanged(bookId: book)
        await until("B 가 실시간으로 받음", timeout: 5) { comment(b, book) == "실시간" }
        // 연결이 끊기면 (1006) 잠깐 뒤 다시 붙는다
        server.dropSockets()
        await until("A 가 끊김을 앎") { await !a.engine.status.live }
        await until("A 가 다시 붙음", timeout: 5) { await a.engine.status.live }
        // 뒤로 가기: 남은 편집을 올리고 연결을 닫는다 · 앞으로 오기: 다시 붙고 받는다
        b.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "뒤로 가기 전에"]) }
        await b.engine.suspend()
        let bs = await b.engine.status
        XCTAssertEqual(bs.pending, 0)
        XCTAssertFalse(bs.live)
        await until("A 가 받음", timeout: 5) { comment(a, book) == "뒤로 가기 전에" }
        a.host.edit(book) { applyOp($0, ["t": "comment", "date": 1, "text": "그동안 A 가 씀"]) }
        a.engine.localChanged(bookId: book)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(comment(b, book), "뒤로 가기 전에") // 뒤에 있는 동안은 받지 않는다
        await b.engine.resume()
        await until("B 가 앞으로 와서 받음", timeout: 5) { comment(b, book) == "그동안 A 가 씀" }
        await until("B 가 다시 붙음", timeout: 5) { await b.engine.status.live }
        // 그룹을 지우면 B 는 알림으로 바로 group-gone
        try await a.engine.wipeGroup()
        await until("B 가 group-gone") { await b.engine.status.state == .groupGone }
        await a.engine.dispose()
        await b.engine.dispose()
    }
}
