// 프로토콜 테스트 벡터 — TypeScript 엔진과 같은 바이트 (libsodium · HMAC 값은 독립 구현으로도 맞춰 봄)
import XCTest
@testable import SpiraldaySync

final class VectorsTests: XCTestCase {
    let K: [UInt8] = (0..<32).map { UInt8($0) }
    let NONCE: [UInt8] = (0..<24).map { UInt8(0x40 + $0) }
    let GID = "AAAAAAAAAAAAAAAAAAAAAA"
    let PID = "BBBBBBBBBBBBBBBBBBBBBB"
    let DEV = "CCCCCCCCCCCCCCCCCCCCCC"
    let NON = "DDDDDDDDDDDDDDDDDDDDDD"

    func testSubkeysRidSealDeviceName() throws {
        XCTAssertEqual(Hex.encode(SyncCrypto.kdf(K, id: 1, ctx: "SpSync01")), "4d37f03f0735137208d5868a25c2de93e84dfa9d2f97adf1317df9029820fde3")
        XCTAssertEqual(Hex.encode(SyncCrypto.kdf(K, id: 2, ctx: "SpSync01")), "7f0bbaa8398adf4a0543368b07ecd50926186c9f77173c56d715254966b81e6d")
        XCTAssertEqual(Hex.encode(SyncCrypto.kdf(K, id: 4, ctx: "SpSync01")), "63c5f93895687070a52b4f05ec5298505b48d63de985e837d247ceaea7c33fd9")
        let keys = try GroupKeys(key: K)
        let rid = keys.rid("d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02")
        XCTAssertEqual(rid, "sgHYur8_RbMqi2xJpcASGa_5l39tklkIl6Ce0Y_Bvek")
        let enc = SyncCrypto.kdf(K, id: 1, ctx: "SpSync01")
        let sealed = Base64URL.encode(SyncCrypto.seal(key: enc, plain: Array("hello".utf8), ad: Array(rid.utf8), nonce: NONCE))
        XCTAssertEqual(sealed, "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWVxVK08-R3oClDO50WGloEL5w0GH_9g")
        XCTAssertEqual(try SyncCrypto.open(key: enc, sealed: Base64URL.decode(sealed)!, ad: Array(rid.utf8)), Array("hello".utf8))
        let name = keys.encryptName("Mac", deviceId: DEV, nonce: NONCE)
        XCTAssertEqual(name, "e1.AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWVwLcA8ymdDMtVb903JuIe5Xm4Mc")
        XCTAssertEqual(keys.decryptName(name, deviceId: DEV), "Mac")
        XCTAssertNil(keys.decryptName(name, deviceId: "EEEEEEEEEEEEEEEEEEEEEE"))
    }

    func testPairingCodeAndQr() throws {
        XCTAssertEqual(Hex.encode(Pairing.salt), "922c67779db7a763e2d1cdbee67bb017")
        let p = try PairingSecret.fromCode("ABCD-EFGH")
        XCTAssertEqual(p.codeHash, "fuhrkiODLs51-clN0ssDqApAqcA9Yp0-mPDX0fs43b8")
        XCTAssertEqual(Hex.encode(p.wrapKey), "96b47ae740d6bf63583e6afbd2aa4013a7afdbecf642fc5c76fce79f45f0b34f")
        let wrapped = p.wrap(try GroupKeys(key: K), gid: GID, nonce: NONCE)
        XCTAssertEqual(wrapped, "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWV9OBe2VPPWZ_IMlrtAIcG-Dumc8ypyAt8a94NeEEnte96AihU_Zl-EMmGnqxYQBO9w")
        XCTAssertEqual(try p.unwrap(wrapped, gid: GID).key, K)
        XCTAssertEqual(Hex.encode(p.confirmKey), "6471ad5d0b44c0695328d5cc34ecc244d59ca216fb21fef0efe616316d3e2ea4")
        XCTAssertEqual(p.confirmDigits(gid: GID, pairingId: PID, deviceId: DEV, nonce: NON), "8301")

        let secret: [UInt8] = (0..<32).map { UInt8(0x20 + $0) }
        XCTAssertEqual(Pairing.qrPrefix + Base64URL.encode(secret), "SPIRALDAY-PAIR:1:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
        let q = try PairingSecret.fromQrSecret(secret)
        XCTAssertEqual(q.codeHash, "Xs2pXONmG3BV-SmMSp1Dj_TI2cA24t_71yFa-WIt3KM")
        XCTAssertEqual(Hex.encode(q.wrapKey), "0eae70027cd49f0a472a9d0d9985daa504f343f8b716a9390502a3d657a041c2")
        XCTAssertEqual(Hex.encode(q.confirmKey), "31f1e6685eda9ae7fb742483b85d85317a287fa6eeb76aa002158fc2e9a68b33")
        XCTAssertEqual(q.confirmDigits(gid: GID, pairingId: PID, deviceId: DEV, nonce: NON), "6754")
    }

    func testRecoveryCode() throws {
        XCTAssertEqual(Hex.encode(RecoverySecret.salt), "8a722939f50019b1bafeb76a1e636da9")
        let r = try RecoverySecret.fromCode("01234-56789-ABCDE-FGHJK-MNPYS")
        XCTAssertEqual(r.recoveryId, "g9EjOpLP1JbXBP1vcmwyYbBkZA3tSatN5tPv9hMzyvQ")
        XCTAssertEqual(r.auth, "dJEKJoNyEa4BPLyc3znAPXrT6fT7-ZZGfbJihKJ6Axs")
        XCTAssertEqual(r.authHash, "uRoUn0JxBOQEFjdH0GkjRKVH6VLoVv3YISQQwcqXzBU")
        XCTAssertEqual(Hex.encode(r.wrapKey), "57d53a06e50dcf02d4b3b23595d31a074acfed9e859a5fd6130f8f1a91838438")
        let wrapped = r.wrap(try GroupKeys(key: K), gid: GID, nonce: NONCE)
        XCTAssertEqual(wrapped, "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWVyFQqKY_DIcH-0c6rW-7sl-WgY_WEhTqDtmgOPloNh5jEjHBmWR9ZSXJxwaoF6vCkQ")
        XCTAssertEqual(try r.unwrap(r.wrap(try GroupKeys(key: K), gid: GID), gid: GID).key, K)
    }

    func testCarryTaskId() {
        XCTAssertEqual(CarryID.carryTaskId("3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "0D594A5F-8FD8-50CA-803B-6260FFD0478F")
    }

    // MARK: - 실시간 초안 (Docs/SpiraldaySync.md §7.6) — TypeScript 엔진과 같은 바이트

    let FROM = "CCCCCCCCCCCCCCCCCCCCCC"
    let KEY = "d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02"

    struct DraftVector {
        let name: String
        let q: String
        let s: JSONValue
        let json: String
        let draft: String
    }

    var draftVectors: [DraftVector] {
        [
            DraftVector(
                name: "① 메모(COMMENT) \"안녕\"", q: "0199a29fb68000010123456789abcdef",
                s: ["c": [:], "f": ["comment": ["안녕", "0199a29fb68000000123456789abcdef"]]],
                json: #"{"k":"d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02","s":{"c":{},"f":{"comment":["안녕","0199a29fb68000000123456789abcdef"]}},"v":1}"#,
                draft: "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWV5r548mIOXJwhGe1HeeJeEj-8bcdSk43ESPTX6NKGsN_vUao9aMexbnLU8m1xIFbRHzF8lcUza92RqvxDbI6ElFf3bzCsP2oxFGW1t-y3KJqQ4SyJ2NwRpqpSYW78NcE4Jnj4xO2H6jD8GPrevk8ZfUigpueEAAsdmdZRaSqibyaigZibRoeSkWP_fHOvS9thDnUa4vTWJtU8MGLV-XVuBNdPaQToEL6IY-f5WXjxeAkXUI9IFMa6hj88NUvO9m3Z3ndSQrSmgOz_wuYb8MN7v5puFGMx7y20wnIsf-JeX7SXJPwAgBQd5cM184FNa_EruNbsJbXP-lYk_Yf8eCq2NXyO7PHx2MBasD0QruRxeNU"),
            DraftVector(
                name: "② 할 일 글 (조합 중인 \"준\")", q: "0199a29fb68000030123456789abcdef",
                s: ["c": ["tasks": ["0D594A5F-8FD8-50CA-803B-6260FFD0478F": ["a": "", "f": ["text": ["회의 준", "0199a29fb68000020123456789abcdef"]]]]], "f": [:]],
                json: #"{"k":"d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02","s":{"c":{"tasks":{"0D594A5F-8FD8-50CA-803B-6260FFD0478F":{"a":"","f":{"text":["회의 준","0199a29fb68000020123456789abcdef"]}}}},"f":{}},"v":1}"#,
                draft: "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWV5r548mIOXJwhGe1HeeJeEj-8bcdSk43ESPTX6NKGsN_vUao9aMexbnLU8m1xIFbRHzF8lcUza92RqvxDbI6ElFf3byd6L69jRjPzsf_gYs6FMTRKH5_kkllmi0b4rhn_ZDq6TCpEPyX9h2dDvk4Yv1VkpLRB1c5dHwaC-WozuDD9Q96OUxKUiScbUticZLVhPVQy4nfWotF6djKRfyT-gVFLbQDsFDqMJ2M8XD10vg9HAB-ZBZc6GWhrYhyN9vxZWOGFFfemFWx5RrFb8MN7v5puFGMx7y20wnIsf-JeX7SXJPwAgBQd5cM184FNa_EruNbsJbXP-lYk_Yf8eCq2NX0AmwQEjRARjJJYS_KAsaV"),
            DraftVector(
                name: "③ 타임테이블 07시 줄", q: "0199a29fb68000050123456789abcdef",
                s: ["c": [:], "f": ["s07": [[3, 3, 3, -1, -1, -1], "0199a29fb68000040123456789abcdef"]]],
                json: #"{"k":"d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2026-10-02","s":{"c":{},"f":{"s07":[[3,3,3,-1,-1,-1],"0199a29fb68000040123456789abcdef"]}},"v":1}"#,
                draft: "AUBBQkNERUZHSElKS0xNTk9QUVJTVFVWV5r548mIOXJwhGe1HeeJeEj-8bcdSk43ESPTX6NKGsN_vUao9aMexbnLU8m1xIFbRHzF8lcUza92RqvxDbI6ElFf3bzCsP2oxFGW1s_thu01dqujMQt-mSMMkywD49cL4fX2-EK1H_fA9GK9KP80ZfUjgJyaFAQoemsOEP_3jbjbsx55Y2UVFVOc9vPUrHJthDnUa4vTWJtU8MGLV-XVuBNdPaQToEL6IY-f5WXjxeAkXUI9IFMa6hj88NUvO9m3Z3ndSQrSmgOz_wuYb8MN7v5puFGMx7y20wnIsf-JeX7SXJPwAgBQd5cM184FNa_EruNbsJbXP-lYk_Yf8eCq2NVmlE8gCsazqERPAI5WLErZ"),
        ]
    }

    func testLiveKeyIsSubkey5() {
        XCTAssertEqual(Hex.encode(SyncCrypto.kdf(K, id: 5, ctx: "SpSync01")), "648f97d5b65e4ba6fe7a7e47c09fdde808921dc15bf2c8e014cd29e828f1704e")
        XCTAssertEqual(Hex.encode(SyncCrypto.kdf(K, id: 1, ctx: "SpSync01")), "4d37f03f0735137208d5868a25c2de93e84dfa9d2f97adf1317df9029820fde3")
    }

    func testDraftVectorsByteForByte() throws {
        let keys = try GroupKeys(key: K)
        let live = SyncCrypto.kdf(K, id: 5, ctx: "SpSync01")
        for v in draftVectors {
            let st = try CRDT.parseState(v.s)
            let draft = keys.sealDraft(key: KEY, state: st, gid: GID, from: FROM, q: v.q, nonce: NONCE)
            XCTAssertEqual(draft, v.draft, v.name)
            XCTAssertEqual(draft?.utf8.count, 396, v.name)
            // 평문 = 정규 JSON + 공백 (256바이트)
            let plain = try SyncCrypto.open(key: live, sealed: Base64URL.decode(v.draft)!, ad: Array("spiralday/draft/v1:\(GID):\(FROM):\(v.q)".utf8))
            XCTAssertEqual(plain.count, 256, v.name)
            let text = String(decoding: plain, as: UTF8.self)
            XCTAssertEqual(String(text.reversed().drop { $0 == " " }.reversed()), v.json, v.name)
            XCTAssertTrue(plain.suffix(256 - v.json.utf8.count).allSatisfy { $0 == 0x20 }, v.name)
            // 풀기: 같은 키 · 같은 상태
            let back = try keys.openDraft(v.draft, gid: GID, from: FROM, q: v.q)
            XCTAssertEqual(back.key, KEY, v.name)
            XCTAssertEqual(back.state, st, v.name)
            XCTAssertEqual(CRDT.toJSON(back.state).canonical, v.s.canonical, v.name)
        }
    }

    func testDraftAntiVectors() throws {
        let keys = try GroupKeys(key: K)
        let v = draftVectors[0]
        // from · q · gid 를 바꾼 AD, K_enc 로는 풀리지 않는다
        XCTAssertThrowsError(try keys.openDraft(v.draft, gid: GID, from: "DDDDDDDDDDDDDDDDDDDDDD", q: v.q))
        XCTAssertThrowsError(try keys.openDraft(v.draft, gid: GID, from: FROM, q: "0199a29fb68000020123456789abcdef"))
        XCTAssertThrowsError(try keys.openDraft(v.draft, gid: "BBBBBBBBBBBBBBBBBBBBBB", from: FROM, q: v.q))
        let enc = SyncCrypto.kdf(K, id: 1, ctx: "SpSync01")
        XCTAssertThrowsError(try SyncCrypto.open(key: enc, sealed: Base64URL.decode(v.draft)!, ad: Array("spiralday/draft/v1:\(GID):\(FROM):\(v.q)".utf8)))
        // 초안을 레코드로 끼워 넣어도 풀리지 않는다 (키 · AD 가 다르다)
        XCTAssertThrowsError(try keys.decryptRecord(rid: keys.rid(KEY), ct: v.draft))
    }

    func testDraftLimitsAndRejectedShapes() throws {
        let keys = try GroupKeys(key: K)
        let q = draftVectors[0].q
        let live = SyncCrypto.kdf(K, id: 5, ctx: "SpSync01")
        // 너무 크면 봉인하지 않는다 (평문 23,552바이트 넘음)
        let big = RecState(f: ["comment": FieldEntry(.string(String(repeating: "가", count: 8000)), q)])
        XCTAssertNil(keys.sealDraft(key: KEY, state: big, gid: GID, from: FROM, q: q))
        let almost = RecState(f: ["comment": FieldEntry(.string(String(repeating: "a", count: 23_000)), q)])
        let sealed = try XCTUnwrap(keys.sealDraft(key: KEY, state: almost, gid: GID, from: FROM, q: q))
        XCTAssertLessThanOrEqual(sealed.utf8.count, 32_000)
        XCTAssertEqual(try keys.openDraft(sealed, gid: GID, from: FROM, q: q).key, KEY)
        func raw(_ json: String) -> String {
            var p = Array(json.utf8)
            while p.count % 256 != 0 { p.append(0x20) }
            return Base64URL.encode(SyncCrypto.seal(key: live, plain: p, ad: Array("spiralday/draft/v1:\(GID):\(FROM):\(q)".utf8)))
        }
        func message(_ d: String) -> String {
            do {
                _ = try keys.openDraft(d, gid: GID, from: FROM, q: q)
                return ""
            } catch {
                return "\(error)"
            }
        }
        // 지움(x) · 책 정보 · 모르는 버전 · 모양이 틀린 상태는 받지 않는다
        XCTAssertTrue(message(raw(#"{"v":1,"k":"\#(KEY)","s":{"f":{},"c":{},"x":"\#(q)"}}"#)).contains("지울 수 없음"))
        XCTAssertTrue(message(raw(#"{"v":1,"k":"b/3F2504E0-4F89-11D3-9A0C-0305E82C3301","s":{"f":{},"c":{}}}"#)).contains("받지 않는"))
        XCTAssertTrue(message(raw(#"{"v":2,"k":"\#(KEY)","s":{"f":{},"c":{}}}"#)).contains("버전"))
        XCTAssertFalse(message(raw(#"{"v":1,"k":"\#(KEY)","s":{"f":{"a":1}}}"#)).isEmpty)
        // __proto__ 는 버린다
        let proto = try keys.openDraft(raw(#"{"v":1,"k":"\#(KEY)","s":{"f":{"__proto__":["x","\#(q)"]},"c":{}}}"#), gid: GID, from: FROM, q: q)
        XCTAssertTrue(proto.state.f.isEmpty)
        XCTAssertTrue(message("short").contains("형식"))
        // 정규형이 아닌 base64url (모양은 맞아도) 은 거절
        XCTAssertFalse(message(String(repeating: "A", count: 397)).isEmpty)
    }
}
