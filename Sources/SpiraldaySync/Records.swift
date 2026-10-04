// 앱 데이터 ↔ 동기화 레코드 (레코드 키 · 평평한 모양 · 비교 · 상태 → 앱 값).
//
// 레코드 (키는 암호문 안에만 있고, 서버는 HMAC 한 rid 만 본다):
//   b/<BOOKID>              책 정보 (이름 · 기간 · 표지 · 만든 때)
//   p/<BOOKID>              책의 설정 (형광펜 · 저장한 D-day · 기본 컬러 · 첫 장의 말)
//   d/<BOOKID>/<yyyy-MM-dd> 하루
//   w/<BOOKID>/<yyyy-MM-dd> 한 주 (월요일)
//   l                       책장 수준 설정 (기기마다 따로가 아닌 것)
// 기기마다 따로 (동기화하지 않음): library.activeID · sampleSeeded, 예시 플래너(isSample) 전부, prefs.lastKind · ddaysPerDay.
import Foundation

// MARK: - 키

public enum RecordKind: String, Sendable {
    case book, prefs, day, week, lib
}

public struct ParsedKey: Sendable, Equatable {
    public let kind: RecordKind
    public let bookId: String?
    public let date: String?
}

public enum RecordKeys {
    public static let lib = "l"
    public static func book(_ id: String) -> String { "b/\(id.uppercased())" }
    public static func prefs(_ id: String) -> String { "p/\(id.uppercased())" }
    public static func day(_ id: String, _ date: String) -> String { "d/\(id.uppercased())/\(date)" }
    public static func week(_ id: String, _ date: String) -> String { "w/\(id.uppercased())/\(date)" }

    public static func parse(_ key: String) -> ParsedKey? {
        if key == lib { return ParsedKey(kind: .lib, bookId: nil, date: nil) }
        let u = Array(key.utf8)
        guard u.count == 38 || u.count == 49, u[1] == UInt8(ascii: "/") else { return nil }
        let kind: RecordKind
        switch u[0] {
        case UInt8(ascii: "b"): kind = .book
        case UInt8(ascii: "p"): kind = .prefs
        case UInt8(ascii: "d"): kind = .day
        case UInt8(ascii: "w"): kind = .week
        default: return nil
        }
        let id = String(decoding: u[2..<38], as: UTF8.self)
        guard isUpperUuid(id) else { return nil }
        let dated = kind == .day || kind == .week
        if u.count == 38 { return dated ? nil : ParsedKey(kind: kind, bookId: id, date: nil) }
        guard dated, u[38] == UInt8(ascii: "/") else { return nil }
        let date = String(decoding: u[39...], as: UTF8.self)
        guard isDateKey(date) else { return nil }
        return ParsedKey(kind: kind, bookId: id, date: date)
    }

    /// yyyy-MM-dd (숫자 모양만)
    public static func isDateKey(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 10 else { return false }
        for (i, c) in u.enumerated() {
            if i == 4 || i == 7 {
                if c != UInt8(ascii: "-") { return false }
            } else if c < 0x30 || c > 0x39 {
                return false
            }
        }
        return true
    }

    static func uuidShape(_ s: String, upperOnly: Bool) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return false }
                continue
            }
            let digit = c >= 0x30 && c <= 0x39
            let upper = c >= 0x41 && c <= 0x46
            let lower = c >= 0x61 && c <= 0x66
            if !(digit || upper || (!upperOnly && lower)) { return false }
        }
        return true
    }

    static func isUpperUuid(_ s: String) -> Bool { uuidShape(s, upperOnly: true) }

    /// UUID 모양 (대소문자 무관)
    public static func isUuid(_ v: JSONValue?) -> Bool {
        guard case let .string(s)? = v else { return false }
        return uuidShape(s, upperOnly: false)
    }

    public static func isUuid(_ s: String) -> Bool { uuidShape(s, upperOnly: false) }
}

// MARK: - 평평한 모양

public struct FlatItem: Sendable, Equatable {
    public var id: String
    public var f: [String: JSONValue]

    public static func == (a: FlatItem, b: FlatItem) -> Bool { JS.same(a.id, b.id) && JSONValue.object(a.f) == JSONValue.object(b.f) }
}

/// 앱 값을 비교하기 좋게 편 것: 단일 필드 + id 로 묶은 모음
public struct Flat: Sendable, Equatable {
    public var s: [String: JSONValue]
    public var c: [String: [FlatItem]]

    public init(s: [String: JSONValue] = [:], c: [String: [FlatItem]] = [:]) {
        self.s = s
        self.c = c
    }

    public static func == (a: Flat, b: Flat) -> Bool {
        guard JSONValue.object(a.s) == JSONValue.object(b.s), a.c.count == b.c.count else { return false }
        for (k, xs) in a.c {
            guard let ys = b.c[k], xs == ys else { return false }
        }
        return true
    }

    /// 저장소에 둘 JSON
    public var json: JSONValue {
        .object([
            "s": .object(s),
            "c": .object(c.mapValues { .array($0.map { .object(["id": .string($0.id), "f": .object($0.f)]) }) }),
        ])
    }

    public init?(json v: JSONValue?) {
        guard case let .object(o)? = v, case let .object(s)? = o["s"], case let .object(c)? = o["c"] else { return nil }
        var cols: [String: [FlatItem]] = [:]
        for (k, arr) in c {
            guard case let .array(items) = arr else { return nil }
            var list: [FlatItem] = []
            for it in items {
                guard case let .string(id)? = it["id"], case let .object(f)? = it["f"] else { return nil }
                list.append(FlatItem(id: id, f: f))
            }
            cols[k] = list
        }
        self.init(s: s, c: cols)
    }
}

struct Schema: Sendable {
    /// 단일 필드의 기본값 (도장이 없을 때 · 앱에 없을 때)
    let scalarDefault: @Sendable (String) -> JSONValue
    /// 모음 이름 → 항목 필드 기본값 (순서대로)
    let items: [(String, [String: JSONValue])]
    /// 순서를 따로 적는 모음 ('o:<이름>' 필드)
    let ordered: [String]
    /// 단일 필드를 비교하는 순서 (모든 엔진이 같은 순서 — 같은 시계면 같은 도장이 나오게)
    var scalarOrder: [String] = []
    /// 모음 이름 → 항목 필드를 비교하는 순서
    var itemOrder: [String: [String]] = [:]
}

/// 비교할 키의 순서: 알려진 키(정해진 순서) → 지금 값의 나머지 키 → 예전 값에만 있는 키 (나머지는 JS 정렬 순서)
func diffKeys(_ cur: [String: JSONValue], _ prev: [String: JSONValue], known: [String]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for k in known where cur[k] != nil && seen.insert(k).inserted { out.append(k) }
    for k in cur.keys.sorted(by: JS.less) where seen.insert(k).inserted { out.append(k) }
    for k in known where prev[k] != nil && seen.insert(k).inserted { out.append(k) }
    for k in prev.keys.sorted(by: JS.less) where seen.insert(k).inserted { out.append(k) }
    return out
}

let XP = "x:" // 모르는(새 버전) 키
let OP = "o:" // 모음 순서

/// JS `v ?? def` (없거나 null 이면 def)
@inline(__always)
func nn(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
}

func extrasOf(_ o: [String: JSONValue], known: Set<String>, into: inout [String: JSONValue]) {
    for (k, v) in o where !known.contains(k) { into[XP + k] = v }
}

/// x: 필드를 앱 값으로 옮긴다 (null 은 없음). 프로토타입을 바꾸는 키(__proto__)는 옮기지 않는다.
/// 앱이 아는 키(known)는 x: 로 덮어쓰지 않는다 — 비교는 그런 x: 를 만들지 않으므로 받은 상태를 꾸며 넣었을 때만이고,
/// 덮어쓰면 앱이 파일을 읽지 못할 수 있다
func putExtras(_ f: [String: FieldEntry], into: inout [String: JSONValue], known: Set<String>) {
    for (k, e) in f where k.hasPrefix(XP) && k != XP + "__proto__" {
        let name = String(k.dropFirst(XP.count))
        if known.contains(name) { continue }
        if !e.value.isNull { into[name] = e.value }
    }
}

// MARK: - 하루

let DAY_KNOWN: Set<String> = ["tasks", "slots", "comment", "memoTags", "memos", "theme", "notes", "ddays", "dayOff"]
let TASK_KNOWN: Set<String> = ["id", "text", "mark", "cat", "carriedFrom", "row"]
let NOTE_KNOWN: Set<String> = ["id", "kind", "start", "end", "text"]
let DDAY_KNOWN: Set<String> = ["id", "title", "date", "source"]
let EMPTY_ROW: JSONValue = .array(Array(repeating: .number(-1), count: PlannerModel.slotsPerRow))
let EMPTY_LIST: JSONValue = .array([])

public func slotField(_ row: Int) -> String { row < 10 ? "s0\(row)" : "s\(row)" }
let SLOT_FIELDS = (0..<PlannerModel.slotRows).map(slotField)

func isSlotField(_ k: String) -> Bool {
    let u = Array(k.utf8)
    return u.count == 3 && u[0] == UInt8(ascii: "s") && u[1] >= 0x30 && u[1] <= 0x39 && u[2] >= 0x30 && u[2] <= 0x39
}

/// 메모 · 메모 태그는 줄마다 필드: m0 m1 m2 · mt0 mt1 mt2 (두 기기가 서로 다른 줄을 같이 고쳐도 둘 다 남는다).
/// memoCount 를 넘는 줄(예전 파일)은 m+ · mt+ 에 통째로 (문자열 배열, 기본 []).
public func memoField(_ tags: Bool, _ line: Int) -> String { (tags ? "mt" : "m") + String(line) }
public func memoRestField(_ tags: Bool) -> String { tags ? "mt+" : "m+" }
let MEMO_FIELDS = (0..<PlannerModel.memoCount).map { memoField(false, $0) } + [memoRestField(false)]
let MEMO_TAG_FIELDS = (0..<PlannerModel.memoCount).map { memoField(true, $0) } + [memoRestField(true)]

/// m0 … m(memoCount-1) · mt0 … (/^mt?\d$/ 이고 줄 번호 < memoCount)
func isMemoLineField(_ k: String) -> Bool {
    let u = Array(k.utf8)
    let digit: UInt8
    if u.count == 2, u[0] == UInt8(ascii: "m") { digit = u[1] } else if u.count == 3, u[0] == UInt8(ascii: "m"), u[1] == UInt8(ascii: "t") { digit = u[2] } else { return false }
    return digit >= 0x30 && digit <= 0x39 && Int(digit - 0x30) < PlannerModel.memoCount
}

func isMemoRestField(_ k: String) -> Bool { k == "m+" || k == "mt+" }

let DAY_SCHEMA = Schema(
    scalarDefault: { k in
        if isSlotField(k) { return EMPTY_ROW }
        if isMemoLineField(k) { return "" }
        if isMemoRestField(k) { return EMPTY_LIST }
        switch k {
        case "comment": return ""
        case "dayOff": return false
        default: return .null
        }
    },
    items: [
        ("tasks", ["text": "", "mark": 0, "cat": .null, "carriedFrom": .null, "row": .null]),
        ("notes", ["kind": "text", "start": 0, "end": 0, "text": ""]),
        ("ddays", ["title": "", "date": .null, "source": .null]),
    ],
    ordered: ["ddays"],
    scalarOrder: ["comment", "theme", "dayOff"] + MEMO_FIELDS + MEMO_TAG_FIELDS + SLOT_FIELDS,
    itemOrder: ["tasks": ["text", "mark", "cat", "carriedFrom", "row"], "notes": ["kind", "start", "end", "text"], "ddays": ["title", "date", "source"]])

func padStrings(_ a: JSONValue?) -> [String] {
    var arr: [String] = []
    if case let .array(xs)? = a { arr = xs.map { $0.stringValue ?? "" } }
    while arr.count < PlannerModel.memoCount { arr.append("") }
    return arr
}

/// memos / memoTags → m0 m1 m2 m+ (줄마다)
func putMemoLines(_ s: inout [String: JSONValue], _ tags: Bool, _ a: JSONValue?) {
    let arr = padStrings(a)
    for i in 0..<PlannerModel.memoCount { s[memoField(tags, i)] = .string(arr[i]) }
    s[memoRestField(tags)] = .array(arr.dropFirst(PlannerModel.memoCount).map { .string($0) })
}

/// m0 m1 m2 m+ → memos / memoTags (늘 memoCount 줄 이상)
func memoLines(_ f: [String: FieldEntry], _ tags: Bool) -> [String] {
    var out: [String] = []
    for i in 0..<PlannerModel.memoCount { out.append(f[memoField(tags, i)]?.value.stringValue ?? "") }
    if case let .array(xs)? = f[memoRestField(tags)]?.value { out += xs.map { $0.stringValue ?? "" } }
    return out
}

func ddayItem(_ d: [String: JSONValue]) -> FlatItem {
    var f: [String: JSONValue] = ["title": nn(d["title"]) ?? "", "date": nn(d["date"]) ?? .null, "source": nn(d["source"]) ?? .null]
    extrasOf(d, known: DDAY_KNOWN, into: &f)
    return FlatItem(id: JS.string(d["id"]).uppercased(), f: f)
}

/// 배열의 객체들 (JS `for (const t of r.tasks ?? [])` — 객체가 아닌 것은 빈 객체로)
func objects(_ v: JSONValue?) -> [[String: JSONValue]] {
    guard case let .array(xs)? = v else { return [] }
    return xs.map { $0.objectValue ?? [:] }
}

public enum Records {
    public static func flattenDay(_ v: JSONValue?) -> Flat {
        var s: [String: JSONValue] = [:]
        var c: [String: [FlatItem]] = ["tasks": [], "notes": [], "ddays": []]
        guard let v = nn(v) else { return Flat(s: s, c: c) }
        let r = v.objectValue ?? [:]
        s["comment"] = .string(r["comment"]?.stringValue ?? "")
        s["theme"] = r["theme"]?.isInteger == true ? r["theme"]! : .null
        s["dayOff"] = .bool(r["dayOff"]?.boolValue == true)
        putMemoLines(&s, false, r["memos"])
        putMemoLines(&s, true, r["memoTags"])
        let slots = r["slots"]?.arrayValue ?? []
        for i in 0..<PlannerModel.slotRows {
            var row: [JSONValue] = []
            for j in 0..<PlannerModel.slotsPerRow {
                let k = i * PlannerModel.slotsPerRow + j
                if k < slots.count, slots[k].isInteger { row.append(slots[k]) } else { row.append(.number(-1)) }
            }
            s[slotField(i)] = .array(row)
        }
        extrasOf(r, known: DAY_KNOWN, into: &s)
        for t in objects(r["tasks"]) {
            var f: [String: JSONValue] = [
                "text": nn(t["text"]) ?? "",
                "mark": nn(t["mark"]) ?? 0,
                "cat": nn(t["cat"]) ?? .null,
                "carriedFrom": JS.truthy(t["carriedFrom"]) ? .string(JS.string(t["carriedFrom"]).uppercased()) : .null,
                "row": nn(t["row"]) ?? .null,
            ]
            extrasOf(t, known: TASK_KNOWN, into: &f)
            c["tasks"]!.append(FlatItem(id: JS.string(t["id"]).uppercased(), f: f))
        }
        for n in objects(r["notes"]) {
            var f: [String: JSONValue] = [
                "kind": nn(n["kind"]) ?? "text",
                "start": nn(n["start"]) ?? 0,
                "end": nn(n["end"]) ?? 0,
                "text": nn(n["text"]) ?? "",
            ]
            extrasOf(n, known: NOTE_KNOWN, into: &f)
            c["notes"]!.append(FlatItem(id: JS.string(n["id"]).uppercased(), f: f))
        }
        for d in objects(r["ddays"]) { c["ddays"]!.append(ddayItem(d)) }
        return Flat(s: s, c: c)
    }

    // MARK: 한 주

    static let WEEK_KNOWN: Set<String> = ["goal", "review", "stars"]
    static let WEEK_SCHEMA = Schema(
        scalarDefault: { k in
            if k == "goal" || k == "review" { return "" }
            if k == "stars" { return 0 }
            return .null
        },
        items: [], ordered: [], scalarOrder: ["goal", "review", "stars"])

    public static func flattenWeek(_ v: JSONValue?) -> Flat {
        var s: [String: JSONValue] = [:]
        guard let v = nn(v) else { return Flat(s: s, c: [:]) }
        let w = v.objectValue ?? [:]
        s["goal"] = .string(w["goal"]?.stringValue ?? "")
        s["review"] = .string(w["review"]?.stringValue ?? "")
        s["stars"] = w["stars"]?.isInteger == true ? w["stars"]! : 0
        extrasOf(w, known: WEEK_KNOWN, into: &s)
        return Flat(s: s, c: [:])
    }

    // MARK: 책 설정

    /// lastKind · ddaysPerDay 는 기기마다 따로
    static let PREFS_LOCAL = ["lastKind", "ddaysPerDay"]
    static let PREFS_KNOWN: Set<String> = ["categories", "ddays", "defaultTheme", "mottoText", "lastKind", "ddaysPerDay"]
    static let CAT_KNOWN: Set<String> = ["id", "name", "hex", "counts"]
    static let PREFS_SCHEMA = Schema(
        scalarDefault: { k in k == "defaultTheme" ? 0 : .null },
        items: [
            ("categories", ["name": "", "hex": "CFCFD4", "counts": true]),
            ("ddays", ["title": "", "date": .null, "source": .null]),
        ],
        ordered: ["categories", "ddays"],
        scalarOrder: ["defaultTheme", "mottoText"],
        itemOrder: ["categories": ["name", "hex", "counts"], "ddays": ["title", "date", "source"]])

    /// 형광펜 목록이 앱의 기본 형광펜 그대로인지 (같은 순서 · id · name · hex · counts, 모르는 키 없음).
    /// 그대로면 "아무도 정하지 않은 값" 이다 — 앱(디코더 · 새 책 · 빈 목록 채우기)이 채운 값과 사용자가 둔 값을 구별할 수 없다.
    /// 비교는 이것을 도장이 없는 "설정 안 됨" 으로 본다 (비공개 docs/sync-engine.md §4.1). 2026-10-04 사고: 처음 켠 기기가 채운
    /// 기본 형광펜이 그룹을 만든 기기의 형광펜을 이겼다. TS isDefaultCategoryList 와 같다
    public static func isDefaultCategoryList(_ items: [FlatItem]) -> Bool {
        guard items.count == defaultCategoryItems.count else { return false }
        for (it, d) in zip(items, defaultCategoryItems) {
            guard it.id == d.id, it.f.count == 3, it.f["name"] == d.f["name"], it.f["hex"] == d.f["hex"], it.f["counts"] == d.f["counts"] else { return false }
        }
        return true
    }

    /// 기본 형광펜의 평평한 모양 ("설정 안 됨" 에서 바뀔 때의 지난 값)
    static let defaultCategoryItems: [FlatItem] = PlannerModel.defaultCategories.map { c in
        FlatItem(id: JS.string(c["id"]), f: ["name": c["name"] ?? "", "hex": c["hex"] ?? "", "counts": c["counts"] ?? false])
    }

    /// 상태 → 앱 값에 보이는 항목인지. 살아 있어야 하고, 기본값 도장으로만 더한 항목(a = Stamps.defaultStamp — 기기가 본 기본 형광펜)은
    /// 그 모음의 순서 목록(o:)이 있으면 그 목록에 있을 때만 보인다. 순서 목록은 누군가 진짜 도장으로 적은 실제 목록이라, 거기에 없는
    /// 기본 id 는 그 목록을 가진 기기에 없던 형광펜이다 — 예전 엔진은 그룹을 만들기 전에 지운 형광펜에 지움 표시를 남기지 않았다
    /// (2026-10-04 사고의 5). 순서 목록이 없으면 보인다. 비공개 docs/sync-engine.md §4.1 · §5 — TS isShown 과 같다
    public static func isShown(_ st: RecState, _ col: String, _ id: String, _ it: ItemState) -> Bool {
        guard it.isAlive else { return false }
        guard it.a == Stamps.defaultStamp else { return true }
        guard case let .array(order)? = st.f[OP + col]?.value else { return true }
        return order.contains(.string(id))
    }

    public static func flattenPrefs(_ v: JSONValue?) -> Flat {
        var s: [String: JSONValue] = [:]
        var c: [String: [FlatItem]] = ["categories": [], "ddays": []]
        guard let v = nn(v) else { return Flat(s: s, c: c) }
        let p = v.objectValue ?? [:]
        s["defaultTheme"] = p["defaultTheme"]?.isInteger == true ? p["defaultTheme"]! : 0
        if case let .string(m)? = p["mottoText"], !m.isEmpty { s["mottoText"] = .string(m) } else { s["mottoText"] = .null }
        extrasOf(p, known: PREFS_KNOWN, into: &s)
        for cat in objects(p["categories"]) {
            var f: [String: JSONValue] = ["name": nn(cat["name"]) ?? "", "hex": nn(cat["hex"]) ?? "", "counts": .bool(cat["counts"]?.boolValue == true)]
            extrasOf(cat, known: CAT_KNOWN, into: &f)
            c["categories"]!.append(FlatItem(id: JS.string(cat["id"]), f: f))
        }
        for d in objects(p["ddays"]) { c["ddays"]!.append(ddayItem(d)) }
        return Flat(s: s, c: c)
    }

    // MARK: 책 정보

    static let BOOK_KNOWN: Set<String> = ["name", "start", "end", "cover", "created", "id", "isSample"]
    static let BOOK_SCHEMA = Schema(
        scalarDefault: { k in k == "name" ? "" : k == "cover" ? 0 : .null },
        items: [], ordered: [], scalarOrder: ["name", "start", "end", "cover", "created"])

    public static func flattenBook(_ v: JSONValue?) -> Flat {
        var s: [String: JSONValue] = [:]
        guard let v = nn(v) else { return Flat(s: s, c: [:]) }
        let b = v.objectValue ?? [:]
        s["name"] = .string(b["name"]?.stringValue ?? "")
        s["start"] = b["start"]?.stringValue.map { .string($0) } ?? .null
        s["end"] = b["end"]?.stringValue.map { .string($0) } ?? .null
        s["cover"] = b["cover"]?.isInteger == true ? b["cover"]! : 0
        s["created"] = b["created"]?.stringValue.map { .string($0) } ?? .null
        extrasOf(b, known: BOOK_KNOWN, into: &s)
        return Flat(s: s, c: [:])
    }

    // MARK: 책장 수준 설정

    static let LIB_SCHEMA = Schema(scalarDefault: { _ in .null }, items: [], ordered: [])

    /// 앱이 넘긴 책장 설정 (모든 기기가 같이 쓰는 것만)
    public static func flattenLib(_ v: JSONValue?) -> Flat {
        var s: [String: JSONValue] = [:]
        if let o = nn(v)?.objectValue { extrasOf(o, known: [], into: &s) }
        return Flat(s: s, c: [:])
    }

    static func schema(_ kind: RecordKind) -> Schema {
        switch kind {
        case .day: return DAY_SCHEMA
        case .week: return WEEK_SCHEMA
        case .prefs: return PREFS_SCHEMA
        case .book: return BOOK_SCHEMA
        case .lib: return LIB_SCHEMA
        }
    }

    public static func flatten(_ kind: RecordKind, _ v: JSONValue?) -> Flat {
        switch kind {
        case .day: return flattenDay(v)
        case .week: return flattenWeek(v)
        case .prefs: return flattenPrefs(v)
        case .book: return flattenBook(v)
        case .lib: return flattenLib(v)
        }
    }

    // MARK: - 비교 (지난 그림자 → 지금 값) → 바뀐 필드에 새 도장

    /// prev(마지막으로 맞춘 값, 없으면 빈 값) 와 cur 를 비교해 바뀐 것만 담은 조각.
    /// 새 항목: a 와 모든 필드에 같은 새 도장. 사라진 항목: d. 고친 필드: 새 도장. 도장은 앱의 순서대로 매긴다.
    /// 그림자에 있던 x: 필드(모르는 키)가 지금 값에 없으면 바뀐 것으로 보지 않는다 — 모르는 키를 버리는 앱
    /// (모델로 읽고 다시 쓰는 iOS · Windows)이 새 버전 기기의 값을 null 로 지우지 않게. 지우려면 null 을 넘긴다
    ///
    /// 책 설정의 형광펜 (비공개 docs/sync-engine.md §4.1 — TS diffFlat 과 같은 바이트). base = 그 레코드의 지금 상태 (없으면 빈 상태):
    ///   - 지난 값이 기본 형광펜(또는 빈 목록 — 설정 안 됨)이고 지금도 기본 형광펜 그대로면 바뀐 것이 없다. 앱이 채운 기본값은 도장을 받지 않는다.
    ///   - 지난 값이 기본 형광펜(설정 안 됨)이고 지금 값이 다르면 (사용자가 처음 형광펜을 고침 · 그룹을 만든 기기의 첫 가져오기):
    ///     지난 값 = 기본 형광펜으로 비교하되, 지금도 있는 기본 항목은 a 와 그대로인 필드를 기본값 도장(Stamps.defaultStamp, 어떤 도장보다
    ///     작다)으로, 바뀐 필드만 새 도장으로 모두 적는다 (반쪽 항목이 없게). 목록에 없는 기본 id 는 지움(새 도장).
    ///     그래서 두 기기가 따로 기본 형광펜의 서로 다른 것을 고쳐도 둘 다 남고(필드마다), 이 기기가 본 기본값은 다른 기기의 진짜 값을
    ///     이기지 못하며, 지운 기본 형광펜(작은 정수 id)을 다른 기기가 채운 기본값이 되살리지 못한다 (지움 도장 > 기본값 도장).
    ///     상태에 그 id 가 지운 채 있으면 지움을 다시 적지 않고, 상태에 살아 있는 형광펜이 하나도 없을 때만 (모두 지운 뒤 앱이 채운
    ///     기본 형광펜을 고침 — 보이는 기본 형광펜이 곧 그 목록이다) 새 항목처럼 다시 더한다. 살아 있는 형광펜이 있으면 이 기기가 본
    ///     기본 목록은 받기 전의 옛 모습이라 지운 id 를 되살리지 않는다 (기본값 도장 a < 지움 도장). "살아 있는" 은 보이는 것 (isShown).
    ///     순서(o:)를 적어야 하면 기본값 도장으로 — 이 기기가 본 기본 목록의 순서는 다른 기기가 진짜로 적은 순서를 이기지 않는다.
    ///   - seed (그룹을 만든 기기의 첫 가져오기 — 진짜 도장): 지난 값이 기본 형광펜이고 지금 값이 다르면 지금 있는 항목은 모두 새 항목
    ///     (a · 모든 필드에 새 도장 — 기본값과 같은 필드도 사용자의 값), 목록에 없는 기본 id 는 지움, 순서도 적는다. 기본값 도장으로
    ///     적으면 나중에 합류하는 같은 책의 옛 사본(시각 0 도장)이 그 필드를 이긴다. TS DiffOptions.seed 와 같다
    public static func diff(_ kind: RecordKind, prev: Flat?, cur: Flat, clock: StampSource, base: RecState? = nil, seed: Bool = false) -> RecState {
        let schema = schema(kind)
        var out = RecState()
        let ps = prev?.s ?? [:]
        for k in diffKeys(cur.s, ps, known: schema.scalarOrder) {
            if cur.s[k] == nil, k.hasPrefix(XP) { continue }
            let pv = ps[k] ?? schema.scalarDefault(k)
            let cv = cur.s[k] ?? schema.scalarDefault(k)
            if pv != cv { out.f[k] = FieldEntry(cv, clock.next()) }
        }
        for (col, defs) in schema.items {
            var pItems = prev?.c[col] ?? []
            let cItems = cur.c[col] ?? []
            /// 기본 형광펜(설정 안 됨)에서 바뀜: 지난 값 = 기본 형광펜, 그대로인 기본값은 기본값 도장으로
            var implicit = false
            /// 그룹을 만든 기기의 첫 가져오기: 지금 목록에 없는 기본 형광펜 (지움 표시)
            var seedGone: [FlatItem] = []
            let had = base?.c[col] ?? [:]
            /// 상태에 지운 채 있는 항목 · 그것을 다시 더할지 (보이는 형광펜이 하나도 없을 때 — 보이는 기본 형광펜이 곧 그 목록)
            func gone(_ id: String) -> Bool { had[id].map { !$0.isAlive } ?? false }
            let noneAlive = base.map { b in !had.contains { isShown(b, col, $0.key, $0.value) } } ?? true
            if kind == .prefs, col == "categories" {
                let prevDefault = pItems.isEmpty || isDefaultCategoryList(pItems)
                if prevDefault, isDefaultCategoryList(cItems) { continue } // 그대로 기본 형광펜 (순서도)
                if prevDefault, seed {
                    let ids = Set(cItems.map(\.id))
                    seedGone = defaultCategoryItems.filter { !ids.contains($0.id) }
                    pItems = []
                } else if prevDefault {
                    pItems = defaultCategoryItems
                    implicit = true
                }
            }
            var pMap: [String: FlatItem] = [:]
            for i in pItems { pMap[i.id] = i }
            var cIds: [String] = []
            var cIdSet = Set<String>()
            var delta: [String: ItemState] = [:]
            for it in cItems {
                if cIdSet.contains(it.id) { continue } // 같은 id 가 둘이면 앞의 것만
                cIdSet.insert(it.id)
                cIds.append(it.id)
                if let p = pMap[it.id], !(implicit && noneAlive && gone(it.id)) {
                    var f: [String: FieldEntry] = [:]
                    for k in diffKeys(it.f, p.f, known: schema.itemOrder[col] ?? []) {
                        if it.f[k] == nil, k.hasPrefix(XP) { continue }
                        let pv = p.f[k] ?? defs[k] ?? .null
                        let cv = it.f[k] ?? defs[k] ?? .null
                        if pv != cv {
                            f[k] = FieldEntry(cv, clock.next())
                        } else if implicit {
                            f[k] = FieldEntry(cv, Stamps.defaultStamp)
                        }
                    }
                    if implicit {
                        delta[it.id] = ItemState(a: Stamps.defaultStamp, f: f)
                    } else if !f.isEmpty {
                        delta[it.id] = ItemState(a: "", f: f)
                    }
                } else {
                    let st = clock.next()
                    var f: [String: FieldEntry] = [:]
                    for (k, dv) in defs { f[k] = FieldEntry(it.f[k] ?? dv, st) }
                    for (k, v) in it.f { f[k] = FieldEntry(v, st) }
                    delta[it.id] = ItemState(a: st, f: f)
                }
            }
            for p in pItems + seedGone where !cIdSet.contains(p.id) && delta[p.id] == nil {
                if implicit || !seedGone.isEmpty, gone(p.id) { continue } // 이미 지운 기본 형광펜
                delta[p.id] = ItemState(a: "", d: clock.next(), f: [:])
            }
            if !delta.isEmpty { out.c[col] = delta }
            if schema.ordered.contains(col) {
                // 기대하는 순서: 지난 순서(남은 것) + 새 항목은 뒤에. 새 항목이 있거나 다르면 순서를 통째로 적는다.
                // 기본 형광펜을 보던 기기(implicit)의 순서는 기본값 도장 — 진짜로 적은 순서를 이기지 않는다 (isShown)
                let kept = pItems.filter { cIdSet.contains($0.id) }.map(\.id)
                let added = cIds.filter { pMap[$0] == nil }
                let expected = kept + added
                if !added.isEmpty || !sameIds(expected, cIds) {
                    out.f[OP + col] = FieldEntry(.array(cIds.map { .string($0) }), implicit ? Stamps.defaultStamp : clock.next())
                }
            }
        }
        return out
    }

    static func sameIds(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { JS.same($0, $1) }
    }

    /// 앱 값만으로 만든 상태 (정규화 비교용, 도장은 뜻이 없다)
    static func stateOfFlat(_ kind: RecordKind, _ cur: Flat) -> RecState {
        var st = RecState()
        CRDT.mergeInto(&st, diff(kind, prev: nil, cur: cur, clock: ZeroClock(node: "0000000000000000")))
        return st
    }

    // MARK: - 상태 → 앱 값

    static func str(_ v: JSONValue?, _ def: String) -> String { v?.stringValue ?? def }
    static func int(_ v: JSONValue?, _ def: Int) -> Int { v?.safeInt ?? def }
    static func optInt(_ v: JSONValue?) -> Int? { v?.safeInt }
    static func bool(_ v: JSONValue?, _ def: Bool) -> Bool { v?.boolValue ?? def }
    static func uuidOpt(_ v: JSONValue?) -> String? {
        guard case let .string(s)? = v, RecordKeys.isUuid(s) else { return nil }
        return s.uppercased()
    }

    struct LiveItem {
        let id: String
        let it: ItemState
        func get(_ k: String) -> JSONValue? { it.f[k]?.value }
    }

    static let maxSafe = 9_007_199_254_740_991.0

    /// 살아 있는 항목을 보일 순서로: (sortKey) → o: 목록의 자리 → a → id
    static func liveItems(_ st: RecState, _ col: String, sortKey: ((LiveItem) -> Double)? = nil) -> [LiveItem] {
        let items = st.c[col] ?? [:]
        var rank: [String: Int] = [:]
        if case let .array(order)? = st.f[OP + col]?.value {
            for (i, x) in order.enumerated() {
                if case let .string(id) = x, rank[id] == nil { rank[id] = i }
            }
        }
        var out: [LiveItem] = []
        for (id, it) in items where isShown(st, col, id, it) { out.append(LiveItem(id: id, it: it)) } // 지운 항목 · 그룹 목록에 없던 기본 형광펜
        out.sort { x, y in
            if let sortKey {
                let d = sortKey(x) - sortKey(y)
                if d != 0 { return d < 0 }
            }
            let rx = Double(rank[x.id] ?? Int(maxSafe))
            let ry = Double(rank[y.id] ?? Int(maxSafe))
            if rx != ry { return rx < ry }
            if !JS.same(x.it.a, y.it.a) { return JS.less(x.it.a, y.it.a) }
            return JS.less(x.id, y.id)
        }
        return out
    }

    static func buildDDay(_ x: LiveItem) -> JSONValue? {
        guard RecordKeys.isUuid(x.id), let date = ISODate.normalize(x.get("date")) else { return nil }
        var d: [String: JSONValue] = ["id": .string(x.id.uppercased()), "title": .string(str(x.get("title"), "")), "date": .string(date)]
        if let src = uuidOpt(x.get("source")) { d["source"] = .string(src) }
        putExtras(x.it.f, into: &d, known: DDAY_KNOWN)
        return .object(d)
    }

    /// 하루. 빈 날이면 nil (앱은 빈 날을 파일에 두지 않는다)
    public static func buildDay(_ st: RecState) -> JSONValue? {
        if st.x != nil { return nil }
        var slots: [Int] = []
        slots.reserveCapacity(PlannerModel.slotCount)
        for f in SLOT_FIELDS {
            let row = st.f[f]?.value.arrayValue
            for j in 0..<PlannerModel.slotsPerRow {
                let v = row.flatMap { j < $0.count ? $0[j] : nil }
                slots.append(v?.safeInt ?? -1)
            }
        }
        var tasks: [JSONValue] = []
        for x in liveItems(st, "tasks", sortKey: { Double(optInt($0.get("row")) ?? Int(maxSafe)) }) {
            guard RecordKeys.isUuid(x.id) else { continue }
            let mark = int(x.get("mark"), 0)
            var t: [String: JSONValue] = ["id": .string(x.id.uppercased()), "text": .string(str(x.get("text"), "")), "mark": .number(Double(mark >= 0 && mark <= 4 ? mark : 0))]
            if let cat = optInt(x.get("cat")) { t["cat"] = JSONValue(cat) }
            if let cf = uuidOpt(x.get("carriedFrom")) { t["carriedFrom"] = .string(cf) }
            if let row = optInt(x.get("row")), row >= 0 { t["row"] = JSONValue(row) }
            putExtras(x.it.f, into: &t, known: TASK_KNOWN)
            tasks.append(.object(t))
        }
        var notes: [JSONValue] = []
        for x in liveItems(st, "notes") {
            guard RecordKeys.isUuid(x.id) else { continue }
            let clamp = { (n: Int) in min(143, max(0, n)) }
            var n: [String: JSONValue] = [
                "id": .string(x.id.uppercased()),
                "kind": x.get("kind") == .string("meal") ? "meal" : "text",
                "start": JSONValue(clamp(int(x.get("start"), 0))),
                "end": JSONValue(clamp(int(x.get("end"), 0))),
                "text": .string(str(x.get("text"), "")),
            ]
            putExtras(x.it.f, into: &n, known: NOTE_KNOWN)
            notes.append(.object(n))
        }
        var ddays: [JSONValue] = []
        for x in liveItems(st, "ddays") { if let d = buildDDay(x) { ddays.append(d) } }
        let comment = str(st.f["comment"]?.value, "")
        let memoTags = memoLines(st.f, true)
        let memos = memoLines(st.f, false)
        let dayOff = bool(st.f["dayOff"]?.value, false)
        let theme = optInt(st.f["theme"]?.value)
        var r: [String: JSONValue] = [
            "tasks": .array(tasks),
            "slots": .array(slots.map { JSONValue($0) }),
            "comment": .string(comment),
            "memoTags": .array(memoTags.map { .string($0) }),
            "memos": .array(memos.map { .string($0) }),
            "notes": .array(notes),
            "ddays": .array(ddays),
            "dayOff": .bool(dayOff),
        ]
        if let theme { r["theme"] = JSONValue(theme) }
        let before = r.count
        putExtras(st.f, into: &r, known: DAY_KNOWN)
        let hasExtras = r.count > before
        let hasRecord = PlannerModel.dayHasRecord(tasks: tasks.count, slots: slots, comment: comment, memos: memos, memoTags: memoTags, theme: theme, notes: notes.count)
        let empty = !hasRecord && ddays.isEmpty && !dayOff
        return empty && !hasExtras ? nil : .object(r)
    }

    /// 한 주. 모두 기본값이면 nil
    public static func buildWeek(_ st: RecState) -> JSONValue? {
        if st.x != nil { return nil }
        var w: [String: JSONValue] = [
            "goal": .string(str(st.f["goal"]?.value, "")),
            "review": .string(str(st.f["review"]?.value, "")),
            "stars": JSONValue(int(st.f["stars"]?.value, 0)),
        ]
        putExtras(st.f, into: &w, known: WEEK_KNOWN)
        let empty = w["goal"] == "" && w["review"] == "" && w["stars"] == 0 && w.count == 3
        return empty ? nil : .object(w)
    }

    /// 책 설정 중 동기화하는 부분 (lastKind · ddaysPerDay 는 넣지 않는다)
    public static func buildPrefs(_ st: RecState) -> [String: JSONValue] {
        var categories: [JSONValue] = []
        for x in liveItems(st, "categories") {
            guard isCategoryId(x.id), let n = Double(x.id) else { continue }
            var c: [String: JSONValue] = [
                "id": .number(n),
                "name": .string(str(x.get("name"), "")),
                "hex": .string(str(x.get("hex"), "CFCFD4")),
                "counts": .bool(bool(x.get("counts"), true)),
            ]
            putExtras(x.it.f, into: &c, known: CAT_KNOWN)
            categories.append(.object(c))
            // 앱은 12개를 넘는 목록을 기본값으로 되돌려 읽는다 → 앞의 12개만 (나머지는 상태에 남는다)
            if categories.count >= PlannerModel.maxCategories { break }
        }
        var ddays: [JSONValue] = []
        for x in liveItems(st, "ddays") { if let d = buildDDay(x) { ddays.append(d) } }
        var p: [String: JSONValue] = ["categories": .array(categories), "ddays": .array(ddays), "defaultTheme": JSONValue(int(st.f["defaultTheme"]?.value, 0))]
        if case let .string(m)? = st.f["mottoText"]?.value, !m.isEmpty { p["mottoText"] = .string(m) }
        putExtras(st.f, into: &p, known: PREFS_KNOWN)
        return p
    }

    /// /^-?\d{1,9}$/
    static func isCategoryId(_ s: String) -> Bool {
        var u = Array(s.utf8)
        if u.first == UInt8(ascii: "-") { u.removeFirst() }
        return (1...9).contains(u.count) && u.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    public enum BookValue: Equatable, Sendable {
        case book(JSONValue)
        case deleted
    }

    /// 책 정보. 지운 책이면 .deleted, 아직 모양이 갖춰지지 않았으면 nil
    public static func buildBook(_ id: String, _ st: RecState) -> BookValue? {
        if st.x != nil { return .deleted }
        guard let start = ISODate.normalize(st.f["start"]?.value), let created = ISODate.normalize(st.f["created"]?.value) else { return nil }
        var b: [String: JSONValue] = [
            "id": .string(id.uppercased()),
            "name": .string(str(st.f["name"]?.value, "")),
            "start": .string(start),
            "cover": JSONValue(int(st.f["cover"]?.value, 0)),
            "created": .string(created),
        ]
        if let end = ISODate.normalize(st.f["end"]?.value) { b["end"] = .string(end) }
        putExtras(st.f, into: &b, known: BOOK_KNOWN)
        return .book(.object(b))
    }

    public static func buildLib(_ st: RecState) -> JSONValue {
        var out: [String: JSONValue] = [:]
        putExtras(st.f, into: &out, known: [])
        return .object(out)
    }

    // MARK: - 책 한 권의 값 넣기 (새 값을 돌려준다)

    public static func withDay(_ d: JSONValue, _ date: String, _ r: JSONValue?) -> JSONValue {
        var o = d.objectValue ?? [:]
        var days = o["days"]?.objectValue ?? [:]
        days[date] = r
        o["days"] = .object(days)
        return .object(o)
    }

    public static func withWeek(_ d: JSONValue, _ date: String, _ w: JSONValue?) -> JSONValue {
        var o = d.objectValue ?? [:]
        var weeks = o["weeks"]?.objectValue ?? [:]
        weeks[date] = w
        o["weeks"] = .object(weeks)
        return .object(o)
    }

    public static func withPrefs(_ d: JSONValue, _ p: [String: JSONValue]) -> JSONValue {
        var o = d.objectValue ?? [:]
        // 기기마다 따로인 값은 지금 것을 그대로
        var prefs: [String: JSONValue] = ["lastKind": "daily", "ddaysPerDay": true]
        for (k, v) in p { prefs[k] = v }
        if let cur = o["prefs"]?.objectValue {
            for k in PREFS_LOCAL { if let v = cur[k] { prefs[k] = v } }
        }
        // 형광펜이 하나도 없으면(설정 안 됨 · 모두 지움) 앱에는 기본 형광펜. 비교는 이 기본 형광펜을 편집으로 보지 않는다 (diff, §4.1)
        if prefs["categories"]?.arrayValue?.isEmpty ?? true { prefs["categories"] = .array(PlannerModel.defaultCategories) }
        o["prefs"] = .object(prefs)
        return .object(o)
    }

    /// 동기화하는 책인지 (예시 플래너는 기기마다 따로)
    public static func isSyncedBook(_ b: JSONValue) -> Bool {
        b["isSample"] != .bool(true) && RecordKeys.isUuid(b["id"])
    }

    public static func books(_ lib: JSONValue) -> [JSONValue] {
        lib["books"]?.arrayValue ?? []
    }

    public static func syncedBooks(_ lib: JSONValue) -> [JSONValue] {
        books(lib).filter(isSyncedBook)
    }

    /// 상태 → 앱 값
    public static func materialize(_ pk: ParsedKey, _ st: RecState) -> JSONValue? {
        switch pk.kind {
        case .day: return buildDay(st)
        case .week: return buildWeek(st)
        case .prefs:
            if st.x != nil { return nil }
            // 앱이 보는 그대로: 형광펜이 없으면(설정 안 됨) 앱의 기본 형광펜 (withPrefs 와 같다 — 넣을 값 pend · 맞추기 비교가 앱 값과 같게)
            var p = buildPrefs(st)
            if p["categories"]?.arrayValue?.isEmpty ?? true { p["categories"] = .array(PlannerModel.defaultCategories) }
            return .object(p)
        case .book:
            switch buildBook(pk.bookId!, st) {
            case let .book(b)?: return b
            case .deleted?: return .string("deleted")
            case nil: return nil
            }
        case .lib: return buildLib(st)
        }
    }

    static func flattenOf(_ pk: ParsedKey, _ v: JSONValue?) -> Flat {
        switch pk.kind {
        case .day: return flattenDay(v)
        case .week: return flattenWeek(v)
        case .prefs: return flattenPrefs(v)
        case .book: return flattenBook(v == .string("deleted") ? nil : v)
        case .lib: return flattenLib(v)
        }
    }

    /// 하루의 그림자가 빈 날인지 (기본값뿐)
    static func isEmptyFlat(_ f: Flat) -> Bool {
        for (k, v) in f.s {
            if k == "comment", v != "" { return false }
            if k == "theme", !v.isNull { return false }
            if k == "dayOff", v != false { return false }
            if isMemoLineField(k), v != "" { return false }
            if isMemoRestField(k), case let .array(xs) = v, xs.contains(where: { $0 != "" }) { return false }
            if isSlotField(k), case let .array(xs) = v, xs.contains(where: { $0 != -1 }) { return false }
            if k.hasPrefix(XP), !v.isNull { return false }
        }
        return f.c.values.allSatisfy(\.isEmpty)
    }
}

// MARK: - 날짜

/// Swift .iso8601 모양 ("2026-10-01T15:00:00Z", 소수 초 없음)으로 맞춘다 (JS Date.parse → toISOString 과 같은 규칙).
/// 앱(JSONDecoder .iso8601)이 읽지 못하는 날짜는 내보내지 않는다 —
/// 월 13 같은 범위 밖 값은 이미 그 모양이어도 nil, 0000–9999 년 밖은 nil.
public enum ISODate {
    public static func normalize(_ v: JSONValue?) -> String? {
        guard case let .string(s)? = v else { return nil }
        let u = Array(s.utf8)
        // /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/
        func digits(_ a: Int, _ n: Int) -> Int? {
            guard a + n <= u.count else { return nil }
            var v = 0
            for i in a..<(a + n) {
                guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }
                v = v * 10 + Int(u[i] - 0x30)
            }
            return v
        }
        func at(_ i: Int, _ c: Character) -> Bool { i < u.count && u[i] == c.asciiValue! }
        guard u.count >= 20, let Y = digits(0, 4), at(4, "-"), let M = digits(5, 2), at(7, "-"), let D = digits(8, 2), at(10, "T"),
              let h = digits(11, 2), at(13, ":"), let m = digits(14, 2), at(16, ":"), let sec = digits(17, 2) else { return nil }
        // V8 의 규칙: 월 1–12, 일 1–31 (넘치면 다음 달로), 시 0–24 (24 는 00:00:00.000 일 때만), 분 · 초 0–59
        guard (1...12).contains(M), (1...31).contains(D), m <= 59, sec <= 59, h <= 24, h < 24 || (m == 0 && sec == 0) else { return nil }
        // 이미 그 모양이면 그대로 (Swift 의 .iso8601 도 일 · 24시 넘침을 받아 다음 날로 읽는다)
        if u.count == 20, u[19] == UInt8(ascii: "Z") { return s }
        var i = 19
        var ms = 0
        if at(i, ".") {
            i += 1
            let start = i
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
            guard i > start else { return nil }
            // 밀리초까지만 (뒤는 버린다)
            for k in 0..<3 { ms = ms * 10 + (start + k < i ? Int(u[start + k] - 0x30) : 0) }
        }
        var offset = 0
        guard i < u.count else { return nil }
        if u[i] == UInt8(ascii: "Z") {
            guard i + 1 == u.count else { return nil }
        } else if u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") {
            let sign = u[i] == UInt8(ascii: "+") ? 1 : -1
            guard let oh = digits(i + 1, 2) else { return nil }
            var j = i + 3
            if at(j, ":") { j += 1 }
            guard let om = digits(j, 2), j + 2 == u.count, oh <= 23, om <= 59 else { return nil }
            offset = sign * (oh * 60 + om)
        } else {
            return nil
        }
        if h == 24, ms != 0 { return nil }
        let days = daysFromCivil(Y, M, 1) + (D - 1)
        var t = Int64(days) * 86_400_000 + Int64(h * 3_600_000 + m * 60_000 + sec * 1000 + ms) - Int64(offset) * 60_000
        // 초 아래는 버린다 (toISOString 의 .sss 를 떼는 것과 같다)
        t = Int64((Double(t) / 1000).rounded(.down)) * 1000
        let out = format(t)
        // 앱이 읽을 수 있는 해 (0000–9999) 만
        return out.hasPrefix("+") || out.hasPrefix("-") ? nil : out
    }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 1970-01-01 부터의 날 수 (그레고리력, 음수 연도 포함)
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// ms → "YYYY-MM-DDTHH:mm:ssZ" (JS toISOString, 0–9999 밖은 ±YYYYYY)
    public static func format(_ ms: Int64) -> String {
        var days = Int(ms / 86_400_000)
        var rem = Int(ms % 86_400_000)
        if rem < 0 {
            rem += 86_400_000
            days -= 1
        }
        let (y, mo, d) = civil(fromDays: days)
        let h = rem / 3_600_000, mi = rem / 60000 % 60, s = rem / 1000 % 60
        func p(_ v: Int, _ n: Int) -> String {
            let t = String(v)
            return String(repeating: "0", count: max(0, n - t.count)) + t
        }
        let year = (0...9999).contains(y) ? p(y, 4) : (y < 0 ? "-" : "+") + p(abs(y), 6)
        return "\(year)-\(p(mo, 2))-\(p(d, 2))T\(p(h, 2)):\(p(mi, 2)):\(p(s, 2))Z"
    }
}
