// 앱 기본 형광펜은 세 벌이 한 값이다 (감사 A · O, 묶음 S): Mac · iOS 의 Kit (Prefs.defaultCategories), Swift 엔진
// (PlannerModel.defaultCategories), 그리고 Windows · Android 의 web 앱 · TS 엔진 — 그쪽은 비공개 저장소의
// web/tests/defaultCategoriesParity.test.ts 가 같은 JSON (sync/engine/test/fixtures/default-categories.json) 과 견준다.
// 이 저장소의 Tests/Fixtures/default-categories.json 은 그 파일을 그대로 옮긴 것이다 (바이트까지 같게 둔다).
// 엔진은 이 목록 그대로를 "설정 안 됨" 으로 본다 (비공개 docs/sync-engine.md §4.1) — 한 벌만 달라도 그 기기의 기본 형광펜이
// 진짜 편집이 되어 다른 기기의 형광펜을 이긴다 (2026-10-04 형광펜 사고가 버전 · 플랫폼 사이에서 다시).
//
// 같은 묶음: 옛 D-day 하나짜리 파일(ddayTitle · ddayDate)의 D-day id 는 값에서 정한다 — 같은 옛 파일을 읽은 두 기기가
// D-day 를 둘 만들지 않게 (web core/model.ts legacyDDayId 와 같은 규칙 · 같은 벡터).
import XCTest
import SpiraldayKit
@testable import SpiraldaySync

final class DefaultCategoriesParityTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/default-categories.json")

    private func fixtureCategories() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.fixture)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["categories"] as? [[String: Any]])
    }

    /// Kit == 엔진 == 공유 JSON (순서 · id · 이름 · 색 · TOTAL TIME 에 넣는지 — 그 밖의 키 없음)
    func testKitEngineAndTheSharedFixtureAreOneList() throws {
        let want = try fixtureCategories()
        XCTAssertEqual(want.count, 7)
        for c in want { XCTAssertEqual(Set(c.keys), ["id", "name", "hex", "counts"]) }
        let kit = Prefs.defaultCategories
        XCTAssertEqual(kit.count, want.count, "Kit")
        for (k, w) in zip(kit, want) {
            XCTAssertEqual(k.id, w["id"] as? Int, "Kit")
            XCTAssertEqual(k.name, w["name"] as? String, "Kit")
            XCTAssertEqual(k.hex, w["hex"] as? String, "Kit")
            XCTAssertEqual(k.counts, w["counts"] as? Bool, "Kit")
        }
        let engine = PlannerModel.defaultCategories
        XCTAssertEqual(engine.count, want.count, "엔진")
        for (e, w) in zip(engine, want) {
            let o = try XCTUnwrap(e.objectValue)
            XCTAssertEqual(Set(o.keys), ["id", "name", "hex", "counts"], "엔진")
            XCTAssertEqual(o["id"], JSONValue(try XCTUnwrap(w["id"] as? Int)), "엔진")
            XCTAssertEqual(o["name"], .string(try XCTUnwrap(w["name"] as? String)), "엔진")
            XCTAssertEqual(o["hex"], .string(try XCTUnwrap(w["hex"] as? String)), "엔진")
            XCTAssertEqual(o["counts"], .bool(try XCTUnwrap(w["counts"] as? Bool)), "엔진")
        }
    }

    /// 앱이 채우는 목록 (새 책 · 형광펜이 없는 파일 · 12개를 넘는 파일) 을 앱이 파일에 쓴 그대로 엔진이 읽으면 "설정 안 됨" 이다.
    /// 이름 하나를 바꾼 목록은 진짜 목록이다
    func testWhatTheKitFillsIsWhatTheEngineCallsNotSet() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        func engineSees(_ p: Prefs) throws -> Bool {
            let v = try JSONValue.parse(enc.encode(p))
            let flat = Records.flattenPrefs(v)
            return Records.isDefaultCategoryList(flat.c["categories"] ?? [])
        }
        XCTAssertTrue(try engineSees(PlannerData().prefs), "새 책")
        XCTAssertTrue(try engineSees(dec.decode(Prefs.self, from: Data("{}".utf8))), "형광펜이 없는 파일")
        let thirteen = (0..<13).map { #"{"id":\#($0),"name":"펜 \#($0)","hex":"8EDCD2","counts":true}"# }.joined(separator: ",")
        XCTAssertTrue(try engineSees(dec.decode(Prefs.self, from: Data(#"{"categories":[\#(thirteen)]}"#.utf8))), "12개를 넘는 파일")
        var renamed = Prefs()
        renamed.categories[0].name = "개발 업무"
        XCTAssertFalse(try engineSees(renamed), "이름을 바꾼 목록은 진짜 목록")
    }

    // MARK: 옛 D-day id

    /// 같은 옛 파일을 몇 번 읽어도 · 어느 기기가 읽어도 같은 id (web 과 같은 벡터)
    func testTheLegacyDDayGetsTheSameIdEveryTime() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let raw = Data(#"{"days":{},"weeks":{},"prefs":{"ddayTitle":"시험","ddayDate":"2026-11-01T15:00:00Z"}}"#.utf8)
        let a = try XCTUnwrap(dec.decode(PlannerData.self, from: raw).prefs.ddays.first)
        let b = try XCTUnwrap(dec.decode(PlannerData.self, from: raw).prefs.ddays.first)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.title, "시험")
        // 플랫폼 사이 벡터 (비공개 web/tests/model.test.ts · docs/sync-engine.md §8)
        XCTAssertEqual(a.id.uuidString, "116E4CC2-C837-5BC7-BDC4-D978F1815524")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T15:00:00Z"))
        XCTAssertEqual(DDay.legacyID(title: "시험", date: date).uuidString, "116E4CC2-C837-5BC7-BDC4-D978F1815524")
        XCTAssertEqual(DDay.legacyID(title: "", date: date).uuidString, "3C5CDE39-1608-5570-B18B-E1D194313092")
        // 제목이 없어도 하나의 id
        let untitled = Data(#"{"days":{},"weeks":{},"prefs":{"ddayDate":"2026-11-01T15:00:00Z"}}"#.utf8)
        XCTAssertEqual(try dec.decode(PlannerData.self, from: untitled).prefs.ddays.first?.id.uuidString,
                       "3C5CDE39-1608-5570-B18B-E1D194313092")
        // 새 형식(ddays 목록)이 있으면 옛 값은 보지 않는다 (그 목록의 id 그대로)
        let both = Data(#"{"days":{},"weeks":{},"prefs":{"ddays":[{"id":"0D594A5F-8FD8-50CA-803B-6260FFD0478F","title":"새","date":"2026-12-01T00:00:00Z"}],"ddayTitle":"시험","ddayDate":"2026-11-01T15:00:00Z"}}"#.utf8)
        XCTAssertEqual(try dec.decode(PlannerData.self, from: both).prefs.ddays.map(\.id.uuidString), ["0D594A5F-8FD8-50CA-803B-6260FFD0478F"])
    }
}
