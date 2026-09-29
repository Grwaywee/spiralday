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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([PlanTask].self, forKey: .tasks) ?? []
        let s = try c.decodeIfPresent([Int].self, forKey: .slots) ?? []
        slots = Self.pad(s, Self.slotCount, -1)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        memoTags = Self.pad(try c.decodeIfPresent([String].self, forKey: .memoTags) ?? [], Self.memoCount, "")
        memos = Self.pad(try c.decodeIfPresent([String].self, forKey: .memos) ?? [], Self.memoCount, "")
        theme = try c.decodeIfPresent(Int.self, forKey: .theme)
        notes = try c.decodeIfPresent([TimeNote].self, forKey: .notes) ?? []
    }

    private static func pad<T>(_ a: [T], _ n: Int, _ fill: T) -> [T] {
        Array((a + Array(repeating: fill, count: n)).prefix(n))
    }

    var isEmpty: Bool {
        tasks.isEmpty && slots.allSatisfy { $0 < 0 } && comment.isEmpty
            && memos.allSatisfy(\.isEmpty) && memoTags.allSatisfy(\.isEmpty) && theme == nil && notes.isEmpty
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
    /// D-day (최대 2개)
    var ddays: [DDay] = []
    /// 따로 고르지 않은 날의 컬러 컨셉
    var defaultTheme = 0

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
        ddays = Array((try c.decodeIfPresent([DDay].self, forKey: .ddays) ?? []).prefix(Self.maxDDays))
        // 예전 버전의 D-day 하나짜리 저장 형식
        if ddays.isEmpty, let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let date = try legacy.decodeIfPresent(Date.self, forKey: .ddayDate) {
            ddays = [DDay(title: try legacy.decodeIfPresent(String.self, forKey: .ddayTitle) ?? "", date: date)]
        }
        defaultTheme = try c.decodeIfPresent(Int.self, forKey: .defaultTheme) ?? 0
    }
}

struct DDay: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var date: Date
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

@MainActor
final class PlannerStore: ObservableObject {
    @Published var data: PlannerData
    /// 데이터가 바뀔 때마다 올라간다 (페이지 스냅샷 캐시 무효화용)
    private(set) var version = 0

    private let url: URL?
    private var saveWork: DispatchWorkItem?

    init(inMemory: Bool = false) {
        if inMemory {
            url = nil
            data = PlannerData()
            return
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperPlanner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("planner.json")
        url = file
        if let raw = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            data = (try? dec.decode(PlannerData.self, from: raw)) ?? PlannerData()
        } else {
            data = PlannerData()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func scheduleSave() {
        version &+= 1
        guard url != nil else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let raw = try? enc.encode(data) {
            try? raw.write(to: url, options: .atomic)
        }
    }

    // Days
    func day(_ d: Date) -> DayRecord { data.days[Dates.key(d)] ?? DayRecord() }

    func editDay(_ d: Date, _ f: (inout DayRecord) -> Void) {
        let k = Dates.key(d)
        var r = data.days[k] ?? DayRecord()
        f(&r)
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
    func taskText(_ d: Date, _ i: Int, defaultCat: @escaping () -> Int?) -> Binding<String> {
        Binding(
            get: { let t = self.day(d).tasks; return i < t.count ? t[i].text : "" },
            set: { v in
                self.editDay(d) { r in
                    if i < r.tasks.count { r.tasks[i].text = v }
                    else if !v.isEmpty { r.tasks.append(PlanTask(text: v, cat: defaultCat())) }
                }
            }
        )
    }

    func dayField(_ d: Date, _ kp: WritableKeyPath<DayRecord, String>) -> Binding<String> {
        Binding(get: { self.day(d)[keyPath: kp] }, set: { v in self.editDay(d) { $0[keyPath: kp] = v } })
    }

    func memoTag(_ d: Date, _ i: Int) -> Binding<String> {
        Binding(get: { self.day(d).memoTags[i] }, set: { v in self.editDay(d) { $0.memoTags[i] = v } })
    }

    func memo(_ d: Date, _ i: Int) -> Binding<String> {
        Binding(get: { self.day(d).memos[i] }, set: { v in self.editDay(d) { $0.memos[i] = v } })
    }

    func weekField(_ s: Date, _ kp: WritableKeyPath<WeekRecord, String>) -> Binding<String> {
        Binding(get: { self.week(s)[keyPath: kp] }, set: { v in self.editWeek(s) { $0[keyPath: kp] = v } })
    }

    func cleanup(_ d: Date) {
        guard day(d).tasks.contains(where: { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        editDay(d) { $0.tasks.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    func cycleMark(_ d: Date, _ id: UUID) {
        editDay(d) { r in
            if let i = r.tasks.firstIndex(where: { $0.id == id }) { r.tasks[i].mark = r.tasks[i].mark.next }
        }
    }

    func setMark(_ d: Date, _ id: UUID, _ m: Mark) {
        editDay(d) { r in
            if let i = r.tasks.firstIndex(where: { $0.id == id }) { r.tasks[i].mark = m }
        }
    }

    func setCategory(_ d: Date, _ id: UUID, _ cat: Int?) {
        editDay(d) { r in
            if let i = r.tasks.firstIndex(where: { $0.id == id }) { r.tasks[i].cat = cat }
        }
    }

    func delete(_ d: Date, _ id: UUID) {
        editDay(d) { $0.tasks.removeAll { $0.id == id } }
    }

    func postpone(_ d: Date, _ id: UUID) {
        guard let t = day(d).tasks.first(where: { $0.id == id }) else { return }
        setMark(d, id, .moved)
        editDay(Dates.add(days: 1, to: d)) { $0.tasks.append(PlanTask(text: t.text, cat: t.cat)) }
    }

    // Sample content for previews / snapshots
    func fillSample(around today: Date) {
        let ws = Dates.weekStart(today)
        fillSampleHistory(before: ws, weeks: 6)
        editWeek(ws) { $0.goal = "런칭 전 QA 끝내고 금요일 전에 배포 준비 완료하기"; $0.review = "집중 시간이 늘었다!"; $0.stars = 4 }
        editPrefs {
            $0.ddays = [DDay(title: "런칭", date: Dates.add(days: 9, to: ws)),
                        DDay(title: "분기 리뷰", date: Dates.add(days: 23, to: ws))]
        }
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
                r.tasks = sample[i].map { PlanTask(text: $0.0, mark: $0.2, cat: $0.1) }
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
                    r.tasks = (0..<n).map { _ in PlanTask(text: names[rnd(names.count)], mark: marks[rnd(marks.count)], cat: rnd(7)) }
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
