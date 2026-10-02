// JSON 값 (앱 데이터 · 레코드 상태 · 서버 본문).
//
// TypeScript 엔진(Windows 앱)과 같은 결과를 내도록 JavaScript 의 규칙을 그대로 따른다.
//   - 숫자는 모두 Double (JS number). 정수 판정 · 문자열로 바꾸기도 JS 와 같다 (jsNumberString).
//   - 정규 JSON (canonical) = 키를 UTF-16 코드 단위 순서로 정렬하고 공백 없이 (JSON.stringify 와 같은 이스케이프).
//   - 문자열 비교는 Swift 의 유니코드 동치(정규화)가 아니라 정확한 글자 단위로 한다 (JS === · < 와 같게).
import Foundation

public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - 같음 (JS jsonEq: 키 순서 무관, 문자열은 글자 그대로)

extension JSONValue: Equatable {
    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return JS.same(x, y)
        case let (.array(x), .array(y)):
            guard x.count == y.count else { return false }
            for i in x.indices where !(x[i] == y[i]) { return false }
            return true
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            for (k, v) in x {
                guard let w = y[k], v == w else { return false }
            }
            return true
        default: return false
        }
    }
}

// MARK: - 꺼내기

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// JS Number.isInteger
    public var isInteger: Bool {
        if case let .number(n) = self { return JS.isInteger(n) }
        return false
    }

    /// JS Number.isSafeInteger 이면 그 값
    public var safeInt: Int? {
        if case let .number(n) = self, JS.isSafeInteger(n) { return Int(n) }
        return nil
    }
}

// MARK: - 리터럴 (테스트 · 기본값)

// (nil 리터럴은 받지 않는다: Optional 의 nil 과 헷갈리면 조용히 .null 이 되어 버린다)
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

extension JSONValue {
    public init(_ n: Int) { self = .number(Double(n)) }
}

// MARK: - 정규 JSON 쓰기

extension JSONValue {
    /// 정규 JSON (키 정렬 · 공백 없음). 같은 값 = 같은 글자 (모든 엔진이 같은 바이트)
    public var canonical: String {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// 정규 JSON 의 UTF-8 바이트
    public var canonicalBytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(into: &out)
        return out
    }

    /// 정규 JSON 을 Data 로 (앱 파일 · 요청 본문)
    public func jsonData() -> Data { Data(canonicalBytes) }

    func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case let .bool(b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case let .number(n): out.append(contentsOf: Array(JS.numberString(n).utf8))
        case let .string(s): JS.writeString(s, into: &out)
        case let .array(a):
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                v.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let .object(o):
            out.append(UInt8(ascii: "{"))
            for (i, k) in JS.sortedKeys(o).enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JS.writeString(k, into: &out)
                out.append(UInt8(ascii: ":"))
                o[k]!.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }
}

// MARK: - 읽기

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON 을 읽을 수 없음 (\(offset)): \(message)" }
}

extension JSONValue {
    /// UTF-8 JSON 읽기 (JS JSON.parse 와 같은 규칙: 같은 키가 둘이면 뒤의 것, 숫자는 Double)
    public static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var p = JSONParser(raw.bindMemory(to: UInt8.self))
            return try p.parseDocument()
        }
    }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        try bytes.withUnsafeBufferPointer { buf in
            var p = JSONParser(buf)
            return try p.parseDocument()
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    /// Codable 값 → JSONValue (앱의 모델을 엔진에 넘길 때. encoder 는 앱이 파일에 쓰는 것과 같은 설정으로)
    public init<T: Encodable>(encoding value: T, using encoder: JSONEncoder = JSONEncoder()) throws {
        self = try JSONValue.parse(try encoder.encode(value))
    }

    /// JSONValue → Codable 값 (엔진이 넘긴 앱 값을 앱의 모델로)
    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: jsonData())
    }
}

struct JSONParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0
    var depth = 0
    /// 너무 깊은 중첩은 거절한다 (스택이 넘치지 않게)
    static let maxDepth = 512

    init(_ b: UnsafeBufferPointer<UInt8>) { self.b = b }

    func fail(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    mutating func skipWS() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
    }

    mutating func parseDocument() throws -> JSONValue {
        // UTF-8 BOM 은 건너뛴다
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        skipWS()
        let v = try parseValue()
        skipWS()
        if i != b.count { throw fail("값 뒤에 글자가 더 있음") }
        return v
    }

    mutating func parseValue() throws -> JSONValue {
        guard i < b.count else { throw fail("끝남") }
        switch b[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: StaticString) throws {
        let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        guard i + w.count <= b.count else { throw fail("모르는 값") }
        for k in 0..<w.count where b[i + k] != w[k] { throw fail("모르는 값") }
        i += w.count
    }

    mutating func parseObject() throws -> JSONValue {
        depth += 1
        if depth > Self.maxDepth { throw fail("너무 깊음") }
        defer { depth -= 1 }
        i += 1
        var o: [String: JSONValue] = [:]
        skipWS()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
        while true {
            skipWS()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("키가 아님") }
            let k = try parseString()
            skipWS()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail(": 가 없음") }
            i += 1
            skipWS()
            o[k] = try parseValue()
            skipWS()
            guard i < b.count else { throw fail("끝남") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            throw fail(", 나 } 가 없음")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        depth += 1
        if depth > Self.maxDepth { throw fail("너무 깊음") }
        defer { depth -= 1 }
        i += 1
        var a: [JSONValue] = []
        skipWS()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
        while true {
            skipWS()
            a.append(try parseValue())
            skipWS()
            guard i < b.count else { throw fail("끝남") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            throw fail(", 나 ] 가 없음")
        }
    }

    mutating func hex4() throws -> UInt16 {
        guard i + 4 <= b.count else { throw fail("\\u 가 짧음") }
        var v: UInt16 = 0
        for _ in 0..<4 {
            let c = b[i]
            var d: UInt16
            switch c {
            case 0x30...0x39: d = UInt16(c - 0x30)
            case 0x41...0x46: d = UInt16(c - 0x41 + 10)
            case 0x61...0x66: d = UInt16(c - 0x61 + 10)
            default: throw fail("\\u 가 hex 가 아님")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func parseString() throws -> String {
        i += 1 // "
        var out: [UInt8] = []
        var start = i
        while true {
            guard i < b.count else { throw fail("문자열이 끝나지 않음") }
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                if out.isEmpty {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                    i += 1
                    return s
                }
                out.append(contentsOf: b[start..<i])
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { throw fail("문자열 안의 제어 문자") }
            if c != UInt8(ascii: "\\") { i += 1; continue }
            out.append(contentsOf: b[start..<i])
            i += 1
            guard i < b.count else { throw fail("끝남") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                let u = try hex4()
                var scalar: Unicode.Scalar?
                if u >= 0xD800, u < 0xDC00 {
                    // 짝이 맞는 서로게이트면 하나로, 아니면 U+FFFD (Swift 문자열은 홀로 선 서로게이트를 담지 못한다)
                    if i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let lo = try hex4()
                        if lo >= 0xDC00, lo < 0xE000 {
                            scalar = Unicode.Scalar(0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(lo) - 0xDC00))
                        } else {
                            i = save
                        }
                    }
                } else if !(u >= 0xDC00 && u < 0xE000) {
                    scalar = Unicode.Scalar(u)
                }
                let sc = scalar ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(sc)).utf8))
            default: throw fail("모르는 \\ 글자")
            }
            start = i
        }
    }

    mutating func parseNumber() throws -> JSONValue {
        let s = i
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail("숫자가 아님") }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if b[i] >= 0x31, b[i] <= 0x39 {
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        } else {
            throw fail("모르는 값")
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            let d = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            if i == d { throw fail("소수점 뒤에 숫자가 없음") }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            let d = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            if i == d { throw fail("지수에 숫자가 없음") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self)
        guard let v = Double(text) else { throw fail("숫자가 아님") }
        // JSON 은 Infinity 를 나타낼 수 없다 (JS 는 1e400 을 Infinity 로 읽지만 다시 쓰면 null) → null 로 둔다
        return v.isFinite ? .number(v) : .null
    }
}

// MARK: - JavaScript 규칙

/// TypeScript 엔진과 같은 결과를 내기 위한 JS 의 규칙들
public enum JS {
    /// 글자 그대로 같은지 (JS ===). Swift == 는 유니코드 정규화로 같은 것도 같다고 본다
    @inline(__always)
    public static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// JS 문자열 a < b (UTF-16 코드 단위 순서)
    public static func less(_ a: String, _ b: String) -> Bool {
        var x = a.utf8.makeIterator()
        var y = b.utf8.makeIterator()
        // ASCII 끼리는 UTF-8 바이트 순서 = UTF-16 순서. 처음 다른 글자가 ASCII 가 아니면 UTF-16 으로 다시 본다
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (p?, q?):
                if p == q { continue }
                if p < 0x80, q < 0x80 { return p < q }
                return a.utf16.lexicographicallyPrecedes(b.utf16)
            }
        }
    }

    /// JS a >= b
    @inline(__always)
    public static func greaterOrEqual(_ a: String, _ b: String) -> Bool { !less(a, b) }

    /// 객체 키를 JS Array.prototype.sort() 순서로
    public static func sortedKeys<V>(_ o: [String: V]) -> [String] {
        o.keys.sorted(by: less)
    }

    public static func isInteger(_ d: Double) -> Bool { d.isFinite && d.rounded(.towardZero) == d }

    public static func isSafeInteger(_ d: Double) -> Bool { isInteger(d) && abs(d) <= 9_007_199_254_740_991 }

    /// JS String(number) (Number::toString)
    public static func numberString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return "0" }
        if isSafeInteger(d) { return String(Int64(d)) }
        let neg = d < 0
        // Swift 의 description 은 가장 짧게 되돌아오는 숫자 (JS 와 같은 자릿수). 그 자릿수와 지수만 쓴다
        let s = "\(abs(d))"
        var mant = Substring(s)
        var exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mant = s[s.startIndex..<e]
            exp = Int(s[s.index(after: e)...]) ?? 0
        }
        var digits = ""
        var point = 0
        if let dot = mant.firstIndex(of: ".") {
            let a = mant[mant.startIndex..<dot]
            let c = mant[mant.index(after: dot)...]
            digits = String(a) + String(c)
            point = a.count
        } else {
            digits = String(mant)
            point = mant.count
        }
        var n = point + exp
        // 앞의 0 (n 을 줄인다) · 뒤의 0 을 뗀다
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
        let k = digits.count
        var out = neg ? "-" : ""
        if k <= n, n <= 21 {
            out += digits + String(repeating: "0", count: n - k)
        } else if 0 < n, n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            out += digits[..<idx] + "." + digits[idx...]
        } else if -6 < n, n <= 0 {
            out += "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let first = digits.prefix(1)
            let rest = digits.dropFirst()
            out += first + (rest.isEmpty ? "" : "." + rest) + "e" + (e < 0 ? "-" : "+") + String(abs(e))
        }
        return out
    }

    /// JSON.stringify(문자열) 과 같은 글자
    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for c in s.utf8 {
            switch c {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x08: out.append(0x5C); out.append(UInt8(ascii: "b"))
            case 0x0C: out.append(0x5C); out.append(UInt8(ascii: "f"))
            case 0x0A: out.append(0x5C); out.append(UInt8(ascii: "n"))
            case 0x0D: out.append(0x5C); out.append(UInt8(ascii: "r"))
            case 0x09: out.append(0x5C); out.append(UInt8(ascii: "t"))
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 15)]])
            default: out.append(c)
            }
        }
        out.append(0x22)
    }

    /// JS String(v) — 키 · id 를 글로 바꿀 때 (String(t.id))
    public static func string(_ v: JSONValue?) -> String {
        guard let v else { return "undefined" }
        switch v {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return numberString(n)
        case let .string(s): return s
        case let .array(a):
            return a.map { x in
                if case .null = x { return "" }
                return string(x)
            }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// JS 의 참 같은 값 (truthy)
    public static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case let .bool(b): return b
        case let .number(n): return n != 0 && !n.isNaN
        case let .string(s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// 안정 정렬 (JS Array.prototype.sort 는 안정 정렬이다)
    public static func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { x, y in
            if less(x.element, y.element) { return true }
            if less(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }
}
