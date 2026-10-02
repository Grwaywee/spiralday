// 바이트 · base64url (패딩 없음, 정규형만) · hex
import Foundation

public enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    private static let inverse: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    /// base64url, 패딩 없음 (RFC 4648 §5)
    public static func encode<B: Collection>(_ bytes: B) -> String where B.Element == UInt8 {
        let b = Array(bytes)
        var out = [UInt8]()
        out.reserveCapacity((b.count * 4 + 2) / 3)
        var i = 0
        while i + 2 < b.count {
            let n = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
            out.append(alphabet[Int(n >> 18)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            out.append(alphabet[Int(n & 63)])
            i += 3
        }
        let rest = b.count - i
        if rest == 1 {
            let n = UInt32(b[i]) << 16
            out.append(alphabet[Int(n >> 18)])
            out.append(alphabet[Int(n >> 12 & 63)])
        } else if rest == 2 {
            let n = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8
            out.append(alphabet[Int(n >> 18)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// base64url → 바이트. 형식이 틀리거나 정규형이 아니면 nil
    public static func decode(_ s: String) -> [UInt8]? {
        let u = Array(s.utf8)
        if u.count % 4 == 1 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(u.count * 3 / 4)
        var acc: UInt32 = 0
        var bits = 0
        for c in u {
            let v = inverse[Int(c)]
            if v < 0 { return nil }
            acc = (acc << 6 | UInt32(v)) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(acc >> UInt32(bits) & 0xFF))
            }
        }
        if bits > 0, acc & ((1 << UInt32(bits)) - 1) != 0 { return nil }
        return out
    }
}

public enum Hex {
    public static func encode<B: Sequence>(_ bytes: B) -> String where B.Element == UInt8 {
        let d = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for x in bytes {
            out.append(d[Int(x >> 4)])
            out.append(d[Int(x & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ s: String) -> [UInt8]? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        func val(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let a = val(u[i]), let b = val(u[i + 1]) else { return nil }
            out.append(a << 4 | b)
            i += 2
        }
        return out
    }
}

@inline(__always)
func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }

/// 상수 시간 비교
func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var d: UInt8 = 0
    for i in a.indices { d |= a[i] ^ b[i] }
    return d == 0
}
