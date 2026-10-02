// 레코드 상태(RecState)와 합치기(merge). 교환 · 결합 · 멱등 (ConvergenceTests)
//
// 레코드 상태 = 필드마다 (값, HLC 도장) + id 로 묶은 모음(할 일 · 메모 · D-day · 형광펜 …).
// 합치기는 반격자(join)다: 교환 · 결합 · 멱등.
//   - 필드: 도장이 큰 쪽 (같은 도장이면 값의 정규 JSON 이 큰 쪽)
//   - 모음 항목: a(더한 도장) = 최대, d(지운 도장) = 최대. 살아 있음 ⇔ d 가 없거나 a > d. d 이하 도장의 필드는 버린다.
//   - x(지움): 레코드 전체를 영구히 지운 표시.
import Foundation

public struct FieldEntry: Sendable, Equatable {
    public var value: JSONValue
    public var stamp: Stamp

    public init(_ value: JSONValue, _ stamp: Stamp) {
        self.value = value
        self.stamp = stamp
    }

    public static func == (a: FieldEntry, b: FieldEntry) -> Bool { a.value == b.value && JS.same(a.stamp, b.stamp) }
}

public struct ItemState: Sendable, Equatable {
    /// 더한 도장 ("" = 이 조각에는 없음)
    public var a: Stamp
    /// 지운 도장
    public var d: Stamp?
    public var f: [String: FieldEntry]

    public init(a: Stamp, d: Stamp? = nil, f: [String: FieldEntry] = [:]) {
        self.a = a
        self.d = d
        self.f = f
    }

    public var isAlive: Bool {
        guard let d else { return true }
        return JS.less(d, a)
    }
}

public struct RecState: Sendable, Equatable {
    public var f: [String: FieldEntry]
    public var c: [String: [String: ItemState]]
    /// 레코드를 영구히 지운 도장
    public var x: Stamp?

    public init(f: [String: FieldEntry] = [:], c: [String: [String: ItemState]] = [:], x: Stamp? = nil) {
        self.f = f
        self.c = c
        self.x = x
    }

    /// 상태끼리 같은지 (빈 모음은 없는 것과 같다)
    public static func == (a: RecState, b: RecState) -> Bool { CRDT.stateKey(a) == CRDT.stateKey(b) }
}

public enum CRDT {
    static func sameStamp(_ a: Stamp?, _ b: Stamp?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return JS.same(x, y)
        default: return false
        }
    }

    static func maxS(_ a: Stamp?, _ b: Stamp?) -> Stamp? {
        guard let a else { return b }
        guard let b else { return a }
        return JS.greaterOrEqual(a, b) ? a : b
    }

    static func pick(_ x: FieldEntry?, _ y: FieldEntry?) -> FieldEntry? {
        guard let x else { return y }
        guard let y else { return x }
        if JS.less(y.stamp, x.stamp) { return x }
        if JS.less(x.stamp, y.stamp) { return y }
        // 같은 도장인데 값이 다르면 정규 JSON 이 큰 쪽
        return JS.greaterOrEqual(x.value.canonical, y.value.canonical) ? x : y
    }

    @discardableResult
    static func mergeFields(_ into: inout [String: FieldEntry], _ from: [String: FieldEntry]) -> Bool {
        var changed = false
        for (k, fe) in from {
            let cur = into[k]
            guard let win = pick(cur, fe) else { continue }
            if let cur, win == cur { continue }
            into[k] = win
            changed = true
        }
        return changed
    }

    /// d 이하 도장의 필드 버리기
    static func gcItem(_ it: inout ItemState) {
        guard let d = it.d else { return }
        it.f = it.f.filter { JS.less(d, $0.value.stamp) }
    }

    static func mergeItem(_ into: inout ItemState, _ from: ItemState) -> Bool {
        var changed = false
        let a = maxS(into.a, from.a) ?? ""
        if !JS.same(a, into.a) {
            into.a = a
            changed = true
        }
        let d = maxS(into.d, from.d)
        if !sameStamp(d, into.d) {
            into.d = d
            changed = true
        }
        if mergeFields(&into.f, from.f) { changed = true }
        let before = into.f.count
        gcItem(&into)
        if into.f.count != before { changed = true }
        return changed
    }

    /// from 을 into 에 합친다. 바뀐 것이 있으면 true
    @discardableResult
    public static func mergeInto(_ into: inout RecState, _ from: RecState) -> Bool {
        if let x = maxS(into.x, from.x) {
            let changed = !sameStamp(into.x, x) || !into.f.isEmpty || !into.c.isEmpty
            into.x = x
            into.f = [:]
            into.c = [:]
            return changed
        }
        var changed = mergeFields(&into.f, from.f)
        for (name, src) in from.c {
            var dst = into.c[name] ?? [:]
            for (id, s) in src {
                if var cur = dst[id] {
                    if mergeItem(&cur, s) {
                        changed = true
                        dst[id] = cur
                    }
                } else {
                    var copy = ItemState(a: s.a, d: s.d, f: [:])
                    mergeFields(&copy.f, s.f)
                    gcItem(&copy)
                    dst[id] = copy
                    changed = true
                }
            }
            into.c[name] = dst
        }
        return changed
    }

    public static func merge(_ a: RecState, _ b: RecState) -> RecState {
        var out = RecState()
        mergeInto(&out, a)
        mergeInto(&out, b)
        return out
    }

    /// 비교 · 직렬화용: 빈 모음을 뺀 모양
    public static func normalize(_ s: RecState) -> RecState {
        if let x = s.x { return RecState(x: x) }
        return RecState(f: s.f, c: s.c.filter { !$0.value.isEmpty })
    }

    /// 상태 → JSON (payload 의 "s", 저장소). 빈 모음은 쓰지 않는다
    public static func toJSON(_ s0: RecState) -> JSONValue {
        let s = normalize(s0)
        var o: [String: JSONValue] = [:]
        o["f"] = fieldsJSON(s.f)
        var c: [String: JSONValue] = [:]
        for (name, items) in s.c {
            var m: [String: JSONValue] = [:]
            for (id, it) in items {
                var io: [String: JSONValue] = ["a": .string(it.a), "f": fieldsJSON(it.f)]
                if let d = it.d { io["d"] = .string(d) }
                m[id] = .object(io)
            }
            c[name] = .object(m)
        }
        o["c"] = .object(c)
        if let x = s.x { o["x"] = .string(x) }
        return .object(o)
    }

    static func fieldsJSON(_ f: [String: FieldEntry]) -> JSONValue {
        .object(f.mapValues { .array([$0.value, .string($0.stamp)]) })
    }

    /// 상태의 정규 문자열 (같은 상태 = 같은 글자)
    public static func stateKey(_ s: RecState) -> String { toJSON(s).canonical }

    /// 빈 조각인지 (합쳐도 바뀌는 것이 없는)
    public static func isEmptyDelta(_ s: RecState) -> Bool {
        s.x == nil && s.f.isEmpty && s.c.values.allSatisfy(\.isEmpty)
    }

    /// 이 기기의 편집 조각(delta)의 도장을 지금 상태(state)에서 그 필드 · 항목이 가진 도장보다 크게 올린다.
    /// 보통은 아무것도 하지 않는다 (HLC 가 본 모든 도장보다 큰 도장을 준다). 시계가 크게 앞선 기기의 도장을 HLC 가
    /// 다 따라가지 않을 때 "본 뒤에 고친 것이 이긴다" 를 필드마다 지킨다
    public static func liftDelta(_ delta: inout RecState, _ state: RecState, node: String) {
        func above(_ s: Stamp, _ floor: Stamp?) -> Stamp {
            guard let floor, Stamps.isStamp(floor), !JS.less(floor, s) else { return s }
            return Stamps.after(floor, node: node)
        }
        for k in Array(delta.f.keys) {
            if let cur = state.f[k] { delta.f[k]!.stamp = above(delta.f[k]!.stamp, cur.stamp) }
        }
        for name in Array(delta.c.keys) {
            guard let have = state.c[name] else { continue }
            for id in Array(delta.c[name]!.keys) {
                guard let cur = have[id] else { continue }
                var it = delta.c[name]![id]!
                if !it.a.isEmpty {
                    // 더하기(다시 더하기): 있던 a · d 보다 크게. 필드도 a 보다 작으면 지운 도장 이하로 버려지므로 함께 올린다
                    let a = above(above(it.a, cur.a.isEmpty ? nil : cur.a), cur.d)
                    it.a = a
                    for k in Array(it.f.keys) {
                        var s = JS.less(it.f[k]!.stamp, a) ? a : it.f[k]!.stamp
                        s = above(s, cur.f[k]?.stamp)
                        it.f[k]!.stamp = s
                    }
                } else {
                    for k in Array(it.f.keys) { it.f[k]!.stamp = above(it.f[k]!.stamp, cur.f[k]?.stamp) }
                }
                // 지우기: 있던 a 보다 커야 지워진다
                if let d = it.d { it.d = above(d, cur.a.isEmpty ? nil : cur.a) }
                delta.c[name]![id] = it
            }
        }
    }

    /// frag(받았지만 아직 서버에서 확인되지 않은 초안 조각)에서 by(서버 버전 · 내가 올린 상태)가 이미 덮는 것을 지운다 (frag 를 바꾼다).
    /// 덮음 = by 와 합쳐도 by 가 바뀌지 않음: 필드는 by 의 도장 ≥ 조각의 도장, 항목 필드는 그것 또는 by 의 항목 d ≥ 도장(버려짐),
    /// 항목 a · d 는 by 의 것 ≥. by 에 x 가 있으면 모두 덮는다. 다 지워지면 빈 조각 (isEmptyDelta). Docs/SpiraldaySync.md §7.7 (확인 대기)
    public static func dropCovered(_ frag: inout RecState, by: RecState) {
        if by.x != nil {
            frag = RecState()
            return
        }
        for k in Array(frag.f.keys) {
            if let b = by.f[k], JS.greaterOrEqual(b.stamp, frag.f[k]!.stamp) { frag.f[k] = nil }
        }
        for name in Array(frag.c.keys) {
            var items = frag.c[name]!
            let have = by.c[name] ?? [:]
            for id in Array(items.keys) {
                var it = items[id]!
                if let b = have[id] {
                    for k in Array(it.f.keys) {
                        let st = it.f[k]!.stamp
                        if let d = b.d, !JS.less(d, st) {
                            it.f[k] = nil
                        } else if let bf = b.f[k], JS.greaterOrEqual(bf.stamp, st) {
                            it.f[k] = nil
                        }
                    }
                    if !it.a.isEmpty, !b.a.isEmpty, JS.greaterOrEqual(b.a, it.a) { it.a = "" }
                    if let d = it.d, let bd = b.d, JS.greaterOrEqual(bd, d) { it.d = nil }
                }
                if it.a.isEmpty, it.d == nil, it.f.isEmpty { items[id] = nil } else { items[id] = it }
            }
            if items.isEmpty { frag.c[name] = nil } else { frag.c[name] = items }
        }
    }

    /// 상태에 들어 있는 가장 큰 도장 (HLC 에 알려 주려고)
    public static func maxStamp(in s: RecState) -> Stamp? {
        var m: Stamp? = s.x
        func see(_ t: Stamp?) {
            guard let t, !t.isEmpty else { return }
            if m == nil || JS.less(m!, t) { m = t }
        }
        for e in s.f.values { see(e.stamp) }
        for items in s.c.values {
            for it in items.values {
                see(it.a)
                see(it.d)
                for e in it.f.values { see(e.stamp) }
            }
        }
        return m
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// 받은 JSON 이 RecState 모양인지 검사 (모양이 틀리면 던진다). "__proto__" 키는 버린다
    public static func parseState(_ v: JSONValue?) throws -> RecState {
        func stamp(_ t: JSONValue?, allowEmpty: Bool = false) throws -> Stamp {
            guard case let .string(s)? = t, allowEmpty || !s.isEmpty, s.utf16.count <= 64 else {
                throw ParseError(description: "상태: 도장이 틀림")
            }
            return s
        }
        func fields(_ o: JSONValue?) throws -> [String: FieldEntry] {
            guard case let .object(m)? = o else { throw ParseError(description: "상태: 필드가 객체가 아님") }
            var out: [String: FieldEntry] = [:]
            for (k, e) in m where k != "__proto__" {
                guard case let .array(pair) = e, pair.count == 2 else { throw ParseError(description: "상태: 필드 \(k) 모양이 틀림") }
                out[k] = FieldEntry(pair[0], try stamp(pair[1]))
            }
            return out
        }
        guard case let .object(o)? = v else { throw ParseError(description: "상태가 객체가 아님") }
        var out = RecState(f: o.keys.contains("f") ? try fields(o["f"]) : [:])
        if o.keys.contains("x") { out.x = try stamp(o["x"]) }
        if let cv = o["c"] {
            guard case let .object(cols) = cv else { throw ParseError(description: "상태: 모음이 객체가 아님") }
            for (name, items) in cols where name != "__proto__" {
                guard case let .object(im) = items else { throw ParseError(description: "상태: 모음 \(name) 이 객체가 아님") }
                var m: [String: ItemState] = [:]
                for (id, it) in im where id != "__proto__" {
                    guard case let .object(io) = it else { throw ParseError(description: "상태: 항목 \(id) 가 객체가 아님") }
                    var aRaw: JSONValue = .string("")
                    if let a = io["a"], !a.isNull { aRaw = a }
                    var item = ItemState(a: try stamp(aRaw, allowEmpty: true), f: io.keys.contains("f") ? try fields(io["f"]) : [:])
                    if io.keys.contains("d") { item.d = try stamp(io["d"]) }
                    m[id] = item
                }
                out.c[name] = m
            }
        }
        return out
    }
}
