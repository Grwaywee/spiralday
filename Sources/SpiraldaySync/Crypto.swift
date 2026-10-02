// 암호 (libsodium — swift-sodium 의 Clibsodium). 서버는 아무것도 풀 수 없다.
// 바이트 규칙은 모든 클라이언트 엔진이 같다 (VectorsTests 의 테스트 벡터를 바이트 그대로 만든다).
//
// 그룹 키 K (32바이트 난수) → crypto_kdf 로 하위 키 (문맥 "SpSync01"):
//   1 enc  — 레코드 암호화 (XChaCha20-Poly1305-IETF)
//   2 rid  — 레코드 id: rid = base64url(HMAC-SHA256(K_rid, 레코드 키))
//   3      — 쓰지 않는다 (예전 확인 숫자 자리. 다른 용도로 다시 쓰지 않는다)
//   4 name — 기기 이름 암호화 (AD 에 기기 id)
//   5 live — 실시간 초안 봉인 (AD "spiralday/draft/v1:gid:from:q"). 레코드 키와 달라서 초안을 레코드로 끼워 넣을 수 없다
// 페어링 seed (QR 비밀 · 8자 코드의 Argon2id) → crypto_kdf (문맥 "SpPair01"):
//   1 codeHash (서버의 색인) · 2 wrapKey (K 를 감싼다) · 3 confirmKey (확인 숫자 4자리)
// 봉인 = 0x01 ‖ nonce(24) ‖ AEAD(키, nonce, 평문, AD)
import Clibsodium
import Foundation
import os

public struct CryptoError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum SyncCrypto {
    public static let keyBytes = 32
    static let version: UInt8 = 1
    static let nonceBytes = 24
    static let tagBytes = 16
    /// 레코드 평문(압축을 푼 JSON) 최대 크기. 압축 폭탄으로 다른 기기를 멈추지 못하게
    public static let maxPlainBytes = 32 * 1024 * 1024
    /// Argon2id 매개변수 (모든 앱이 같아야 한다)
    public static let argonOps: UInt64 = 3
    public static let argonMem: Int = 64 * 1024 * 1024

    static let ctxGroup = "SpSync01"
    static let ctxPair = "SpPair01"
    static let ctxRecovery = "SpRecv01"

    private static let ready: Bool = sodium_init() >= 0

    /// libsodium 준비 (여러 번 불러도 된다)
    @discardableResult
    public static func prepare() -> Bool {
        precondition(ready, "libsodium 을 준비하지 못함")
        return ready
    }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        prepare()
        var b = [UInt8](repeating: 0, count: n)
        b.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, n) }
        return b
    }

    /// crypto_kdf_derive_from_key(32, id, ctx, key)
    public static func kdf(_ key: [UInt8], id: UInt64, ctx: String) -> [UInt8] {
        prepare()
        precondition(key.count == crypto_kdf_KEYBYTES && ctx.utf8.count == crypto_kdf_CONTEXTBYTES)
        var out = [UInt8](repeating: 0, count: keyBytes)
        var c = Array(ctx.utf8).map { CChar(bitPattern: $0) }
        c.append(0)
        let r = out.withUnsafeMutableBufferPointer { o in
            key.withUnsafeBufferPointer { k in
                crypto_kdf_derive_from_key(o.baseAddress!, keyBytes, id, c, k.baseAddress!)
            }
        }
        precondition(r == 0)
        return out
    }

    /// HMAC-SHA256 (키 32바이트)
    public static func hmac(_ key: [UInt8], _ msg: [UInt8]) -> [UInt8] {
        prepare()
        precondition(key.count == crypto_auth_hmacsha256_KEYBYTES)
        var out = [UInt8](repeating: 0, count: Int(crypto_auth_hmacsha256_BYTES))
        _ = out.withUnsafeMutableBufferPointer { o in
            msg.withUnsafeBufferPointer { m in
                key.withUnsafeBufferPointer { k in
                    crypto_auth_hmacsha256(o.baseAddress!, m.baseAddress ?? UnsafePointer(bitPattern: 1)!, UInt64(m.count), k.baseAddress!)
                }
            }
        }
        return out
    }

    public static func sha256(_ msg: [UInt8]) -> [UInt8] {
        prepare()
        var out = [UInt8](repeating: 0, count: Int(crypto_hash_sha256_BYTES))
        _ = out.withUnsafeMutableBufferPointer { o in
            msg.withUnsafeBufferPointer { m in
                crypto_hash_sha256(o.baseAddress!, m.baseAddress ?? UnsafePointer(bitPattern: 1)!, UInt64(m.count))
            }
        }
        return out
    }

    /// Argon2id (opslimit 3, memlimit 64 MiB) → 32바이트
    public static func argon2id(password: [UInt8], salt: [UInt8]) throws -> [UInt8] {
        prepare()
        precondition(salt.count == crypto_pwhash_SALTBYTES)
        var out = [UInt8](repeating: 0, count: keyBytes)
        let r = out.withUnsafeMutableBufferPointer { o in
            password.withUnsafeBufferPointer { p in
                salt.withUnsafeBufferPointer { s in
                    p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { pc in
                        crypto_pwhash(o.baseAddress!, UInt64(keyBytes), pc, UInt64(p.count), s.baseAddress!,
                                      argonOps, argonMem, crypto_pwhash_ALG_ARGON2ID13)
                    }
                }
            }
        }
        guard r == 0 else { throw CryptoError("Argon2id 를 계산하지 못함 (메모리 부족)") }
        return out
    }

    /// 봉인: 0x01 ‖ 난수 nonce ‖ AEAD
    public static func seal(key: [UInt8], plain: [UInt8], ad: [UInt8]) -> [UInt8] {
        seal(key: key, plain: plain, ad: ad, nonce: nil)
    }

    /// (테스트 벡터) nonce 를 정해 봉인 — 공개하지 않는다: 같은 키로 nonce 를 다시 쓰면 XChaCha20-Poly1305 의 비밀이 깨진다. nil = 난수
    static func seal(key: [UInt8], plain: [UInt8], ad: [UInt8], nonce: [UInt8]?) -> [UInt8] {
        prepare()
        precondition(key.count == keyBytes)
        let npub = nonce ?? randomBytes(nonceBytes)
        precondition(npub.count == nonceBytes)
        var box = [UInt8](repeating: 0, count: plain.count + tagBytes)
        var clen: UInt64 = 0
        let r = box.withUnsafeMutableBufferPointer { c in
            plain.withUnsafeBufferPointer { m in
                ad.withUnsafeBufferPointer { a in
                    npub.withUnsafeBufferPointer { n in
                        key.withUnsafeBufferPointer { k in
                            crypto_aead_xchacha20poly1305_ietf_encrypt(
                                c.baseAddress!, &clen, m.baseAddress, UInt64(m.count),
                                a.baseAddress, UInt64(a.count), nil, n.baseAddress!, k.baseAddress!)
                        }
                    }
                }
            }
        }
        precondition(r == 0 && Int(clen) == box.count)
        return [version] + npub + box
    }

    public static func open(key: [UInt8], sealed: [UInt8], ad: [UInt8]) throws -> [UInt8] {
        prepare()
        guard sealed.count >= 1 + nonceBytes + tagBytes else { throw CryptoError("암호문이 너무 짧음") }
        guard sealed[0] == version else { throw CryptoError("모르는 암호문 버전 \(sealed[0])") }
        guard key.count == keyBytes else { throw CryptoError("키 길이가 틀림") }
        let npub = Array(sealed[1..<(1 + nonceBytes)])
        let box = Array(sealed[(1 + nonceBytes)...])
        var plain = [UInt8](repeating: 0, count: box.count - tagBytes)
        var mlen: UInt64 = 0
        let r = plain.withUnsafeMutableBufferPointer { m in
            box.withUnsafeBufferPointer { c in
                ad.withUnsafeBufferPointer { a in
                    npub.withUnsafeBufferPointer { n in
                        key.withUnsafeBufferPointer { k in
                            crypto_aead_xchacha20poly1305_ietf_decrypt(
                                m.baseAddress, &mlen, nil, c.baseAddress!, UInt64(c.count),
                                a.baseAddress, UInt64(a.count), n.baseAddress!, k.baseAddress!)
                        }
                    }
                }
            }
        }
        guard r == 0 else { throw CryptoError("복호화 실패 (키가 다르거나 내용이 바뀜)") }
        if Int(mlen) < plain.count { plain.removeSubrange(Int(mlen)...) }
        return plain
    }

    /// 16자리 hex 노드 id (HLC)
    public static func newNodeId() -> String { Hex.encode(randomBytes(8)) }
}

// MARK: - 그룹 키

/// 실시간 초안 (Docs/SpiraldaySync.md §7.6 — 모든 엔진이 같은 바이트)
public enum Draft {
    /// 초안 평문은 이 단위로 공백(0x20)을 채운다 (서버가 크기로 글자 수를 세지 못하게)
    public static let pad = 256
    /// 채운 평문 최대 (92 × 256). 넘으면 보내지 않는다 (레코드 경로)
    public static let maxPlain = 92 * pad
    /// 봉인한 초안 base64url 길이: 평문 최소 256바이트 → 396자, 서버 한도 32,000자
    public static let minChars = 396
    public static let maxChars = 32_000
    /// 초안 payload 버전
    public static let version = 1

    /// 봉인한 초안 모양 (^[A-Za-z0-9_-]{396,32000}$)
    public static func isDraft(_ s: String) -> Bool {
        let u = s.utf8
        guard u.count >= minChars, u.count <= maxChars else { return false }
        return u.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }
    }

    static func ad(gid: String, from: String, q: String) -> [UInt8] { utf8("spiralday/draft/v1:\(gid):\(from):\(q)") }
}

public final class GroupKeys: Sendable {
    public let key: [UInt8]
    let enc: [UInt8]
    let ridKey: [UInt8]
    let nameKey: [UInt8]
    /// K_live (id 5): 실시간 초안
    let liveKey: [UInt8]
    private let ridCache = OSAllocatedUnfairLock(initialState: [String: String]())

    public init(key: [UInt8]) throws {
        guard key.count == SyncCrypto.keyBytes else { throw CryptoError("그룹 키는 32바이트") }
        self.key = key
        enc = SyncCrypto.kdf(key, id: 1, ctx: SyncCrypto.ctxGroup)
        ridKey = SyncCrypto.kdf(key, id: 2, ctx: SyncCrypto.ctxGroup)
        nameKey = SyncCrypto.kdf(key, id: 4, ctx: SyncCrypto.ctxGroup)
        liveKey = SyncCrypto.kdf(key, id: 5, ctx: SyncCrypto.ctxGroup)
    }

    /// 초안 봉인 (Docs/SpiraldaySync.md §7.6): payload {v: 1, k: 레코드 키, s: 조각} 의 정규 JSON 을 공백으로 256바이트의 배수까지 채워
    /// K_live 로, AD = "spiralday/draft/v1:gid:from:q". 채운 평문이 23,552바이트를 넘으면 nil (보내지 않는다). nonce 는 늘 난수
    public func sealDraft(key recordKey: String, state: RecState, gid: String, from: String, q: Stamp) -> String? {
        sealDraft(key: recordKey, state: state, gid: gid, from: from, q: q, nonce: nil)
    }

    /// (테스트 벡터) nonce 를 정해 봉인 — 공개하지 않는다 (nonce 를 다시 쓰면 비밀이 깨진다). nil = 난수
    func sealDraft(key recordKey: String, state: RecState, gid: String, from: String, q: Stamp, nonce: [UInt8]?) -> String? {
        let payload: JSONValue = ["v": JSONValue(Draft.version), "k": .string(recordKey), "s": CRDT.toJSON(state)]
        let json = payload.canonicalBytes
        let size = max(Draft.pad, (json.count + Draft.pad - 1) / Draft.pad * Draft.pad)
        if size > Draft.maxPlain { return nil }
        var plain = json
        plain.append(contentsOf: repeatElement(0x20, count: size - json.count))
        return Base64URL.encode(SyncCrypto.seal(key: liveKey, plain: plain, ad: Draft.ad(gid: gid, from: from, q: q), nonce: nonce))
    }

    /// 초안 풀기와 모양 검사 (§4.4 의 3–4). 틀리면 CryptoError:
    /// 형식 · 풀리지 않음 · 평문 23,552바이트 초과 · JSON 객체가 아님 · v ≠ 1 · 키가 하루 · 한 주 · 책 설정이 아님 · 상태 모양 · 레코드 지움(x)
    public func openDraft(_ draft: String, gid: String, from: String, q: Stamp) throws -> (key: String, state: RecState) {
        guard Draft.isDraft(draft) else { throw CryptoError("초안 형식이 틀림") }
        guard let sealed = Base64URL.decode(draft) else { throw CryptoError("초안이 base64url 이 아님") }
        let plain = try SyncCrypto.open(key: liveKey, sealed: sealed, ad: Draft.ad(gid: gid, from: from, q: q))
        if plain.count > Draft.maxPlain { throw CryptoError("초안이 너무 큼") }
        // JS 는 잘못된 UTF-8 이면 (fatal 디코더) 실패한다
        guard String(bytes: plain, encoding: .utf8) != nil, let p = try? JSONValue.parse(plain) else { throw CryptoError("초안이 JSON 이 아님") }
        guard case let .object(o) = p else { throw CryptoError("초안 모양이 틀림") }
        guard o["v"] == .number(Double(Draft.version)) else { throw CryptoError("모르는 초안 버전") }
        guard case let .string(k)? = o["k"] else { throw CryptoError("초안 모양이 틀림") }
        guard let pk = RecordKeys.parse(k), pk.kind == .day || pk.kind == .week || pk.kind == .prefs else {
            throw CryptoError("초안으로 받지 않는 레코드")
        }
        let s: RecState
        do {
            s = try CRDT.parseState(o["s"])
        } catch {
            throw CryptoError("초안 상태 모양이 틀림")
        }
        if s.x != nil { throw CryptoError("초안은 레코드를 지울 수 없음") }
        return (k, s)
    }

    public static func generate() -> GroupKeys {
        // crypto_kdf_keygen = 32바이트 난수
        try! GroupKeys(key: SyncCrypto.randomBytes(SyncCrypto.keyBytes))
    }

    public convenience init(base64 k: String) throws {
        guard let b = Base64URL.decode(k) else { throw CryptoError("그룹 키가 base64url 이 아님") }
        try self.init(key: b)
    }

    public var base64: String { Base64URL.encode(key) }

    /// 레코드 키 → 서버에 보이는 id (43자)
    public func rid(_ recordKey: String) -> String {
        if let r = ridCache.withLock({ $0[recordKey] }) { return r }
        let r = Base64URL.encode(SyncCrypto.hmac(ridKey, utf8(recordKey)))
        ridCache.withLock { c in
            if c.count > 50_000 { c.removeAll() }
            c[recordKey] = r
        }
        return r
    }

    /// 레코드 내용 → 암호문 (base64url). plain = gzip(정규 JSON)
    public func encryptRecord(rid: String, payload: JSONValue) -> String {
        let gz = try! Gzip.compress(payload.canonicalBytes)
        return Base64URL.encode(SyncCrypto.seal(key: enc, plain: gz, ad: utf8(rid)))
    }

    /// 암호문 → 레코드 내용. AD 로 rid 를 묶었으므로 다른 rid 의 암호문을 끼워 넣으면 실패한다
    public func decryptRecord(rid: String, ct: String) throws -> JSONValue {
        guard let sealed = Base64URL.decode(ct) else { throw CryptoError("암호문이 base64url 이 아님") }
        let gz = try SyncCrypto.open(key: enc, sealed: sealed, ad: utf8(rid))
        let plain: [UInt8]
        do {
            plain = try Gzip.decompress(gz, maxBytes: SyncCrypto.maxPlainBytes)
        } catch let e as Gzip.Failure {
            throw CryptoError(e.message == "압축을 푼 크기가 너무 큼" || e.message == "압축 데이터가 너무 짧음" ? e.message : "압축을 풀 수 없음")
        }
        // JS 는 잘못된 UTF-8 이면 (fatal 디코더) 실패한다
        guard String(bytes: plain, encoding: .utf8) != nil else { throw CryptoError("압축을 풀 수 없음") }
        do {
            return try JSONValue.parse(plain)
        } catch {
            throw CryptoError("레코드가 JSON 이 아님")
        }
    }

    /// 기기 이름 (서버에는 "e1." + 암호문). AD 에 그 기기의 id 를 묶는다 (서버가 이름을 바꿔치기하면 풀리지 않는다)
    public func encryptName(_ name: String, deviceId: String) -> String {
        encryptName(name, deviceId: deviceId, nonce: nil)
    }

    /// (테스트 벡터) nonce 를 정해서 — 공개하지 않는다. nil = 난수
    func encryptName(_ name: String, deviceId: String, nonce: [UInt8]?) -> String {
        // 서버 한도 256자: 이름은 120바이트까지 (JS 처럼 UTF-16 단위로 뒤에서 뗀다)
        var units = Array(name.trimmingCharacters(in: JS.whitespace).utf16)
        while String(decoding: units, as: UTF16.self).utf8.count > 120 { units.removeLast() }
        let n = String(decoding: units, as: UTF16.self)
        return "e1." + Base64URL.encode(SyncCrypto.seal(key: nameKey, plain: utf8(n), ad: Self.nameAD(deviceId), nonce: nonce))
    }

    public func decryptName(_ stored: String?, deviceId: String) -> String? {
        guard let stored, stored.hasPrefix("e1."), let b = Base64URL.decode(String(stored.dropFirst(3))) else { return nil }
        guard let plain = try? SyncCrypto.open(key: nameKey, sealed: b, ad: Self.nameAD(deviceId)) else { return nil }
        return String(bytes: plain, encoding: .utf8)
    }

    static func nameAD(_ deviceId: String) -> [UInt8] { utf8("spiralday/device-name/v1:\(deviceId)") }
}

extension JS {
    /// JS String.prototype.trim 이 떼는 글자 (WhiteSpace · LineTerminator)
    static let whitespace: CharacterSet = {
        var s = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        s.insert(charactersIn: "\u{2000}"..."\u{200A}")
        return s
    }()
}

// MARK: - 페어링

public struct PairingSecret: Sendable {
    /// 서버에 보내는 조회 값 (32바이트, base64url 43자). 코드 원문은 보내지 않는다
    public let codeHash: String
    /// K 를 감싸는 키 (서버는 모른다)
    public let wrapKey: [UInt8]
    /// 확인 숫자를 만드는 키 (서버는 모른다). seed 에서 나오므로 K 가 오가기 전에 두 화면에 보인다
    public let confirmKey: [UInt8]

    init(seed: [UInt8]) {
        codeHash = Base64URL.encode(SyncCrypto.kdf(seed, id: 1, ctx: SyncCrypto.ctxPair))
        wrapKey = SyncCrypto.kdf(seed, id: 2, ctx: SyncCrypto.ctxPair)
        confirmKey = SyncCrypto.kdf(seed, id: 3, ctx: SyncCrypto.ctxPair)
    }

    /// QR: 32바이트 비밀에서 (Argon2 없이: 비밀이 충분히 길다)
    public static func fromQrSecret(_ secret: [UInt8]) throws -> PairingSecret {
        guard secret.count == 32 else { throw CryptoError("QR 비밀은 32바이트") }
        return PairingSecret(seed: secret)
    }

    /// 8자 코드에서: Argon2id 로 늘린다
    public static func fromCode(_ code: String) throws -> PairingSecret {
        guard let c = Codes.canonicalPairingCode(code) else { throw CryptoError("페어링 코드 형식이 틀림") }
        let seed = try SyncCrypto.argon2id(password: utf8(c), salt: Pairing.salt)
        return PairingSecret(seed: seed)
    }

    /// 확인 숫자 4자리 (두 기기 화면에 같은 숫자 — 승인 게이트)
    /// h = HMAC-SHA256(confirmKey, "spiralday/pair-confirm/v1:" + gid + ":" + pairingId + ":" + deviceId + ":" + nonce)
    public func confirmDigits(gid: String, pairingId: String, deviceId: String, nonce: String) -> String {
        let h = SyncCrypto.hmac(confirmKey, utf8("spiralday/pair-confirm/v1:\(gid):\(pairingId):\(deviceId):\(nonce)"))
        let n = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
        let s = String(n % 10000)
        return String(repeating: "0", count: 4 - s.count) + s
    }

    public func wrap(_ keys: GroupKeys, gid: String) -> String { wrap(keys, gid: gid, nonce: nil) }

    /// (테스트 벡터) nonce 를 정해서 — 공개하지 않는다. nil = 난수
    func wrap(_ keys: GroupKeys, gid: String, nonce: [UInt8]?) -> String {
        Base64URL.encode(SyncCrypto.seal(key: wrapKey, plain: keys.key, ad: Pairing.ad(gid), nonce: nonce))
    }

    public func unwrap(_ wrapped: String, gid: String) throws -> GroupKeys {
        guard let b = Base64URL.decode(wrapped) else { throw CryptoError("감싼 키가 base64url 이 아님") }
        return try GroupKeys(key: SyncCrypto.open(key: wrapKey, sealed: b, ad: Pairing.ad(gid)))
    }
}

public enum Pairing {
    /// QR 에 담는 글: "SPIRALDAY-PAIR:1:<비밀 base64url>"
    public static let qrPrefix = "SPIRALDAY-PAIR:1:"
    static let salt: [UInt8] = Array(SyncCrypto.sha256(utf8("spiralday/pair/v1")).prefix(16))
    static func ad(_ gid: String) -> [UInt8] { utf8("spiralday/pair/v1:\(gid)") }

    public static func newQrSecret() -> (secret: [UInt8], text: String) {
        let s = SyncCrypto.randomBytes(32)
        return (s, qrPrefix + Base64URL.encode(s))
    }

    /// 새 기기가 합류를 요청할 때 고르는 난수 (16바이트, base64url 22자) — 확인 숫자에 들어간다
    public static func newNonce() -> String { Base64URL.encode(SyncCrypto.randomBytes(16)) }

    public enum Input: Equatable, Sendable {
        case qr(secret: [UInt8])
        case code(String)
    }

    /// 사용자가 넣은 것(QR 글 · 링크 · 8자 코드) 읽기. 모르는 모양이면 nil
    public static func parseInput(_ input: String) -> Input? {
        let t = input.trimmingCharacters(in: JS.whitespace)
        if let r = t.range(of: qrPrefix) {
            let rest = t[r.upperBound...].utf8.prefix { c in
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
            }
            guard rest.count >= 43 else { return nil }
            let s = String(decoding: rest.prefix(43), as: UTF8.self)
            guard let secret = Base64URL.decode(s), secret.count == 32 else { return nil }
            return .qr(secret: secret)
        }
        return Codes.canonicalPairingCode(t).map { .code($0) }
    }
}

// MARK: - 복구

public struct RecoverySecret: Sendable {
    /// 서버의 보관함 id = base64url(HMAC-SHA256(K_r, "rid"))
    public let recoveryId: String
    /// 합류 증명 (서버는 SHA-256 만 안다)
    public let auth: String
    public let authHash: String
    public let wrapKey: [UInt8]

    static let salt: [UInt8] = Array(SyncCrypto.sha256(utf8("spiralday/recovery/v1")).prefix(16))
    static func ad(_ gid: String) -> [UInt8] { utf8("spiralday/recovery/v1:\(gid)") }

    public static func fromCode(_ code: String) throws -> RecoverySecret {
        guard let c = Codes.canonicalRecoveryCode(code) else { throw CryptoError("복구 코드 형식이 틀림 (글자를 다시 확인하세요)") }
        let seed = try SyncCrypto.argon2id(password: utf8(c), salt: salt)
        let kr = SyncCrypto.kdf(seed, id: 1, ctx: SyncCrypto.ctxRecovery)
        let authKey = SyncCrypto.kdf(seed, id: 3, ctx: SyncCrypto.ctxRecovery)
        return RecoverySecret(
            recoveryId: Base64URL.encode(SyncCrypto.hmac(kr, utf8("rid"))),
            auth: Base64URL.encode(authKey),
            authHash: Base64URL.encode(SyncCrypto.sha256(authKey)),
            wrapKey: SyncCrypto.kdf(seed, id: 2, ctx: SyncCrypto.ctxRecovery))
    }

    public func wrap(_ keys: GroupKeys, gid: String) -> String { wrap(keys, gid: gid, nonce: nil) }

    /// (테스트 벡터) nonce 를 정해서 — 공개하지 않는다. nil = 난수
    func wrap(_ keys: GroupKeys, gid: String, nonce: [UInt8]?) -> String {
        Base64URL.encode(SyncCrypto.seal(key: wrapKey, plain: keys.key, ad: Self.ad(gid), nonce: nonce))
    }

    public func unwrap(_ wrapped: String, gid: String) throws -> GroupKeys {
        guard let b = Base64URL.decode(wrapped) else { throw CryptoError("감싼 키가 base64url 이 아님") }
        return try GroupKeys(key: SyncCrypto.open(key: wrapKey, sealed: b, ad: Self.ad(gid)))
    }
}
