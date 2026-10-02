// 사람이 읽고 치는 코드 (Crockford base32: 0-9 A-Z 에서 I L O U 를 뺀 32자).
// 읽을 때는 대소문자 · 공백 · 하이픈을 가리지 않고, O→0 · I/L→1 로 읽는다.
//   페어링 코드: 8자 (40비트), "ABCD-EFGH" 로 보인다.
//   복구 코드: 25자 = 무작위 23자(115비트) + 검사 2자, "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX".
//     검사 값 = Σ (i+1)·v_i mod 1021 → [sum >> 5, sum & 31]
import Foundation

public enum Codes {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let pairingCodeLength = 8
    public static let recoveryDataLength = 23
    public static let recoveryCodeLength = 25

    private static let value: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { m[c] = i }
        m["O"] = 0
        m["I"] = 1
        m["L"] = 1
        return m
    }()

    /// 건너뛰는 글자 (하이픈 · 공백 · 대시 · 탭 · 줄바꿈)
    private static let separators: Set<Unicode.Scalar> = ["-", " ", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}", "\t", "\n"]

    static func randomSymbols(_ n: Int) -> [Int] {
        // 256 은 32 로 나누어떨어져 고르게 나온다
        SyncCrypto.randomBytes(n).map { Int($0 & 31) }
    }

    /// 입력 → 기호 값 목록. 쓸 수 없는 글자가 있으면 nil
    public static func decodeSymbols(_ input: String) -> [Int]? {
        var out: [Int] = []
        for sc in input.uppercased().unicodeScalars {
            if separators.contains(sc) { continue }
            guard let v = value[Character(sc)] else { return nil }
            out.append(v)
        }
        return out
    }

    static func encode(_ vs: [Int]) -> String { String(vs.map { alphabet[$0] }) }

    static func group(_ s: String, _ size: Int) -> String {
        var parts: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if cur.count == size {
                parts.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.joined(separator: "-")
    }

    // MARK: 페어링 코드

    /// 새 8자 페어링 코드 ("ABCD-EFGH")
    public static func newPairingCode() -> String {
        group(encode(randomSymbols(pairingCodeLength)), 4)
    }

    /// 정규형 (하이픈 없는 대문자 8자). 틀리면 nil
    public static func canonicalPairingCode(_ input: String) -> String? {
        guard let v = decodeSymbols(input), v.count == pairingCodeLength else { return nil }
        return encode(v)
    }

    public static func formatPairingCode(_ c: String) -> String { group(canonicalPairingCode(c) ?? c, 4) }

    // MARK: 복구 코드

    static func checksum(_ data: [Int]) -> [Int] {
        var sum = 0
        for (i, v) in data.enumerated() { sum = (sum + (i + 1) * v) % 1021 }
        return [sum >> 5, sum & 31]
    }

    /// 새 복구 코드 ("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"). 한 번만 보여 준다
    public static func newRecoveryCode() -> String {
        let data = randomSymbols(recoveryDataLength)
        return group(encode(data + checksum(data)), 5)
    }

    public enum RecoveryCheck: String, Sendable {
        case ok, short, long
        case invalidChar = "invalid-char"
        case checksum
    }

    /// 입력 중 검사 (화면에 "짧아요" · "글자를 확인해 주세요" 를 보여 줄 때)
    public static func checkRecoveryCode(_ input: String) -> RecoveryCheck {
        guard let v = decodeSymbols(input) else { return .invalidChar }
        if v.count < recoveryCodeLength { return .short }
        if v.count > recoveryCodeLength { return .long }
        let c = checksum(Array(v.prefix(recoveryDataLength)))
        return v[23] == c[0] && v[24] == c[1] ? .ok : .checksum
    }

    /// 정규형 (하이픈 없는 대문자 25자). 검사 값이 틀리면 nil
    public static func canonicalRecoveryCode(_ input: String) -> String? {
        guard checkRecoveryCode(input) == .ok, let v = decodeSymbols(input) else { return nil }
        return encode(v)
    }

    public static func formatRecoveryCode(_ c: String) -> String { group(canonicalRecoveryCode(c) ?? c, 5) }
}
