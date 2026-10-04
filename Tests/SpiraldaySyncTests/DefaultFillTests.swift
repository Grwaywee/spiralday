// 회귀: 기기가 "기본값으로 채운" 값(앱 기본 형광펜)이 다른 기기의 진짜 값을 이기면 안 된다.
//
// 처음 켠 기기가 합류해 받은 책을 처음 넣을 때 (이 기기에 그 책 파일이 없음 → cur = nil → PlannerModel.emptyPlannerData()),
// BookApplyJob.run → RecData.applyTo(.prefs) 가 기본 prefs 를 그림자 없이 비교(absorb)한다 → 기본 형광펜 7개가 이 기기의
// 새 항목으로 진짜 HLC 도장을 받아(liftDelta) 그룹을 만든 기기의 형광펜을 이긴다. TS 엔진과 같다 (sync/engine/test/default-fill.test.ts).
// XCTExpectFailure { } = "지금은 틀린다". 고치면 기대한 실패가 없어 이 시험들이 실패한다 → XCTExpectFailure 를 걷어 낸다.
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class DefaultFillTests: XCTestCase {
    /// 그룹을 만든 기기의 형광펜 (이름을 바꾸고 id 5 를 지운 7개 — 그룹을 만들기 전에 지워 지움 표시가 없다)
    static let ownerCats: JSONValue = [
        ["id": 0, "name": "개발 업무", "hex": "8EDCD2", "counts": true],
        ["id": 1, "name": "외부 일정", "hex": "F8B38A", "counts": true],
        ["id": 2, "name": "일반 업무", "hex": "A9CFF3", "counts": true],
        ["id": 3, "name": "개인 일정", "hex": "F3DB78", "counts": false],
        ["id": 4, "name": "운동", "hex": "CDB6EF", "counts": false],
        ["id": 6, "name": "휴식·이동", "hex": "CFCFD4", "counts": false],
        ["id": 7, "name": "비 계획", "hex": "B9E4A8", "counts": true],
    ]
    static let book = "40BBE1E5-3BB7-49D8-A3A5-A25FFF2F3829"
    static let sample = "0074794E-5D66-48D9-BE05-28A48B3B1DB2"
    static let info: JSONValue = ["id": .string(book), "name": "나의 업무 일지", "start": "2026-09-28T15:00:00Z", "cover": 4, "created": "2026-09-29T05:19:13Z"]

    static func ownerData() -> JSONValue {
        var d = PlannerModel.emptyPlannerData().objectValue!
        var p = d["prefs"]!.objectValue!
        p["categories"] = ownerCats
        p["defaultTheme"] = 4
        p["mottoText"] = "회귀 시험의 첫 장 글"
        d["prefs"] = .object(p)
        return .object(d)
    }

    private func cats(_ d: Dev) -> JSONValue? { d.host.book(Self.book)?["prefs"]?["categories"] }

    private func withCats(_ data: JSONValue, _ c: JSONValue) -> JSONValue {
        var d = data.objectValue!
        var p = d["prefs"]!.objectValue!
        p["categories"] = c
        d["prefs"] = .object(p)
        return .object(d)
    }

    /// 필드 [값, 도장] 의 도장
    static func stamp(_ e: JSONValue) -> String? {
        guard let a = e.arrayValue, a.count == 2 else { return nil }
        return a[1].stringValue
    }

    /// 저장소에 적힌 p 레코드 상태에서 이 노드의 도장이 있는 경로
    private func stampsBy(_ d: Dev, node: String) async -> [String] {
        guard let st = await d.storage.records["p/\(Self.book)"]?["state"] else { return ["(p 레코드 없음)"] }
        var out: [String] = []
        for (k, v) in st["f"]?.objectValue ?? [:] where Self.stamp(v)?.hasSuffix(node) == true { out.append(k) }
        for (col, items) in st["c"]?.objectValue ?? [:] {
            for (id, it) in items.objectValue ?? [:] {
                if it["a"]?.stringValue?.hasSuffix(node) == true { out.append("\(col)/\(id)/a") }
                for (k, v) in it["f"]?.objectValue ?? [:] where Self.stamp(v)?.hasSuffix(node) == true { out.append("\(col)/\(id)/\(k)") }
            }
        }
        return out.sorted()
    }

    private func owner(_ server: FakeSyncServer) async throws -> Dev {
        let mac = await device(server, platform: "Mac", ip: "10.0.0.1")
        mac.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        mac.host.setBook(Self.book, Self.ownerData())
        try await mac.engine.initialize()
        try await mac.engine.createGroup(deviceName: "Mac")
        try await mac.engine.syncNow()
        return mac
    }

    /// 처음 켠 기기: 예시 플래너만 (isSample — 동기화하지 않는다)
    private func fresh(_ server: FakeSyncServer, platform: String) async -> Dev {
        let d = await device(server, platform: platform, ip: "10.0.0.2")
        d.host.library = ["books": [["id": .string(Self.sample), "name": "예시 플래너", "start": "2026-09-16T15:00:00Z", "cover": 3,
                                     "created": "2026-09-29T16:08:58Z", "isSample": true]],
                          "activeID": .string(Self.sample), "sampleSeeded": true]
        d.host.setBook(Self.sample, PlannerModel.emptyPlannerData())
        return d
    }

    func testFreshJoinerDoesNotStampDefaultCategoriesOfABookItMaterialises() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let phone = await fresh(server, platform: "iPhone")
        try await phone.engine.initialize()
        try await pairQr(mac, phone, name: "iPhone")
        try await syncAll(phone, mac)
        let byPhone = await stampsBy(phone, node: await phone.engine.nodeId)
        let (phoneCats, macCats) = (cats(phone), cats(mac))
        XCTAssertEqual(phone.host.book(Self.book)?["prefs"]?["defaultTheme"], 4, "기본값과 같은 단일 필드는 도장을 받지 않아 그룹 값이 남는다")
        // 비동기 시험에서는 기대한 실패를 같은 스레드의 블록 안에서 적는다
        XCTExpectFailure("2026-10-04 형광펜 사고: 들어온 기기가 받은 책을 처음 만들 때 기본 형광펜을 편집으로 올린다 (BookApplyJob.run · RecData.applyTo)") {
            XCTAssertEqual(byPhone, [], "들어온 기기는 p 레코드에 도장을 찍지 않는다 (사용자가 아무것도 고치지 않았다)")
            XCTAssertEqual(phoneCats, Self.ownerCats)
            XCTAssertEqual(macCats, Self.ownerCats, "그룹을 만든 기기의 형광펜이 되돌아가지 않는다")
        }
    }

    /// 지금의 모습 (사고 재현) — 사고 기기의 SyncState p/40BB… 와 같은 모양: 들어온 기기의 도장 29개 (형광펜 0–6 × (a + 필드 3) + o:categories)
    func testIncidentShapeToday() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let phone = await fresh(server, platform: "iPhone")
        try await phone.engine.initialize()
        try await pairQr(mac, phone, name: "iPhone")
        try await syncAll(phone, mac)
        var expected = ["o:categories"]
        for id in 0...6 { for k in ["a", "counts", "hex", "name"] { expected.append("categories/\(id)/\(k)") } }
        let byPhone = await stampsBy(mac, node: await phone.engine.nodeId)
        XCTAssertEqual(byPhone, expected.sorted())
        let names = cats(mac)?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, PlannerModel.defaultCategories.compactMap { $0["name"]?.stringValue } + ["비 계획"])
        XCTAssertEqual(mac.host.book(Self.book)?["prefs"]?["defaultTheme"], 4)
    }

    func testRecoveryRestoreDoesNotStampDefaultCategories() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let code = try await mac.engine.setupRecovery()
        let restored = await fresh(server, platform: "iPhone")
        try await restored.engine.initialize()
        _ = try await restored.engine.restoreFromRecovery(code: code, deviceName: "새 iPhone")
        try await syncAll(restored, mac)
        let (rCats, macCats) = (cats(restored), cats(mac))
        XCTExpectFailure("복구 코드로 되살린 새 기기도 같은 넣기 길 (cur = nil → 기본 형광펜을 편집으로)") {
            XCTAssertEqual(rCats, Self.ownerCats)
            XCTAssertEqual(macCats, Self.ownerCats)
        }
    }

    /// 같은 뿌리: restoreBook 이 그림자를 지우고 넣기 직전의 비교가 앱 파일 값 전체를 이 기기의 새 편집(HLC)으로 올린다
    func testRestoringAnUnlistedBookDoesNotRevertNewerEditsFromAnotherDevice() async throws {
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
        a.host.edit(Self.book) { self.withCats($0, Self.ownerCats) }
        try await a.engine.syncNow()
        // b 는 아직 받지 않았고, b 의 책장에서만 그 책이 빠졌다 (파일은 그대로 — 잃은 것 → 되살린다)
        b.host.editLibrary { lib in
            var o = lib.objectValue!
            o["books"] = []
            return .object(o)
        }
        try await syncAll(b, a)
        XCTAssertEqual(Records.books(b.host.library).compactMap { $0["id"]?.stringValue }, [Self.book])
        let (bCats, aCats) = (cats(b), cats(a))
        XCTExpectFailure("book-unlisted 되살리기: 이 기기 파일의 옛 형광펜이 더 새 편집을 이긴다") {
            XCTAssertEqual(bCats, Self.ownerCats, "되살린 책")
            XCTAssertEqual(aCats, Self.ownerCats, "다른 기기의 편집이 되돌아가지 않는다")
        }
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
        a.host.edit(Self.book) { self.withCats($0, Self.ownerCats) }
        try await syncAll(a, b)
        XCTAssertEqual(cats(b), Self.ownerCats)
        b.host.setBook(Self.book, nil)                          // 파일만 사라짐 (책장에는 그대로)
        try await syncAll(b, a)
        let (bCats, aCats) = (cats(b), cats(a))
        XCTExpectFailure("잃은 책 파일 되살리기(book-missing)도 cur = nil → 기본 형광펜을 편집으로 올린다") {
            XCTAssertEqual(bCats, Self.ownerCats, "되살린 책")
            XCTAssertEqual(aCats, Self.ownerCats, "다른 기기")
        }
    }

    func testZeroStampedDefaultsDoNotResurrectACategoryTheGroupNeverHad() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let other = await device(server, platform: "iPad", ip: "10.0.0.3")
        other.host.library = ["books": [Self.info], "activeID": .string(Self.book), "sampleSeeded": true]
        other.host.setBook(Self.book, PlannerModel.emptyPlannerData())
        try await other.engine.initialize()
        try await pairQr(mac, other, name: "iPad")
        try await syncAll(other, mac)
        let (otherCats, macCats) = (cats(other), cats(mac))
        XCTExpectFailure("시각 0 으로 가져온 기본 형광펜 5 가 그룹에 없던 항목으로 살아난다 (지움 표시가 없다)") {
            XCTAssertEqual(otherCats, Self.ownerCats)
            XCTAssertEqual(macCats, Self.ownerCats)
        }
    }
}
