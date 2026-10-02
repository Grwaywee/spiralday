// 합치기 규칙의 성질 (서버 없이).
// 여러 복제본이 아무렇게나 고치고, 상태를 아무 순서로 · 여러 번 · 늦게 주고받아도 모두 같은 결과가 된다.
// 지운 것은 되살아나지 않고, 서로 다른 필드 · 시간 줄의 동시 편집은 둘 다 남는다.
// (fast-check 대신 씨앗을 정한 난수로 300번씩. 실패하면 씨앗을 보여 준다)
import XCTest
@testable import SpiraldaySync

let BOOK = "11111111-2222-4333-8444-555555555555"
let KEYS = [RecordKeys.prefs(BOOK)] + DATES.map { RecordKeys.day(BOOK, $0) } + WEEKS.map { RecordKeys.week(BOOK, $0) }

func flatOf(_ data: JSONValue, _ key: String) -> Flat {
    let pk = RecordKeys.parse(key)!
    switch pk.kind {
    case .prefs: return Records.flattenPrefs(data["prefs"])
    case .day: return Records.flattenDay(data["days"]?[pk.date!])
    default: return Records.flattenWeek(data["weeks"]?[pk.date!])
    }
}

final class WallBox: @unchecked Sendable {
    var t: Int64 = 1_700_000_000_000
}

/// 엔진의 핵심만 떼어 낸 복제본 (비교 → 합치기 → 넣기)
final class Replica {
    var data = PlannerModel.emptyPlannerData()
    var states: [String: RecState] = [:]
    var shadows: [String: Flat] = [:]
    var pending = Set<String>()
    let hlc: HLC
    private var imported = false

    init(_ node: String, skewMs: Int64) {
        let w = WallBox()
        hlc = HLC(node: node, wall: {
            w.t += 7
            return w.t + skewMs
        })
    }

    /// 엔진처럼: 처음 비교(그룹에 들어가기 전부터 있던 것)는 시각 0 도장
    func diff() {
        let clock: StampSource = imported ? hlc : ZeroClock(node: hlc.node)
        imported = true
        for key in KEYS {
            let delta = Records.diff(RecordKeys.parse(key)!.kind, prev: shadows[key], cur: flatOf(data, key), clock: clock)
            shadows[key] = flatOf(data, key)
            var st = states[key] ?? RecState()
            CRDT.mergeInto(&st, delta)
            states[key] = st
        }
    }

    func snapshot() -> [String: RecState] { states }

    func receive(_ snap: [String: RecState]) {
        for (k, s) in snap {
            if let m = CRDT.maxStamp(in: s) { hlc.observe(m) }
            var st = states[k] ?? RecState()
            if CRDT.mergeInto(&st, s) { pending.insert(k) }
            states[k] = st
        }
    }

    func apply() {
        if !imported { diff() }
        for key in pending.sorted() {
            let pk = RecordKeys.parse(key)!
            // 넣기 전에 사이에 쓴 것을 먼저 비교
            let delta = Records.diff(pk.kind, prev: shadows[key], cur: flatOf(data, key), clock: hlc)
            CRDT.mergeInto(&states[key]!, delta)
            let st = states[key]!
            switch pk.kind {
            case .day:
                let b = Records.buildDay(st)
                data = Records.withDay(data, pk.date!, b)
                shadows[key] = Records.flattenDay(b)
            case .week:
                let b = Records.buildWeek(st)
                data = Records.withWeek(data, pk.date!, b)
                shadows[key] = Records.flattenWeek(b)
            default:
                let b = Records.buildPrefs(st)
                data = Records.withPrefs(data, b)
                shadows[key] = Records.flattenPrefs(.object(b))
            }
        }
        pending = []
    }
}

enum Step {
    case edit(r: Int, op: Op)
    case diff(r: Int)
    case send(from: Int, to: Int)
    case deliver(k: Int, dup: Bool)
    case apply(r: Int)
}

func randomStep(_ rng: inout Rng, _ n: Int) -> Step {
    switch rng.weighted([(10, 0), (4, 1), (4, 2), (4, 3), (3, 4)]) {
    case 0: return .edit(r: rng.nat(n - 1), op: randomOp(&rng))
    case 1: return .diff(r: rng.nat(n - 1))
    case 2: return .send(from: rng.nat(n - 1), to: rng.nat(n - 1))
    case 3: return .deliver(k: rng.nat(30), dup: rng.bool())
    default: return .apply(r: rng.nat(n - 1))
    }
}

func runReplicas(_ n: Int, _ steps: [Step], _ skews: [Int64]) -> ([Replica], Tracker) {
    let reps = (0..<n).map { i in Replica(String(repeating: "0", count: 15) + String(i, radix: 16), skewMs: skews[i]) }
    // 모두 같은 책을 맞춘 상태에서 시작 (가져오기 뒤의 지우기만 '지운 것' 이다)
    for r in reps { r.diff() }
    let tr = Tracker()
    var inflight: [(to: Int, snap: [String: RecState])] = []
    for st in steps {
        switch st {
        case let .edit(r, op): reps[r].data = applyOp(reps[r].data, op, tr)
        case let .diff(r): reps[r].diff()
        case let .send(from, to):
            reps[from].diff()
            inflight.append((to, reps[from].snapshot()))
        case let .deliver(k, dup):
            if inflight.isEmpty { break }
            let i = k % inflight.count
            let m = inflight[i]
            if !dup { inflight.remove(at: i) }
            reps[m.to].receive(m.snap)
        case let .apply(r): reps[r].apply()
        }
    }
    // 남은 것 다 보내고, 모두가 모두와 주고받는다
    for m in inflight { reps[m.to].receive(m.snap) }
    for _ in 0..<3 {
        for r in reps {
            r.diff()
            r.apply()
            r.diff()
        }
        for a in reps { for b in reps where a !== b { b.receive(a.snapshot()) } }
        for r in reps { r.apply() }
    }
    return (reps, tr)
}

final class ConvergenceTests: XCTestCase {
    let lib: JSONValue = ["books": [["id": .string(BOOK), "name": "b", "start": "2026-09-01T00:00:00Z", "cover": 0, "created": "2026-09-01T00:00:00Z"]]]

    func testReplicasConvergeAndNothingResurrects() {
        let runs = Int(ProcessInfo.processInfo.environment["CONVERGENCE_RUNS"] ?? "300") ?? 300
        for run in 0..<runs {
            let seed = UInt64(0xC0FFEE) &+ UInt64(run) &* 7919
            var rng = Rng(seed)
            let n = rng.int(2, 4)
            let steps = (0..<rng.int(5, 120)).map { _ in randomStep(&rng, n) }
            let skews = (0..<n).map { _ in Int64(rng.int(-600_000, 600_000)) }
            let (reps, tr) = runReplicas(n, steps, skews)
            let views = reps.map { syncedView(lib, [BOOK: $0.data]) }
            for v in views where v != views[0] {
                XCTFail("씨앗 \(seed): 앱 데이터가 다름\n\(v)\n≠\n\(views[0])")
                return
            }
            for key in KEYS {
                let ks = reps.map { CRDT.stateKey($0.states[key] ?? RecState()) }
                for k in ks where k != ks[0] {
                    XCTFail("씨앗 \(seed): 상태가 다름 \(key)")
                    return
                }
            }
            let ids = allIds(reps[0].data)
            for id in tr.mustBeGone() {
                if id.hasPrefix("cat:") {
                    // 형광펜이 모두 지워져 기본값으로 되돌린 경우는 새로 더한 것
                    let c = reps[0].data["prefs"]?["categories"]?.arrayValue?.first { "cat:\(JS.numberString($0["id"]?.numberValue ?? -1))" == id }
                    let def = PlannerModel.defaultCategories.first { "cat:\(JS.numberString($0["id"]?.numberValue ?? -1))" == id }
                    if let c, let def, c["name"] == def["name"] { continue }
                }
                if ids.contains(id) {
                    XCTFail("씨앗 \(seed): 지운 \(id) 가 되살아남")
                    return
                }
            }
        }
    }

    func testMergeIsCommutativeAssociativeIdempotent() {
        for run in 0..<300 {
            var rng = Rng(UInt64(0xBEEF) &+ UInt64(run))
            let steps = (0..<rng.int(5, 80)).map { _ in randomStep(&rng, 3) }
            // 끝까지 맞추지 않은(서로 다른) 상태를 얻는다
            let reps = (0..<3).map { Replica(String(repeating: "0", count: 15) + String($0), skewMs: Int64($0 * 1000)) }
            let tr = Tracker()
            for st in steps {
                switch st {
                case let .edit(r, op): reps[r % 3].data = applyOp(reps[r % 3].data, op, tr)
                case let .diff(r): reps[r % 3].diff()
                case let .send(from, to):
                    reps[from % 3].diff()
                    reps[to % 3].receive(reps[from % 3].snapshot())
                case let .apply(r): reps[r % 3].apply()
                case .deliver: break
                }
            }
            for r in reps { r.diff() }
            for key in KEYS {
                let a = reps[0].states[key] ?? RecState(), b = reps[1].states[key] ?? RecState(), c = reps[2].states[key] ?? RecState()
                XCTAssertEqual(CRDT.stateKey(CRDT.merge(a, b)), CRDT.stateKey(CRDT.merge(b, a)))
                XCTAssertEqual(CRDT.stateKey(CRDT.merge(CRDT.merge(a, b), c)), CRDT.stateKey(CRDT.merge(a, CRDT.merge(b, c))))
                XCTAssertEqual(CRDT.stateKey(CRDT.merge(a, a)), CRDT.stateKey(a))
                XCTAssertEqual(CRDT.stateKey(CRDT.merge(CRDT.merge(a, b), b)), CRDT.stateKey(CRDT.merge(a, b)))
            }
        }
    }

    // MARK: 동시 편집이 사라지지 않는다

    enum Target {
        case comment, theme, dayOff, goal, stars, motto
        case memo(Int), memoTag(Int), hour(Int), taskText(Int), taskMark(Int), taskRow(Int), noteText(Int), catName(Int)
    }

    let TARGETS: [Target] = {
        var t: [Target] = [.comment, .theme, .dayOff]
        for i in 0..<3 { t += [.memo(i), .memoTag(i)] }
        t += (0..<24).map { Target.hour($0) }
        for i in 0..<3 { t += [.taskText(i), .taskMark(i)] }
        t += [.taskRow(3), .noteText(0), .noteText(1), .goal, .stars]
        t += (0..<4).map { Target.catName($0) }
        t.append(.motto)
        return t
    }()
    let D = DATES[1]
    let W = WEEKS[0]

    func base() -> JSONValue {
        var d = PlannerModel.emptyPlannerData().objectValue!
        var day = TDay()
        day.tasks = (0..<4).map { (i: Int) in TTask(id: "0000000\(i)-0000-4000-8000-000000000000", text: "t\(i)", mark: 0, row: i) }
        day.comment = "c"
        day.notes = (0..<2).map { ["id": .string("1000000\($0)-0000-4000-8000-000000000000"), "kind": "text", "start": JSONValue($0 * 10), "end": JSONValue($0 * 10 + 2), "text": .string("n\($0)")] }
        d["days"] = [D: day.json]
        d["weeks"] = [W: ["goal": "g", "review": "", "stars": 1]]
        return .object(d)
    }

    func edit(_ d0: JSONValue, _ t: Target, _ v: Int) -> (data: JSONValue, check: (JSONValue) -> Bool) {
        var d = d0.objectValue!
        var r = TDay(d["days"]![D]!)
        var prefs = d["prefs"]!.objectValue!
        var week = d["weeks"]![W]!.objectValue!
        let s = "v\(v)"
        let D = self.D, W = self.W
        func day(_ x: JSONValue) -> TDay { TDay(x["days"]![D]!) }
        var check: (JSONValue) -> Bool
        switch t {
        case .comment:
            r.comment = s
            check = { day($0).comment == s }
        case .theme:
            r.theme = v % 9
            check = { day($0).theme == v % 9 }
        case .dayOff:
            r.dayOff = true
            check = { day($0).dayOff }
        case let .memo(i):
            r.memos[i] = s
            check = { day($0).memos[i] == s }
        case let .memoTag(i):
            r.memoTags[i] = s
            check = { day($0).memoTags[i] == s }
        case let .hour(h):
            for j in 0..<6 { r.slots[h * 6 + j] = v % 7 }
            check = { day($0).slots[(h * 6)..<(h * 6 + 6)].allSatisfy { $0 == v % 7 } }
        case let .taskText(i):
            r.tasks[i].text = s
            let id = r.tasks[i].id
            check = { day($0).tasks.first { $0.id == id }?.text == s }
        case let .taskMark(i):
            r.tasks[i].mark = 1 + v % 3
            let id = r.tasks[i].id
            check = { day($0).tasks.first { $0.id == id }?.mark == 1 + v % 3 }
        case let .taskRow(i):
            r.tasks[i].row = 20 + v % 5
            r.tasks.sort { $0.row! < $1.row! }
            check = { day($0).tasks.first { $0.id == "00000003-0000-4000-8000-000000000000" }?.row == 20 + v % 5 }
        case let .noteText(i):
            let id = r.notes[i]["id"]!
            var n = r.notes[i].objectValue!
            n["text"] = .string(s)
            r.notes[i] = .object(n)
            check = { day($0).notes.first { $0["id"] == id }?["text"] == .string(s) }
        case .goal:
            week["goal"] = .string(s)
            check = { $0["weeks"]?[W]?["goal"] == .string(s) }
        case .stars:
            week["stars"] = JSONValue(2 + v % 4)
            check = { $0["weeks"]?[W]?["stars"] == JSONValue(2 + v % 4) }
        case let .catName(i):
            var cats = prefs["categories"]!.arrayValue!
            var c = cats[i].objectValue!
            c["name"] = .string(s)
            cats[i] = .object(c)
            prefs["categories"] = .array(cats)
            check = { x in (x["prefs"]?["categories"]?.arrayValue ?? []).first { $0["id"] == JSONValue(i) }?["name"] == .string(s) }
        case .motto:
            prefs["mottoText"] = .string(s)
            check = { $0["prefs"]?["mottoText"] == .string(s) }
        }
        var days = d["days"]!.objectValue!
        days[D] = r.json
        d["days"] = .object(days)
        var weeks = d["weeks"]!.objectValue!
        weeks[W] = .object(week)
        d["weeks"] = .object(weeks)
        d["prefs"] = .object(prefs)
        return (.object(d), check)
    }

    func testConcurrentEditsToDifferentPlacesAllSurvive() {
        for run in 0..<300 {
            var rng = Rng(UInt64(0xABCD) &+ UInt64(run))
            let owner = TARGETS.map { _ in rng.int(0, 2) }
            let skew = Int64(rng.int(-3_600_000, 3_600_000))
            let aFirst = rng.bool()
            let a = Replica("aaaaaaaaaaaaaaaa", skewMs: 0)
            let b = Replica("bbbbbbbbbbbbbbbb", skewMs: skew)
            a.data = base()
            a.diff()
            b.receive(a.snapshot())
            b.apply()
            b.diff()
            var checks: [(JSONValue) -> Bool] = []
            for (i, t) in TARGETS.enumerated() {
                let who = owner[i]
                if who == 0 { continue }
                let rep = who == 1 ? a : b
                let e = edit(rep.data, t, i + 3)
                rep.data = e.data
                checks.append(e.check)
            }
            a.diff()
            b.diff()
            let (x, y) = aFirst ? (a, b) : (b, a)
            y.receive(x.snapshot())
            x.receive(y.snapshot())
            a.apply()
            b.apply()
            for (i, c) in checks.enumerated() {
                XCTAssertTrue(c(a.data), "run \(run) a 편집 \(i)")
                XCTAssertTrue(c(b.data), "run \(run) b 편집 \(i)")
            }
        }
    }

    func pairOfReplicas(skewB: Int64 = 0) -> (Replica, Replica) {
        let a = Replica("aaaaaaaaaaaaaaaa", skewMs: 0)
        let b = Replica("bbbbbbbbbbbbbbbb", skewMs: skewB)
        a.data = base()
        a.diff()
        b.receive(a.snapshot())
        b.apply()
        b.diff()
        return (a, b)
    }

    func exchange(_ a: Replica, _ b: Replica) {
        a.diff()
        b.diff()
        a.receive(b.snapshot())
        b.receive(a.snapshot())
        a.apply()
        b.apply()
    }

    func testSameHourRowConcurrentlyPaintedOneSideWinsDeterministically() {
        let (a, b) = pairOfReplicas()
        a.data = applyOp(a.data, ["t": "paint", "date": 1, "start": 12, "len": 2, "cat": 1])
        b.data = applyOp(b.data, ["t": "paint", "date": 1, "start": 15, "len": 2, "cat": 2])
        exchange(a, b)
        XCTAssertEqual(a.data["days"]?[D]?["slots"], b.data["days"]?[D]?["slots"])
    }

    /// 메모 · 메모 태그는 줄마다 합친다 — 서로 다른 줄의 동시 편집은 둘 다, memoCount 를 넘는 예전 줄도 그대로
    func testMemoLinesMergePerLineAndExtraLinesRoundTrip() {
        let a = Replica("aaaaaaaaaaaaaaaa", skewMs: 0)
        let b = Replica("bbbbbbbbbbbbbbbb", skewMs: 0)
        var d0 = base().objectValue!
        var day0 = TDay(d0["days"]![D]!)
        day0.memos = ["", "", "", "넷째 줄"]
        d0["days"] = [D: day0.json]
        a.data = .object(d0)
        a.diff()
        b.receive(a.snapshot())
        b.apply()
        b.diff()
        XCTAssertEqual(TDay(b.data["days"]![D]!).memos, ["", "", "", "넷째 줄"])
        func editDay(_ rep: Replica, _ f: (inout TDay) -> Void) {
            var d = rep.data.objectValue!
            var r = TDay(d["days"]![D]!)
            f(&r)
            var days = d["days"]!.objectValue!
            days[D] = r.json
            d["days"] = .object(days)
            rep.data = .object(d)
        }
        editDay(a) { $0.memos[0] = "A 첫 줄"; $0.memoTags[2] = "A 태그" }
        editDay(b) { $0.memos[1] = "B 둘째 줄"; $0.memos[3] = "B 넷째 줄" }
        exchange(a, b)
        XCTAssertEqual(TDay(a.data["days"]![D]!).memos, ["A 첫 줄", "B 둘째 줄", "", "B 넷째 줄"])
        XCTAssertEqual(TDay(a.data["days"]![D]!).memoTags, ["", "", "A 태그"])
        XCTAssertEqual(a.data["days"]!.canonical, b.data["days"]!.canonical)
    }

    func testTwoDevicesCarryingTheSameTaskMakeOneTask() {
        let (a, b) = pairOfReplicas()
        a.data = applyOp(a.data, ["t": "carry", "date": 1, "i": 0])
        b.data = applyOp(b.data, ["t": "carry", "date": 1, "i": 0])
        exchange(a, b)
        let next = a.data["days"]![DATES[2]]!["tasks"]!.arrayValue!
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0]["carriedFrom"], "00000000-0000-4000-8000-000000000000")
        XCTAssertEqual(a.data["days"]!.canonical, b.data["days"]!.canonical)
    }

    func testDeletedTaskEditedElsewhereDoesNotResurrect() {
        let (a, b) = pairOfReplicas(skewB: 3_600_000) // b 의 시계가 한 시간 빠르다
        a.data = applyOp(a.data, ["t": "delTask", "date": 1, "i": 0])
        b.data = applyOp(b.data, ["t": "editTask", "date": 1, "i": 0, "text": "고침"])
        exchange(a, b)
        for r in [a, b] {
            XCTAssertFalse((r.data["days"]![D]!["tasks"]!.arrayValue!).contains { $0["id"] == "00000000-0000-4000-8000-000000000000" })
        }
    }
}
