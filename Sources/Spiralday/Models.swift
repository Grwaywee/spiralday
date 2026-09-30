import Foundation
import SwiftUI
import AppKit

// MARK: - Data

enum Mark: Int, Codable, CaseIterable {
    case none, done, partial, missed, moved

    var next: Mark { Mark(rawValue: (rawValue + 1) % Mark.allCases.count)! }

    var label: String {
        switch self {
        case .none: "표시 없음"
        case .done: "완료  ○"
        case .partial: "일부  △"
        case .missed: "못함  ×"
        case .moved: "미룸  →"
        }
    }
}

struct PlanTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var mark: Mark = .none
    var cat: Int? = nil
    /// → (미룸) 으로 전날에서 넘어온 할 일이면: 전날 할 일의 id (1.0.4).
    /// 없으면 nil — 예전 파일에는 없는 키라 nil 로 읽고, nil 이면 JSON 에 적지 않는다 (자동 Codable 의 Optional 규칙).
    var carriedFrom: UUID? = nil
    /// 일간 TASKS 의 몇째 줄에 적었는지 (0 부터, 1.0.5). 할 일은 적은 줄에 그대로 있고 저절로 모이거나 옮겨지지 않는다.
    /// 예전 파일에는 없는 키라 nil 로 읽고, 처음 열 때 그때 보이던 줄을 매긴다 (DayRecord.assignTaskRows).
    var row: Int? = nil
}

/// 타임테이블 위에 쓰는 것: 손글씨 메모, 밥시간(아이콘 → 화살표)
struct TimeNote: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, meal }
    var id = UUID()
    var kind: Kind
    /// 시작 / 끝 칸 (0...143, 끝 칸 포함)
    var start: Int
    var end: Int
    var text = ""
}

struct DayRecord: Codable, Equatable {
    static let slotCount = 144 // 24 rows (06시 시작) × 6 칸(10분)
    static let memoCount = 3

    var tasks: [PlanTask] = []
    var slots: [Int] = Array(repeating: -1, count: DayRecord.slotCount)
    /// COMMENT 칸
    var comment = ""
    /// MEMO 3줄 (왼쪽 작은 칸 + 본문)
    var memoTags: [String] = Array(repeating: "", count: DayRecord.memoCount)
    var memos: [String] = Array(repeating: "", count: DayRecord.memoCount)
    /// 이 날의 컬러 컨셉 (nil = 기본값 따르기)
    var theme: Int? = nil
    /// 타임테이블 메모 · 밥시간
    var notes: [TimeNote] = []
    /// 이 날에 붙인 D-day (최대 Prefs.maxDDays 개). 저장한 D-day 를 복사해 둔 것이라
    /// 목록에서 고치거나 지워도, 다른 날에 붙인 것을 바꿔도 이 날은 그대로다.
    var ddays: [DDay] = []
    /// 쉬는 날 (1.0.4). COMMENT 칸에 DAY OFF 가 찍히고, 연속 기록을 끊지 않는다.
    /// 적어 둔 COMMENT 는 지우지 않고 그대로 둔다 (작성하기로 돌아오면 다시 보인다).
    var dayOff = false

    private enum CodingKeys: String, CodingKey {
        case tasks, slots, comment, memoTags, memos, theme, notes, ddays, dayOff
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([PlanTask].self, forKey: .tasks) ?? []
        let s = try c.decodeIfPresent([Int].self, forKey: .slots) ?? []
        slots = Array(Self.pad(s, Self.slotCount, -1).prefix(Self.slotCount))
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        memoTags = Self.pad(try c.decodeIfPresent([String].self, forKey: .memoTags) ?? [], Self.memoCount, "")
        memos = Self.pad(try c.decodeIfPresent([String].self, forKey: .memos) ?? [], Self.memoCount, "")
        theme = try c.decodeIfPresent(Int.self, forKey: .theme)
        notes = try c.decodeIfPresent([TimeNote].self, forKey: .notes) ?? []
        ddays = try c.decodeIfPresent([DDay].self, forKey: .ddays) ?? []
        dayOff = try c.decodeIfPresent(Bool.self, forKey: .dayOff) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(slots, forKey: .slots)
        try c.encode(comment, forKey: .comment)
        try c.encode(memoTags, forKey: .memoTags)
        try c.encode(memos, forKey: .memos)
        try c.encodeIfPresent(theme, forKey: .theme)
        try c.encode(notes, forKey: .notes)
        // D-day 를 붙인 날만 적는다 (붙이지 않은 날은 예전 파일 모양 그대로)
        if !ddays.isEmpty { try c.encode(ddays, forKey: .ddays) }
        // 쉬는 날만 적는다
        if dayOff { try c.encode(true, forKey: .dayOff) }
    }

    private static func pad<T>(_ a: [T], _ n: Int, _ fill: T) -> [T] {
        a.count >= n ? a : a + Array(repeating: fill, count: n - a.count)
    }

    /// D-day 말고 적거나 칠하거나 고른 것이 있는지. "기록한 날" 은 이것으로 센다
    /// (D-day 만 붙인 날, DAY OFF 만 고른 날은 기록이 아니다).
    var hasRecord: Bool {
        !(tasks.isEmpty && slots.allSatisfy { $0 < 0 } && comment.isEmpty
            && memos.allSatisfy(\.isEmpty) && memoTags.allSatisfy(\.isEmpty) && theme == nil && notes.isEmpty)
    }

    /// 저장할 것이 하나도 없는지. D-day 만 붙인 날, DAY OFF 만 고른 날도 비어 있지 않다 (지우지 않고 저장한다).
    var isEmpty: Bool { !hasRecord && ddays.isEmpty && !dayOff }
}

// MARK: - 할 일 줄 (1.0.5)
// 할 일은 TASKS 의 아무 줄에나 쓰고(PlanTask.row), 형광펜(분류)은 쓴 뒤에 왼쪽 칸을 눌러 고른다.
// tasks 배열은 늘 줄 순서로 둔다 (주간 페이지 · 통계 · 예시 점검이 그 순서로 읽는다).

extension DayRecord {
    /// 모든 할 일에 줄이 있고, 줄 순서대로 놓여 있고, 겹치지 않는지
    var taskRowsReady: Bool {
        var last = -1
        for t in tasks {
            guard let r = t.row, r > last else { return false }
            last = r
        }
        return true
    }

    /// 줄 번호가 없는 할 일에 줄을 매기고 줄 순서로 놓는다.
    /// - 모두 없으면 (1.0.4 까지의 기록): 그때 보이던 그대로 — 같은 형광펜끼리 모은 순서로, 긴 할 일이 이어 쓰던 줄까지.
    ///   (한 줄짜리만 있으면 0, 1, 2, …) 백업 없이 메모리에서 바꾸고 다음 저장 때 파일에 적힌다 (키만 늘어난다).
    /// - 일부만 없거나 같은 줄에 둘이면: 줄이 있는 것은 그대로, 나머지는 위에서부터 빈 줄에.
    mutating func assignTaskRows() {
        guard !taskRowsReady else { return }
        if tasks.allSatisfy({ $0.row == nil }) {
            let g = PlannerStore.grouped(tasks)
            let starts = DailyForm.legacyTaskRows(g.map(\.text))
            tasks = g.enumerated().map { i, t in
                var t = t
                t.row = i < starts.count ? starts[i] : i
                return t
            }
            return
        }
        var used = Set<Int>()
        var pending: [Int] = []
        let order = tasks.indices.sorted { (tasks[$0].row ?? .max, $0) < (tasks[$1].row ?? .max, $1) }
        for i in order {
            if let r = tasks[i].row, r >= 0, used.insert(r).inserted { continue }
            pending.append(i)
        }
        var next = 0
        for i in pending {
            while used.contains(next) { next += 1 }
            tasks[i].row = next
            used.insert(next)
        }
        tasks = order.map { tasks[$0] }.sorted { $0.row! < $1.row! }
    }

    /// 할 일을 제 줄에 놓은 모양 (긴 할 일이 이어 쓴 줄, 막혀서 줄인 글자, 늘어난 칸 수). 일간 페이지와 같은 계산.
    var taskLayout: RuledText.RowLayout { DailyForm.taskLayout(tasks) }

    /// 할 일이 쓰고 있는 마지막 줄 (긴 할 일이 이어 쓴 줄까지). which 에 맞는 할 일이 없으면 nil.
    func lastTaskLine(where which: (PlanTask) -> Bool) -> Int? {
        let L = taskLayout
        return tasks.indices.last(where: { which(tasks[$0]) }).map { L.items[$0].row + L.items[$0].span - 1 }
    }

    /// 새 할 일을 놓을 줄: after 보다 아래의 첫 빈 줄 → 없으면 맨 위부터 첫 빈 줄 →
    /// 그래도 없으면 맨 끝에 한 줄 더 (그만큼 TASKS 칸 수가 늘고 모든 줄이 같은 비율로 조금 작아진다).
    func freeTaskRow(after: Int) -> Int {
        let L = taskLayout
        if let r = L.emptyRows.first(where: { $0 > after }) ?? L.emptyRows.first { return r }
        return L.rows
    }

    /// 할 일 하나를 row 줄에 넣는다 (그 줄을 이미 다른 할 일이 쓰고 있으면 그 아래 빈 줄에). 넣은 줄을 돌려준다.
    @discardableResult
    mutating func insertTask(_ t: PlanTask, row: Int) -> Int {
        assignTaskRows()
        var t = t
        let r = row < 0 || taskLayout.owner(row) != nil ? freeTaskRow(after: row) : row
        t.row = r
        tasks.append(t)
        tasks.sort { $0.row! < $1.row! }
        return r
    }

    /// → 로 전날에서 넘어온 할 일을 넣는다: 같은 형광펜(없음은 없음끼리) 할 일이 쓰는 마지막 줄 아래의 첫 빈 줄 →
    /// 그 형광펜이 없거나 아래에 빈 줄이 없으면 맨 위부터 첫 빈 줄 → 빈 줄이 하나도 없으면 맨 끝에 한 줄 더.
    /// 마지막 경우에 맨 끝에 붙이는 것은: 이미 쓴 할 일의 줄을 옮기지 않고(쓴 자리는 그대로), 넘어온 할 일도 가리지 않고
    /// 보이게 하려는 것. TASKS 칸 수가 하나 늘고 모든 줄이 같은 비율로 조금 작아진다 (1.0.4 에서 넘칠 때와 같은 모양).
    /// 앱의 → (PlannerStore.setMark) 와 예시 플래너가 같이 쓴다.
    @discardableResult
    mutating func insertCarried(_ t: PlanTask) -> Int {
        assignTaskRows()
        // 같은 형광펜 묶음이 있으면 그 바로 아래로 (아래 할 일들은 빈 줄이 나올 때까지 한 줄씩 내려간다)
        if t.cat != nil, let end = lastTaskLine(where: { $0.cat == t.cat }) {
            return insertShifting(t, at: end + 1)
        }
        let after = lastTaskLine { $0.cat == t.cat } ?? -1
        return insertTask(t, row: freeTaskRow(after: after))
    }

    /// row 줄에 할 일을 끼워 넣는다. 그 줄부터 이어진 할 일들은 빈 줄이 나올 때까지 한 줄씩 아래로 밀린다
    /// (빈 줄이 없으면 맨 끝에 한 줄 더). 1.0.4 까지처럼 같은 형광펜끼리 붙여 두려고 쓴다.
    @discardableResult
    mutating func insertShifting(_ t: PlanTask, at row: Int) -> Int {
        assignTaskRows()
        var cursor = row + 1
        for k in tasks.indices where tasks[k].row! >= row {
            guard tasks[k].row! < cursor else { break }   // 빈 줄을 만나면 거기서 멈춘다
            tasks[k].row = cursor
            cursor += 1
        }
        var t = t
        t.row = row
        tasks.append(t)
        tasks.sort { $0.row! < $1.row! }
        return row
    }

    /// 형광펜을 고른 할 일을 같은 형광펜 묶음으로 옮긴다: 그 형광펜을 쓰는 다른 할 일이 있고
    /// 이미 그 묶음에 붙어 있지 않으면, 묶음의 마지막 줄 바로 아래로 (insertShifting). 없으면 제 줄에 그대로.
    mutating func joinCategoryGroup(_ id: UUID) {
        assignTaskRows()
        guard let i = tasks.firstIndex(where: { $0.id == id }), let cat = tasks[i].cat else { return }
        let L = taskLayout
        let others = tasks.indices.filter { $0 != i && tasks[$0].cat == cat }
        guard !others.isEmpty else { return }
        let start = L.items[i].row, end = start + L.items[i].span
        // 이미 묶음 바로 아래나 바로 위에 붙어 있으면 그대로
        if others.contains(where: { L.items[$0].row + L.items[$0].span == start || L.items[$0].row == end }) { return }
        let t = tasks.remove(at: i)
        guard let groupEnd = lastTaskLine(where: { $0.cat == cat }) else { tasks.insert(t, at: i); return }
        insertShifting(t, at: groupEnd + 1)
    }
}

struct WeekRecord: Codable, Equatable {
    var goal = ""
    var review = ""
    var stars = 0
}

struct Category: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var hex: String
    var counts: Bool

    var color: Color { Color(hex: hex) }
}

struct Prefs: Codable, Equatable {
    var categories: [Category] = Prefs.defaultCategories
    var lastKind: PageKind = .daily
    /// 저장한 D-day 목록 (개수 제한 없음). 날마다 여기서 골라 그날에 복사해 붙인다 (DayRecord.ddays).
    /// 목록을 고치거나 지워도 이미 붙인 날은 바뀌지 않는다.
    var ddays: [DDay] = []
    /// 따로 고르지 않은 날의 컬러 컨셉
    var defaultTheme = 0
    /// D-day 를 날마다 따로 붙이는 파일인지. 1.0.2 까지의 파일은 false 로 읽혀서 처음 열 때 한 번 옮긴다.
    var ddaysPerDay = true
    /// 첫 장(표지 다음 장)에 적는 말. 비어 있으면 파일에 남기지 않는다.
    var motto: String {
        get { mottoText ?? "" }
        set { mottoText = newValue.isEmpty ? nil : newValue }
    }
    private var mottoText: String?

    /// 하루에 붙일 수 있는 D-day 수
    static let maxDDays = 2
    static let maxCategories = 12

    private enum LegacyKeys: String, CodingKey { case ddayTitle, ddayDate }

    static let defaultCategories: [Category] = [
        Category(id: 0, name: "집중 업무", hex: "8EDCD2", counts: true),
        Category(id: 1, name: "미팅", hex: "F8B38A", counts: true),
        Category(id: 2, name: "소통·메일", hex: "A9CFF3", counts: true),
        Category(id: 3, name: "기획", hex: "F3DB78", counts: true),
        Category(id: 4, name: "학습", hex: "CDB6EF", counts: true),
        Category(id: 5, name: "개인", hex: "F6AEC5", counts: false),
        Category(id: 6, name: "휴식·이동", hex: "CFCFD4", counts: false),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cats = try c.decodeIfPresent([Category].self, forKey: .categories) ?? []
        categories = (1...Prefs.maxCategories).contains(cats.count) ? cats : Prefs.defaultCategories
        lastKind = try c.decodeIfPresent(PageKind.self, forKey: .lastKind) ?? .daily
        ddays = try c.decodeIfPresent([DDay].self, forKey: .ddays) ?? []
        // 예전 버전의 D-day 하나짜리 저장 형식
        if ddays.isEmpty, let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let date = try legacy.decodeIfPresent(Date.self, forKey: .ddayDate) {
            ddays = [DDay(title: try legacy.decodeIfPresent(String.self, forKey: .ddayTitle) ?? "", date: date)]
        }
        defaultTheme = try c.decodeIfPresent(Int.self, forKey: .defaultTheme) ?? 0
        ddaysPerDay = try c.decodeIfPresent(Bool.self, forKey: .ddaysPerDay) ?? false
        mottoText = try c.decodeIfPresent(String.self, forKey: .mottoText).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct DDay: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var date: Date
    /// 날에 붙인 복사본이면: 복사해 온 저장한 D-day 의 id (새로 만들어 목록에 저장하지 않았으면 nil)
    var source: UUID? = nil

    /// 기준 날에서 센 "D-3" / "D-DAY" / "D+2"
    func count(from day: Date) -> String {
        let n = Dates.daysBetween(day, date)
        return n > 0 ? "D-\(n)" : n == 0 ? "D-DAY" : "D+\(-n)"
    }
}

struct PlannerData: Codable {
    var days: [String: DayRecord] = [:]
    var weeks: [String: WeekRecord] = [:]
    var prefs = Prefs()
}

// MARK: - Dates

enum Dates {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "ko_KR")
        c.timeZone = .current
        return c
    }()

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { keyFormatter.string(from: d) }
    static func parse(_ key: String) -> Date? { keyFormatter.date(from: key) }
    static func day(_ d: Date) -> Date { cal.startOfDay(for: d) }
    static func weekStart(_ d: Date) -> Date {
        cal.dateInterval(of: .weekOfYear, for: d)?.start ?? day(d)
    }
    static func add(days n: Int, to d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        cal.dateComponents([.day], from: day(a), to: day(b)).day ?? 0
    }
    static func isToday(_ d: Date) -> Bool { cal.isDateInToday(d) }
    static func comp(_ d: Date) -> DateComponents {
        cal.dateComponents([.year, .month, .day, .weekday, .weekOfYear], from: d)
    }

    static let weekdayEN = ["", "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    static let monthEN = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let monthFull = ["", "January", "February", "March", "April", "May", "June", "July",
                            "August", "September", "October", "November", "December"]
}

func formatHM(_ minutes: Int) -> (String, String) {
    (String(minutes / 60), String(format: "%02d", minutes % 60))
}

// MARK: - Store

/// 플래너 한 권 (책). 기록은 권마다 따로 저장된다.
struct BookInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// 첫 장 (반드시 있다). 이 날 이전으로는 넘어가지 않는다.
    var start: Date
    /// 마지막 장 (없으면 끝없이 넘어간다)
    var end: Date? = nil
    /// 표지 색 (ColorConcept id)
    var cover = 0
    var created = Date()
    /// 앱이 꽂아 둔 예시 플래너인지 (1.0.4). 다른 책과 똑같이 쓰고 지울 수 있고, 표시만 다르다.
    /// "플래너가 없다(첫 실행)" 를 셀 때는 빼고 센다 (PlannerStore.userBooks).
    var isSample = false

    private enum CodingKeys: String, CodingKey { case id, name, start, end, cover, created, isSample }

    /// 날짜가 이 책 안에 있는지
    func contains(_ d: Date) -> Bool {
        let day = Dates.day(d)
        if day < Dates.day(start) { return false }
        if let end, day > Dates.day(end) { return false }
        return true
    }

    var periodText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy. M. d."
        return "\(f.string(from: start)) – \(end.map { f.string(from: $0) } ?? "계속")"
    }
}

// 예시 표시는 1.0.4 부터: 예전 파일은 false 로 읽고, 예시가 아닌 책은 예전 모양 그대로 적는다
extension BookInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        cover = try c.decode(Int.self, forKey: .cover)
        created = try c.decode(Date.self, forKey: .created)
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encode(cover, forKey: .cover)
        try c.encode(created, forKey: .created)
        if isSample { try c.encode(true, forKey: .isSample) }
    }
}

struct Library: Codable {
    var books: [BookInfo] = []
    var activeID: UUID? = nil
    /// 예시 플래너를 한 번 꽂아 뒀는지 (1.0.4). 사용자가 지운 뒤에 저절로 다시 만들지 않으려고
    /// 책 목록과 같은 파일에 적는다 (책과 표시가 한 번에 같이 저장되고, 데이터 폴더를 따라다닌다).
    var sampleSeeded = false
}

extension Library {
    private enum Keys: String, CodingKey { case books, activeID, sampleSeeded }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        books = try c.decodeIfPresent([BookInfo].self, forKey: .books) ?? []
        activeID = try c.decodeIfPresent(UUID.self, forKey: .activeID)
        sampleSeeded = try c.decodeIfPresent(Bool.self, forKey: .sampleSeeded) ?? false
    }
}

@MainActor
final class PlannerStore: ObservableObject {
    /// 지금 펼친 책의 내용
    @Published var data: PlannerData
    /// 모든 책 목록과 펼친 책
    @Published private(set) var library = Library()
    /// 데이터가 바뀔 때마다 올라간다 (페이지 스냅샷 캐시 무효화용)
    private(set) var version = 0

    /// 저장 폴더 (메모리 전용이면 nil)
    let folder: URL?
    private var saveWork: DispatchWorkItem?
    /// library.json 이 있는데 읽지 못했다 → 앱이 저절로 덮어쓰지 않는다 (예시 플래너를 꽂지 않는다)
    private var libraryUnreadable = false
    /// 메모리 전용일 때 펼치지 않은 책의 내용 (파일 대신)
    private var memoryBooks: [UUID: PlannerData] = [:]

    var books: [BookInfo] { library.books }
    var activeBook: BookInfo? { library.books.first { $0.id == library.activeID } }
    /// 사용자가 만든 책 (예시 플래너는 뺀다). "플래너가 한 권도 없다 = 처음" 은 이것으로 센다.
    var userBooks: [BookInfo] { library.books.filter { !$0.isSample } }
    var hasSampleBook: Bool { library.books.contains(where: \.isSample) }

    /// 이 책 말고 펼칠 책: 사용자가 만든 책이 먼저, 없으면 예시 플래너
    func fallbackBook(excluding id: UUID?) -> BookInfo? {
        let rest = library.books.filter { $0.id != id }
        return rest.first { !$0.isSample } ?? rest.first
    }

    private static let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 앱의 저장 폴더(~/Library/Application Support/Spiralday)를 쓰거나, 메모리에서만 쓴다
    convenience init(inMemory: Bool = false) {
        guard !inMemory else {
            self.init(folder: nil)
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Spiralday", isDirectory: true)
        PlannerStore.migrateFolder(from: support.appendingPathComponent("PaperPlanner", isDirectory: true), to: dir)
        self.init(folder: dir)
    }

    /// folder 에 저장하는 저장소 (nil = 메모리 전용). `--sample-book-test` 는 임시 폴더로 첫 실행 · 업데이트를 흉내 낸다.
    init(folder dir: URL?) {
        data = PlannerData()
        folder = dir
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("books", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let rawLibrary = try? Data(contentsOf: libraryURL!)
        if let rawLibrary, let lib = try? Self.dec.decode(Library.self, from: rawLibrary) {
            library = lib
        } else {
            libraryUnreadable = rawLibrary != nil
            migrateLegacy()
        }
        // 펼친 책이 없으면 사용자가 만든 첫 책을 편다. 예시 플래너만 있으면(첫 실행 도중) 펴지 않고
        // 튜토리얼에서 만든 책이 펼쳐지게 둔다.
        if activeBook == nil { library.activeID = userBooks.first?.id }
        if let id = library.activeID { data = loadBook(id) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// 예전 이름(Spiralday) 시절의 데이터 폴더를 새 이름 폴더로 복사한다. 원본은 그대로 둔다.
    private static func migrateFolder(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.copyItem(at: old, to: new)
    }

    private var libraryURL: URL? { folder?.appendingPathComponent("library.json") }
    private func bookURL(_ id: UUID) -> URL? { folder?.appendingPathComponent("books/\(id.uuidString).json") }
    /// 펼친 책의 저장 파일
    var activeBookURL: URL? { library.activeID.flatMap(bookURL) }

    private func loadBook(_ id: UUID) -> PlannerData {
        if folder == nil { return memoryBooks[id] ?? PlannerData() }
        guard let url = bookURL(id),
              var d = Self.openBookFile(url, book: library.books.first { $0.id == id })?.data else { return PlannerData() }
        // 1.0.4 까지의 기록: 할 일에 그때 보이던 줄을 매긴다 (다음 저장 때 파일에 적힌다)
        for (k, r) in d.days where !r.taskRowsReady { d.days[k]?.assignTaskRows() }
        return d
    }

    // MARK: D-day 옮기기 (1.0.3: 모든 날에 같은 D-day → 날마다 따로)

    /// 옮긴 결과 요약
    struct DDayMigration {
        /// 저장한 D-day 목록에 남은 개수
        var library = 0
        /// D-day 를 복사해 붙인 날 (yyyy-MM-dd)
        var stampedDays: [String] = []
        var todayKey = ""
        /// 옮긴 뒤 오늘 붙어 있는 D-day
        var today: [DDay] = []
        /// 옮기기 전 원본을 남긴 파일 (이번에 새로 만들었으면 true)
        var backup: URL? = nil
        var backupCreated = false
    }

    /// 옮기기 전 원본을 남기는 파일: "<책 파일>.before-per-day-dday.json"
    /// 옮기기 코드는 지우지 않는다. 사용자가 그 책을 지울 때만 같이 지운다 (deleteBook).
    static func ddayBackupURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".before-per-day-dday.json") }

    /// 책 파일을 읽는다. D-day 를 날마다 따로 붙이기 전(1.0.2 까지)의 파일이면
    /// 원본을 옆에 백업으로 남기고 → 옮기고 → 그 파일에 저장한다. 이미 옮긴 파일이면 읽기만 한다.
    /// loadBook 과 `--dday-migrate-test` 가 같이 쓴다.
    static func openBookFile(_ url: URL, book: BookInfo?, today: Date = Date()) -> (data: PlannerData, migration: DDayMigration?)? {
        guard let raw = try? Data(contentsOf: url), var d = try? dec.decode(PlannerData.self, from: raw) else { return nil }
        guard !d.prefs.ddaysPerDay else { return (d, nil) }
        // 무엇이든 바꾸기 전에 원본을 남긴다. 남기지 못하면 이번에는 옮기지 않는다.
        let backup = ddayBackupURL(url)
        var created = false
        if !FileManager.default.fileExists(atPath: backup.path) {
            guard (try? raw.write(to: backup, options: .withoutOverwriting)) != nil else { return (d, nil) }
            created = true
        }
        var m = migrateDDaysPerDay(&d, today: today, book: book)
        m.backup = backup
        m.backupCreated = created
        if let out = try? enc.encode(d) { try? out.write(to: url, options: .atomic) }
        return (d, m)
    }

    /// 예전 파일은 D-day 한 목록(prefs.ddays)을 모든 일간 페이지에 보여 줬다.
    /// 이미 쓴 날(기록이 있는 날)과 오늘에는 그 D-day 를 복사해 붙여서 전과 똑같이 보이게 하고,
    /// 나머지 날은 비워 둔다. 목록은 "저장한 D-day" 로 그대로 남긴다.
    /// 이미 D-day 가 붙은 날은 건드리지 않고, 옮긴 뒤에는 ddaysPerDay = true 라서 두 번 붙이지 않는다.
    static func migrateDDaysPerDay(_ d: inout PlannerData, today: Date, book: BookInfo?) -> DDayMigration {
        let lib = d.prefs.ddays
        let tk = Dates.key(today)
        var m = DDayMigration(library: lib.count, todayKey: tk)
        if !d.prefs.ddaysPerDay, !lib.isEmpty {
            // 날마다 새 id 로 복사 (예전 페이지에 보이던 것은 앞의 두 개)
            func copies() -> [DDay] { lib.prefix(Prefs.maxDDays).map { DDay(title: $0.title, date: $0.date, source: $0.id) } }
            for k in d.days.keys.sorted() {
                guard let r = d.days[k], r.hasRecord, r.ddays.isEmpty else { continue }
                d.days[k]?.ddays = copies()
                m.stampedDays.append(k)
            }
            // 오늘은 아직 아무것도 안 썼어도 전처럼 보이게 (책 기간 밖이면 두지 않는다)
            if book?.contains(today) ?? true, d.days[tk]?.ddays.isEmpty ?? true {
                var r = d.days[tk] ?? DayRecord()
                r.ddays = copies()
                d.days[tk] = r
                m.stampedDays.append(tk)
            }
        }
        d.prefs.ddaysPerDay = true
        m.today = d.days[tk]?.ddays ?? []
        return m
    }

    /// 한 권짜리 예전 저장 파일(planner.json)을 첫 번째 책 "내 플래너" 로 옮긴다. 원본은 백업으로 남긴다.
    private func migrateLegacy() {
        guard let folder else { return }
        let legacy = folder.appendingPathComponent("planner.json")
        guard let raw = try? Data(contentsOf: legacy), let old = try? Self.dec.decode(PlannerData.self, from: raw) else { return }
        let first = old.days.keys.sorted().first.flatMap(Dates.parse) ?? Dates.day(Date())
        let book = BookInfo(name: "내 플래너", start: min(first, Dates.day(Date())))
        library = Library(books: [book], activeID: book.id)
        if let url = bookURL(book.id), let out = try? Self.enc.encode(old) { try? out.write(to: url, options: .atomic) }
        writeLibrary()
        try? FileManager.default.moveItem(at: legacy, to: folder.appendingPathComponent("planner.json.backup"))
    }

    // MARK: books

    /// 새 책을 만들고 펼친다. 형광펜 구성과 기본 컬러는 지금 책에서 이어받는다.
    /// 지금 펼친 책이 예시 플래너면 예시의 형광펜 대신 내가 만든 첫 책의 것을 (없으면 기본값을) 쓴다.
    @discardableResult
    func createBook(name: String, start: Date, end: Date?, cover: Int = 0) -> UUID {
        var book = BookInfo(name: name, start: Dates.day(start), end: end.map(Dates.day), cover: cover)
        if let e = book.end, e < book.start { book.end = book.start }
        var fresh = PlannerData()
        // 이어받을 곳: 펼친 책. 예시 플래너면 내가 만든 첫 책 (없으면 기본값)
        var inherit: Prefs? = activeBook == nil ? nil : data.prefs
        if activeBook?.isSample == true { inherit = userBooks.first.map { loadBook($0.id).prefs } }
        if let inherit {
            fresh.prefs.categories = inherit.categories
            fresh.prefs.defaultTheme = inherit.defaultTheme
        }
        fresh.prefs.lastKind = data.prefs.lastKind
        saveNow()
        stashMemoryBook()
        // 예시 플래너는 책장 맨 끝에 둔다
        if let i = library.books.firstIndex(where: \.isSample) {
            library.books.insert(book, at: i)
        } else {
            library.books.append(book)
        }
        library.activeID = book.id
        data = fresh
        bump()
        saveNow()
        return book.id
    }

    func updateBook(_ id: UUID, _ f: (inout BookInfo) -> Void) {
        guard let i = library.books.firstIndex(where: { $0.id == id }) else { return }
        f(&library.books[i])
        library.books[i].start = Dates.day(library.books[i].start)
        if let e = library.books[i].end { library.books[i].end = max(Dates.day(e), library.books[i].start) }
        bump()
        writeLibrary()
    }

    /// 다른 책을 펼친다
    func activate(_ id: UUID) {
        guard id != library.activeID, library.books.contains(where: { $0.id == id }) else { return }
        saveNow()
        stashMemoryBook()
        library.activeID = id
        data = loadBook(id)
        bump()
        writeLibrary()
    }

    /// 책을 지운다 (파일도, D-day 옮기기 백업 사본도). 펼친 책이면 남은 책 가운데 사용자가 만든 첫 책을
    /// (없으면 예시 플래너를) 펼친다.
    func deleteBook(_ id: UUID) {
        let next = fallbackBook(excluding: id)?.id
        library.books.removeAll { $0.id == id }
        memoryBooks[id] = nil
        if let url = bookURL(id) {
            try? FileManager.default.removeItem(at: url)
            // "영구히 지워져요" 약속대로 1.0.3 옮기기 때 남긴 원본 사본도 지운다
            try? FileManager.default.removeItem(at: Self.ddayBackupURL(url))
        }
        if library.activeID == id {
            library.activeID = next
            data = library.activeID.map(loadBook) ?? PlannerData()
        }
        bump()
        writeLibrary()
    }

    private func bump() { version &+= 1 }

    /// 메모리 전용이면 다른 책으로 바꾸기 전에 지금 책의 내용을 들고 있는다 (파일 대신)
    private func stashMemoryBook() {
        guard folder == nil, let id = library.activeID else { return }
        memoryBooks[id] = data
    }

    // MARK: 예시 플래너 (1.0.4)

    /// 설치 후 처음 한 번만: 예시 플래너를 책장 끝에 꽂아 둔다. 펼친 책은 바꾸지 않는다
    /// (책이 한 권도 없던 첫 실행이면 튜토리얼에서 만든 책이 펼쳐진다).
    /// 한 번 꽂은 뒤에는 사용자가 지워도 다시 만들지 않는다 (library.sampleSeeded).
    /// 일반 실행에서 책장을 읽고 옮기기까지 끝난 뒤에 부른다. 메모리 전용 저장소에서는 아무것도 하지 않는다.
    func seedSampleBookIfNeeded(today: Date = Date()) {
        guard folder != nil, !libraryUnreadable, !library.sampleSeeded else { return }
        if hasSampleBook {
            library.sampleSeeded = true
            writeLibrary()
        } else {
            addSampleBook(today: today)
        }
    }

    /// 오늘까지 14일치 예시 플래너를 새로 만들어 책장 끝에 꽂는다 (펼치지는 않는다).
    /// 이미 예시 플래너가 있거나 책 파일을 쓰지 못하면 nil. 설정의 ‘예시 플래너 다시 넣기’도 이것을 쓴다.
    @discardableResult
    func addSampleBook(today: Date = Date()) -> UUID? {
        guard !hasSampleBook else { return nil }
        let sample = Self.makeSampleBook(today: today)
        if folder == nil {
            memoryBooks[sample.book.id] = sample.data
        } else {
            guard let url = bookURL(sample.book.id), let raw = try? Self.enc.encode(sample.data),
                  (try? raw.write(to: url, options: .atomic)) != nil else { return nil }
        }
        library.books.append(sample.book)
        library.sampleSeeded = true
        bump()
        writeLibrary()
        return sample.book.id
    }

    /// 메모리 전용(스냅샷/QA)에서 이 책 한 권만 꽂고 펼친다
    func useBook(_ book: BookInfo, data: PlannerData) {
        guard folder == nil else { return }
        library = Library(books: [book], activeID: book.id)
        self.data = data
        bump()
    }

    // MARK: saving

    func scheduleSave() {
        version &+= 1
        guard folder != nil else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        guard folder != nil else { return }
        if let url = activeBookURL, let raw = try? Self.enc.encode(data) {
            try? raw.write(to: url, options: .atomic)
        }
        writeLibrary()
    }

    private func writeLibrary() {
        guard let url = libraryURL, let raw = try? Self.enc.encode(library) else { return }
        try? raw.write(to: url, options: .atomic)
    }

    /// 메모리 전용(데모/스냅샷)에서 쓸 책
    func useDemoBook(start: Date, end: Date? = nil) {
        let book = BookInfo(name: "데모 플래너", start: Dates.day(start), end: end)
        library = Library(books: [book], activeID: book.id)
    }

    // Days
    /// 그날 기록. 할 일은 늘 줄이 매겨져 줄 순서로 온다 (가져온 예전 백업처럼 줄이 없는 기록도 보이던 줄로).
    func day(_ d: Date) -> DayRecord {
        var r = data.days[Dates.key(d)] ?? DayRecord()
        if !r.taskRowsReady { r.assignTaskRows() }
        return r
    }

    func editDay(_ d: Date, _ f: (inout DayRecord) -> Void) {
        let k = Dates.key(d)
        var r = data.days[k] ?? DayRecord()
        // 고치기 전후로 할 일 줄을 맞춘다 (줄 없이 더한 할 일은 위에서부터 빈 줄에)
        if !r.taskRowsReady { r.assignTaskRows() }
        f(&r)
        if !r.taskRowsReady { r.assignTaskRows() }
        data.days[k] = r.isEmpty ? nil : r
        scheduleSave()
    }

    // Weeks
    func week(_ start: Date) -> WeekRecord { data.weeks[Dates.key(start)] ?? WeekRecord() }

    func editWeek(_ start: Date, _ f: (inout WeekRecord) -> Void) {
        var r = week(start)
        f(&r)
        data.weeks[Dates.key(start)] = r
        scheduleSave()
    }

    func editPrefs(_ f: (inout Prefs) -> Void) {
        f(&data.prefs)
        scheduleSave()
    }

    // MARK: D-day
    // 저장한 D-day(prefs.ddays)는 목록일 뿐이고, 페이지에 보이는 것은 그날 붙인 복사본(DayRecord.ddays)이다.
    // 날에 붙이거나 떼거나 고치면 그 날만 바뀌고, 목록을 고치거나 지워도 이미 붙인 날은 그대로다.

    /// 저장한 D-day
    var ddayLibrary: [DDay] { data.prefs.ddays }

    /// 이 날에 붙인 D-day
    func ddays(_ d: Date) -> [DDay] { day(d).ddays }

    /// 저장한 D-day 를 이 날에 복사해 붙인다. 이미 붙였거나 두 개가 다 찼으면 false.
    @discardableResult
    func applyDDay(_ libraryID: UUID, to d: Date) -> Bool {
        guard let item = ddayLibrary.first(where: { $0.id == libraryID }) else { return false }
        let now = ddays(d)
        guard now.count < Prefs.maxDDays, !now.contains(where: { $0.source == libraryID }) else { return false }
        editDay(d) { $0.ddays.append(DDay(title: item.title, date: Dates.day(item.date), source: libraryID)) }
        return true
    }

    /// 새 D-day 를 이 날에 붙인다. save 면 저장한 D-day 목록에도 더한다. 두 개가 다 찼으면 nil.
    @discardableResult
    func addDDay(title: String, date: Date, to d: Date, save: Bool = true) -> UUID? {
        guard ddays(d).count < Prefs.maxDDays else { return nil }
        let day = Dates.day(date)
        var source: UUID? = nil
        if save { source = addLibraryDDay(title: title, date: day) }
        let copy = DDay(title: title, date: day, source: source)
        editDay(d) { $0.ddays.append(copy) }
        return copy.id
    }

    /// 이 날에서만 뗀다 (다른 날, 저장한 목록은 그대로)
    func removeDDay(_ id: UUID, from d: Date) {
        editDay(d) { $0.ddays.removeAll { $0.id == id } }
    }

    /// 이 날에 붙인 것만 고친다
    func editDDay(_ id: UUID, on d: Date, _ f: (inout DDay) -> Void) {
        editDay(d) { r in
            guard let i = r.ddays.firstIndex(where: { $0.id == id }) else { return }
            f(&r.ddays[i])
            r.ddays[i].date = Dates.day(r.ddays[i].date)
        }
    }

    /// 어제와 같게: 전날 붙인 D-day 를 이 날에도 복사해 붙인다 (이미 있는 것은 건너뛴다)
    func copyPreviousDDays(to d: Date) {
        let prev = ddays(Dates.add(days: -1, to: d))
        guard !prev.isEmpty else { return }
        editDay(d) { r in
            for p in prev where r.ddays.count < Prefs.maxDDays {
                let dup = r.ddays.contains { p.source != nil ? $0.source == p.source : ($0.title == p.title && $0.date == p.date) }
                if !dup { r.ddays.append(DDay(title: p.title, date: p.date, source: p.source)) }
            }
        }
    }

    /// 저장한 D-day 목록에 더한다 (어느 날에도 붙이지 않는다)
    @discardableResult
    func addLibraryDDay(title: String = "", date: Date) -> UUID {
        let item = DDay(title: title, date: Dates.day(date))
        editPrefs { $0.ddays.append(item) }
        return item.id
    }

    /// 목록에서만 고친다 (이미 붙인 날은 그대로)
    func editLibraryDDay(_ id: UUID, _ f: (inout DDay) -> Void) {
        editPrefs { p in
            guard let i = p.ddays.firstIndex(where: { $0.id == id }) else { return }
            f(&p.ddays[i])
            p.ddays[i].date = Dates.day(p.ddays[i].date)
        }
    }

    /// 목록에서만 지운다 (이미 붙인 날은 그대로)
    func removeLibraryDDay(_ id: UUID) {
        editPrefs { $0.ddays.removeAll { $0.id == id } }
    }

    /// "기록한 날" 수: D-day 만 붙인 날은 빼고 센다
    var recordedDayCount: Int { data.days.values.lazy.filter(\.hasRecord).count }

    // Time-table notes
    @discardableResult
    func addNote(_ d: Date, _ note: TimeNote) -> UUID {
        editDay(d) { $0.notes.append(note) }
        return note.id
    }

    func updateNote(_ d: Date, _ id: UUID, _ f: (inout TimeNote) -> Void) {
        editDay(d) { r in if let i = r.notes.firstIndex(where: { $0.id == id }) { f(&r.notes[i]) } }
    }

    func removeNote(_ d: Date, _ id: UUID) {
        editDay(d) { $0.notes.removeAll { $0.id == id } }
    }

    /// 지우개: 범위와 겹치는 메모/밥시간을 지운다
    func removeNotes(_ d: Date, overlapping range: ClosedRange<Int>) {
        guard day(d).notes.contains(where: { range.overlaps($0.start...$0.end) }) else { return }
        editDay(d) { $0.notes.removeAll { range.overlaps($0.start...$0.end) } }
    }

    /// 편집을 마쳤는데 비어 있는 글씨 메모는 지운다
    func cleanupNotes(_ d: Date) {
        guard day(d).notes.contains(where: { $0.kind == .text && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        editDay(d) { $0.notes.removeAll { $0.kind == .text && $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    // Color concept
    func concept(_ d: Date) -> ColorConcept { ColorConcept.of(day(d).theme ?? data.prefs.defaultTheme) }

    func setTheme(_ d: Date, _ theme: Int?) { editDay(d) { $0.theme = theme } }

    // Categories
    var categories: [Category] { data.prefs.categories }

    func category(_ id: Int?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    /// 형광펜 편집 (설정 창 / 팔레트)
    func updateCategory(_ id: Int, _ f: (inout Category) -> Void) {
        editPrefs { p in
            if let i = p.categories.firstIndex(where: { $0.id == id }) { f(&p.categories[i]) }
        }
    }

    @discardableResult
    func addCategory(name: String = "새 형광펜", hex: String = "B9E4A8") -> Int? {
        guard categories.count < Prefs.maxCategories else { return nil }
        let id = (categories.map(\.id).max() ?? -1) + 1
        editPrefs { $0.categories.append(Category(id: id, name: name, hex: hex, counts: true)) }
        return id
    }

    /// 지운 형광펜으로 칠한 칸은 빈 칸으로 보이고, 그 색이던 할 일은 색 없음이 된다.
    func removeCategory(_ id: Int) {
        guard categories.count > 1 else { return }
        editPrefs { $0.categories.removeAll { $0.id == id } }
    }

    func moveCategories(from: IndexSet, to: Int) {
        editPrefs { $0.categories.move(fromOffsets: from, toOffset: to) }
    }

    func minutes(_ d: Date, cat: Int? = nil) -> Int {
        let slots = day(d).slots
        let n: Int
        if let cat {
            n = slots.filter { $0 == cat }.count
        } else {
            let counted = Set(categories.filter(\.counts).map(\.id))
            n = slots.filter { counted.contains($0) }.count
        }
        return n * 10
    }

    // Bindings
    /// 같은 형광펜(카테고리)끼리 모은다. 묶음 순서는 처음 나온 순서, 묶음 안 순서는 그대로.
    /// 1.0.4 까지 할 일을 보여 주던 순서라서, 이제는 줄이 없는 예전 기록에 줄을 매길 때만 쓴다 (assignTaskRows).
    nonisolated static func grouped(_ tasks: [PlanTask]) -> [PlanTask] {
        var order: [Int?] = []
        var buckets: [Int?: [PlanTask]] = [:]
        for t in tasks {
            if buckets[t.cat] == nil { order.append(t.cat) }
            buckets[t.cat, default: []].append(t)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    /// 빈 할 일을 row 줄에 만들어 그 id 를 돌려준다 (그 줄을 이미 다른 할 일이 쓰고 있으면 그 아래 빈 줄에).
    /// 형광펜(분류)은 보통 없이 만들고, 다 쓴 뒤에 왼쪽 칸을 눌러 고른다.
    @discardableResult
    func addTask(_ d: Date, row: Int, cat: Int? = nil) -> UUID {
        let t = PlanTask(text: "", cat: cat)
        editDay(d) { $0.insertTask(t, row: row) }
        return t.id
    }

    /// 빈 할 일을 마지막으로 쓴 줄 다음의 빈 줄에 만든다 (주간 페이지의 빈 줄을 눌렀을 때).
    /// 아래에 빈 줄이 없으면 위에서부터 첫 빈 줄, 그것도 없으면 맨 끝에 한 줄 더.
    @discardableResult
    func addTaskAfterLast(_ d: Date, cat: Int? = nil) -> UUID {
        let t = PlanTask(text: "", cat: cat)
        editDay(d) { r in r.insertTask(t, row: r.freeTaskRow(after: r.lastTaskLine { _ in true } ?? -1)) }
        return t.id
    }

    func taskText(_ d: Date, id: UUID) -> Binding<String> {
        Binding(
            get: { self.day(d).tasks.first { $0.id == id }?.text ?? "" },
            set: { v in self.editDay(d) { r in if let i = r.tasks.firstIndex(where: { $0.id == id }) { r.tasks[i].text = v } } }
        )
    }

    func dayField(_ d: Date, _ kp: WritableKeyPath<DayRecord, String>) -> Binding<String> {
        Binding(get: { self.day(d)[keyPath: kp] }, set: { v in self.editDay(d) { $0[keyPath: kp] = v } })
    }

    /// 메모는 3칸이 기본이고, 넘치면 늘어난다
    func memoTag(_ d: Date, _ i: Int) -> Binding<String> {
        Binding(get: { let t = self.day(d).memoTags; return i < t.count ? t[i] : "" },
                set: { v in self.editDay(d) { r in
                    while r.memoTags.count <= i { r.memoTags.append("") }
                    r.memoTags[i] = v
                } })
    }

    func memo(_ d: Date, _ i: Int) -> Binding<String> {
        Binding(get: { let m = self.day(d).memos; return i < m.count ? m[i] : "" },
                set: { v in self.editDay(d) { r in
                    while r.memos.count <= i { r.memos.append("") }
                    r.memos[i] = v
                } })
    }

    func weekField(_ s: Date, _ kp: WritableKeyPath<WeekRecord, String>) -> Binding<String> {
        Binding(get: { self.week(s)[keyPath: kp] }, set: { v in self.editWeek(s) { $0[keyPath: kp] = v } })
    }

    /// 비어 있는 할 일을 지운다 (지금 쓰고 있는 것은 남긴다). 글을 다 지운 할 일은 이렇게 없어진다.
    /// 남은 할 일은 제 줄에 그대로 있다 (모으거나 당기지 않는다).
    func cleanup(_ d: Date, keep: UUID? = nil) {
        guard day(d).tasks.contains(where: { $0.id != keep && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        editDay(d) { $0.tasks.removeAll { $0.id != keep && $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// 펜 클릭: ○ → △ → × → → → 없음
    func cycleMark(_ d: Date, _ id: UUID) {
        guard let t = day(d).tasks.first(where: { $0.id == id }) else { return }
        setMark(d, id, t.mark.next)
    }

    /// 체크 표시를 바꾼다. 일간 · 주간의 펜 클릭, 오른쪽 클릭 메뉴, 내일로 미루기가 모두 여기를 지난다.
    /// → (미룸) 이 되면 다음 날로 넘기고, → 를 떼면 다음 날에 넘긴 것을 손대지 않았을 때만 거둔다.
    func setMark(_ d: Date, _ id: UUID, _ m: Mark) {
        guard let t = day(d).tasks.first(where: { $0.id == id }) else { return }
        if t.mark != m {
            editDay(d) { r in
                if let i = r.tasks.firstIndex(where: { $0.id == id }) { r.tasks[i].mark = m }
            }
        }
        if m == .moved {
            carryForward(d, t)
        } else if t.mark == .moved {
            withdrawCarry(d, t)
        }
    }

    /// 다음 날에 이 할 일에서 넘어온 할 일 (없으면 nil)
    func carriedCopy(of id: UUID, from d: Date) -> PlanTask? {
        day(Dates.add(days: 1, to: d)).tasks.first { $0.carriedFrom == id }
    }

    /// → : 다음 날에 같은 글 · 같은 형광펜 · 표시 없는 할 일을 하나 만든다 (자리는 DayRecord.insertCarried).
    /// 이미 넘긴 것이 있거나, 다음 날이 이 플래너의 기간 밖이거나, 빈 할 일이면 하지 않는다.
    /// 넘어간 할 일은 보통 할 일과 같아서 고치고 표시하고 또 → 로 넘길 수 있다.
    private func carryForward(_ d: Date, _ t: PlanTask) {
        let next = Dates.add(days: 1, to: d)
        guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              activeBook?.contains(next) ?? true,
              carriedCopy(of: t.id, from: d) == nil else { return }
        editDay(next) { $0.insertCarried(PlanTask(text: t.text, cat: t.cat, carriedFrom: t.id)) }
    }

    /// → 를 뗐을 때: 다음 날에 넘긴 할 일을 그대로 두었으면 (표시 없음 · 글과 형광펜이 같으면) 지운다.
    /// 거기서 고쳐 쓰거나 표시했으면 이제 그날의 할 일이라 남긴다.
    private func withdrawCarry(_ d: Date, _ t: PlanTask) {
        guard let copy = carriedCopy(of: t.id, from: d),
              copy.mark == .none, copy.text == t.text, copy.cat == t.cat else { return }
        editDay(Dates.add(days: 1, to: d)) { $0.tasks.removeAll { $0.id == copy.id } }
    }

    /// 할 일의 형광펜(분류)을 고른다 (nil = 없음). 같은 형광펜을 쓰는 할 일이 이미 있으면
    /// 그 묶음 바로 아래로 옮겨 1.0.4 까지처럼 같은 형광펜끼리 모아 둔다. 처음 쓰는 형광펜이면 제 줄에 그대로.
    func setCategory(_ d: Date, _ id: UUID, _ cat: Int?) {
        guard let t = day(d).tasks.first(where: { $0.id == id }), t.cat != cat else { return }
        editDay(d) { r in
            guard let i = r.tasks.firstIndex(where: { $0.id == id }) else { return }
            r.tasks[i].cat = cat
            r.joinCategoryGroup(id)
        }
    }

    /// 할 일을 지운다. 이미 다음 날로 넘긴 할 일은 그날의 할 일이라 그대로 둔다.
    func delete(_ d: Date, _ id: UUID) {
        editDay(d) { $0.tasks.removeAll { $0.id == id } }
    }

    /// 내일로 미루기 = → 표시 (다음 날로 한 번만 넘어간다)
    func postpone(_ d: Date, _ id: UUID) { setMark(d, id, .moved) }

    // MARK: DAY OFF

    func isDayOff(_ d: Date) -> Bool { day(d).dayOff }

    /// 쉬는 날로 두거나 되돌린다. COMMENT 글은 그대로 남는다.
    func setDayOff(_ d: Date, _ on: Bool) {
        guard isDayOff(d) != on else { return }
        editDay(d) { $0.dayOff = on }
    }

    // Sample content for previews / snapshots
    func fillSample(around today: Date) {
        let ws = Dates.weekStart(today)
        fillSampleHistory(before: ws, weeks: 6)
        editWeek(ws) { $0.goal = "런칭 전 QA 끝내고 금요일 전에 배포 준비 완료하기"; $0.review = "집중 시간이 늘었다!"; $0.stars = 4 }
        // 저장한 D-day 두 개. 이번 주 날마다 붙여 두고, 주말에는 런칭만.
        let launch = addLibraryDDay(title: "런칭", date: Dates.add(days: 9, to: ws))
        let review = addLibraryDDay(title: "분기 리뷰", date: Dates.add(days: 23, to: ws))
        let sample: [[(String, Int?, Mark)]] = [
            [("주간 회의 자료 정리", 1, .done), ("디자인 리뷰 피드백", 0, .done), ("API 스펙 문서", 3, .partial), ("메일 답장", 2, .done), ("운동 30분", 5, .missed)],
            [("QA 시나리오 작성", 0, .done), ("버그 리포트 정리", 0, .done), ("파트너사 미팅", 1, .done), ("회고 준비", 3, .partial),
             ("릴리즈 일정 공유", 2, .done), ("영어 스터디", 4, .done), ("스트레칭", 5, .missed)],
            [("버그 트리아지", 0, .done), ("릴리즈 노트 초안", 3, .done), ("1:1 미팅", 1, .missed), ("세금계산서 발행", 2, .done)],
            [("성능 개선 PR", 0, .partial), ("고객 인터뷰", 1, .done), ("마케팅 카피 검토", 2, .done)],
            [("배포 체크리스트", 0, .none), ("팀 점심", 6, .none), ("주간 리포트", 3, .none)],
            [("사이드 프로젝트", 4, .none), ("장보기", 5, .none)],
            [("다음 주 계획", 3, .none), ("독서", 4, .none)],
        ]
        let paint: [[(Int, Int, Int)]] = [
            [(3, 17, 1), (18, 32, 0), (36, 50, 2), (54, 66, 0), (70, 74, 6)],
            [(2, 14, 0), (15, 24, 1), (27, 40, 0), (42, 47, 2), (48, 58, 4), (60, 63, 6)],
            [(4, 20, 0), (21, 30, 3), (36, 48, 1), (50, 60, 0)],
            [(3, 22, 0), (24, 35, 1), (40, 52, 2)],
            [(6, 18, 0), (36, 42, 6)],
            [], [],
        ]
        for i in 0..<7 {
            let d = Dates.add(days: i, to: ws)
            editDay(d) { r in
                r.tasks = sample[i].enumerated().map { k, t in PlanTask(text: t.0, mark: t.2, cat: t.1, row: k) }
                for (a, b, c) in paint[i] { for s in a...b { r.slots[s] = c } }
                r.theme = [nil, nil, 3, 6, 4, 7, 2][i]
                if i == 1 {
                    r.notes = [TimeNote(kind: .meal, start: 36, end: 41),
                               TimeNote(kind: .text, start: 20, end: 23, text: "파트너 미팅"),
                               TimeNote(kind: .meal, start: 75, end: 79)]
                    r.comment = "버려야 할 것을 못 버리면 스스로를 버리게 된다"
                    r.memoTags = ["내일", "메모", ""]
                    r.memos = ["오전에 QA 결과 공유", "회의실 예약 확인하기", ""]
                }
            }
            applyDDay(launch, to: d)
            if i < 5 { applyDDay(review, to: d) }
        }
    }

    /// 홈 통계용: 지난 몇 주 동안의 그럴듯한 기록 (결정적 의사 난수)
    private func fillSampleHistory(before weekStart: Date, weeks: Int) {
        var seed: UInt64 = 0xC0FFEE
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let names = ["기획서 정리", "고객 미팅", "메일 답장", "코드 리뷰", "주간 보고", "디자인 검토", "리서치", "운동", "독서", "1:1 미팅"]
        let marks: [Mark] = [.done, .done, .done, .partial, .missed, .moved]
        for w in 1...weeks {
            for d in 0..<7 {
                let day = Dates.add(days: -7 * w + d, to: weekStart)
                let weekend = d >= 5
                editDay(day) { r in
                    let n = weekend ? rnd(3) : 3 + rnd(4)
                    r.tasks = (0..<n).map { k in PlanTask(text: names[rnd(names.count)], mark: marks[rnd(marks.count)], cat: rnd(7), row: k) }
                    var s = 2 + rnd(4)
                    let blocks = weekend ? rnd(3) : 4 + rnd(4)
                    for _ in 0..<blocks {
                        let len = 3 + rnd(10)
                        let cat = rnd(10) < 6 ? 0 : rnd(7)
                        for k in s..<min(s + len, 90) { r.slots[k] = cat }
                        s += len + rnd(5)
                    }
                    if rnd(4) == 0 { r.theme = rnd(ColorConcept.all.count) }
                }
            }
        }
    }
}
