// 코드 · UUIDv5 · HLC · 바이트 · JSON(JS 규칙) · 날짜 · 암호
import XCTest
@testable import SpiraldaySync

final class CodesTests: XCTestCase {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    func testPairingCodeShapeAndLenientReading() {
        for _ in 0..<50 {
            let c = Codes.newPairingCode()
            XCTAssertNotNil(c.range(of: "^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$", options: .regularExpression), c)
            XCTAssertEqual(Codes.canonicalPairingCode(c.lowercased()), c.replacingOccurrences(of: "-", with: ""))
        }
        XCTAssertEqual(Codes.canonicalPairingCode("o1il-abcd"), "0111ABCD")
        XCTAssertNil(Codes.canonicalPairingCode("ABCD-EFG"))
        XCTAssertNil(Codes.canonicalPairingCode("ABCD-EFGU"))
        XCTAssertEqual(Codes.canonicalPairingCode("AB\u{2013}CD EF\u{2014}GH"), "ABCDEFGH")
    }

    func testRecoveryCodeCatchesSingleErrorsAndAdjacentSwaps() {
        for _ in 0..<30 {
            let c = Codes.newRecoveryCode()
            XCTAssertNotNil(c.range(of: "^([0-9A-HJKMNP-TV-Z]{5}-){4}[0-9A-HJKMNP-TV-Z]{5}$", options: .regularExpression), c)
            XCTAssertEqual(Codes.checkRecoveryCode(c), .ok)
            XCTAssertEqual(Codes.canonicalRecoveryCode(c.lowercased().replacingOccurrences(of: "-", with: " ")), c.replacingOccurrences(of: "-", with: ""))
            XCTAssertEqual(Codes.formatRecoveryCode(c.replacingOccurrences(of: "-", with: "")), c)
            let raw = Array(c.replacingOccurrences(of: "-", with: ""))
            for p in 0..<25 {
                for ch in alphabet where ch != raw[p] {
                    var bad = raw
                    bad[p] = ch
                    XCTAssertEqual(Codes.checkRecoveryCode(String(bad)), .checksum)
                }
                if p < 24, raw[p] != raw[p + 1] {
                    var sw = raw
                    sw.swapAt(p, p + 1)
                    XCTAssertEqual(Codes.checkRecoveryCode(String(sw)), .checksum)
                }
            }
        }
        XCTAssertEqual(Codes.checkRecoveryCode("ABC"), .short)
        XCTAssertEqual(Codes.checkRecoveryCode(String(repeating: "U", count: 25)), .invalidChar)
        XCTAssertEqual(Codes.checkRecoveryCode(String(repeating: "0", count: 26)), .long)
    }

    func testUUIDv5() {
        // DNS 이름공간 + "www.example.com" (RFC 9562 부록)
        XCTAssertEqual(CarryID.uuidV5(namespace: "6ba7b810-9dad-11d1-80b4-00c04fd430c8", name: "www.example.com"), "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
        let a = CarryID.carryTaskId("E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        XCTAssertEqual(a, CarryID.carryTaskId("e621e1f8-c36c-495a-93fc-0c247a3e6e5f"))
        // Python: uuid.uuid5(uuid.UUID('E621E1F8-…'), 'carry')
        XCTAssertEqual(a, "F0D88FE3-AC08-5FA8-B047-DA3B2BA83191")
        XCTAssertNotEqual(CarryID.carryTaskId(a!), a)
        XCTAssertNil(CarryID.carryTaskId("not-a-uuid"))
        XCTAssertEqual(CarryID.carryTaskId(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!).uuidString, "0D594A5F-8FD8-50CA-803B-6260FFD0478F")
    }
}

final class HLCTests: XCTestCase {
    final class Wall: @unchecked Sendable { var t: Int64 = 1000 }

    func testMonotonicAndAboveObserved() {
        let w = Wall()
        let h = HLC(node: "aaaaaaaaaaaaaaaa", wall: { w.t })
        let a = h.next()
        let b = h.next()
        XCTAssertTrue(JS.less(a, b))
        h.observe(Stamps.make(t: 5000, c: 7, node: "bbbbbbbbbbbbbbbb"))
        let c = h.next()
        XCTAssertTrue(JS.less(Stamps.make(t: 5000, c: 7, node: "bbbbbbbbbbbbbbbb"), c))
        XCTAssertEqual(Stamps.parse(c)!.t, 5000)
        XCTAssertEqual(Stamps.parse(c)!.c, 8)
        w.t = 9000
        XCTAssertEqual(Stamps.parse(h.next())!.t, 9000)
    }

    func testCounterOverflowBumpsTime() {
        let h = HLC(node: "aaaaaaaaaaaaaaaa", last: Stamps.make(t: 10, c: 0xFFFF, node: "bbbbbbbbbbbbbbbb"), wall: { 0 })
        let p = Stamps.parse(h.next())!
        XCTAssertEqual(p.t, 11)
        XCTAssertEqual(p.c, 0)
    }

    func testZeroClockBelowRealClock() {
        let z = ZeroClock(node: "aaaaaaaaaaaaaaaa")
        let h = HLC(node: "aaaaaaaaaaaaaaaa", wall: { 1_700_000_000_000 })
        var prev = ""
        for _ in 0..<70_000 {
            let s = z.next()
            XCTAssertTrue(JS.less(prev, s))
            prev = s
        }
        XCTAssertTrue(JS.less(prev, h.next()))
    }

    func testStampFormatMatchesTS() {
        XCTAssertEqual(Stamps.make(t: 1_759_370_000_000, c: 3, node: "0123456789abcdef"), "0199a29fb68000030123456789abcdef")
    }
}

final class JSONTests: XCTestCase {
    func testBase64URLRoundTripAndCanonicalOnly() {
        var rng = Rng(42)
        for n in 0..<120 {
            let b = (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let s = Base64URL.encode(b)
            XCTAssertEqual(Base64URL.decode(s), b)
            XCTAssertEqual(s, Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
        }
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("AB=="))
        XCTAssertNil(Base64URL.decode("AB")) // 남는 비트가 0 이 아님 (정규형 아님)
        XCTAssertEqual(Base64URL.decode("AA"), [0])
    }

    func testCanonicalSortsKeysLikeJS() throws {
        let v = try JSONValue.parse(#"{"b":1,"a":[1,{"d":2,"c":null}]}"#)
        XCTAssertEqual(v.canonical, #"{"a":[1,{"c":null,"d":2}],"b":1}"#)
        // UTF-16 순서: U+1F600 (서로게이트 D83D) 이 U+FFFF 보다 앞
        let o: JSONValue = ["\u{FFFF}": 1, "\u{1F600}": 2, "é": 3, "a": 4]
        XCTAssertEqual(o.canonical, "{\"a\":4,\"é\":3,\"\u{1F600}\":2,\"\u{FFFF}\":1}")
    }

    func testJSStringEscapes() {
        XCTAssertEqual(JSONValue.string("\u{2028}\u{0007}\u{001f}/é\"\\\n").canonical, "\"\u{2028}\\u0007\\u001f/é\\\"\\\\\\n\"")
    }

    func testNumbersLikeJS() {
        let cases: [(Double, String)] = [
            (1e21, "1e+21"), (1e20, "100000000000000000000"), (0.000001, "0.000001"), (1e-7, "1e-7"), (123.456, "123.456"),
            (-0.0, "0"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (0.1 + 0.2, "0.30000000000000004"),
            (-1.5, "-1.5"), (42, "42"), (-7, "-7"), (Double("9007199254740993")!, "9007199254740992"), (1.5e300, "1.5e+300"), (123e-20, "1.23e-18"),
        ]
        for (d, s) in cases { XCTAssertEqual(JS.numberString(d), s, "\(d)") }
    }

    func testParserLikeJSONParse() throws {
        XCTAssertEqual(try JSONValue.parse(#"{"a":1,"a":2}"#), ["a": 2])
        XCTAssertEqual(try JSONValue.parse(#""😀""#), .string("\u{1F600}"))
        XCTAssertEqual(try JSONValue.parse(#""\ud83d x""#), .string("\u{FFFD} x"))
        XCTAssertEqual(try JSONValue.parse(" [1.0, -0, 2e3] "), [1, 0, 2000])
        XCTAssertThrowsError(try JSONValue.parse("[1,]"))
        XCTAssertThrowsError(try JSONValue.parse("01"))
        XCTAssertThrowsError(try JSONValue.parse("\"a\u{0001}\""))
        XCTAssertThrowsError(try JSONValue.parse(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)))
        // 정규화(NFC/NFD)가 다른 글은 다른 값 (JS === 와 같게)
        XCTAssertNotEqual(JSONValue.string("\u{E9}"), JSONValue.string("e\u{301}"))
    }

    func testISODatesLikeV8() {
        let cases: [(String, String?)] = [
            ("2026-10-01T15:00:00Z", "2026-10-01T15:00:00Z"),
            ("2026-13-45T99:99:99Z", nil), // 앱이 읽지 못하는 날짜는 내보내지 않는다 (TS 는 그대로 둔다)
            ("2026-02-30T00:00:00Z", "2026-02-30T00:00:00Z"), // 이미 그 모양이고 V8 · Swift 가 읽는 값이면 그대로
            ("2026-10-01T24:00:00Z", "2026-10-01T24:00:00Z"),
            ("2026-02-30T00:00:00.000Z", "2026-03-02T00:00:00Z"),
            ("2026-10-01T24:00:00+00:00", "2026-10-02T00:00:00Z"),
            ("2026-10-01T15:00:00.123456Z", "2026-10-01T15:00:00Z"),
            ("2026-10-01T15:00:00+0900", "2026-10-01T06:00:00Z"),
            ("2026-10-01T15:00:00+09:00", "2026-10-01T06:00:00Z"),
            ("2026-10-01T15:00:00-00:30", "2026-10-01T15:30:00Z"),
            ("2026-10-01T15:00:00+23:59", "2026-09-30T15:01:00Z"),
            ("0000-01-01T00:00:00+01:00", nil), // TS: -000001-12-31T23:00:00Z (앱이 읽지 못한다)
            ("9999-12-31T23:00:00-02:00", nil), // TS: +010000-01-01T01:00:00Z
            ("0000-01-01T01:00:00+01:00", "0000-01-01T00:00:00Z"),
            ("2026-13-01T00:00:00.0Z", nil), ("2026-10-01T25:00:00+00:00", nil), ("2026-10-01T15:60:00.0Z", nil),
            ("2026-10-32T00:00:00.0Z", nil), ("2026-10-01T15:00:00+24:00", nil), ("2026-10-01T24:00:01.0Z", nil),
            ("2026-10-01T15:00:00.Z", nil), ("2026-10-01", nil), ("x", nil),
        ]
        for (s, want) in cases { XCTAssertEqual(ISODate.normalize(.string(s)), want, s) }
        XCTAssertNil(ISODate.normalize(.number(1)))
        XCTAssertEqual(ISODate.format(-500), "1969-12-31T23:59:59Z")
        // 내보내는 날짜는 앱의 JSONDecoder(.iso8601) 가 늘 읽는다
        struct W: Decodable { let d: Date }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for (s, _) in cases {
            guard let n = ISODate.normalize(.string(s)) else { continue }
            XCTAssertNoThrow(try dec.decode(W.self, from: Data("{\"d\":\"\(n)\"}".utf8)), n)
        }
    }
}

final class CryptoTests: XCTestCase {
    func testRidDeterministicAndOpaque() {
        let k = GroupKeys.generate()
        XCTAssertEqual(k.rid("d/X/2026-10-02"), k.rid("d/X/2026-10-02"))
        XCTAssertEqual(k.rid("d/X/2026-10-02").utf8.count, 43)
        XCTAssertNotEqual(k.rid("d/X/2026-10-02"), GroupKeys.generate().rid("d/X/2026-10-02"))
    }

    func testRecordEncryptionRoundTripAndTamper() throws {
        let k = GroupKeys.generate()
        let rid = k.rid("w/A/2026-09-28")
        let payload: JSONValue = ["v": 1, "k": "w/A/2026-09-28", "s": ["f": ["goal": ["한 주 목표", "x"]], "c": [:]]]
        let ct = k.encryptRecord(rid: rid, payload: payload)
        XCTAssertEqual(try k.decryptRecord(rid: rid, ct: ct), payload)
        XCTAssertThrowsError(try k.decryptRecord(rid: k.rid("other"), ct: ct))
        XCTAssertThrowsError(try GroupKeys.generate().decryptRecord(rid: rid, ct: ct))
        var raw = Base64URL.decode(ct)!
        XCTAssertEqual(raw[0], 1)
        XCTAssertGreaterThanOrEqual(raw.count, 41)
        raw[30] ^= 1
        XCTAssertThrowsError(try k.decryptRecord(rid: rid, ct: Base64URL.encode(raw)))
    }

    /// TS 엔진이 만든 암호문을 푼다 (같은 키 · 같은 rid)
    func testDecryptsTypeScriptCiphertext() throws {
        let keys = try GroupKeys(key: (0..<32).map { UInt8($0) })
        let rid = keys.rid("d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02")
        let ct = TSFixtures.recordCiphertext
        let v = try keys.decryptRecord(rid: rid, ct: ct)
        XCTAssertEqual(v.canonical, TSFixtures.recordPlain)
        let st = try CRDT.parseState(v["s"])
        XCTAssertEqual(Records.buildDay(st)?["comment"], "비밀 일기 ✍️")
        // 같은 앱 값 · 같은 0 시계 → TS 와 같은 도장 (비교 순서가 같다)
        var slots = [JSONValue](repeating: -1, count: 144)
        for i in 0..<6 { slots[i] = 3 }
        let day: JSONValue = [
            "tasks": [["id": "AAAAAAAA-0000-4000-8000-000000000001", "text": "회의 😀", "mark": 1, "cat": 2, "row": 0]],
            "slots": .array(slots), "comment": "비밀 일기 ✍️", "memoTags": ["", "", ""], "memos": ["메모", "", ""], "notes": [], "ddays": [],
            "dayOff": false, "theme": 4, "weird": ["a": [1.5, .null]],
        ]
        var mine = RecState()
        CRDT.mergeInto(&mine, Records.diff(.day, prev: nil, cur: Records.flattenDay(day), clock: ZeroClock(node: "0123456789abcdef")))
        XCTAssertEqual(CRDT.toJSON(mine).canonical, CRDT.toJSON(st).canonical)
        // Swift 가 만든 암호문도 같은 평문으로 풀린다
        let back = try keys.decryptRecord(rid: rid, ct: keys.encryptRecord(rid: rid, payload: v))
        XCTAssertEqual(back.canonical, TSFixtures.recordPlain)
    }

    func testDeviceNameBoundToDeviceId() {
        let k = GroupKeys.generate()
        let id = String(repeating: "D", count: 22)
        let n = k.encryptName("부엌 iPad", deviceId: id)
        XCTAssertTrue(n.hasPrefix("e1."))
        XCTAssertLessThanOrEqual(n.count, 256)
        XCTAssertEqual(k.decryptName(n, deviceId: id), "부엌 iPad")
        XCTAssertNil(GroupKeys.generate().decryptName(n, deviceId: id))
        XCTAssertNil(k.decryptName(n, deviceId: String(repeating: "E", count: 22)))
        XCTAssertNil(k.decryptName("p.iPad", deviceId: id))
        XCTAssertEqual(k.decryptName(k.encryptName(String(repeating: "가", count: 200), deviceId: id), deviceId: id)?.count, 40)
        // 이모지(서로게이트 쌍)를 반으로 자르면 JS 처럼 U+FFFD
        let cut = k.decryptName(k.encryptName(String(repeating: "a", count: 118) + "😀", deviceId: id), deviceId: id)!
        XCTAssertEqual(cut, String(repeating: "a", count: 118))
    }

    func testPairingQrAndCode() throws {
        let k = GroupKeys.generate()
        let q = Pairing.newQrSecret()
        guard case let .qr(secret)? = Pairing.parseInput("https://spiralday.com/pair#\(q.text)") else { return XCTFail("QR 을 읽지 못함") }
        let p1 = try PairingSecret.fromQrSecret(q.secret)
        let w = p1.wrap(k, gid: String(repeating: "G", count: 22))
        XCTAssertEqual(try PairingSecret.fromQrSecret(secret).unwrap(w, gid: String(repeating: "G", count: 22)).key, k.key)
        XCTAssertThrowsError(try p1.unwrap(w, gid: String(repeating: "H", count: 22)))
        let code = Codes.newPairingCode()
        let pc = try PairingSecret.fromCode(code)
        XCTAssertEqual(pc.codeHash.utf8.count, 43)
        XCTAssertEqual(try PairingSecret.fromCode(code.lowercased()).codeHash, pc.codeHash)
        XCTAssertEqual(try PairingSecret.fromCode(code).unwrap(pc.wrap(k, gid: "G"), gid: "G").key, k.key)
        XCTAssertEqual(Pairing.parseInput(code), .code(code.replacingOccurrences(of: "-", with: "")))
        XCTAssertNil(Pairing.parseInput("nope"))
        XCTAssertNil(Pairing.parseInput(Pairing.qrPrefix + "short"))
    }

    func testConfirmDigitsFromSeedPerRequest() throws {
        let q = Pairing.newQrSecret()
        let a = try PairingSecret.fromQrSecret(q.secret)
        let b = try PairingSecret.fromQrSecret(q.secret)
        let g = String(repeating: "G", count: 22), p = String(repeating: "P", count: 22), d = String(repeating: "D", count: 22)
        let nonce = Pairing.newNonce()
        let x = a.confirmDigits(gid: g, pairingId: p, deviceId: d, nonce: nonce)
        XCTAssertEqual(x.count, 4)
        XCTAssertTrue(x.allSatisfy(\.isNumber))
        XCTAssertEqual(b.confirmDigits(gid: g, pairingId: p, deviceId: d, nonce: nonce), x)
        XCTAssertNotEqual(Base64URL.encode(a.confirmKey), a.codeHash)
        XCTAssertNotEqual(a.confirmKey, a.wrapKey)
        func same(_ f: () throws -> String) rethrows -> Int { try (0..<50).filter { _ in try f() == x }.count }
        XCTAssertLessThan(try same { try PairingSecret.fromQrSecret(Pairing.newQrSecret().secret).confirmDigits(gid: g, pairingId: p, deviceId: d, nonce: nonce) }, 3)
        XCTAssertLessThan(same { a.confirmDigits(gid: g, pairingId: p, deviceId: d, nonce: Pairing.newNonce()) }, 3)
        XCTAssertLessThan(same { a.confirmDigits(gid: g, pairingId: p, deviceId: Pairing.newNonce(), nonce: nonce) }, 3)
        XCTAssertLessThan(same { a.confirmDigits(gid: Pairing.newNonce(), pairingId: p, deviceId: d, nonce: nonce) }, 3)
        XCTAssertEqual(Pairing.newNonce().utf8.count, 22)
    }

    func testRecovery() throws {
        let k = GroupKeys.generate()
        let code = Codes.newRecoveryCode()
        let r = try RecoverySecret.fromCode(code)
        XCTAssertEqual(r.recoveryId.utf8.count, 43)
        XCTAssertEqual(try RecoverySecret.fromCode(code.lowercased()).recoveryId, r.recoveryId)
        XCTAssertEqual(try RecoverySecret.fromCode(code).unwrap(r.wrap(k, gid: "G"), gid: "G").key, k.key)
        let last = code.last!
        XCTAssertThrowsError(try RecoverySecret.fromCode(String(code.dropLast()) + (last == "0" ? "1" : "0")))
    }
}

final class HardeningTests: XCTestCase {
    let keys = try! GroupKeys(key: [UInt8](repeating: 7, count: 32))
    lazy var rid = keys.rid("d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02")
    lazy var enc = SyncCrypto.kdf(keys.key, id: 1, ctx: "SpSync01")
    func sealRaw(_ plain: [UInt8]) -> String { Base64URL.encode(SyncCrypto.seal(key: enc, plain: plain, ad: Array(rid.utf8))) }

    func testCategoryIdReuseKeepsAppOrder() {
        final class T: @unchecked Sendable { var t: Int64 = 1000 }
        let tb = T()
        let clock = HLC(node: "00000000000000a1", wall: {
            tb.t += 1
            return tb.t
        })
        var st = RecState()
        func step(_ prev: [String: JSONValue]?, _ cur: [String: JSONValue]) {
            CRDT.mergeInto(&st, Records.diff(.prefs, prev: prev.map { Records.flattenPrefs(.object($0)) }, cur: Records.flattenPrefs(.object(cur)), clock: clock))
        }
        let p0 = PlannerModel.defaultPrefs() // 0..6
        step(nil, p0)
        var cats = p0["categories"]!.arrayValue!
        // 1 을 맨 뒤로 → 순서 목록 [0,2,3,4,5,6,1]
        let one = cats.remove(at: 1)
        cats.append(one)
        var p1 = p0
        p1["categories"] = .array(cats)
        step(p0, p1)
        // 6 을 지운다
        var p2 = p1
        cats.removeAll { $0["id"] == 6 }
        p2["categories"] = .array(cats)
        step(p1, p2)
        // 새 형광펜: id = 가장 큰 id + 1 = 6, 맨 뒤에
        var p3 = p2
        cats.append(["id": 6, "name": "새 형광펜", "hex": "B9E4A8", "counts": true])
        p3["categories"] = .array(cats)
        step(p2, p3)
        let built = Records.buildPrefs(st)["categories"]!.arrayValue!
        XCTAssertEqual(built.map { $0["id"]! }, cats.map { $0["id"]! })
        XCTAssertEqual(built.last?["name"], "새 형광펜")
    }

    func testDecompressionBombIsRefused() throws {
        let bomb = try Gzip.compress([UInt8](repeating: 0, count: SyncCrypto.maxPlainBytes + 1024))
        XCTAssertLessThan(bomb.count, 200_000)
        XCTAssertThrowsError(try keys.decryptRecord(rid: rid, ct: sealRaw(bomb)))
    }

    func testLyingGzipSizeFails() throws {
        let plain: JSONValue = ["v": 1, "k": "x", "s": ["f": ["comment": [.string(String(repeating: "a", count: 5000)), .string(String(repeating: "0", count: 32))]], "c": [:]]]
        let gz = try Gzip.compress(plain.canonicalBytes)
        var lie = gz
        let n = lie.count
        lie[n - 4] = 10
        lie[n - 3] = 0
        lie[n - 2] = 0
        lie[n - 1] = 0
        XCTAssertThrowsError(try keys.decryptRecord(rid: rid, ct: sealRaw(lie)))
        XCTAssertEqual(try keys.decryptRecord(rid: rid, ct: sealRaw(gz))["k"], "x")
    }

    func testProtoKeysAreDropped() throws {
        let raw = try JSONValue.parse(#"{"f":{"__proto__":[{"theme":5},"000000000001000000000000000000a1"],"x:__proto__":[{"dayOff":true},"000000000001000000000000000000a1"],"comment":["hi","000000000001000000000000000000a1"]},"c":{"__proto__":{},"tasks":{"__proto__":{"a":"000000000001000000000000000000a1","f":{}}}}}"#)
        let st = try CRDT.parseState(raw)
        XCTAssertNil(st.f["__proto__"])
        XCTAssertNil(st.c["__proto__"])
        XCTAssertNil(st.c["tasks"]?["__proto__"])
        let day = Records.buildDay(st)!
        XCTAssertEqual(day["comment"], "hi")
        XCTAssertNil(day["theme"])
        XCTAssertNil(day["__proto__"])
        XCTAssertEqual(day["dayOff"], false)
    }

    // "앱이 읽지 못하는 값은 넣지 않는다" (TypeScript 엔진과 같은 기대값)
    func testExtrasNeverOverwriteKnownKeys() throws {
        let S = "000000000001000000000000000000a1"
        let st = try CRDT.parseState([
            "f": ["x:tasks": ["nope", .string(S)], "x:theme": ["x", .string(S)], "x:comment": [5, .string(S)], "comment": ["hi", .string(S)], "x:extra": [1, .string(S)]],
            "c": ["tasks": ["AAAAAAAA-0000-4000-8000-000000000001": ["a": .string(S), "f": ["text": ["t", .string(S)], "x:mark": ["m", .string(S)], "x:new": [true, .string(S)]]]]],
        ])
        let day = Records.buildDay(st)!
        XCTAssertEqual(day["tasks"]?.arrayValue?.count, 1)
        XCTAssertEqual(day["tasks"]?.arrayValue?[0]["mark"], 0)
        XCTAssertEqual(day["tasks"]?.arrayValue?[0]["new"], true)
        XCTAssertNil(day["theme"])
        XCTAssertEqual(day["comment"], "hi")
        XCTAssertEqual(day["extra"], 1)
    }

    func testBookDatesOnlyWhatTheAppCanRead() throws {
        let S = "000000000001000000000000000000a1"
        func book(_ start: String) throws -> JSONValue? {
            let st = try CRDT.parseState(["f": ["start": [.string(start), .string(S)], "created": ["2026-09-01T00:00:00Z", .string(S)]]])
            if case let .book(b)? = Records.buildBook("3F2504E0-4F89-11D3-9A0C-0305E82C3301", st) { return b }
            return nil
        }
        XCTAssertNil(try book("2026-13-45T99:99:99Z"))
        XCTAssertNil(try book("0000-01-01T00:00:00+01:00"))
        XCTAssertNil(try book("9999-12-31T23:00:00-02:00"))
        XCTAssertNil(try book("2026-10-01T24:00:01Z"))
        XCTAssertEqual(try book("2026-02-30T00:00:00Z")?["start"], "2026-02-30T00:00:00Z")
        XCTAssertEqual(try book("2026-10-01T15:00:00.5+09:00")?["start"], "2026-10-01T06:00:00Z")
        XCTAssertEqual(try book("0000-01-01T01:00:00+01:00")?["start"], "0000-01-01T00:00:00Z")
    }

    func testParseStateRejectsBadShapes() {
        XCTAssertThrowsError(try CRDT.parseState(.array([])))
        XCTAssertThrowsError(try CRDT.parseState(["f": .null]))
        XCTAssertThrowsError(try CRDT.parseState(["f": ["a": [1]]]))
        XCTAssertThrowsError(try CRDT.parseState(["f": ["a": [1, ""]]]))
        XCTAssertThrowsError(try CRDT.parseState(["f": ["a": [1, .string(String(repeating: "a", count: 65))]]]))
        XCTAssertThrowsError(try CRDT.parseState(["x": .null]))
        XCTAssertThrowsError(try CRDT.parseState(["c": ["tasks": ["X": ["a": "", "d": 3]]]]))
        XCTAssertNoThrow(try CRDT.parseState(["c": ["tasks": ["X": ["a": .null]]]]))
    }
}
