// 앱 데이터 모양 (SpiraldayKit Models.swift 와 같은 JSON — 모든 Spiralday 앱이 같은 파일 형식을 쓴다)
// 엔진은 앱 JSON 형식을 바꾸지 않는다. 모르는 키는 그대로 두고, 동기화할 때는 통째로(LWW) 옮긴다.
//
//   PlannerData  { days: {yyyy-MM-dd: DayRecord}, weeks: {yyyy-MM-dd: WeekRecord}, prefs: Prefs }
//   DayRecord    { tasks, slots(144), comment, memoTags(3), memos(3), theme?, notes, ddays?, dayOff? }
//   Library      { books: [BookInfo], activeID?, sampleSeeded? }
//   BookInfo     { id, name, start, end?, cover, created, isSample? }   날짜 = Swift .iso8601 ("2026-10-01T15:00:00Z")
import Foundation

public enum PlannerModel {
    public static let slotCount = 144
    public static let slotRows = 24
    public static let slotsPerRow = 6
    public static let memoCount = 3
    public static let maxCategories = 12

    public static let defaultCategories: [JSONValue] = [
        ["id": 0, "name": "집중 업무", "hex": "8EDCD2", "counts": true],
        ["id": 1, "name": "미팅", "hex": "F8B38A", "counts": true],
        ["id": 2, "name": "소통·메일", "hex": "A9CFF3", "counts": true],
        ["id": 3, "name": "기획", "hex": "F3DB78", "counts": true],
        ["id": 4, "name": "학습", "hex": "CDB6EF", "counts": true],
        ["id": 5, "name": "개인", "hex": "F6AEC5", "counts": false],
        ["id": 6, "name": "휴식·이동", "hex": "CFCFD4", "counts": false],
    ]

    public static func emptyDay() -> [String: JSONValue] {
        [
            "tasks": [],
            "slots": .array(Array(repeating: .number(-1), count: slotCount)),
            "comment": "",
            "memoTags": ["", "", ""],
            "memos": ["", "", ""],
            "notes": [],
            "ddays": [],
            "dayOff": false,
        ]
    }

    public static func emptyWeek() -> [String: JSONValue] { ["goal": "", "review": "", "stars": 0] }

    public static func defaultPrefs() -> [String: JSONValue] {
        ["categories": .array(defaultCategories), "lastKind": "daily", "ddays": [], "defaultTheme": 0, "ddaysPerDay": true]
    }

    public static func emptyPlannerData() -> JSONValue {
        ["days": [:], "weeks": [:], "prefs": .object(defaultPrefs())]
    }

    /// DayRecord.hasRecord (D-day · DAY OFF 만 있는 날은 기록이 아니다)
    static func dayHasRecord(tasks: Int, slots: [Int], comment: String, memos: [String], memoTags: [String], theme: Int?, notes: Int) -> Bool {
        !(tasks == 0 && slots.allSatisfy { $0 < 0 } && comment.isEmpty && memos.allSatisfy(\.isEmpty)
            && memoTags.allSatisfy(\.isEmpty) && theme == nil && notes == 0)
    }
}
