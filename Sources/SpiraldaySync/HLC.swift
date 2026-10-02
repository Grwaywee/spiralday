// 하이브리드 논리 시계 (HLC).
// 도장(Stamp) = 고정 폭 문자열: 밀리초 12자리 hex + 카운터 4자리 hex + 기기(노드) id 16자리 hex.
// 문자열 비교 = (시각, 카운터, 노드) 순서 비교.
import Foundation

public typealias Stamp = String

public enum Stamps {
    public static let maxT: Int64 = 0xFFFF_FFFF_FFFF
    public static let maxC = 0xFFFF
    /// 받은 도장이 이 기기 시계보다 이만큼 넘게 앞서면 시계를 그만큼만 따라간다 (모든 엔진이 같은 값)
    public static let maxDriftMs: Int64 = 24 * 3_600_000

    /// s 바로 다음 도장 (같은 시각 · 카운터 + 1, 이 노드). 끝에 닿으면 그대로
    public static func after(_ s: Stamp, node: String) -> Stamp {
        guard let p = parse(s) else { return s }
        if p.c < maxC { return make(t: p.t, c: p.c + 1, node: node) }
        if p.t < maxT { return make(t: p.t + 1, c: 0, node: node) }
        return make(t: p.t, c: p.c, node: node)
    }

    /// 16자리 소문자 hex
    public static func isNode(_ s: String) -> Bool {
        let u = s.utf8
        return u.count == 16 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func isStamp(_ s: String) -> Bool {
        let u = s.utf8
        return u.count == 32 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func make(t: Int64, c: Int, node: String) -> Stamp {
        precondition(t >= 0 && t <= maxT, "HLC 시각이 범위를 벗어남")
        precondition(c >= 0 && c <= maxC, "HLC 카운터가 범위를 벗어남")
        let th = String(t, radix: 16)
        let ch = String(c, radix: 16)
        return String(repeating: "0", count: 12 - th.count) + th + String(repeating: "0", count: 4 - ch.count) + ch + node
    }

    public static func parse(_ s: Stamp) -> (t: Int64, c: Int, node: String)? {
        guard isStamp(s) else { return nil }
        let u = Array(s.utf8)
        guard let t = Int64(String(decoding: u[0..<12], as: UTF8.self), radix: 16),
              let c = Int(String(decoding: u[12..<16], as: UTF8.self), radix: 16) else { return nil }
        return (t, c, String(decoding: u[16...], as: UTF8.self))
    }
}

/// 도장을 만드는 것 (진짜 시계 · 처음 가져오기용 0 시계)
public protocol StampSource: AnyObject {
    func next() -> Stamp
}

/// 진짜 시계. 엔진(actor)과 앱에 넣는 일(호스트의 MainActor 차례)이 같은 시계를 쓰므로 안에서 잠근다
public final class HLC: StampSource, @unchecked Sendable {
    public let node: String
    private let lock = NSLock()
    private var t: Int64 = 0
    private var c = 0
    private let wall: () -> Int64

    public init(node: String, last: Stamp? = nil, wall: @escaping () -> Int64) {
        precondition(Stamps.isNode(node), "HLC 노드 id 는 16자리 hex")
        self.node = node
        self.wall = wall
        if let last { observe(last) }
    }

    /// 지금 이 기기에서 일어난 일의 도장 (지금까지 본 모든 도장보다 크다)
    public func next() -> Stamp {
        let w = min(Stamps.maxT, max(0, wall()))
        return lock.withLock {
            if w > t {
                t = w
                c = 0
            } else if c < Stamps.maxC {
                c += 1
            } else if t < Stamps.maxT {
                // 카운터가 다 차면 논리 시각을 1ms 올린다
                t += 1
                c = 0
            }
            return Stamps.make(t: t, c: c, node: node)
        }
    }

    /// 다른 기기의 도장을 봤다: 다음 도장은 이것보다 크게.
    /// 이 기기 시계 + 하루 보다 앞선 도장은 그 시각까지만 따라가고 true 를 돌려준다 (시계가 많이 틀린 기기)
    @discardableResult
    public func observe(_ s: Stamp) -> Bool {
        guard var p = Stamps.parse(s) else { return false }
        let cap = min(Stamps.maxT, max(0, wall()) + Stamps.maxDriftMs)
        let skewed = p.t > cap
        if skewed {
            p.t = cap
            p.c = 0
        }
        lock.withLock {
            if p.t > t || (p.t == t && p.c > c) {
                t = p.t
                c = p.c
            }
        }
        return skewed
    }

    /// 지금까지 본 가장 큰 (시각, 카운터)
    public var last: Stamp { lock.withLock { Stamps.make(t: t, c: c, node: node) } }

}

/// 처음 가져오기(그룹에 합류하기 전부터 있던 기록)용 시계: 시각 0 에서 시작한다.
/// 그룹에 이미 있는 값과 부딪치면 그룹 값이 이긴다. 카운터는 가져온 순서를 지킨다.
public final class ZeroClock: StampSource {
    public let node: String
    private var t: Int64 = 0
    private var c = 0

    public init(node: String) {
        precondition(Stamps.isNode(node), "HLC 노드 id 는 16자리 hex")
        self.node = node
    }

    public func next() -> Stamp {
        c += 1
        if c > Stamps.maxC {
            t += 1
            c = 0
        }
        return Stamps.make(t: t, c: c, node: node)
    }
}
