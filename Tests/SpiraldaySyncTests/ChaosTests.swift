// 진짜 엔진 여러 대 + 가짜 서버 + 말 안 듣는 네트워크.
// 요청이 늦게 · 순서가 바뀌어 · 두 번 · 아예 안 닿거나 응답만 사라져도, 편집 · 비교 · 동기화를 아무 때나 동시에 해도
// 끝나면 모든 기기의 플래너가 같고, 지운 것은 되살아나지 않는다. (CHAOS_RUNS=200 으로 오래 돌릴 수 있다)
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class ChaosTests: XCTestCase {
    func testEnginesConvergeUnderNetworkChaos() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["CHAOS_RUNS"] ?? "15") ?? 15
        let base = UInt64(ProcessInfo.processInfo.environment["CHAOS_SEED"] ?? "") ?? 0x5EED
        for run in 0..<runs {
            let seed = base &+ UInt64(run) &* 104_729
            try await scenario(seed: seed)
        }
    }

    func scenario(seed: UInt64) async throws {
        var rng = Rng(seed)
        let n = rng.int(2, 3)
        var limits = FakeServerLimits()
        limits.claimPer10Min = 0
        let server = FakeSyncServer(limits: limits)
        var devs: [Dev] = []
        for i in 0..<n {
            let net = FakeNet()
            let host = MemoryHost()
            let st = MemorySyncStorage()
            let engine = SyncEngine(SyncEngineOptions(host: host, transport: server.transport(ip: "10.0.0.\(i + 1)", net: net), storage: st, platform: .web, auto: false))
            devs.append(Dev(host: host, engine: engine, storage: st, events: EventLog(), net: net))
        }
        // 기기 0 이 책 하나로 그룹을 만들고, 나머지가 QR 로 들어온다 (이때는 네트워크 정상)
        let book = newBook("공유 플래너")
        let bookId = book.info["id"]!.stringValue!
        var data = book.data
        for _ in 0..<rng.int(0, 8) { data = applyOp(data, randomOp(&rng)) }
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

        // 아무렇게나
        for (i, d) in devs.enumerated() {
            d.net.chaos = FakeNet.Chaos(dropRequest: 0.08, dropResponse: 0.08, duplicate: 0.08, maxDelayMs: 4, seed: seed &+ UInt64(i))
        }
        let tr = Tracker()
        var running: [Task<Void, Never>] = []
        let steps = rng.int(40, 160)
        for _ in 0..<steps {
            let d = devs[rng.nat(n - 1)]
            switch rng.weighted([(10, "edit"), (3, "scan"), (5, "sync"), (4, "settle"), (1, "newBook"), (2, "editOther"), (1, "dropOther")]) {
            case "edit":
                let op = randomOp(&rng)
                tr.scope = "\(bookId)/"
                if d.host.book(bookId) != nil { d.host.edit(bookId) { applyOp($0, op, tr) } }
            case "editOther":
                let op = randomOp(&rng)
                if let id = Records.books(d.host.library).first(where: { $0["id"]?.stringValue != bookId })?["id"]?.stringValue, d.host.book(id) != nil {
                    tr.scope = "\(id)/"
                    d.host.edit(id) { applyOp($0, op, tr) }
                }
            case "newBook":
                let nb = newBook("책", created: "2026-09-0\(1 + rng.nat(8))T00:00:00Z", id: rng.uuid())
                d.host.editLibrary { lib in
                    var o = lib.objectValue!
                    o["books"] = .array(Records.books(lib) + [nb.info])
                    return .object(o)
                }
                d.host.setBook(nb.info["id"]!.stringValue!, nb.data)
            case "dropOther":
                if let victim = Records.books(d.host.library).first(where: { $0["id"]?.stringValue != bookId })?["id"]?.stringValue {
                    d.host.editLibrary { lib in
                        var o = lib.objectValue!
                        o["books"] = .array(Records.books(lib).filter { $0["id"]?.stringValue != victim })
                        return .object(o)
                    }
                    d.host.setBook(victim, nil)
                    tr.scope = ""
                    tr.del("book:\(victim)")
                }
            case "scan":
                let e = d.engine
                running.append(Task { try? await e.scanNow() })
            case "sync":
                let e = d.engine
                running.append(Task { try? await e.syncNow() })
            default:
                try await Task.sleep(nanoseconds: UInt64(rng.int(0, 3)) * 1_000_000)
            }
        }

        // 조용히: 네트워크를 고치고, 하던 것을 기다리고, 모두가 몇 바퀴 맞춘다
        for d in devs { d.net.chaos = nil }
        for t in running { await t.value }
        for _ in 0..<6 {
            for d in devs { try await d.engine.syncNow() }
            let views = devs.map(view)
            var allClean = true
            for d in devs where await d.engine.status.pending != 0 { allClean = false }
            if allClean, views.allSatisfy({ $0 == views[0] }) { break }
        }

        for (i, d) in devs.enumerated() {
            let st = await d.engine.status
            XCTAssertEqual(st.state, .idle, "씨앗 \(seed) D\(i)")
            XCTAssertEqual(st.pending, 0, "씨앗 \(seed) D\(i)")
        }
        let views = devs.map(view)
        for (i, v) in views.enumerated() where v != views[0] {
            XCTFail("씨앗 \(seed): D\(i) 의 플래너가 다름\n\(v)\n≠\n\(views[0])")
        }
        let gone = tr.mustBeGone()
        for d in devs {
            var ids = Set<String>()
            for b in Records.books(d.host.library) {
                let id = b["id"]!.stringValue!
                ids.insert("book:\(id)")
                if let data = d.host.book(id) { for x in allIds(data) { ids.insert("\(id)/\(x)") } }
            }
            for id in gone {
                // 형광펜은 id 를 다시 쓰고, 모두 지우면 앱이 기본값으로 되돌린다 → 합치기 테스트에서 따로 본다
                if id.contains("/cat:") { continue }
                // → 미룸 id(UUIDv5)는 어느 기기든 같은 id 로 다시 더할 수 있다 (그래서 되살아남 검사에서 뺀다)
                if let last = id.split(separator: "/").last, last.count == 36, Array(last)[14] == "5" { continue }
                XCTAssertFalse(ids.contains(id), "씨앗 \(seed): 지운 \(id) 가 되살아남")
            }
        }
        for d in devs { await d.engine.dispose() }
    }
}
