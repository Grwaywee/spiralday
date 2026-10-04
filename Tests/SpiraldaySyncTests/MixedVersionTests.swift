// 회귀 (2026-10-04 형광펜 사고 고침의 검토 — 비공개 sync/engine/test/mixed-versions.test.ts 와 같은 규칙, 예전 엔진은 서버에 직접
// 쓴 레코드 · 예전 모양의 저장소로 흉내 낸다):
//   - 책 설정(p/)은 payload v 2, 나머지는 v 1 (예전 엔진은 v 1 만 읽어 책 설정을 덮지 못한다). v 1 로 받은 책 설정은 v 2 로 다시 올린다
//   - 책 설정 초안도 v 2 만 받는다 (예전 엔진의 v 1 책 설정 조각은 버린다)
//   - 예전 엔진의 저장소로 켜면 처음부터 다시 받고, 보내지 못한 책 설정(예전 엔진이 막힌 동안 쌓은 기본 형광펜)은 버린다
//   - 같은 책의 옛 사본을 가진 기기의 합류(시각 0)는 그룹을 만든 기기의 형광펜을 이기지 못한다 (첫 가져오기는 진짜 도장 — seed)
//   - 기본값 도장으로만 더한 항목은 진짜 순서 목록에 없으면 보이지 않는다 (Records.isShown)
//   - 사고가 난 그룹: 고친 앱에서 형광펜을 되돌리면 모든 기기에 가고 5 는 지움 표시
import XCTest
@testable import SpiraldaySync
import SpiraldaySyncTesting

final class MixedVersionTests: XCTestCase {
    static let book = DefaultFillTests.book
    static let ownerCats = DefaultFillTests.ownerCats
    static let defaults = DefaultFillTests.defaults
    /// 사고 뒤의 형광펜 (기본 0–6 + Mac 의 7)
    static let incident: JSONValue = .array(PlannerModel.defaultCategories + [["id": 7, "name": "비 계획", "hex": "B9E4A8", "counts": true]])

    private func owner(_ server: FakeSyncServer, _ data: JSONValue = DefaultFillTests.ownerData()) async throws -> Dev {
        let mac = await device(server, platform: "Mac", ip: "10.0.0.1")
        mac.host.library = ["books": [DefaultFillTests.info], "activeID": .string(Self.book), "sampleSeeded": true]
        mac.host.setBook(Self.book, data)
        try await mac.engine.initialize()
        try await mac.engine.createGroup(deviceName: "Mac")
        try await mac.engine.syncNow()
        return mac
    }

    private func fresh(_ server: FakeSyncServer, _ mac: Dev, ip: String = "10.0.0.2", storage: MemorySyncStorage? = nil) async throws -> Dev {
        let d = await device(server, storage: storage, platform: "iPhone", ip: ip)
        d.host.library = ["books": [["id": "0074794E-5D66-48D9-BE05-28A48B3B1DB2", "name": "예시 플래너", "start": "2026-09-16T15:00:00Z", "cover": 3,
                                     "created": "2026-09-29T16:08:58Z", "isSample": true]],
                          "activeID": "0074794E-5D66-48D9-BE05-28A48B3B1DB2", "sampleSeeded": true]
        d.host.setBook("0074794E-5D66-48D9-BE05-28A48B3B1DB2", PlannerModel.emptyPlannerData())
        try await d.engine.initialize()
        try await pairQr(mac, d, name: "iPhone")
        return d
    }

    private func cats(_ d: Dev) -> JSONValue? { d.host.book(Self.book)?["prefs"]?["categories"] }

    /// 서버의 레코드 payload (그룹 키로 푼 것)
    private func serverPayload(_ server: FakeSyncServer, _ d: Dev, _ key: String) async throws -> JSONValue? {
        let creds = await d.storage.meta!["creds"]!
        let keys = try GroupKeys(base64: creds["key"]!.stringValue!)
        guard let r = server.recordCiphertext(gid: creds["gid"]!.stringValue!, rid: keys.rid(key)) else { return nil }
        return try keys.decryptRecord(rid: keys.rid(key), ct: r.ct)
    }

    private func serverCats(_ server: FakeSyncServer, _ d: Dev) async throws -> JSONValue? {
        guard let p = try await serverPayload(server, d, RecordKeys.prefs(Self.book)) else { return nil }
        return Records.materialize(RecordKeys.parse(RecordKeys.prefs(Self.book))!, try CRDT.parseState(p["s"]))?["categories"]
    }

    /// 예전 엔진처럼 서버에 v 1 로 쓴다 (그 상태 그대로)
    private func writeV1(_ server: FakeSyncServer, _ d: Dev, _ key: String, _ state: RecState) async throws {
        let creds = await d.storage.meta!["creds"]!
        let keys = try GroupKeys(base64: creds["key"]!.stringValue!)
        let gid = creds["gid"]!.stringValue!
        let rid = keys.rid(key)
        let ct = keys.encryptRecord(rid: rid, payload: ["v": 1, "k": .string(key), "s": CRDT.toJSON(state)])
        let r = try await server.transport().putRecord(Auth(gid: gid, token: creds["token"]!.stringValue!),
                                                        RecordWrite(rid: rid, baseSeq: server.recordCiphertext(gid: gid, rid: rid)?.seq ?? 0, ct: ct))
        guard case .ok = r else { return XCTFail("\(r)") }
    }

    /// 예전 엔진이 받은 책을 만들 때 올린 모양: 기본 형광펜 0–6 이 모두 진짜 도장 (그룹 값보다 나중), 순서 목록도
    private static func legacyDefaults(node: String = "bea2000000000000", t: Int64) -> RecState {
        var st = RecState()
        var c: [String: ItemState] = [:]
        for (i, cat) in PlannerModel.defaultCategories.enumerated() {
            let s = String(format: "%012llx%04llx", t, Int64(i)) + node
            c[JS.string(cat["id"])] = ItemState(a: s, f: ["name": FieldEntry(cat["name"]!, s), "hex": FieldEntry(cat["hex"]!, s), "counts": FieldEntry(cat["counts"]!, s)])
        }
        st.c["categories"] = c
        st.f["o:categories"] = FieldEntry(.array(PlannerModel.defaultCategories.map { .string(JS.string($0["id"])) }), String(format: "%012llx%04llx", t, Int64(99)) + node)
        return st
    }

    func testPrefsAreWrittenAsV2AndOtherRecordsAsV1() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let p = try await serverPayload(server, mac, RecordKeys.prefs(Self.book))
        let b = try await serverPayload(server, mac, RecordKeys.book(Self.book))
        let d = try await serverPayload(server, mac, RecordKeys.day(Self.book, DefaultFillTests.d1))
        XCTAssertEqual(p?["v"], 2)
        XCTAssertEqual(b?["v"], 1)
        XCTAssertEqual(d?["v"], 1)
    }

    func testPrefsDraftsAreV2AndOldPrefsDraftsAreDropped() throws {
        let keys = try GroupKeys(key: [UInt8](repeating: 7, count: 32))
        let q = "0199a29fb68000010123456789abcdef", g = "Xq3v9yQ0a1B2c3D4e5F6g7", f = "Hk2m4n6p8r0t2v4x6z8B0D"
        var s = RecState()
        s.f["mottoText"] = FieldEntry("글", q)
        let pk = RecordKeys.prefs(Self.book)
        XCTAssertEqual(try keys.openDraft(keys.sealDraft(key: pk, state: s, gid: g, from: f, q: q)!, gid: g, from: f, q: q).key, pk)
        // 예전 엔진의 책 설정 초안 (v 1) — 손으로 봉인
        let old: JSONValue = ["v": 1, "k": .string(pk), "s": CRDT.toJSON(s)]
        var plain = old.canonicalBytes
        plain.append(contentsOf: repeatElement(0x20, count: 256 - plain.count))
        let sealed = Base64URL.encode(SyncCrypto.seal(key: keys.liveKey, plain: plain, ad: Draft.ad(gid: g, from: f, q: q), nonce: nil))
        XCTAssertThrowsError(try keys.openDraft(sealed, gid: g, from: f, q: q))
        let dk = RecordKeys.day(Self.book, DefaultFillTests.d1)
        XCTAssertEqual(try keys.openDraft(keys.sealDraft(key: dk, state: s, gid: g, from: f, q: q)!, gid: g, from: f, q: q).key, dk)
    }

    /// 예전 엔진이 v 1 로 쓴 책 설정을 받으면 같은 상태를 v 2 로 다시 올린다 → 예전 엔진은 더는 그 책 설정을 읽지도 덮지도 못한다
    func testAPrefsRecordWrittenAsV1IsRewrittenAsV2() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let state = try CRDT.parseState(try await serverPayload(server, mac, RecordKeys.prefs(Self.book))?["s"])
        try await writeV1(server, mac, RecordKeys.prefs(Self.book), state)
        let before = try await serverPayload(server, mac, RecordKeys.prefs(Self.book))
        XCTAssertEqual(before?["v"], 1)
        let phone = try await fresh(server, mac)
        try await syncAll(phone, mac)
        let after = try await serverPayload(server, mac, RecordKeys.prefs(Self.book))
        let sc = try await serverCats(server, mac)
        XCTAssertEqual(after?["v"], 2)
        XCTAssertEqual(sc, Self.ownerCats)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
    }

    /// 같은 책의 옛 사본(형광펜 6 의 이름 · 0 의 색을 고쳐 둠, 또는 6 이 없음)을 가진 기기가 합류해도 그룹을 만든 기기의 값이 이긴다
    func testAStaleCopyOfTheSameBookDoesNotBeatTheCreator() async throws {
        for copyCats in [
            DefaultFillTests.renamed(DefaultFillTests.renamed(Self.defaults, 6, "name", "옛 이름"), 0, "hex", "000000"),
            .array(DefaultFillTests.renamed(Self.defaults, 2, "name", "x").arrayValue!.filter { $0["id"] != 6 }),
        ] {
            let server = FakeSyncServer()
            let mac = try await owner(server)
            let other = await device(server, platform: "iPad", ip: "10.0.0.3")
            other.host.library = ["books": [DefaultFillTests.info], "activeID": .string(Self.book), "sampleSeeded": true]
            other.host.setBook(Self.book, DefaultFillTests.withCats(PlannerModel.emptyPlannerData(), copyCats))
            try await other.engine.initialize()
            try await pairQr(mac, other)
            try await syncAll(other, mac)
            XCTAssertEqual(cats(mac), Self.ownerCats)
            XCTAssertEqual(cats(other), Self.ownerCats)
        }
    }

    /// 예전 엔진의 저장소(pv 없음 · 건너뛴 레코드)로 켬: 처음부터 다시 받고, 막힌 동안 쌓인 책 설정(기본 형광펜 — 진짜 도장)은 버린다
    func testUpgradingFromALegacyStorageDiscardsItsUnsentPrefsAndRepulls() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let storage = MemorySyncStorage()
        let phone = try await fresh(server, mac, storage: storage)
        try await syncAll(phone, mac)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        await phone.engine.stop()
        // 예전 엔진의 모양으로: 메타에 pv 없음 · skippedBelow 1, 책 설정은 기본 형광펜(나중 도장)을 보내지 못한 채 · 서버 순번은 409 에서 적은 것
        var meta = await storage.meta!.objectValue!
        meta["pv"] = nil
        meta["skippedBelow"] = 1
        var rec = await storage.records[RecordKeys.prefs(Self.book)]!.objectValue!
        rec["state"] = CRDT.toJSON(Self.legacyDefaults(t: Int64(Date().timeIntervalSince1970 * 1000) + 60_000))
        rec["dirty"] = true
        try await storage.write(StorageBatch(meta: .object(meta), put: [(RecordKeys.prefs(Self.book), .object(rec))]))
        phone.host.edit(Self.book) { DefaultFillTests.withCats($0, Self.defaults) }   // 예전 앱이 보던 기본 형광펜
        let up = await device(server, storage: storage, host: phone.host, platform: "iPhone", ip: "10.0.0.2")
        try await up.engine.initialize()
        try await syncAll(up, mac)
        try await syncAll(up, mac)
        let sc = try await serverCats(server, mac)
        let sp = try await serverPayload(server, mac, RecordKeys.prefs(Self.book))
        let pv = await storage.meta?["pv"]
        XCTAssertEqual(cats(up), Self.ownerCats)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        XCTAssertEqual(sc, Self.ownerCats)
        XCTAssertEqual(sp?["v"], 2)
        XCTAssertEqual(pv, 2)
    }

    /// 기본값 도장으로만 더한 항목은 진짜 순서 목록에 없으면 보이지 않는다 (예전 엔진이 만든 그룹: 지운 5 의 지움 표시 없음).
    /// 기본 형광펜을 보던 기기가 더하거나 순서를 바꿔도 그 순서는 기본값 도장 — 그룹의 진짜 순서를 이기지 않는다
    func testDefaultStampedItemsOutsideTheRealOrderAreHidden() {
        let pk = RecordKeys.parse(RecordKeys.prefs(Self.book))!
        var st = RecState()
        var c: [String: ItemState] = [:]
        for (i, cat) in Self.ownerCats.arrayValue!.enumerated() {
            let s = String(format: "0000019a0000%04llx00000000000000a1", Int64(i + 1))
            c[JS.string(cat["id"])] = ItemState(a: s, f: ["name": FieldEntry(cat["name"]!, s), "hex": FieldEntry(cat["hex"]!, s), "counts": FieldEntry(cat["counts"]!, s)])
        }
        st.c["categories"] = c
        st.f["o:categories"] = FieldEntry(.array(Self.ownerCats.arrayValue!.map { .string(JS.string($0["id"])) }), "0000019a0000002000000000000000a1")
        var cur = PlannerModel.defaultPrefs()
        cur["categories"] = .array(PlannerModel.defaultCategories + [["id": 9, "name": "새", "hex": "123456", "counts": true]])
        let delta = Records.diff(.prefs, prev: Records.flattenPrefs(.object(PlannerModel.defaultPrefs())), cur: Records.flattenPrefs(.object(cur)),
                                 clock: ZeroClock(node: "00000000000000b2"), base: st)
        XCTAssertEqual(delta.c["categories"]?["5"]?.a, Stamps.defaultStamp)
        XCTAssertEqual(delta.f["o:categories"]?.stamp, Stamps.defaultStamp)
        _ = CRDT.mergeInto(&st, delta)
        let shown = Records.materialize(pk, st)?["categories"]?.arrayValue ?? []
        XCTAssertEqual(shown.map { $0["id"] }, [0, 1, 2, 3, 4, 6, 7, 9])
        XCTAssertEqual(shown.first?["name"], "개발 업무")
        // 순서 목록이 없으면 (아무도 목록을 정하지 않음) 기본값 도장 항목도 보인다
        var none = RecState()
        var c0 = PlannerModel.defaultPrefs()
        c0["categories"] = DefaultFillTests.renamed(Self.defaults, 0, "name", "X")
        _ = CRDT.mergeInto(&none, Records.diff(.prefs, prev: Records.flattenPrefs(.object(PlannerModel.defaultPrefs())), cur: Records.flattenPrefs(.object(c0)),
                                               clock: ZeroClock(node: "00000000000000b2"), base: none))
        XCTAssertEqual(Records.materialize(pk, none)?["categories"]?.arrayValue?.map { $0["id"] }, [0, 1, 2, 3, 4, 5, 6])
    }

    /// 사고가 난 그룹 (예전 iPhone 이 받은 책을 만들며 기본 형광펜 0–6 을 나중 도장 · v 1 로 올림): 고친 앱에서 Mac 의 형광펜을
    /// 백업대로 되돌리면 모든 기기 · 서버에 가고, 5 는 지움 표시라 나중에 합류한 기기에서도 살아나지 않는다
    func testRepairingTheIncidentGroupWithFixedApps() async throws {
        let server = FakeSyncServer()
        let mac = try await owner(server)
        let phone = try await fresh(server, mac)
        try await syncAll(phone, mac)
        // 사고: 예전 iPhone 의 기본 형광펜 (그룹 값보다 나중 도장) 을 v 1 로 덮어씀 — 7 '비 계획' 은 Mac 의 것이 남는다
        var st = try CRDT.parseState(try await serverPayload(server, mac, RecordKeys.prefs(Self.book))?["s"])
        _ = CRDT.mergeInto(&st, Self.legacyDefaults(t: Int64(Date().timeIntervalSince1970 * 1000) + 1_000))
        try await writeV1(server, mac, RecordKeys.prefs(Self.book), st)
        try await syncAll(mac, phone)
        XCTAssertEqual(cats(mac), Self.incident)
        XCTAssertEqual(cats(phone), Self.incident)
        // 되돌리기: Mac 에서 백업의 형광펜으로 (설정 창 · 또는 앱을 끈 채 책 파일의 prefs.categories — 같은 비교)
        mac.host.edit(Self.book) { DefaultFillTests.withCats($0, Self.ownerCats) }
        try await syncAll(mac, phone)
        try await syncAll(mac, phone)
        let sc = try await serverCats(server, mac)
        XCTAssertEqual(cats(mac), Self.ownerCats)
        XCTAssertEqual(cats(phone), Self.ownerCats)
        XCTAssertEqual(sc, Self.ownerCats)
        let p = try await serverPayload(server, mac, RecordKeys.prefs(Self.book))
        XCTAssertEqual(p?["v"], 2)
        XCTAssertNotNil(p?["s"]?["c"]?["categories"]?["5"]?["d"], "5 는 지움 표시")
        let later = try await fresh(server, mac, ip: "10.0.0.9")
        try await syncAll(later, mac, phone)
        XCTAssertEqual(cats(later), Self.ownerCats)
    }
}
