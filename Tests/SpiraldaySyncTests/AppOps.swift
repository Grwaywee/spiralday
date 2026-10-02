// 테스트용: 앱이 하는 편집을 흉내 낸다.
// 모든 편집은 새 값을 돌려준다. 같은 연산은 TypeScript 엔진의 테스트에서도 같은 결과를 낸다.
import Foundation
@testable import SpiraldaySync

let DATES = ["2026-10-01", "2026-10-02", "2026-10-03"]
let WEEKS = ["2026-09-28", "2026-10-05"]

// MARK: - 결정적 난수 (SplitMix64)

struct Rng {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }

    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    mutating func nat(_ max: Int) -> Int { int(0, max) }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func pick<T>(_ a: [T]) -> T { a[nat(a.count - 1)] }

    mutating func weighted<T>(_ items: [(Int, T)]) -> T {
        let total = items.reduce(0) { $0 + $1.0 }
        var r = nat(total - 1)
        for (w, x) in items {
            if r < w { return x }
            r -= w
        }
        return items.last!.1
    }

    mutating func uuid() -> String {
        var b = (0..<16).map { _ in UInt8(truncatingIfNeeded: next()) }
        b[6] = b[6] & 0x0F | 0x40
        b[8] = b[8] & 0x3F | 0x80
        let h = Hex.encode(b).uppercased()
        let u = Array(h)
        return String(u[0..<8]) + "-" + String(u[8..<12]) + "-" + String(u[12..<16]) + "-" + String(u[16..<20]) + "-" + String(u[20..<32])
    }
}

// MARK: - 연산

/// 앱의 편집 하나 (JSON: {"t": ..., ...})
typealias Op = JSONValue

let WORDS: [String] = ["", "회의", "운동", "책 읽기", "QA", "메일", "장보기", "정리", "x", "긴 글 긴 글 긴 글 "]

func randomOp(_ r: inout Rng) -> Op {
    let date = JSONValue(r.int(0, DATES.count - 1))
    func idx(_ r: inout Rng) -> JSONValue { JSONValue(r.nat(20)) }
    func word(_ r: inout Rng) -> JSONValue { .string(r.pick(WORDS)) }
    func optInt(_ r: inout Rng, _ lo: Int, _ hi: Int) -> JSONValue { r.int(0, 4) == 0 ? .null : JSONValue(r.int(lo, hi)) }
    let kind = r.weighted([
        (6, "addTask"), (4, "editTask"), (3, "markTask"), (2, "rowTask"), (2, "catTask"), (3, "delTask"), (2, "carry"), (1, "uncarry"),
        (5, "paint"), (2, "addNote"), (1, "editNote"), (1, "delNote"), (1, "addDday"), (1, "delDday"), (3, "comment"), (2, "memo"),
        (1, "theme"), (1, "dayOff"), (2, "week"), (1, "addCat"), (1, "renameCat"), (1, "delCat"), (1, "moveCat"), (1, "defaultTheme"),
        (1, "motto"), (1, "addLibDday"), (1, "delLibDday"), (1, "clearDay"),
    ])
    switch kind {
    case "addTask": return ["t": "addTask", "date": date, "id": .string(r.uuid()), "text": word(&r), "cat": optInt(&r, 0, 6)]
    case "editTask": return ["t": "editTask", "date": date, "i": idx(&r), "text": word(&r)]
    case "markTask": return ["t": "markTask", "date": date, "i": idx(&r), "mark": JSONValue(r.int(0, 3))]
    case "rowTask": return ["t": "rowTask", "date": date, "i": idx(&r), "row": JSONValue(r.int(0, 12))]
    case "catTask": return ["t": "catTask", "date": date, "i": idx(&r), "cat": optInt(&r, 0, 6)]
    case "delTask": return ["t": "delTask", "date": date, "i": idx(&r)]
    case "carry": return ["t": "carry", "date": date, "i": idx(&r)]
    case "uncarry": return ["t": "uncarry", "date": date, "i": idx(&r)]
    case "paint": return ["t": "paint", "date": date, "start": JSONValue(r.int(0, 143)), "len": JSONValue(r.int(1, 14)), "cat": JSONValue(r.int(-1, 6))]
    case "addNote":
        return ["t": "addNote", "date": date, "id": .string(r.uuid()), "start": JSONValue(r.int(0, 140)), "len": JSONValue(r.int(0, 3)), "text": word(&r), "meal": .bool(r.bool())]
    case "editNote": return ["t": "editNote", "date": date, "i": idx(&r), "text": word(&r)]
    case "delNote": return ["t": "delNote", "date": date, "i": idx(&r)]
    case "addDday": return ["t": "addDday", "date": date, "id": .string(r.uuid()), "title": word(&r), "day": JSONValue(r.int(0, 60))]
    case "delDday": return ["t": "delDday", "date": date, "i": idx(&r)]
    case "comment": return ["t": "comment", "date": date, "text": word(&r)]
    case "memo": return ["t": "memo", "date": date, "i": JSONValue(r.int(0, 3)), "text": word(&r)]
    case "theme": return ["t": "theme", "date": date, "theme": optInt(&r, 0, 8)]
    case "dayOff": return ["t": "dayOff", "date": date, "on": .bool(r.bool())]
    case "week":
        return ["t": "week", "week": JSONValue(r.int(0, WEEKS.count - 1)), "field": .string(r.pick(["goal", "review", "stars"])), "text": word(&r), "stars": JSONValue(r.int(0, 5))]
    case "addCat": return ["t": "addCat", "name": word(&r), "hex": .string(r.pick(["B9E4A8", "FFCC00", "123456"]))]
    case "renameCat": return ["t": "renameCat", "i": idx(&r), "name": word(&r)]
    case "delCat": return ["t": "delCat", "i": idx(&r)]
    case "moveCat": return ["t": "moveCat", "from": idx(&r), "to": idx(&r)]
    case "defaultTheme": return ["t": "defaultTheme", "v": JSONValue(r.int(0, 8))]
    case "motto": return ["t": "motto", "text": word(&r)]
    case "addLibDday": return ["t": "addLibDday", "id": .string(r.uuid()), "title": word(&r)]
    case "delLibDday": return ["t": "delLibDday", "i": idx(&r)]
    default: return ["t": "clearDay", "date": date]
    }
}

/// 지운 id · 다시 더한 id 기록 (되살아남 검사)
final class Tracker {
    var deleted: [String: Int] = [:]
    var added: [String: Int] = [:]
    var n = 0
    var scope = ""
    func del(_ id: String) { deleted[scope + id] = n }
    func add(_ id: String) { added[scope + id] = n }
    /// 지운 뒤 다시 더한 적이 없는 id
    func mustBeGone() -> Set<String> {
        Set(deleted.filter { (added[$0.key] ?? -1) <= $0.value }.keys)
    }
}

// MARK: - 앱 모델 (테스트용 객체 모양)

struct TTask {
    var id: String
    var text: String
    var mark: Int
    var cat: Int?
    var carriedFrom: String?
    var row: Int?

    init(id: String, text: String, mark: Int, cat: Int? = nil, carriedFrom: String? = nil, row: Int? = nil) {
        self.id = id
        self.text = text
        self.mark = mark
        self.cat = cat
        self.carriedFrom = carriedFrom
        self.row = row
    }

    init(_ j: JSONValue) {
        id = j["id"]?.stringValue ?? ""
        text = j["text"]?.stringValue ?? ""
        mark = j["mark"]?.safeInt ?? 0
        cat = j["cat"]?.safeInt
        carriedFrom = j["carriedFrom"]?.stringValue
        row = j["row"]?.safeInt
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "text": .string(text), "mark": JSONValue(mark)]
        if let cat { o["cat"] = JSONValue(cat) }
        if let carriedFrom { o["carriedFrom"] = .string(carriedFrom) }
        if let row { o["row"] = JSONValue(row) }
        return .object(o)
    }
}

struct TDay {
    var tasks: [TTask] = []
    var slots = [Int](repeating: -1, count: 144)
    var comment = ""
    var memoTags = ["", "", ""]
    var memos = ["", "", ""]
    var theme: Int?
    var notes: [JSONValue] = []
    var ddays: [JSONValue] = []
    var dayOff = false

    init() {}

    init(_ j: JSONValue) {
        tasks = (j["tasks"]?.arrayValue ?? []).map(TTask.init)
        slots = (j["slots"]?.arrayValue ?? []).map { $0.safeInt ?? -1 }
        comment = j["comment"]?.stringValue ?? ""
        memoTags = (j["memoTags"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
        memos = (j["memos"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
        theme = j["theme"]?.safeInt
        notes = j["notes"]?.arrayValue ?? []
        ddays = j["ddays"]?.arrayValue ?? []
        dayOff = j["dayOff"]?.boolValue ?? false
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "tasks": .array(tasks.map(\.json)), "slots": .array(slots.map { JSONValue($0) }), "comment": .string(comment),
            "memoTags": .array(memoTags.map { .string($0) }), "memos": .array(memos.map { .string($0) }),
            "notes": .array(notes), "ddays": .array(ddays), "dayOff": .bool(dayOff),
        ]
        if let theme { o["theme"] = JSONValue(theme) }
        return .object(o)
    }

    var isEmpty: Bool {
        tasks.isEmpty && slots.allSatisfy { $0 < 0 } && comment.isEmpty && memos.allSatisfy(\.isEmpty) && memoTags.allSatisfy(\.isEmpty)
            && theme == nil && notes.isEmpty && ddays.isEmpty && !dayOff
    }
}

func isoDay(_ n: Int) -> String {
    ISODate.format(Int64(ISODate.daysFromCivil(2026, 10, 1) + n) * 86_400_000 + 15 * 3_600_000)
}

func newBook(_ name: String, created: String = "2026-09-01T00:00:00Z", id: String = UUID().uuidString) -> (info: JSONValue, data: JSONValue) {
    return (["id": .string(id), "name": .string(name), "start": "2026-09-01T00:00:00Z", "cover": 1, "created": .string(created)], PlannerModel.emptyPlannerData())
}

/// 연산 하나를 책 내용에 (앱이 하듯). 할 수 없으면 그대로
func applyOp(_ data: JSONValue, _ op: Op, _ tr: Tracker? = nil) -> JSONValue {
    var days: [String: TDay] = (data["days"]?.objectValue ?? [:]).mapValues(TDay.init)
    var weeks: [String: JSONValue] = data["weeks"]?.objectValue ?? [:]
    var prefs: [String: JSONValue] = data["prefs"]?.objectValue ?? PlannerModel.defaultPrefs()
    tr?.n += 1
    func i(_ k: String) -> Int { op[k]?.safeInt ?? 0 }
    func s(_ k: String) -> String { op[k]?.stringValue ?? "" }
    let t = s("t")
    func dayOf(_ n: Int) -> String {
        let k = DATES[n]
        if days[k] == nil { days[k] = TDay() }
        return k
    }
    func done() -> JSONValue {
        for (k, var r) in days {
            r.tasks = JS.stableSorted(r.tasks) { ($0.row ?? 1_000_000_000) < ($1.row ?? 1_000_000_000) }
            days[k] = r.isEmpty ? nil : r
        }
        var o = data.objectValue ?? [:]
        o["days"] = .object(days.mapValues(\.json))
        o["weeks"] = .object(weeks)
        o["prefs"] = .object(prefs)
        return .object(o)
    }
    func pickIndex(_ count: Int, _ n: Int) -> Int? { count > 0 ? n % count : nil }
    var cats = (prefs["categories"]?.arrayValue ?? [])
    var libDdays = prefs["ddays"]?.arrayValue ?? []
    // UUID 는 겹치지 않는다 (같은 id 가 나오면 더하지 않는다)
    if ["addTask", "addNote", "addDday", "addLibDday"].contains(t), allIds(data).contains(s("id")) { return data }
    switch t {
    case "addTask":
        let k = dayOf(i("date"))
        let used = Set(days[k]!.tasks.compactMap(\.row))
        var row = 0
        while used.contains(row) { row += 1 }
        let txt = s("text")
        days[k]!.tasks.append(TTask(id: s("id"), text: txt.isEmpty ? "할 일" : txt, mark: 0, cat: op["cat"]?.safeInt, row: row))
        tr?.add(s("id"))
    case "editTask":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.tasks.count, i("i")) { days[k]!.tasks[x].text = s("text") }
    case "markTask":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.tasks.count, i("i")) { days[k]!.tasks[x].mark = i("mark") }
    case "rowTask":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.tasks.count, i("i")), !days[k]!.tasks.contains(where: { $0.row == i("row") }) { days[k]!.tasks[x].row = i("row") }
    case "catTask":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.tasks.count, i("i")) { days[k]!.tasks[x].cat = op["cat"]?.safeInt }
    case "delTask":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.tasks.count, i("i")) {
            let id = days[k]!.tasks[x].id
            days[k]!.tasks.removeAll { $0.id == id }
            tr?.del(id)
        }
    case "carry":
        // → 미룸: 다음 날에 같은 글의 할 일 (id 는 결정적)
        guard i("date") + 1 < DATES.count else { return done() }
        let k = dayOf(i("date"))
        guard let x = pickIndex(days[k]!.tasks.count, i("i")), !days[k]!.tasks[x].text.trimmingCharacters(in: .whitespaces).isEmpty else { return done() }
        days[k]!.tasks[x].mark = 4
        let task = days[k]!.tasks[x]
        let nk = dayOf(i("date") + 1)
        let cid = CarryID.carryTaskId(task.id)!
        if !days[nk]!.tasks.contains(where: { $0.id == cid }) {
            let used = Set(days[nk]!.tasks.compactMap(\.row))
            var row = 0
            while used.contains(row) { row += 1 }
            days[nk]!.tasks.append(TTask(id: cid, text: task.text, mark: 0, cat: task.cat, carriedFrom: task.id, row: row))
            tr?.add(cid)
        }
    case "uncarry":
        guard i("date") + 1 < DATES.count else { return done() }
        let k = dayOf(i("date"))
        guard let x = pickIndex(days[k]!.tasks.count, i("i")), days[k]!.tasks[x].mark == 4 else { return done() }
        days[k]!.tasks[x].mark = 0
        let task = days[k]!.tasks[x]
        let nk = dayOf(i("date") + 1)
        let cid = CarryID.carryTaskId(task.id)!
        if let c = days[nk]!.tasks.first(where: { $0.id == cid }), c.mark == 0, c.text == task.text {
            days[nk]!.tasks.removeAll { $0.id == cid }
            tr?.del(cid)
        }
    case "paint":
        let k = dayOf(i("date"))
        var x = i("start")
        while x < min(144, i("start") + i("len")) {
            days[k]!.slots[x] = i("cat")
            x += 1
        }
    case "addNote":
        let k = dayOf(i("date"))
        let meal = op["meal"] == .bool(true)
        days[k]!.notes.append(["id": .string(s("id")), "kind": .string(meal ? "meal" : "text"), "start": JSONValue(i("start")),
                               "end": JSONValue(min(143, i("start") + i("len"))), "text": .string(meal ? "" : s("text"))])
        tr?.add(s("id"))
    case "editNote":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.notes.count, i("i")), case var .object(n) = days[k]!.notes[x] {
            n["text"] = .string(s("text"))
            days[k]!.notes[x] = .object(n)
        }
    case "delNote":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.notes.count, i("i")) {
            let id = days[k]!.notes[x]["id"]!.stringValue!
            days[k]!.notes.removeAll { $0["id"]?.stringValue == id }
            tr?.del(id)
        }
    case "addDday":
        let k = dayOf(i("date"))
        if days[k]!.ddays.count < 2 {
            days[k]!.ddays.append(["id": .string(s("id")), "title": .string(s("title")), "date": .string(isoDay(i("day")))])
            tr?.add(s("id"))
        }
    case "delDday":
        let k = dayOf(i("date"))
        if let x = pickIndex(days[k]!.ddays.count, i("i")) {
            let id = days[k]!.ddays[x]["id"]!.stringValue!
            days[k]!.ddays.removeAll { $0["id"]?.stringValue == id }
            tr?.del(id)
        }
    case "comment":
        days[dayOf(i("date"))]!.comment = s("text")
    case "memo":
        let k = dayOf(i("date"))
        while days[k]!.memos.count <= i("i") { days[k]!.memos.append("") }
        days[k]!.memos[i("i")] = s("text")
    case "theme":
        days[dayOf(i("date"))]!.theme = op["theme"]?.safeInt
    case "dayOff":
        days[dayOf(i("date"))]!.dayOff = op["on"] == .bool(true)
    case "clearDay":
        let k = DATES[i("date")]
        if let r = days[k] {
            for x in r.tasks { tr?.del(x.id) }
            for x in r.notes { tr?.del(x["id"]!.stringValue!) }
            for x in r.ddays { tr?.del(x["id"]!.stringValue!) }
            days[k] = nil
        }
    case "week":
        let k = WEEKS[i("week")]
        var w = weeks[k]?.objectValue ?? PlannerModel.emptyWeek()
        if s("field") == "stars" { w["stars"] = JSONValue(i("stars")) } else { w[s("field")] = .string(s("text")) }
        weeks[k] = .object(w)
    case "addCat":
        if cats.count >= 12 { return done() }
        let id = max(-1, cats.compactMap { $0["id"]?.safeInt }.max() ?? -1) + 1
        let nm = s("name")
        cats.append(["id": JSONValue(id), "name": .string(nm.isEmpty ? "새 형광펜" : nm), "hex": .string(s("hex")), "counts": true])
        prefs["categories"] = .array(cats)
        tr?.add("cat:\(id)")
    case "renameCat":
        if let x = pickIndex(cats.count, i("i")), case var .object(c) = cats[x] {
            c["name"] = .string(s("name"))
            cats[x] = .object(c)
            prefs["categories"] = .array(cats)
        }
    case "delCat":
        if cats.count <= 1 { return done() }
        let x = pickIndex(cats.count, i("i"))!
        let id = cats[x]["id"]!.safeInt!
        cats.removeAll { $0["id"]?.safeInt == id }
        prefs["categories"] = .array(cats)
        tr?.del("cat:\(id)")
    case "moveCat":
        if cats.count < 2 { return done() }
        let c = cats.remove(at: i("from") % cats.count)
        cats.insert(c, at: i("to") % (cats.count + 1))
        prefs["categories"] = .array(cats)
    case "defaultTheme":
        prefs["defaultTheme"] = JSONValue(i("v"))
    case "motto":
        if s("text").isEmpty { prefs["mottoText"] = nil } else { prefs["mottoText"] = .string(s("text")) }
    case "addLibDday":
        libDdays.append(["id": .string(s("id")), "title": .string(s("title")), "date": .string(isoDay(10))])
        prefs["ddays"] = .array(libDdays)
        tr?.add(s("id"))
    case "delLibDday":
        if let x = pickIndex(libDdays.count, i("i")) {
            let id = libDdays[x]["id"]!.stringValue!
            libDdays.removeAll { $0["id"]?.stringValue == id }
            prefs["ddays"] = .array(libDdays)
            tr?.del(id)
        }
    default:
        break
    }
    return done()
}

/// 책 내용에 있는 모든 항목 id (할 일 · 메모 · D-day · 형광펜 cat:n · 저장한 D-day)
func allIds(_ data: JSONValue) -> Set<String> {
    var s = Set<String>()
    for (_, r) in data["days"]?.objectValue ?? [:] {
        for x in r["tasks"]?.arrayValue ?? [] { if let id = x["id"]?.stringValue { s.insert(id) } }
        for x in r["notes"]?.arrayValue ?? [] { if let id = x["id"]?.stringValue { s.insert(id) } }
        for x in r["ddays"]?.arrayValue ?? [] { if let id = x["id"]?.stringValue { s.insert(id) } }
    }
    for c in data["prefs"]?["categories"]?.arrayValue ?? [] { if let id = c["id"]?.numberValue { s.insert("cat:\(JS.numberString(id))") } }
    for x in data["prefs"]?["ddays"]?.arrayValue ?? [] { if let id = x["id"]?.stringValue { s.insert(id) } }
    return s
}

/// 동기화되는 부분만, 비교할 수 있는 모양으로 (기기마다 따로인 값 · 예시 플래너 · 책 순서는 뺀다).
func syncedView(_ lib: JSONValue, _ books: [String: JSONValue]) -> String {
    var out: [String: JSONValue] = [:]
    let list = JS.stableSorted(Records.books(lib).filter { $0["isSample"] != .bool(true) }) { JS.less($0["id"]?.stringValue ?? "", $1["id"]?.stringValue ?? "") }
    for b in list {
        let id = b["id"]?.stringValue ?? ""
        let data = books[id] ?? PlannerModel.emptyPlannerData()
        var prefs = data["prefs"]?.objectValue ?? [:]
        prefs["lastKind"] = nil
        prefs["ddaysPerDay"] = nil
        var days: [String: JSONValue] = [:]
        for (k, r) in data["days"]?.objectValue ?? [:] {
            var o = r.objectValue ?? [:]
            let tasks = r["tasks"]?.arrayValue ?? []
            o["tasks"] = .array(tasks.sorted { x, y in
                let rx = x["row"]?.numberValue ?? 1e9, ry = y["row"]?.numberValue ?? 1e9
                if rx != ry { return rx < ry }
                return JS.less(x["id"]?.stringValue ?? "", y["id"]?.stringValue ?? "")
            })
            o["notes"] = .array((r["notes"]?.arrayValue ?? []).sorted { JS.less($0["id"]?.stringValue ?? "", $1["id"]?.stringValue ?? "") })
            days[k] = .object(o)
        }
        var weeks: [String: JSONValue] = [:]
        for (k, w) in data["weeks"]?.objectValue ?? [:] {
            if JS.truthy(w["goal"]) || JS.truthy(w["review"]) || JS.truthy(w["stars"]) { weeks[k] = w }
        }
        var info = b.objectValue ?? [:]
        info["isSample"] = nil
        out[id] = ["info": .object(info), "prefs": .object(prefs), "days": .object(days), "weeks": .object(weeks)]
    }
    return JSONValue.object(out).canonical
}
