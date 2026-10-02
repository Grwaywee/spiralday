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
}
