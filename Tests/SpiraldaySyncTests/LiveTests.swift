// 실시간 쓰기 (docs/sync-live.md): 초안 보내기 · 받기 · presence · 재생 거르기 · 보호 칸 · 저장된 그림자 · 대신 올리기 ·
// 자기 쓰기 다시 받지 않기 · 상황별 보내기 지연. 진짜 엔진 + 가짜 서버(초안 중계 · presence 흉내). TypeScript 엔진의
// sync/engine/test/live.test.ts 와 같은 시나리오.
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

/// 시계 (nil = 진짜 시계)
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var fixed: Int?
    private var offset = 0
    var now: Int { lock.withLock { (fixed ?? Int(Date().timeIntervalSince1970 * 1000)) + offset } }
    func set(_ t: Int?) { lock.withLock { fixed = t } }
    func advance(_ ms: Int) { lock.withLock { offset += ms } }
}

final class LiveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SyncLiveEvent] = []
    func add(_ e: SyncLiveEvent) { lock.withLock { list.append(e) } }
    var all: [SyncLiveEvent] { lock.withLock { list } }
    var typing: [(from: String, at: [FieldAddress], editing: Bool)] {
        all.compactMap { if case let .remoteTyping(f, a, e) = $0 { return (f, a, e) } else { return nil } }
    }

    var held: [FieldAddress?] { all.compactMap { if case let .held(a) = $0 { return .some(a) } else { return nil } } }
}

/// 프레임을 모은다 (relayFilter)
final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [FakeRelay] = []
    func add(_ r: FakeRelay) { lock.withLock { list.append(r) } }
    var all: [FakeRelay] { lock.withLock { list } }
    func take(_ i: Int) -> FakeRelay { lock.withLock { list.remove(at: i) } }
    func takeAll() -> [FakeRelay] { lock.withLock { let l = list; list = []; return l } }
    var count: Int { lock.withLock { list.count } }
}

struct LDev {
    let name: String
    let host: MemoryHost
    let engine: SyncEngine
    let storage: MemorySyncStorage
    let net: FakeNet
    let clock: TestClock
    let ip: String
    let live: LiveLog
    let events: EventLog

    var deviceId: String {
        get async { await engine.status.deviceId ?? "" }
    }
}

nonisolated(unsafe) var ipSeq = 0

/// 테스트가 만든 엔진 (끝나면 멈춘다 — 타이머 · 소켓이 다음 테스트로 넘어가지 않게)
final class EngineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SyncEngine] = []
    func add(_ e: SyncEngine) { lock.withLock { list.append(e) } }
    func takeAll() -> [SyncEngine] { lock.withLock { let l = list; list = []; return l } }
}

let liveEngines = EngineRegistry()

class LiveCase: XCTestCase {
    override func tearDown() async throws {
        for e in liveEngines.takeAll() { await e.dispose() }
        try await super.tearDown()
    }
}

extension PushDelays {
    /// 모든 상황에 같은 지연 (테스트)
    static func all(_ ms: Int) -> PushDelays {
        var d = PushDelays()
        d.pushDelayMs = ms
        d.coveredPushDelayMs = ms
        d.oldPeerPushDelayMs = ms
        d.oldPeerMaxWaitMs = ms
        d.unknownPushDelayMs = ms
        d.unknownMaxWaitMs = ms
        d.alonePushDelayMs = ms
        d.aloneMaxWaitMs = ms
        return d
    }
}

func ldevice(_ server: FakeSyncServer, _ name: String, storage: MemorySyncStorage? = nil, host: MemoryHost? = nil, clock: TestClock = TestClock(),
             _ edit: (inout SyncEngineOptions) -> Void = { _ in }) async -> LDev {
    ipSeq += 1
    let ip = "10.1.\(ipSeq / 200).\(ipSeq % 200 + 1)"
    let h = host ?? MemoryHost()
    let st = storage ?? MemorySyncStorage()
    let net = FakeNet()
    var o = SyncEngineOptions(host: h, transport: server.transport(ip: ip, net: net), storage: st, platform: .windows, auto: false, socket: true,
                              now: { clock.now })
    edit(&o)
    let engine = SyncEngine(o)
    liveEngines.add(engine)
    let live = LiveLog()
    let ev = EventLog()
    await engine.addLiveListener { live.add($0) }
    await engine.addListener { ev.add($0) }
    return LDev(name: name, host: h, engine: engine, storage: st, net: net, clock: clock, ip: ip, live: live, events: ev)
}

/// 조건이 될 때까지 (실시간 길은 actor · 가짜 소켓 줄을 거쳐 비동기로 돈다)
func waitUntil(_ what: String = "", timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line, _ f: () async -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await f() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("기다렸지만 안 됨: \(what)", file: file, line: line)
    throw CancellationError()
}

/// 잠깐 (가짜 소켓 줄 · actor 의 남은 일을 흘려보낸다)
func settle(_ ms: Int = 30) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

let LiveD = "2026-10-02"

/// 공유 책 하나로 그룹: 첫 기기가 만들고 나머지가 QR 로 들어온다. 모두 그 책을 열어 두고 서로의 presence 를 본다
func liveGroup(_ server: FakeSyncServer, _ n: Int, _ edit: @escaping (inout SyncEngineOptions) -> Void = { _ in },
               book bookEdit: ((JSONValue) -> JSONValue)? = nil) async throws -> (devs: [LDev], book: String, key: String) {
    var devs: [LDev] = []
    for i in 0..<n { devs.append(await ldevice(server, String(UnicodeScalar(65 + i)!), edit)) }
    let b = newBook("공유 플래너")
    let id = b.info["id"]!.stringValue!
    devs[0].host.library = ["books": [b.info], "activeID": .string(id)]
    devs[0].host.setBook(id, bookEdit.map { $0(b.data) } ?? b.data)
    for d in devs { try await d.engine.initialize() }
    try await devs[0].engine.createGroup(deviceName: "A")
    try await devs[0].engine.syncNow()
    for d in devs.dropFirst() {
        let offer = try await devs[0].engine.startPairing(mode: .qr)
        let join = try await d.engine.joinGroup(offer.qrText!, deviceName: d.name)
        _ = try await offer.wait(intervalMs: 5)
        try await offer.approve(enteredDigits: join.confirmDigits)
        try await join.accept()
        try await d.engine.syncNow()
    }
    for d in devs { try await d.engine.syncNow() }
    for d in devs { d.host.openBook = id }
    for d in devs {
        try await waitUntil("presence") { await d.engine.presence?.peers == n - 1 }
    }
    return (devs, id, RecordKeys.day(id, LiveD))
}

func setComment(_ d: LDev, _ book: String, _ text: String, date: String = LiveD) {
    d.host.edit(book) { applyOp($0, ["t": "comment", "date": .number(Double(DATES.firstIndex(of: date) ?? 1)), "text": .string(text)]) }
    d.engine.liveEdit([RecordKeys.day(book, date)])
}

func liveComment(_ d: LDev, _ book: String) -> String { d.host.book(book)?["days"]?[LiveD]?["comment"]?.stringValue ?? "" }

func dayTasks(_ d: LDev, _ book: String) -> JSONValue { d.host.book(book)?["days"]?[LiveD]?["tasks"] ?? .array([]) }

/// 하루의 할 일을 통째로 바꾼다 (앱이 고친 것처럼)
func setTasks(_ d: LDev, _ book: String, _ tasks: [JSONValue], slots: ((inout [JSONValue]) -> Void)? = nil) {
    d.host.edit(book) { data in
        var o = data.objectValue!
        var days = o["days"]?.objectValue ?? [:]
        var day = days[LiveD]?.objectValue ?? emptyDayJSON()
        day["tasks"] = .array(tasks)
        if let slots {
            var s = day["slots"]?.arrayValue ?? Array(repeating: -1, count: 144)
            slots(&s)
            day["slots"] = .array(s)
        }
        days[LiveD] = .object(day)
        o["days"] = .object(days)
        return .object(o)
    }
    d.engine.liveEdit([RecordKeys.day(book, LiveD)])
}

func emptyDayJSON() -> [String: JSONValue] {
    ["tasks": [], "slots": .array(Array(repeating: -1, count: 144)), "comment": "", "memos": ["", "", ""], "memoTags": ["", "", ""], "notes": [], "ddays": []]
}

func task(_ id: String, _ text: String, mark: Int = 0, row: Int? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["id": .string(id), "text": .string(text), "mark": JSONValue(mark)]
    if let row { o["row"] = JSONValue(row) }
    return .object(o)
}

final class LiveDraftTests: LiveCase {
    func testLettersArriveOneByOneAndReceiverUploadsNothing() async throws {
        let server = FakeSyncServer()
        let frames = FrameLog()
        server.relayFilter = { frames.add($0); return true }
        let (devs, book, key) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let pa = await a.engine.presence
        XCTAssertEqual(pa, LivePresence(relay: true, peers: 1, live: 1))
        let sb = await b.engine.status
        XCTAssertEqual(sb.presence, LivePresence(relay: true, peers: 1, live: 1))
        let aid = await a.deviceId

        // 한글 조합: ㅇ → 아 → 안 → 안ㄴ → 안녀 → 안녕
        for t in ["ㅇ", "아", "안", "안ㄴ", "안녀", "안녕"] {
            setComment(a, book, t)
            await a.engine.flushLive()
            try await waitUntil("B 가 \(t) 를 받음") { liveComment(b, book) == t }
        }
        XCTAssertEqual(server.draftsSent(by: aid), 6)
        XCTAssertEqual(b.host.liveApplied, 6)
        let typing = b.live.typing
        XCTAssertEqual(typing.count, 6)
        XCTAssertEqual(typing.first?.from, aid)
        XCTAssertEqual(typing.first?.at, [FieldAddress(key: key, field: "comment")])
        XCTAssertEqual(typing.first?.editing, false)
        // 받은 기기: 올릴 것 없음 (초안은 올릴 이유가 아니다)
        var st = await b.engine.status
        XCTAssertEqual(st.pending, 0)
        st = await a.engine.status
        XCTAssertEqual(st.pending, 1)

        let head0 = server.head(gid: st.gid!)
        let bApplied = b.host.applied
        try await a.engine.syncNow()
        XCTAssertEqual(server.head(gid: st.gid!), head0 + 1)
        try await b.engine.syncNow()
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        // 레코드 도장 = 초안 도장 → 받은 쪽 합치기는 바뀌는 것이 없다: 앱에 다시 넣지 않고 다시 올리지도 않는다
        XCTAssertEqual(b.host.applied, bApplied)
        XCTAssertEqual(server.head(gid: st.gid!), head0 + 1)
        st = await b.engine.status
        XCTAssertEqual(st.pending, 0)
        let c = await b.engine.liveCounters
        XCTAssertEqual(c.received, 6)
        XCTAssertEqual(c.dropped, 0)
        XCTAssertEqual(c.adopted, 0)
        // 서버가 본 것: 평문 · 책 id · 날짜 없음
        let seen = server.dump() + frames.all.map(\.frame).joined()
        XCTAssertFalse(seen.contains("안녕"))
        XCTAssertFalse(seen.contains(book))
        XCTAssertFalse(seen.contains(LiveD))
        XCTAssertEqual(frames.count, 6)
    }

    func testClosedBookWaitsForNormalApply() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        b.host.openBook = nil
        setComment(a, book, "닫힌 책")
        await a.engine.flushLive()
        try await waitUntil { await b.engine.liveCounters.received == 1 }
        await settle()
        XCTAssertEqual(liveComment(b, book), "")
        var st = await b.engine.status
        XCTAssertEqual(st.pending, 0)
        try await b.engine.syncNow()
        XCTAssertEqual(liveComment(b, book), "닫힌 책")
        st = await b.engine.status
        XCTAssertEqual(st.pending, 0)
    }

    func testTasksAndPaintingGoLive() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0], b = devs[1]
        let T = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        setTasks(a, book, [task(T, "회")])
        await a.engine.flushLive()
        try await waitUntil { dayTasks(b, book).arrayValue?.first?["text"] == "회" }
        setTasks(a, book, [task(T, "회의 준")]) { s in for i in 42..<45 { s[i] = 3 } }
        await a.engine.flushLive()
        try await waitUntil { dayTasks(b, book).arrayValue?.first?["text"] == "회의 준" }
        let slots = b.host.book(book)?["days"]?[LiveD]?["slots"]?.arrayValue ?? []
        XCTAssertEqual(Array(slots[42..<48]), [3, 3, 3, -1, -1, -1])
    }

    func testNoDraftsWithoutRelayListenersOrLive() async throws {
        // 옛 서버 (중계 없음)
        let s1 = FakeSyncServer()
        s1.live = false
        let b1 = newBook("옛 서버")
        let id1 = b1.info["id"]!.stringValue!
        let a = await ldevice(s1, "A")
        let b = await ldevice(s1, "B")
        a.host.library = ["books": [b1.info], "activeID": .string(id1)]
        a.host.setBook(id1, b1.data)
        try await a.engine.initialize()
        try await b.engine.initialize()
        try await a.engine.createGroup(deviceName: "A")
        try await pairLive(a, b)
        a.host.openBook = id1
        b.host.openBook = id1
        try await waitUntil {
            let x = await a.engine.status.live
            let y = await b.engine.status.live
            return x && y
        }
        await settle()
        var p = await a.engine.presence
        XCTAssertNil(p)
        setComment(a, id1, "옛 서버")
        await a.engine.flushLive()
        await settle()
        let aid1 = await a.deviceId
        XCTAssertEqual(s1.draftsSent(by: aid1), 0)
        XCTAssertEqual(liveComment(b, id1), "")
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        XCTAssertEqual(liveComment(b, id1), "옛 서버")

        // 새 서버, 하지만 다른 기기가 꺼져 있다
        let s2 = FakeSyncServer()
        let g2 = try await liveGroup(s2, 2)
        await g2.devs[1].engine.stop()
        try await waitUntil { await g2.devs[0].engine.presence == LivePresence(relay: true, peers: 0, live: 0) }
        setComment(g2.devs[0], g2.book, "혼자")
        await g2.devs[0].engine.flushLive()
        let aid2 = await g2.devs[0].deviceId
        XCTAssertEqual(s2.draftsSent(by: aid2), 0)

        // live: false = 하위 프로토콜을 내밀지 않는다
        let s3 = FakeSyncServer()
        let g3 = try await liveGroupNoWait(s3, 2) { $0.live = false }
        p = await g3.devs[0].engine.presence
        XCTAssertNil(p)
        setComment(g3.devs[0], g3.book, "x")
        await g3.devs[0].engine.flushLive()
        await settle()
        let aid3 = await g3.devs[0].deviceId
        XCTAssertEqual(s3.draftsSent(by: aid3), 0)
    }

    func testMixedGroupOldAppCountsAsPeerOnly() async throws {
        let server = FakeSyncServer()
        let (devs, book, _) = try await liveGroup(server, 2)
        let a = devs[0]
        let c = await ldevice(server, "C") { $0.live = false }
        try await c.engine.initialize()
        try await pairLive(a, c)
        try await waitUntil { await a.engine.presence == LivePresence(relay: true, peers: 2, live: 1) }
        let pr = await a.engine.presence
        XCTAssertEqual(PushMode.of(pr), .oldPeer)
        setComment(a, book, "섞임")
        await a.engine.flushLive()
        try await waitUntil { liveComment(devs[1], book) == "섞임" }
        await settle()
        let cc = await c.engine.liveCounters
        XCTAssertEqual(cc.received, 0)
        XCTAssertEqual(cc.dropped, 0)
    }

    func testOutsideGroupLiveEditDoesNothing() async throws {
        let server = FakeSyncServer()
        let a = await ldevice(server, "A")
        let b = newBook("혼자 쓰는 책")
        let id = b.info["id"]!.stringValue!
        a.host.library = ["books": [b.info], "activeID": .string(id)]
        a.host.setBook(id, b.data)
        a.host.openBook = id
        try await a.engine.initialize()
        a.engine.liveEdit([RecordKeys.day(id, LiveD)])
        a.engine.setEditing(FieldAddress(key: RecordKeys.day(id, LiveD), field: "comment"))
        await a.engine.flushLive()
        await settle()
        XCTAssertTrue(server.log.isEmpty)
        XCTAssertEqual(a.host.liveReads, 0)
        let behind = await a.engine.storageBehind
        XCTAssertFalse(behind)
    }
}

/// a 가 QR 을 보여 주고 b 가 들어온다 (실시간 테스트용)
func pairLive(_ a: LDev, _ b: LDev) async throws {
    let offer = try await a.engine.startPairing(mode: .qr)
    let join = try await b.engine.joinGroup(offer.qrText!, deviceName: b.name)
    _ = try await offer.wait(intervalMs: 5)
    try await offer.approve(enteredDigits: join.confirmDigits)
    try await join.accept()
    try await b.engine.syncNow()
    try await a.engine.syncNow()
}

/// liveGroup 과 같지만 presence 를 기다리지 않는다 (live: false · 옛 서버)
func liveGroupNoWait(_ server: FakeSyncServer, _ n: Int, _ edit: @escaping (inout SyncEngineOptions) -> Void = { _ in }) async throws -> (devs: [LDev], book: String) {
    var devs: [LDev] = []
    for i in 0..<n { devs.append(await ldevice(server, String(UnicodeScalar(65 + i)!), edit)) }
    let b = newBook("공유 플래너")
    let id = b.info["id"]!.stringValue!
    devs[0].host.library = ["books": [b.info], "activeID": .string(id)]
    devs[0].host.setBook(id, b.data)
    for d in devs { try await d.engine.initialize() }
    try await devs[0].engine.createGroup(deviceName: "A")
    try await devs[0].engine.syncNow()
    for d in devs.dropFirst() { try await pairLive(devs[0], d) }
    for d in devs { d.host.openBook = id }
    for d in devs { try await waitUntil { await d.engine.status.live } }
    return (devs, id)
}
