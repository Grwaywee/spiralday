// 실시간 쓰기 + 말 안 듣는 네트워크 (property): 초안이 늦게 · 두 번 · 순서가 바뀌어 · 아예 안 닿고, HTTP 도 늦게 · 두 번 · 안 닿거나
// 응답만 사라지고, 기기가 앱 파일을 저장하기 전에 죽었다 다시 켜지고, 쓰고 있는 칸이 바뀌고, 시계가 흘러 대신 올리기가 일어나도
// 끝나면 모든 기기의 플래너가 같고 보낼 것이 남지 않는다. 초안은 보통 레코드 사이사이에 섞인다.
// (TypeScript 엔진의 sync/engine/test/live-chaos.test.ts 와 같은 시나리오. LIVE_CHAOS_RUNS=200 · LIVE_CHAOS_SEED=<씨앗>)
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

/// 앱 메모리와 앱 파일이 따로인 앱: 편집 · 실시간 넣기는 메모리에만, save 때 파일로 (엔진의 updateBook 은 파일까지)
final class FileHost: SyncHost, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _library: JSONValue
    private var _books: [String: JSONValue] = [:]
    private var _files: [String: JSONValue] = [:]
    private var _open: String?

    init(library: JSONValue = ["books": [], "sampleSeeded": false]) { _library = library }

    var library: JSONValue {
        get { lock.withLock { _library } }
        set { lock.withLock { _library = newValue } }
    }

    var books: [String: JSONValue] { lock.withLock { _books } }
    var files: [String: JSONValue] { lock.withLock { _files } }
    var openBook: String? {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue?.uppercased() } }
    }

    func book(_ id: String) -> JSONValue? { lock.withLock { _books[id.uppercased()] } }

    func setBook(_ id: String, _ v: JSONValue, file: Bool = true) {
        lock.withLock {
            _books[id.uppercased()] = v
            if file { _files[id.uppercased()] = v }
        }
    }

    func edit(_ id: String, _ f: (JSONValue) -> JSONValue) {
        lock.withLock {
            let k = id.uppercased()
            if let cur = _books[k] { _books[k] = f(cur) }
        }
    }

    /// 앱이 파일에 다 썼다 → 쓴 값
    func save(_ id: String) -> JSONValue? {
        lock.withLock {
            let k = id.uppercased()
            guard let d = _books[k] else { return nil }
            _files[k] = d
            return d
        }
    }

    func readLibrary() async -> JSONValue? { library }

    func readBook(id: String) async -> BookRead {
        lock.withLock { _books[id.uppercased()].map { .ok($0) } ?? .missing }
    }

    func updateBook(id: String, _ transform: @Sendable (JSONValue?) -> JSONValue?) async throws {
        lock.withLock {
            let k = id.uppercased()
            let next = transform(_books[k])
            _books[k] = next
            _files[k] = next
        }
    }

    func updateLibrary(_ transform: @Sendable (JSONValue) -> JSONValue) async throws {
        lock.withLock { _library = transform(_library) }
    }

    func readLive(bookId: String, keys: [String]) async -> [String: JSONValue]? {
        lock.withLock {
            let k = bookId.uppercased()
            guard _open == k, let data = _books[k] else { return nil }
            var out: [String: JSONValue] = [:]
            for key in keys { out[key] = recordValue(RecordKeys.parse(key)!, inBook: data) ?? .null }
            return out
        }
    }

    func applyLive(bookId: String, keys: [String], _ transform: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async -> Bool {
        lock.withLock {
            let k = bookId.uppercased()
            guard _open == k, var data = _books[k] else { return false }
            var cur: [String: JSONValue] = [:]
            for key in keys { cur[key] = recordValue(RecordKeys.parse(key)!, inBook: data) ?? .null }
            let next = transform(cur)
            for key in keys {
                guard let pk = RecordKeys.parse(key), let v = next[key] else { continue }
                let value: JSONValue? = v.isNull ? nil : v
                switch pk.kind {
                case .day: data = Records.withDay(data, pk.date!, value)
                case .week: data = Records.withWeek(data, pk.date!, value)
                case .prefs:
                    if case var .object(o) = data, let value {
                        o["prefs"] = value
                        data = .object(o)
                    }
                default: break
                }
            }
            _books[k] = data
            return true
        }
    }
}

final class LiveChaosTests: LiveCase {
    struct CDev {
        var host: FileHost
        var engine: SyncEngine
        var storage: MemorySyncStorage
        var net: FakeNet
        var clock: TestClock
    }

    func testLiveDraftsConvergeUnderChaos() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["LIVE_CHAOS_RUNS"] ?? "12") ?? 12
        let base = UInt64(ProcessInfo.processInfo.environment["LIVE_CHAOS_SEED"] ?? "") ?? 0x11FE
        var stats = (drafts: 0, dropped: 0, adopted: 0, crashes: 0)
        for run in 0..<runs {
            let seed = base &+ UInt64(run) &* 7919
            try await scenario(seed: seed, stats: &stats)
        }
        if ProcessInfo.processInfo.environment["CHAOS_STATS"] != nil { print("live chaos stats", stats) }
    }

    /// 저절로 도는 엔진(진짜 타이머: 묶음 · 저장 · 보내기 · 받기가 바퀴와 겹친다) + 초안 대부분은 바로, 가끔 늦게 · 두 번 · 버림
    func testLiveDraftsConvergeWithTimersAndRaces() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["LIVE_RACE_RUNS"] ?? "6") ?? 6
        let base = UInt64(ProcessInfo.processInfo.environment["LIVE_CHAOS_SEED"] ?? "") ?? 0xACE5
        var stats = (drafts: 0, dropped: 0, adopted: 0, crashes: 0)
        for run in 0..<runs {
            let seed = base &+ UInt64(run) &* 7919
            try await scenario(seed: seed, auto: true, stats: &stats)
        }
        if ProcessInfo.processInfo.environment["CHAOS_STATS"] != nil { print("live race stats", stats) }
    }

    func make(_ server: FakeSyncServer, _ i: Int, host: FileHost, storage: MemorySyncStorage, clock: TestClock, net: FakeNet, auto: Bool = false) -> CDev {
        var o = SyncEngineOptions(host: host, transport: server.transport(ip: "10.7.0.\(i + 1)", net: net), storage: storage,
                                  platform: .web, auto: auto, socket: true, now: { clock.now })
        if auto {
            o.scanDelayMs = 5
            o.pushDelays = .all(15)
            o.liveThrottleMs = 5
            o.liveFlushMs = 5
            o.minPullIntervalMs = 0
            o.editingGraceMs = 40
            o.pollMs = 200
        }
        let engine = SyncEngine(o)
        liveEngines.add(engine)
        return CDev(host: host, engine: engine, storage: storage, net: net, clock: clock)
    }

    func scenario(seed: UInt64, auto: Bool = false, stats: inout (drafts: Int, dropped: Int, adopted: Int, crashes: Int)) async throws {
        var rng = Rng(seed)
        let n = rng.int(2, 3)
        var limits = FakeServerLimits()
        limits.claimPer10Min = 0
        let server = FakeSyncServer(limits: limits)
        let held = FrameLog()
        if auto {
            // 대부분 바로, 가끔 쥐었다가 (나중에 · 버림 · 두 번)
            final class Coin: @unchecked Sendable {
                let lock = NSLock()
                var r: Rng
                init(_ seed: UInt64) { r = Rng(seed) }
                func roll() -> Int { lock.withLock { r.nat(9) } }
            }
            let coin = Coin(seed ^ 0xD1CE)
            server.relayFilter = { f in
                switch coin.roll() {
                case 0: held.add(f); return false
                case 1: return false
                case 2: f.deliver(); return true
                default: return true
                }
            }
        } else {
            server.relayFilter = { held.add($0); return false }
        }
        let book = newBook("공유 플래너")
        let bookId = book.info["id"]!.stringValue!
        let keys = DATES.map { RecordKeys.day(bookId, $0) } + WEEKS.map { RecordKeys.week(bookId, $0) } + [RecordKeys.prefs(bookId)]
        let addresses: [FieldAddress?] = [
            nil,
            FieldAddress(key: RecordKeys.day(bookId, DATES[0]), field: "comment"),
            FieldAddress(key: RecordKeys.day(bookId, DATES[1]), field: "comment"),
            FieldAddress(key: RecordKeys.day(bookId, DATES[0]), field: "m0"),
            FieldAddress(key: RecordKeys.week(bookId, WEEKS[0]), field: "goal"),
            FieldAddress(key: RecordKeys.prefs(bookId), field: "mottoText"),
        ]
        var devs: [CDev] = []
        for i in 0..<n { devs.append(make(server, i, host: FileHost(), storage: MemorySyncStorage(), clock: TestClock(), net: FakeNet(), auto: auto)) }
        var data = book.data
        for _ in 0..<rng.int(0, 5) { data = applyOp(data, randomOp(&rng)) }
        devs[0].host.library = ["books": [book.info], "activeID": .string(bookId)]
        devs[0].host.setBook(bookId, data)
        for d in devs { try await d.engine.initialize() }
        try await devs[0].engine.createGroup(deviceName: "D0")
        try await devs[0].engine.syncNow()
        for d in devs.dropFirst() {
            let offer = try await devs[0].engine.startPairing(mode: .qr)
            let join = try await d.engine.joinGroup(offer.qrText!, deviceName: "Dn")
            _ = try await offer.wait(intervalMs: 5)
            try await offer.approve(enteredDigits: join.confirmDigits)
            try await join.accept()
            try await d.engine.syncNow()
        }
        for d in devs { try await d.engine.syncNow() }
        for d in devs { d.host.openBook = bookId }
        for d in devs { try await waitUntil { await d.engine.presence?.live == n - 1 } }

        for (i, d) in devs.enumerated() {
            d.net.chaos = FakeNet.Chaos(dropRequest: 0.06, dropResponse: 0.06, duplicate: 0.06, maxDelayMs: 3, seed: seed &+ UInt64(i))
        }
        var running: [Task<Void, Never>] = []
        let steps = rng.int(30, 140)
        let trace = ProcessInfo.processInfo.environment["LIVE_CHAOS_DEBUG"] != nil
        for _ in 0..<steps {
            let di = rng.nat(n - 1)
            let d = devs[di]
            let kind = rng.weighted([(14, "edit"), (3, "save"), (4, "sync"), (12, "draft"), (3, "editing"), (1, "clock"), (1, "open"), (1, "crash"), (3, "settle")])
            if trace { print("STEP D\(di) \(kind)") }
            switch kind {
            case "edit":
                let op = randomOp(&rng)
                if trace { print("  op \(op.canonical)") }
                if d.host.book(bookId) != nil {
                    d.host.edit(bookId) { applyOp($0, op) }
                    d.engine.liveEdit(keys)
                    if auto {
                        await settle(rng.int(0, 4))
                    } else if rng.int(0, 2) > 0 {
                        await d.engine.flushLive()
                    }
                }
            case "save":
                // 앱이 파일에 다 썼다 → 엔진에 저장된 값을 알린다
                if let saved = d.host.save(bookId) { await d.engine.noteLocalChange(bookId: bookId, saved: { saved }) }
            case "sync":
                let e = d.engine
                running.append(Task { try? await e.syncNow() })
            case "draft":
                guard held.count > 0 else { break }
                let h = held.take(rng.nat(held.count - 1))
                stats.drafts += 1
                switch rng.weighted([(6, "ok"), (1, "drop"), (1, "dup"), (1, "later")]) {
                case "drop": break
                case "later": held.add(h)
                case "dup":
                    h.deliver()
                    h.deliver()
                default: h.deliver()
                }
                await settle(1)
            case "editing":
                d.engine.setEditing(addresses[rng.nat(addresses.count - 1)])
            case "clock":
                d.clock.advance(rng.int(1000, 40_000))
            case "open":
                d.host.openBook = rng.bool() ? bookId : nil
            case "crash":
                // 앱이 죽음: 그때까지 저장소에 쓴 것과 앱 파일만 남는다. 다시 켠다
                stats.crashes += 1
                let snap = try await d.storage.load()
                await d.engine.stop()
                let storage = MemorySyncStorage()
                try await storage.write(StorageBatch(meta: snap.meta, put: snap.records))
                let host = FileHost(library: d.host.library)
                for (k, v) in d.host.files { host.setBook(k, v) }
                host.openBook = bookId
                let nd = make(server, di, host: host, storage: storage, clock: d.clock, net: d.net, auto: auto)
                devs[di] = nd
                try await nd.engine.initialize()
            default:
                await settle(Int(rng.int(0, 3)))
            }
        }

        // 조용히: 남은 초안은 버리거나 보내고, 네트워크를 고치고, 하던 것을 기다리고, 쓰기를 마치고, 모두가 몇 바퀴 맞춘다
        for h in held.takeAll() where h.frame.utf8.count % 2 == 0 { h.deliver() }
        server.relayFilter = nil
        for d in devs { d.net.chaos = nil }
        for t in running { await t.value }
        for d in devs { await d.engine.setEditingAndSettle(nil) }
        for d in devs { try await waitUntil { await d.engine.liveQuiet } }
        // 보낸 기기가 저장 전에 죽어 받은 기기에만 남은 초안은 liveAdoptMs(30초) 뒤에 받은 기기가 대신 올린다 → 시간이 흐른 뒤에 같아진다
        for d in devs { d.clock.advance(31_000) }
        var views: [String] = []
        for _ in 0..<8 {
            for d in devs { try await d.engine.syncNow() }
            for d in devs { try await waitUntil { await d.engine.liveQuiet } }
            views = devs.map { syncedView($0.host.library, $0.host.books) }
            var clean = true
            for d in devs where await d.engine.status.pending != 0 { clean = false }
            if clean, views.allSatisfy({ $0 == views[0] }) { break }
        }
        // 저절로 도는 엔진은 주기 확인 · 보내기 타이머가 지금 돌고 있을 수 있다 → 잠깐 쉴 때까지
        if auto {
            for d in devs {
                for _ in 0..<300 where await d.engine.status.state != .idle { await settle(10) }
            }
        }
        for (i, d) in devs.enumerated() {
            let st = await d.engine.status
            XCTAssertEqual(st.state, .idle, "씨앗 \(seed) D\(i) \(st.error ?? "")")
            XCTAssertEqual(st.pending, 0, "씨앗 \(seed) D\(i)")
            let c = await d.engine.liveCounters
            stats.dropped += c.dropped
            stats.adopted += c.adopted
        }
        for (i, v) in views.enumerated() where v != views[0] {
            XCTFail("씨앗 \(seed): D\(i) 의 플래너가 다름\n\(v)\n≠\n\(views[0])")
        }
        if ProcessInfo.processInfo.environment["LIVE_CHAOS_DEBUG"] != nil, views.contains(where: { $0 != views[0] }) {
            for (i, d) in devs.enumerated() {
                for k in keys {
                    let r = await d.engine.debugRecord(k)
                    print("D\(i) \(k): \(r)")
                }
            }
        }
        for d in devs { await d.engine.dispose() }
    }
}
