// 엔진이 앱에 넣는 값은 Swift 앱(SpiraldayKit)이 늘 읽을 수 있어야 한다.
// 받은 상태에 아무 값(틀린 타입 · 범위 밖 · UUID 가 아닌 id · 모르는 키)이 들어 있어도
// 상태 → 앱 값 → SpiraldayKit 의 진짜 모델(PlannerData · BookInfo)로 읽기가 실패하지 않는지 퍼징한다
// (앱 파일과 같은 JSONDecoder: .iso8601 날짜 — PlannerStore.decodeFile 과 같다).
import XCTest
import SpiraldayKit
@testable import SpiraldaySync

final class AppDecodeTests: XCTestCase {
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func junk(_ r: inout Rng, depth: Int = 0) -> JSONValue {
        switch r.int(0, depth > 1 ? 9 : 11) {
        case 0: return .null
        case 1: return .bool(r.bool())
        case 2: return JSONValue(r.int(-5, 200))
        case 3: return .number(Double(r.int(-1000, 1000)) / 7)
        case 4: return .number(1e300)
        case 5: return .string(r.pick(["", "x", "meal", "text", "2026-10-01T15:00:00Z", "2026-13-01T00:00:00Z", "2026-10-01T15:00:00+09:00", r.uuid(), r.uuid().lowercased(), "-0", "007", "9999999999"]))
        case 6: return .string(r.uuid())
        case 7: return JSONValue(r.int(0, 4))
        case 8: return .string("2026-10-0\(r.int(1, 9))T0\(r.int(0, 9)):00:00Z")
        case 9: return JSONValue(-1)
        case 10: return .array((0..<r.int(0, 8)).map { _ in junk(&r, depth: depth + 1) })
        default: return .object(["a": junk(&r, depth: depth + 1), "b": junk(&r, depth: depth + 1)])
        }
    }

    func stamp(_ r: inout Rng) -> String { Stamps.make(t: Int64(r.int(0, 1000)), c: r.int(0, 50), node: "000000000000000\(r.int(0, 9))") }

    func state(_ r: inout Rng, fields: [String], cols: [String: [String]]) -> RecState {
        var st = RecState()
        for f in fields where r.int(0, 2) > 0 { st.f[f] = FieldEntry(junk(&r), stamp(&r)) }
        for _ in 0..<r.int(0, 3) { st.f["x:" + r.pick(["foo", "bar", "__proto__", "tasks"])] = FieldEntry(junk(&r), stamp(&r)) }
        for (col, fs) in cols {
            var items: [String: ItemState] = [:]
            for _ in 0..<r.int(0, 5) {
                let id = r.pick([r.uuid(), r.uuid().lowercased(), "nope", "3", "-1", "1234567890", "\(r.int(0, 20))"])
                var it = ItemState(a: stamp(&r), d: r.int(0, 4) == 0 ? stamp(&r) : nil)
                for f in fs where r.int(0, 3) > 0 { it.f[f] = FieldEntry(junk(&r), stamp(&r)) }
                if r.bool() { it.f["x:extra"] = FieldEntry(junk(&r), stamp(&r)) }
                items[id] = it
            }
            st.c[col] = items
            if r.bool() { st.f["o:" + col] = FieldEntry(.array(items.keys.shuffled().map { .string($0) } + [junk(&r)]), stamp(&r)) }
        }
        return st
    }

    func testMaterializedValuesAlwaysDecodeInTheSwiftApp() throws {
        let dayFields = ["comment", "theme", "dayOff"] + MEMO_FIELDS + MEMO_TAG_FIELDS + (0..<24).map(slotField)
        let dayCols = ["tasks": ["text", "mark", "cat", "carriedFrom", "row"], "notes": ["kind", "start", "end", "text"], "ddays": ["title", "date", "source"]]
        for run in 0..<600 {
            var r = Rng(UInt64(run) &* 31 &+ 7)
            var data = PlannerModel.emptyPlannerData()
            if r.bool() {
                // 앱에 있던 값 (lastKind 등 기기마다 따로인 값) 위에 넣는다
                data = Records.withPrefs(data, ["lastKind": "weekly"])
            }
            let day = state(&r, fields: dayFields, cols: dayCols)
            data = Records.withDay(data, "2026-10-02", Records.buildDay(day))
            let week = state(&r, fields: ["goal", "review", "stars"], cols: [:])
            data = Records.withWeek(data, "2026-09-28", Records.buildWeek(week))
            let prefs = state(&r, fields: ["defaultTheme", "mottoText"], cols: ["categories": ["name", "hex", "counts"], "ddays": ["title", "date", "source"]])
            data = Records.withPrefs(data, Records.buildPrefs(prefs))
            do {
                let p = try decoder.decode(PlannerData.self, from: data.jsonData())
                // 앱은 형광펜이 1–12개가 아니면 기본값으로 되돌려 읽는다 → 엔진은 늘 1–12개를 넣는다
                XCTAssertTrue((1...12).contains(p.prefs.categories.count), "run \(run)")
            } catch {
                XCTFail("run \(run): 앱이 읽지 못함 \(error)\n\(data.canonical.prefix(2000))")
                return
            }
            let book = state(&r, fields: ["name", "start", "end", "cover", "created"], cols: [:])
            if case let .book(b)? = Records.buildBook(r.uuid(), book) {
                XCTAssertNoThrow(try decoder.decode(BookInfo.self, from: b.jsonData()), "run \(run) \(b.canonical)")
            }
        }
    }
}
