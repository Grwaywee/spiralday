// 기본 형광펜은 고정 상수다 (비공개 docs/sync-engine.md §4.1 · §8): 엔진은 이 목록 그대로인 형광펜을 "설정 안 됨" 으로 본다.
// 어느 버전이 목록을 바꾸면 옛 버전 기기가 채운 옛 기본 목록이 새 엔진에게 사용자 값이 되어 진짜 도장으로 올라간다 — 2026-10-04
// 형광펜 사고가 버전 사이에서 다시. 앱 모델(Kit Prefs.defaultCategories)과 엔진(PlannerModel.defaultCategories)이 글자까지 같고,
// 고정된 목록과 같아야 한다 (TS 엔진 types.ts · web core/model.ts 는 web src/sync/__tests__/defaultFill.test.ts 가 같은 목록과 견준다)
import XCTest
import SpiraldayKit
@testable import SpiraldaySync

final class DefaultCategoriesPinTests: XCTestCase {
    static let pinned: [JSONValue] = [
        ["id": 0, "name": "집중 업무", "hex": "8EDCD2", "counts": true],
        ["id": 1, "name": "미팅", "hex": "F8B38A", "counts": true],
        ["id": 2, "name": "소통·메일", "hex": "A9CFF3", "counts": true],
        ["id": 3, "name": "기획", "hex": "F3DB78", "counts": true],
        ["id": 4, "name": "학습", "hex": "CDB6EF", "counts": true],
        ["id": 5, "name": "개인", "hex": "F6AEC5", "counts": false],
        ["id": 6, "name": "휴식·이동", "hex": "CFCFD4", "counts": false],
    ]

    func testTheBuiltInHighlightersAreOneFixedList() {
        XCTAssertEqual(PlannerModel.defaultCategories, Self.pinned, "엔진")
        let kit: [JSONValue] = Prefs.defaultCategories.map { c in
            ["id": JSONValue(c.id), "name": .string(c.name), "hex": .string(c.hex), "counts": .bool(c.counts)]
        }
        XCTAssertEqual(kit, Self.pinned, "앱 모델 (Kit)")
        XCTAssertEqual(PlannerData().prefs.categories.map(\.id), [0, 1, 2, 3, 4, 5, 6], "새 책")
    }
}
