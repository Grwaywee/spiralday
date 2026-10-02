#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// 예시 플래너 (1.0.4): 처음 켤 때 책장에 한 권 꽂아 두는 14일치 예시. 오늘이 마지막 날이다.
// 회사에 다니면서 토익을 준비하고 운동도 하는 사람의 두 주 — 보기만 해도 쓰는 법이 보이도록
// 형광펜 묶음 · ○△×→ (→ 는 앱처럼 다음 날로 넘어가 있다) · 타임테이블 · 밥시간 · 글씨 메모 · COMMENT · MEMO ·
// 날마다 컬러 · 날마다 D-day · DAY OFF 하루 · 주간 목표와 별점을 모두 조금씩 써 둔다.
//
// 내용은 "준비 주 / 첫째 주 / 둘째 주 × 월–일" 21장의 이어지는 이야기로 적어 두고 (주말은 가볍게),
// 오늘이 늘 둘째 주의 같은 요일이 되도록 거꾸로 14장을 잘라 붙인다. 그래서 날짜의 요일과 장의 요일이 늘 맞고
// 이야기 순서도 흐트러지지 않는다 (오늘이 일요일이면 첫째 주 월요일부터, 월요일이면 준비 주 화요일부터).
// 오늘은 저녁 6시 전까지만 한 것으로 두어 쓰는 중처럼 보인다.
// 같은 오늘이면 언제 만들어도 똑같은 내용이 나온다 (id 도 오늘에서 정해진다).
// ─────────────────────────────────────────────────────────────────────────────

extension PlannerStore {
    public static let sampleBookName = "예시 플래너"
    /// 표지: 첫 플래너의 기본 표지(체리)와 겹치지 않는 민트
    public static let sampleBookCover = 3

    /// 예시 플래너 한 권 (책 정보 + 내용). 오늘 − 13일 ~ 오늘, 기본 형광펜.
    public static func makeSampleBook(today now: Date) -> (book: BookInfo, data: PlannerData) {
        let today = Dates.day(now)
        let start = Dates.add(days: -(SampleBook.dayCount - 1), to: today)
        var ids = SampleBook.IDs(seed: Dates.key(today))
        var data = PlannerData()
        data.prefs.categories = Prefs.defaultCategories
        data.prefs.ddaysPerDay = true
        // 첫 장 (1.0.5): 책 맨 앞에 적어 둔 하고 싶은 말
        data.prefs.motto = SampleBook.motto

        // 저장한 D-day: 오늘 뒤의 날짜 셋
        let saved: [SampleBook.DDayKind: DDay] = Dictionary(uniqueKeysWithValues: SampleBook.DDayKind.allCases.map { k in
            (k, DDay(id: ids.next(), title: k.title, date: k.date(after: today)))
        })
        data.prefs.ddays = SampleBook.DDayKind.allCases.compactMap { saved[$0] }

        // 첫날이 이야기의 몇 번째 장인지 (준비 주 월요일 = 0). 오늘은 늘 14 + 요일 = 둘째 주의 같은 요일.
        let s0 = SampleBook.firstStoryDay(today: today)
        var carried: [PlanTask] = []
        for i in 0..<SampleBook.dayCount {
            let date = Dates.add(days: i, to: start)
            let isToday = i == SampleBook.dayCount - 1
            // (s0 + i) % 7 == 그날의 요일
            let page = SampleBook.page(storyDay: s0 + i)
            var r = DayRecord()
            // DAY OFF 예시 자리: 첫째 주 일요일 (dayOffStoryDay). COMMENT 는 적어 둔 채 DAY OFF 로 둔다.
            r.dayOff = page.dayOff

            // 할 일. 오늘은 저녁 일과 미룰 일이 아직 남아 있다 (오늘은 플래너의 마지막 날이라 → 로 넘기지도 않는다).
            var tasks: [PlanTask] = []
            var carryNext: [PlanTask] = []
            for t in page.tasks {
                let open = isToday && (t.late || t.mark == .moved)
                let task = PlanTask(id: ids.next(), text: t.text, mark: open ? .none : t.mark, cat: t.cat)
                tasks.append(task)
                // → : 앱(setMark → carryForward)처럼 다음 날에 같은 글 · 같은 형광펜으로 한 번 넘긴다 (carriedFrom = 이 할 일).
                // 앱에서는 표시 없이 넘어가고, 다음 날 한 표시(then)는 이야기대로 미리 적어 둔다.
                if task.mark == .moved {
                    carryNext.append(PlanTask(id: ids.next(), text: task.text, mark: t.then, cat: task.cat, carriedFrom: task.id))
                }
            }
            // 할 일 줄 (1.0.5): 같은 형광펜끼리 모아 위에서부터 한 줄씩 (1.0.4 와 같은 모양).
            // 어제 → 로 넘어올 할 일이 있으면 그 형광펜 묶음 바로 아래 줄을 비워 두어, 앱의 → (insertCarried) 처럼
            // "같은 형광펜이 쓰는 마지막 줄 아래의 첫 빈 줄" 에 들어가게 한다. blankBefore 는 한 줄 비우고 쓴 예시.
            r.tasks = SampleBook.rowed(PlannerStore.grouped(tasks), reserveAfter: carried.map(\.cat), blankBefore: page.blankBefore)
            for c in carried { r.insertCarried(c) }
            carried = carryNext

            // 타임테이블 · 밥시간 · 글씨 메모 (오늘은 저녁 6시 전까지만)
            let cutoff = isToday ? SampleBook.slot(SampleBook.todayCutoff) : DayRecord.slotCount
            for b in page.paint {
                let s = SampleBook.slot(b.from), e = SampleBook.slot(b.to)
                guard s < cutoff else { continue }
                for k in s..<min(e, cutoff) { r.slots[k] = b.cat }
            }
            for m in page.meals where SampleBook.slot(m.from) < cutoff {
                r.notes.append(TimeNote(id: ids.next(), kind: .meal, start: SampleBook.slot(m.from), end: SampleBook.slot(m.to) - 1))
            }
            for n in page.notes where SampleBook.slot(n.at) < cutoff {
                let s = SampleBook.slot(n.at)
                r.notes.append(TimeNote(id: ids.next(), kind: .text, start: s, end: s, text: n.text))
            }

            r.comment = isToday ? SampleBook.todayComment : page.comment
            for (k, m) in page.memos.prefix(DayRecord.memoCount).enumerated() {
                r.memoTags[k] = m.tag
                r.memos[k] = m.text
            }
            r.theme = page.theme
            r.ddays = page.ddays.compactMap { saved[$0] }.map { DDay(id: ids.next(), title: $0.title, date: $0.date, source: $0.id) }
            data.days[Dates.key(date)] = r
        }

        // 주간: 14일과 겹치는 주마다 그 주 이야기의 목표 · 별점 · 돌아보기 (이번 주는 늘 둘째 주, "지금까지" 매긴 별점).
        // 주간 보기를 처음 열면 이번 주가 나오므로 거기서도 별점이 보이게 한다.
        var ws = Dates.weekStart(start)
        while ws <= today {
            let w = SampleBook.weeks[SampleBook.storyWeek(of: ws, start: start, firstStoryDay: s0)]
            data.weeks[Dates.key(ws)] = WeekRecord(goal: w.goal, review: w.review, stars: w.stars)
            ws = Dates.add(days: 7, to: ws)
        }

        let book = BookInfo(name: sampleBookName, start: start, end: today, cover: sampleBookCover, isSample: true)
        return (book, data)
    }
}

// MARK: - 내용

public enum SampleBook {
    public static let dayCount = 14
    /// 오늘은 이 시각 전까지만 칠하고, 저녁 일(late)은 아직 표시하지 않는다
    public static let todayCutoff = "18:00"
    public static let todayComment = "남은 것도 하나씩, 천천히 해 보자"
    /// 첫 장에 적은 말 (명언이 아니라 이 사람이 스스로 적은 다짐, 한 줄은 짧게)
    public static let motto = "완벽한 하루 말고\n조금 나아진 하루\n그거면 충분해"

    /// 형광펜 (Prefs.defaultCategories 의 id)
    public enum Pen {
        public static let focus = 0, meet = 1, mail = 2, plan = 3, study = 4, me = 5, rest = 6
    }

    public enum DDayKind: CaseIterable {
        case deadline, exam, trip

        public var title: String {
            switch self {
            case .deadline: "기획안 마감"
            case .exam: "토익 시험"
            case .trip: "제주 여행"
            }
        }

        /// 오늘 뒤의 날짜: 마감은 나흘 뒤(주말이면 그다음 월요일), 시험은 보름쯤 뒤 일요일, 여행은 4주 넘어 금요일
        public func date(after today: Date) -> Date {
            switch self {
            case .deadline:
                let d = Dates.add(days: 4, to: today)
                let wd = SampleBook.weekday(d)
                return wd >= 5 ? Dates.add(days: 7 - wd, to: d) : d
            case .exam:
                let d = Dates.add(days: 15, to: today)
                return Dates.add(days: (6 - SampleBook.weekday(d) + 7) % 7, to: d)
            case .trip:
                let d = Dates.add(days: 28, to: today)
                return Dates.add(days: (4 - SampleBook.weekday(d) + 7) % 7, to: d)
            }
        }
    }

    public struct Task {
        public let text: String
        public let cat: Int
        public let mark: Mark
        /// 저녁(6시 뒤)에 하는 일 — 오늘이면 아직 안 한 것으로 둔다
        public var late = false
        /// → 일 때만: 다음 날로 넘어간 할 일에 그날 한 표시
        public var then: Mark = .done
    }

    public struct Block { public let from: String, to: String, cat: Int }
    public struct Span { public let from: String, to: String }
    public struct Note { public let at: String, text: String }
    public struct Memo { public let tag: String, text: String }

    public struct Page {
        public var tasks: [Task]
        /// 칠한 칸 (끝 시각은 넣지 않는다)
        public var paint: [Block]
        public var meals: [Span] = []
        public var notes: [Note] = []
        public var comment = ""
        public var memos: [Memo] = []
        public var theme: Int? = nil
        public var ddays: [DDayKind] = []
        /// 쉬는 날 (DAY OFF). 이야기에서 하루뿐 — dayOffStoryDay
        public var dayOff = false
        /// 이 할 일(형광펜끼리 모은 순서) 앞에서 한 줄 비우고 쓴다 — 할 일은 아무 줄에나 쓸 수 있다는 예시 (1.0.5)
        public var blankBefore: Int? = nil
    }

    public struct Week { public let goal: String, review: String, stars: Int }

    /// 월 = 0 … 일 = 6
    public static func weekday(_ d: Date) -> Int { ((Dates.comp(d).weekday ?? 2) + 5) % 7 }

    /// 형광펜끼리 모은 할 일에 위에서부터 줄을 매긴다. reserveAfter 의 형광펜마다 그 묶음 바로 아래에 한 줄씩 비워 두고
    /// (어제 → 로 넘어올 자리), blankBefore 번째 할 일 앞에서 한 줄 비운다.
    public static func rowed(_ tasks: [PlanTask], reserveAfter cats: [Int?], blankBefore: Int?) -> [PlanTask] {
        var out: [PlanTask] = []
        var row = 0
        for (i, t) in tasks.enumerated() {
            if i == blankBefore { row += 1 }
            var t = t
            t.row = row
            out.append(t)
            row += 1
            if i + 1 == tasks.count || tasks[i + 1].cat != t.cat { row += cats.filter { $0 == t.cat }.count }
        }
        return out
    }

    /// "HH:mm" → 타임테이블 칸 (06:00 = 0, 다음날 05:50 = 143). "24:00" 같은 끝 시각도 받는다.
    public static func slot(_ hm: String) -> Int {
        let p = hm.split(separator: ":").map { Int($0) ?? 0 }
        let h = p[0], m = p.count > 1 ? p[1] : 0
        let row = h >= 6 ? h - 6 : h + 18
        return min(row * 6 + m / 10, DayRecord.slotCount)
    }

    /// 14일의 첫날이 이야기의 몇 번째 장인지 (준비 주 월요일 = 0 … 둘째 주 일요일 = 20).
    /// 오늘(첫날 + 13)이 14 + 요일, 곧 둘째 주의 같은 요일이 되게 한다. 1…7 이라 준비 주 월요일은 쓰이지 않는다.
    public static func firstStoryDay(today: Date) -> Int { weekday(today) + 1 }

    /// 이야기 장 수 (준비 주 · 첫째 주 · 둘째 주)
    public static let storyDayCount = 3 * 7

    /// 이야기의 j 번째 장 (j % 7 = 요일)
    public static func page(storyDay j: Int) -> Page { [prep, first, second][j / 7][j % 7] }

    /// 달력의 한 주(ws = 주 시작)가 이야기의 몇째 주인지 (weeks 의 번호). 14일 앞에 걸친 주는 첫날로 센다.
    public static func storyWeek(of ws: Date, start: Date, firstStoryDay s: Int) -> Int {
        (s + Dates.daysBetween(start, max(ws, start))) / 7
    }

    /// DAY OFF 예시 자리: 첫째 주 일요일 (그 장의 Page.dayOff). 오늘이 무슨 요일이든 14일 안에 늘 들어 있다 (s + i, s = 1…7).
    public static let dayOffStoryDay = 7 + 6

    // 짧게 쓰는 도우미
    private static func t(_ text: String, _ cat: Int, _ mark: Mark, late: Bool = false) -> Task {
        Task(text: text, cat: cat, mark: mark, late: late)
    }
    /// → 로 다음 날에 넘긴 할 일. then = 넘어간 다음 날에 한 표시
    private static func moved(_ text: String, _ cat: Int, then: Mark, late: Bool = false) -> Task {
        Task(text: text, cat: cat, mark: .moved, late: late, then: then)
    }
    private static func b(_ from: String, _ to: String, _ cat: Int) -> Block { Block(from: from, to: to, cat: cat) }
    private static func meal(_ from: String, _ to: String) -> Span { Span(from: from, to: to) }
    private static func note(_ at: String, _ text: String) -> Note { Note(at: at, text: text) }
    private static func memo(_ tag: String, _ text: String) -> Memo { Memo(tag: tag, text: text) }

    private typealias P = Pen

    /// 준비 주 (월 … 일): 행사를 새로 맡아 킥오프 · 목차 · 견적 요청, 토익 접수, 러닝 시작.
    /// 첫날은 늘 화요일 이후라 (firstStoryDay ≥ 1) 월요일 장은 쓰이지 않는다.
    public static let prep: [Page] = [
        // 월: 쓰이지 않는 자리
        Page(tasks: [], paint: []),
        // 화
        Page(tasks: [t("행사 킥오프 회의", P.meet, .done),
                     t("킥오프 내용 정리", P.plan, .done),
                     t("지난 행사 자료 찾아보기", P.focus, .done),
                     t("밀린 메일 답장", P.mail, .done),
                     t("토익 시험 접수", P.study, .done, late: true),
                     t("러닝화 주문", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:40", P.mail), b("10:00", "11:30", P.meet),
                     b("11:30", "12:00", P.plan), b("13:00", "14:30", P.plan), b("14:40", "17:20", P.focus),
                     b("17:20", "17:50", P.mail), b("21:00", "21:20", P.study)],
             meals: [meal("12:00", "13:00"), meal("19:00", "19:40")],
             notes: [note("10:00", "킥오프")],
             comment: "새 행사를 맡았다! 설레고 떨린다",
             memos: [memo("내일", "기획안 목차 잡기"), memo("메모", "토익 접수 완료!")],
             theme: 1, ddays: []),
        // 수
        Page(tasks: [t("행사 기획안 목차 잡기", P.plan, .done),
                     t("팀장님께 목차 공유", P.mail, .done),
                     t("행사 일정표 초안", P.focus, .partial),
                     t("영어 회화 수업", P.study, .done, late: true),
                     t("치과 검진 예약", P.me, .done)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:30", P.mail), b("09:30", "12:00", P.plan),
                     b("13:00", "15:20", P.plan), b("15:20", "15:50", P.mail), b("16:00", "17:50", P.focus),
                     b("19:30", "20:30", P.study)],
             meals: [meal("12:00", "13:00"), meal("18:30", "19:10")],
             comment: "목차가 잡히니 할 일이 보인다",
             memos: [memo("내일", "협력사 견적 요청하기")],
             theme: nil, ddays: [.exam]),
        // 목
        Page(tasks: [t("협력사 3곳 견적 요청", P.mail, .done),
                     t("유관 부서 인사 미팅", P.meet, .done),
                     t("행사 일정표 마무리", P.focus, .done),
                     t("LC 파트1 듣기", P.study, .done, late: true),
                     t("헬스 PT 등록", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "10:10", P.mail), b("10:10", "12:00", P.focus),
                     b("13:00", "14:00", P.meet), b("14:10", "16:40", P.focus), b("16:40", "17:30", P.mail),
                     b("19:00", "19:40", P.me), b("21:00", "21:40", P.study)],
             meals: [meal("12:00", "13:00"), meal("20:00", "20:40")],
             notes: [note("19:00", "PT 상담")],
             comment: "견적 요청 끝! 답장 기다리는 중",
             memos: [memo("할 것", "견적 오면 3곳 비교"), memo("메모", "PT 는 화·목 저녁")],
             theme: 5, ddays: [.exam]),
        // 금
        Page(tasks: [t("주간 업무 보고", P.mail, .done),
                     t("행사 레퍼런스 모으기", P.plan, .done),
                     t("기획안 자료 목록 만들기", P.focus, .done),
                     t("토익 교재 사기", P.study, .done, late: true),
                     t("러닝 코스 찾아보기", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:40", P.mail), b("09:40", "12:00", P.plan),
                     b("13:30", "16:00", P.focus), b("16:00", "16:40", P.mail), b("16:40", "17:30", P.plan),
                     b("20:30", "21:00", P.study)],
             meals: [meal("12:00", "13:30"), meal("19:00", "19:40")],
             comment: "행사 준비 첫 주 끝! 주말엔 달려 보자",
             memos: [memo("주말", "러닝 시작하기"), memo("할 것", "토익 교재 1과")],
             theme: 2, ddays: []),
        // 토: 러닝 시작
        Page(tasks: [t("러닝 시작! 2km", P.me, .done),
                     t("토익 교재 1과", P.study, .done),
                     t("친구 결혼식", P.me, .done),
                     t("방 정리", P.me, .partial, late: true)],
             paint: [b("08:30", "09:00", P.me), b("10:00", "11:30", P.study), b("12:20", "13:00", P.me),
                     b("20:00", "20:30", P.me)],
             meals: [meal("13:00", "14:00")],
             notes: [note("08:30", "첫 러닝!"), note("12:20", "결혼식")],
             comment: "2km 인데 숨차다 ㅋㅋ 그래도 시작!",
             memos: [memo("메모", "러닝 기록 앱 깔기")],
             theme: 4, ddays: []),
        // 일
        Page(tasks: [t("이불 빨래", P.me, .done),
                     t("LC 파트1 복습", P.study, .done),
                     t("부모님 댁 저녁", P.me, .done, late: true),
                     t("다음 주 계획 세우기", P.plan, .done, late: true)],
             paint: [b("10:30", "11:30", P.me), b("14:00", "15:30", P.study), b("21:00", "21:30", P.plan)],
             meals: [meal("12:30", "13:20"), meal("18:00", "19:30")],
             comment: "다음 주부터 본격 시작. 화이팅!",
             memos: [memo("할 것", "기획안 자료 조사부터")],
             theme: 6, ddays: [.exam]),
    ]

    /// 첫째 주 (월 … 일): 행사 기획안 초안 쓰기, 토익 파트별 공부
    public static let first: [Page] = [
        // 월
        Page(tasks: [t("팀 주간 회의", P.meet, .done),
                     t("기획안 자료 조사", P.plan, .done),
                     t("주말 메일 확인하기", P.mail, .done),
                     t("받은 견적서 훑어보기", P.focus, .done),
                     t("LC 파트2 30문제", P.study, .done, late: true),
                     t("러닝 3km", P.me, .missed, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:40", P.mail), b("10:00", "11:00", P.meet),
                     b("11:00", "12:00", P.plan), b("13:00", "15:00", P.plan), b("15:10", "16:30", P.focus),
                     b("16:30", "17:40", P.mail), b("18:00", "18:40", P.rest), b("21:00", "21:50", P.study)],
             meals: [meal("12:00", "13:00"), meal("19:00", "19:50")],
             comment: "월요일 치고 괜찮은 출발!",
             memos: [memo("할 것", "견적서 3곳 비교하기"), memo("메모", "회의실 3층 예약함")],
             // 회사 일 아래에 한 줄 비우고 저녁 일을 쓴 날 (첫째 주 월요일은 오늘이 무슨 요일이든 14일 안에 있다)
             theme: nil, ddays: [.exam], blankBefore: 4),
        // 화
        Page(tasks: [t("행사 장소 후보 조사", P.focus, .done),
                     moved("견적서 3곳 비교", P.focus, then: .done),
                     t("협력사 미팅", P.meet, .done),
                     t("회의록 공유", P.mail, .done),
                     t("RC 단어 50개", P.study, .partial, late: true),
                     t("헬스 PT", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "11:30", P.focus), b("11:30", "12:00", P.mail),
                     b("13:00", "13:30", P.rest), b("13:30", "15:00", P.meet), b("15:00", "15:30", P.rest),
                     b("15:40", "17:50", P.focus), b("17:50", "18:10", P.mail), b("19:30", "20:30", P.me),
                     b("21:30", "21:50", P.study)],
             meals: [meal("12:00", "13:00"), meal("20:40", "21:20")],
             notes: [note("13:30", "협력사")],
             comment: "PT 끝나고 먹는 저녁이 제일 맛있다",
             memos: [memo("할 것", "견적서 비교 마무리")],
             theme: 3, ddays: [.exam]),
        // 수
        Page(tasks: [t("예산표 엑셀 정리", P.focus, .done),
                     t("기획안 초안 1~3장", P.plan, .done),
                     t("거래처 전화 회신", P.mail, .done),
                     t("영어 회화 수업", P.study, .done, late: true),
                     t("택배 반품 접수", P.me, .done)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "10:20", P.focus), b("10:20", "10:50", P.mail),
                     b("10:50", "12:00", P.plan), b("12:40", "13:00", P.me), b("13:00", "15:30", P.plan),
                     b("15:40", "17:30", P.focus), b("17:30", "18:00", P.mail), b("19:30", "20:30", P.study)],
             meals: [meal("12:00", "12:40"), meal("18:30", "19:10")],
             comment: "수요일은 고비. 그래도 해냈다",
             theme: 4, ddays: []),
        // 목
        Page(tasks: [t("팀장님 1:1", P.meet, .done),
                     t("마케팅팀 협의", P.meet, .done),
                     t("기획안 초안 4~6장", P.plan, .partial),
                     t("행사 안내 메일 초안", P.mail, .done),
                     t("LC 파트3 듣기", P.study, .done, late: true),
                     t("헬스 PT", P.me, .done, late: true),
                     moved("엄마 생신 선물 고르기", P.me, then: .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:30", P.mail), b("09:30", "10:00", P.meet),
                     b("10:00", "12:00", P.plan), b("13:00", "14:00", P.meet), b("14:10", "17:00", P.plan),
                     b("17:00", "17:40", P.mail), b("19:30", "20:30", P.me), b("21:00", "21:40", P.study)],
             meals: [meal("12:00", "13:00"), meal("18:30", "19:10")],
             notes: [note("09:30", "1:1")],
             comment: "초안 절반 넘김! 내일 마저 쓰기",
             memos: [memo("내일", "초안 마무리하기"), memo("선물", "스카프 vs 머플러")],
             theme: nil, ddays: [.exam]),
        // 금: 오후 반차 (가벼운 평일)
        Page(tasks: [t("기획안 초안 마무리", P.plan, .done),
                     t("주간 업무 보고", P.mail, .done),
                     t("행사 예산 검토", P.focus, .partial),
                     t("반차 내고 은행 가기", P.me, .done),
                     t("친구들 저녁 약속", P.me, .done, late: true),
                     t("RC 파트5 20문제", P.study, .missed, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:30", P.mail), b("09:30", "12:00", P.plan),
                     b("13:00", "13:40", P.focus), b("13:40", "14:00", P.mail), b("14:00", "14:40", P.rest),
                     b("15:00", "15:40", P.me)],
             meals: [meal("12:00", "13:00"), meal("19:00", "20:50")],
             notes: [note("14:00", "오후 반차")],
             comment: "반차 쓰고 친구들이랑 저녁. 행복한 금요일",
             memos: [memo("주말", "토익 모의고사 1회"), memo("할 것", "제주 숙소 알아보기")],
             theme: 7, ddays: [.exam]),
        // 토
        Page(tasks: [t("한강 러닝 5km", P.me, .done),
                     t("제주 숙소 예약", P.me, .done),
                     t("장보기", P.me, .done),
                     t("토익 모의고사 1회", P.study, .partial)],
             paint: [b("09:00", "09:50", P.me), b("11:00", "11:30", P.me), b("14:00", "15:40", P.study),
                     b("17:00", "17:50", P.me)],
             meals: [meal("12:30", "13:20")],
             notes: [note("14:00", "모의고사")],
             comment: "늦잠 자고 뛰니까 개운하다",
             memos: [memo("메모", "숙소 체크인 3시")],
             theme: 2, ddays: [.trip]),
        // 일: DAY OFF 예시 자리 (dayOffStoryDay). 할 일도 TOTAL 도 거의 없는 쉬는 날.
        // COMMENT 는 DAY OFF 에 가려 있다가 ▾ → 작성하기로 돌아오면 보이므로, 그날 일기처럼 적어 둔다.
        Page(tasks: [t("늦잠 자기", P.me, .done),
                     t("엄마랑 통화", P.me, .done)],
             paint: [b("14:00", "15:30", P.rest)],
             meals: [meal("11:30", "12:30"), meal("18:30", "19:10")],
             notes: [note("14:00", "낮잠")],
             comment: "늦잠에 낮잠까지. 푹 쉬고 충전 완료!",
             theme: 6, ddays: [], dayOff: true),
    ]

    /// 둘째 주 (월 … 일): 기획안 다듬기와 발표, 모의고사, 여행 준비
    public static let second: [Page] = [
        // 월
        Page(tasks: [t("팀 주간 회의", P.meet, .done),
                     t("기획안 중간 리뷰", P.meet, .done),
                     t("리뷰 피드백 정리", P.plan, .done),
                     t("협력사 견적 회신", P.mail, .done),
                     t("LC 파트4 듣기", P.study, .done, late: true),
                     t("러닝 3km", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:30", P.mail), b("10:00", "11:00", P.meet),
                     b("11:00", "12:00", P.plan), b("13:00", "14:00", P.plan), b("14:00", "15:30", P.meet),
                     b("15:40", "17:40", P.plan), b("17:40", "18:00", P.mail), b("19:30", "20:00", P.me),
                     b("21:00", "21:50", P.study)],
             meals: [meal("12:00", "13:00"), meal("18:40", "19:20")],
             notes: [note("14:00", "중간 리뷰")],
             comment: "피드백은 많지만 방향은 맞대. 다행!",
             memos: [memo("내일", "그래프 다시 그리기")],
             theme: 5, ddays: [.deadline, .exam]),
        // 화
        Page(tasks: [t("기획안 그래프 수정", P.plan, .done),
                     moved("행사 동선 그리기", P.plan, then: .done),
                     t("디자인팀 요청 메일", P.mail, .done),
                     t("참가자 명단 정리", P.focus, .done),
                     t("RC 단어 50개", P.study, .done, late: true),
                     t("헬스 PT", P.me, .missed, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "12:00", P.plan), b("13:00", "13:30", P.mail),
                     b("13:30", "16:00", P.focus), b("16:00", "18:00", P.plan), b("18:40", "20:00", P.plan),
                     b("20:00", "20:40", P.rest), b("22:00", "22:40", P.study)],
             meals: [meal("12:00", "13:00"), meal("18:00", "18:40")],
             notes: [note("19:00", "야근ㅠ")],
             comment: "야근했지만 표가 훨씬 보기 좋아졌다",
             memos: [memo("내일", "동선 그리기 먼저!"), memo("할 것", "PT 다음 달 등록")],
             theme: nil, ddays: [.deadline, .exam]),
        // 수
        Page(tasks: [t("발표 자료 만들기", P.plan, .partial),
                     t("디자인팀 미팅", P.meet, .done),
                     t("메일함 정리", P.mail, .done),
                     t("행사 물품 목록 정리", P.focus, .done),
                     t("영어 회화 수업", P.study, .done, late: true),
                     t("치과 정기검진", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "11:00", P.plan), b("11:00", "12:00", P.meet),
                     b("13:00", "15:00", P.plan), b("15:00", "15:40", P.mail), b("15:50", "16:50", P.focus),
                     b("16:50", "17:50", P.plan), b("18:20", "19:00", P.me), b("19:30", "20:30", P.study)],
             meals: [meal("12:00", "13:00"), meal("20:40", "21:20")],
             notes: [note("18:20", "치과")],
             comment: "디자인팀이랑 손발이 척척. 발표 자료는 반쯤",
             memos: [memo("메모", "발표 자료 글꼴 통일")],
             theme: 1, ddays: [.deadline]),
        // 목
        Page(tasks: [t("발표 자료 마무리", P.plan, .done),
                     t("발표 리허설", P.meet, .done),
                     t("행사 체크리스트 작성", P.focus, .done),
                     t("협력사 일정 확인", P.mail, .done),
                     t("LC 파트2 복습", P.study, .partial, late: true),
                     t("헬스 PT", P.me, .done, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "11:30", P.plan), b("11:30", "12:00", P.mail),
                     b("13:00", "14:00", P.meet), b("14:10", "17:30", P.focus), b("17:30", "18:00", P.mail),
                     b("19:30", "20:30", P.me), b("21:30", "21:50", P.study)],
             meals: [meal("12:00", "13:00"), meal("18:40", "19:20")],
             notes: [note("13:00", "리허설")],
             comment: "리허설 칭찬 받음 :) 자신감 충전",
             memos: [memo("내일", "체크리스트 공유"), memo("할 것", "제주 렌터카 예약")],
             theme: 3, ddays: [.deadline, .exam]),
        // 금
        Page(tasks: [t("체크리스트 팀 공유", P.mail, .done),
                     t("주간 업무 보고", P.mail, .done),
                     t("기획안 최종 검토", P.plan, .partial),
                     t("행사 물품 발주", P.focus, .done),
                     t("제주 렌터카 예약", P.me, .done),
                     t("영화 보기", P.me, .done, late: true),
                     t("RC 파트6 풀기", P.study, .missed, late: true)],
             paint: [b("08:10", "08:50", P.rest), b("09:00", "09:40", P.mail), b("09:40", "12:00", P.plan),
                     b("12:40", "13:00", P.me), b("13:00", "15:00", P.focus), b("15:00", "16:30", P.plan),
                     b("16:30", "17:30", P.mail), b("19:30", "21:40", P.me)],
             meals: [meal("12:00", "12:40"), meal("18:40", "19:20")],
             comment: "불금엔 영화지. 기획안도 거의 다 왔다",
             memos: [memo("주말", "모의고사 2회")],
             theme: 4, ddays: [.deadline, .trip]),
        // 토
        Page(tasks: [t("필라테스 체험", P.me, .done),
                     t("제주 짐 목록 쓰기", P.me, .done, late: true),
                     t("토익 모의고사 2회", P.study, .done),
                     t("오답 노트", P.study, .partial, late: true)],
             paint: [b("10:00", "10:50", P.me), b("13:30", "15:30", P.study), b("20:00", "20:30", P.study),
                     b("21:00", "21:30", P.me)],
             meals: [meal("11:30", "12:20"), meal("18:30", "19:20")],
             comment: "모의고사 점수 50점 올랐다!!",
             memos: [memo("메모", "파트7 시간이 모자람")],
             theme: 2, ddays: [.exam, .trip]),
        // 일
        Page(tasks: [t("빨래하고 장보기", P.me, .done),
                     t("공원 산책", P.me, .done),
                     t("일찍 자기", P.me, .done, late: true),
                     t("단어 복습", P.study, .done),
                     t("다음 주 계획 세우기", P.plan, .done, late: true)],
             paint: [b("10:00", "11:00", P.me), b("14:00", "15:00", P.me), b("16:00", "17:00", P.study),
                     b("21:00", "21:30", P.plan)],
             meals: [meal("12:00", "12:50")],
             comment: "산책하면서 머리 비우기 성공",
             memos: [memo("메모", "기획안 마감까지 조금만 더!")],
             theme: 8, ddays: [.exam, .trip]),
    ]

    /// 주간 기록: 이야기의 준비 주 · 첫째 주 · 둘째 주 (storyWeek 번호). 이번 주는 늘 둘째 주라 "지금까지"로 쓴다.
    /// 돌아보기(review)는 주간 페이지에 보이지 않지만 파일에는 남는 칸이라 같이 채워 둔다.
    public static let weeks: [Week] = [
        Week(goal: "행사 준비 시작! 토익 접수하고 러닝 시작하기", review: "킥오프 무사히 끝. 첫 러닝은 숨찼다", stars: 3),
        Week(goal: "행사 기획안 초안 쓰고 토익 LC 매일 30분", review: "초안 완성! 운동은 조금 부족했다", stars: 4),
        Week(goal: "기획안 다듬어서 마감 전에 여유 있게 끝내기", review: "마감 앞두고 지금까지는 순조롭다", stars: 4),
    ]

    /// 같은 오늘이면 늘 같은 id 를 만드는 작은 난수 (splitmix64)
    public struct IDs {
        private var state: UInt64

        public init(seed: String) {
            // FNV-1a
            state = seed.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
        }

        private mutating func mix() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        public mutating func next() -> UUID {
            let a = mix(), b = mix()
            var x = [UInt8](repeating: 0, count: 16)
            for i in 0..<8 {
                x[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i)))
                x[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i)))
            }
            x[6] = (x[6] & 0x0F) | 0x40   // 버전 4
            x[8] = (x[8] & 0x3F) | 0x80   // RFC 4122
            return UUID(uuid: (x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
                               x[8], x[9], x[10], x[11], x[12], x[13], x[14], x[15]))
        }
    }
}
