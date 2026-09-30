import AppKit
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
    static let sampleBookName = "예시 플래너"
    /// 표지: 첫 플래너의 기본 표지(체리)와 겹치지 않는 민트
    static let sampleBookCover = 3

    /// 예시 플래너 한 권 (책 정보 + 내용). 오늘 − 13일 ~ 오늘, 기본 형광펜.
    static func makeSampleBook(today now: Date) -> (book: BookInfo, data: PlannerData) {
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

enum SampleBook {
    static let dayCount = 14
    /// 오늘은 이 시각 전까지만 칠하고, 저녁 일(late)은 아직 표시하지 않는다
    static let todayCutoff = "18:00"
    static let todayComment = "남은 것도 하나씩, 천천히 해 보자"
    /// 첫 장에 적은 말 (명언이 아니라 이 사람이 스스로 적은 다짐, 한 줄은 짧게)
    static let motto = "완벽한 하루 말고\n조금 나아진 하루\n그거면 충분해"

    /// 형광펜 (Prefs.defaultCategories 의 id)
    enum Pen {
        static let focus = 0, meet = 1, mail = 2, plan = 3, study = 4, me = 5, rest = 6
    }

    enum DDayKind: CaseIterable {
        case deadline, exam, trip

        var title: String {
            switch self {
            case .deadline: "기획안 마감"
            case .exam: "토익 시험"
            case .trip: "제주 여행"
            }
        }

        /// 오늘 뒤의 날짜: 마감은 나흘 뒤(주말이면 그다음 월요일), 시험은 보름쯤 뒤 일요일, 여행은 4주 넘어 금요일
        func date(after today: Date) -> Date {
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

    struct Task {
        let text: String
        let cat: Int
        let mark: Mark
        /// 저녁(6시 뒤)에 하는 일 — 오늘이면 아직 안 한 것으로 둔다
        var late = false
        /// → 일 때만: 다음 날로 넘어간 할 일에 그날 한 표시
        var then: Mark = .done
    }

    struct Block { let from: String, to: String, cat: Int }
    struct Span { let from: String, to: String }
    struct Note { let at: String, text: String }
    struct Memo { let tag: String, text: String }

    struct Page {
        var tasks: [Task]
        /// 칠한 칸 (끝 시각은 넣지 않는다)
        var paint: [Block]
        var meals: [Span] = []
        var notes: [Note] = []
        var comment = ""
        var memos: [Memo] = []
        var theme: Int? = nil
        var ddays: [DDayKind] = []
        /// 쉬는 날 (DAY OFF). 이야기에서 하루뿐 — dayOffStoryDay
        var dayOff = false
        /// 이 할 일(형광펜끼리 모은 순서) 앞에서 한 줄 비우고 쓴다 — 할 일은 아무 줄에나 쓸 수 있다는 예시 (1.0.5)
        var blankBefore: Int? = nil
    }

    struct Week { let goal: String, review: String, stars: Int }

    /// 월 = 0 … 일 = 6
    static func weekday(_ d: Date) -> Int { ((Dates.comp(d).weekday ?? 2) + 5) % 7 }

    /// 형광펜끼리 모은 할 일에 위에서부터 줄을 매긴다. reserveAfter 의 형광펜마다 그 묶음 바로 아래에 한 줄씩 비워 두고
    /// (어제 → 로 넘어올 자리), blankBefore 번째 할 일 앞에서 한 줄 비운다.
    static func rowed(_ tasks: [PlanTask], reserveAfter cats: [Int?], blankBefore: Int?) -> [PlanTask] {
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
    static func slot(_ hm: String) -> Int {
        let p = hm.split(separator: ":").map { Int($0) ?? 0 }
        let h = p[0], m = p.count > 1 ? p[1] : 0
        let row = h >= 6 ? h - 6 : h + 18
        return min(row * 6 + m / 10, DayRecord.slotCount)
    }

    /// 14일의 첫날이 이야기의 몇 번째 장인지 (준비 주 월요일 = 0 … 둘째 주 일요일 = 20).
    /// 오늘(첫날 + 13)이 14 + 요일, 곧 둘째 주의 같은 요일이 되게 한다. 1…7 이라 준비 주 월요일은 쓰이지 않는다.
    static func firstStoryDay(today: Date) -> Int { weekday(today) + 1 }

    /// 이야기 장 수 (준비 주 · 첫째 주 · 둘째 주)
    static let storyDayCount = 3 * 7

    /// 이야기의 j 번째 장 (j % 7 = 요일)
    static func page(storyDay j: Int) -> Page { [prep, first, second][j / 7][j % 7] }

    /// 달력의 한 주(ws = 주 시작)가 이야기의 몇째 주인지 (weeks 의 번호). 14일 앞에 걸친 주는 첫날로 센다.
    static func storyWeek(of ws: Date, start: Date, firstStoryDay s: Int) -> Int {
        (s + Dates.daysBetween(start, max(ws, start))) / 7
    }

    /// DAY OFF 예시 자리: 첫째 주 일요일 (그 장의 Page.dayOff). 오늘이 무슨 요일이든 14일 안에 늘 들어 있다 (s + i, s = 1…7).
    static let dayOffStoryDay = 7 + 6

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
    static let prep: [Page] = [
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
    static let first: [Page] = [
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
    static let second: [Page] = [
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
    static let weeks: [Week] = [
        Week(goal: "행사 준비 시작! 토익 접수하고 러닝 시작하기", review: "킥오프 무사히 끝. 첫 러닝은 숨찼다", stars: 3),
        Week(goal: "행사 기획안 초안 쓰고 토익 LC 매일 30분", review: "초안 완성! 운동은 조금 부족했다", stars: 4),
        Week(goal: "기획안 다듬어서 마감 전에 여유 있게 끝내기", review: "마감 앞두고 지금까지는 순조롭다", stars: 4),
    ]

    /// 같은 오늘이면 늘 같은 id 를 만드는 작은 난수 (splitmix64)
    struct IDs {
        private var state: UInt64

        init(seed: String) {
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

        mutating func next() -> UUID {
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

// MARK: - QA CLI

/// `Spiralday --sample-book-test <dir>` — 앱의 실제 데이터 폴더는 건드리지 않는다. 오늘을 기준으로 예시 플래너를 만들어
///   sample.json                 책 내용 (PlannerData)
///   daily-YYYY-MM-DD.png        14일치 일간 (1277 × 2000, --snapshot 과 같은 PageSnapshotter)
///   daily-YYYY-MM-DD-write.png  DAY OFF 날을 ▾ → 작성하기로 돌렸을 때 (가려 둔 COMMENT)
///   weekly-YYYY-MM-DD.png       겹치는 주 (주 시작 날짜)
///   daily-cover.png · daily-motto.png · weekly-cover.png · weekly-motto.png   책 맨 앞의 표지 · 첫 장
///   home.png                    홈
///   onboarding-ready.png        튜토리얼 마지막 장 (예시 플래너 안내 줄)
///   settings-books*.png         설정 → 플래너 (예시 표시 / 지운 뒤 ‘다시 넣기’)
/// 을 쓰고, <dir>/store-sim 임시 폴더에서 첫 실행 · 1.0.3 에서 업데이트 · 다시 켜기 · 지우기를 흉내 내 확인한다.
@MainActor
enum SampleBookTest {
    private static var failures = 0

    static func run(to dir: URL) async -> Int32 {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().path.lowercased()
        let target = dir.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        for name in ["spiralday", "paperplanner"] where target == support + "/" + name || target.hasPrefix(support + "/" + name + "/") {
            print("결과 폴더를 앱의 실제 데이터 폴더(~/Library/Application Support) 안에 둘 수 없어요")
            return 2
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = Dates.day(Date())
        let (book, data) = PlannerStore.makeSampleBook(today: today)

        // 같은 오늘이면 같은 내용인지
        let again = PlannerStore.makeSampleBook(today: today).data
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let json = try? enc.encode(data) else { print("JSON 로 만들지 못했어요"); return 1 }
        do { try json.write(to: dir.appendingPathComponent("sample.json"), options: .atomic) } catch {
            print("sample.json 을 쓰지 못했어요: \(error.localizedDescription)")
            return 1
        }

        let store = PlannerStore(inMemory: true)
        store.useBook(book, data: data)
        print("예시 플래너: \(book.name) · \(book.periodText) · 표지 \(ColorConcept.of(book.cover).name) · isSample \(book.isSample)")
        check("같은 오늘로 다시 만들면 같은 내용", (try? enc.encode(again)) == json)
        print("저장한 D-day: " + store.ddayLibrary.map { "\($0.title) \(Dates.key($0.date)) (\($0.count(from: today)))" }.joined(separator: " · "))

        var d = book.start
        while d <= today {
            let state = AppState(kind: .daily, today: today)
            state.store = store
            state.dayIndex = Dates.daysBetween(state.baseDay, d)
            render(store, state, .daily, state.dayIndex, dir.appendingPathComponent("daily-\(Dates.key(d)).png"))
            let r = store.day(d)
            // ↳ = 전날 → 에서 넘어온 할 일
            let marks = r.tasks.map { ($0.carriedFrom != nil ? "↳" : "") + sym($0.mark) }.joined()
            let (h, m) = formatHM(store.minutes(d))
            let dd = r.ddays.map { "\($0.title) \($0.count(from: d))" }.joined(separator: ", ")
            let meals = r.notes.filter { $0.kind == .meal }.count, texts = r.notes.filter { $0.kind == .text }.count
            print("\(Dates.key(d)) \(Dates.weekdayEN[Dates.comp(d).weekday!].prefix(3)) 할 일 \(r.tasks.count) [\(marks)] "
                  + "TOTAL \(h)H\(m)M · 밥 \(meals) · 글씨 \(texts) · 컬러 \(r.theme.map { ColorConcept.of($0).name } ?? "기본") · "
                  + "D-day [\(dd)] · COMMENT \(r.comment.isEmpty ? "-" : "‘\(r.comment)’") · MEMO \(r.memos.filter { !$0.isEmpty }.count)"
                  + (r.dayOff ? " · DAY OFF" : ""))
            d = Dates.add(days: 1, to: d)
        }
        // DAY OFF 날을 작성하기로 돌렸을 때: 가려 둔 COMMENT 가 그날 일기로 읽히는지 눈으로 본다 (다른 그림에는 영향 없게 따로)
        for (key, r) in data.days where r.dayOff {
            guard let off = Dates.parse(key) else { continue }
            let write = PlannerStore(inMemory: true)
            write.useBook(book, data: data)
            write.setDayOff(off, false)
            let state = AppState(kind: .daily, today: today)
            state.store = write
            state.dayIndex = Dates.daysBetween(state.baseDay, off)
            render(write, state, .daily, state.dayIndex, dir.appendingPathComponent("daily-\(key)-write.png"))
            check("DAY OFF 를 작성하기로 돌리면 COMMENT 가 그대로 보인다 (\(key) ‘\(write.day(off).comment)’)",
                  !write.isDayOff(off) && !write.day(off).comment.isEmpty && write.day(off).comment == r.comment)
        }
        let found = problems(data, today: today)
        for p in found { print("  · \(p)") }
        check("내용 점검 (오늘): 요일·이야기 순서 · 주간 목표는 그 주 이야기 · → 는 다음 날에 하나 (carriedFrom · 같은 글 · 같은 형광펜 · "
              + "이야기대로 표시) · 넘어온 할 일은 전날 → 에서 · ○ 형광펜은 타임테이블에도 · 오늘은 쓰는 중 (→ 없음) · 오늘 D-day · "
              + "D-day 0/1/2개 날 · 이웃한 날 컬러 다름 · 컬러 5가지 이상 · 주간 목표와 별점 · TOTAL 평일 4–10시간 / 주말 1–3시간 · "
              + "DAY OFF 는 쉬는 날(첫째 주 일요일) 하루만, 가볍게 · 할 일 줄은 15줄 안 · 형광펜끼리 이어서 · 한 줄 비우고 쓴 날", found.isEmpty)
        // 오늘의 요일에 따라 준비 주 · 첫째 주 · 둘째 주에서 잘라 오는 곳이 달라지므로, 요일 7가지 모두 내용만 따로 점검한다
        var rotations: [String] = []
        for k in 1..<7 {
            let other = Dates.add(days: k, to: today)
            let p = problems(PlannerStore.makeSampleBook(today: other).data, today: other)
            if !p.isEmpty { rotations.append("\(Dates.key(other)): " + p.joined(separator: " / ")) }
        }
        for r in rotations { print("  · \(r)") }
        check("내용 점검 (오늘이 다른 요일일 때 6가지도)", rotations.isEmpty)
        // 앱의 setMark 로 → 를 다시 눌러 만든 것과 같은지 (요일 7가지 모두)
        var appDiffs: [String] = []
        for k in 0..<7 {
            let other = Dates.add(days: k, to: today)
            let p = carryMismatches(today: other)
            if !p.isEmpty { appDiffs.append("\(Dates.key(other)): " + p.joined(separator: " / ")) }
        }
        for r in appDiffs { print("  · \(r)") }
        check("→ 넘기기가 앱과 같다 (요일 7가지): 표시를 떼고 앱에서 → 를 다시 누르면 같은 줄에 같은 할 일이 넘어가고, "
              + "그대로 → 를 또 눌러도 늘지 않는다", appDiffs.isEmpty)

        var ws = Dates.weekStart(book.start)
        while ws <= today {
            let state = AppState(kind: .weekly, today: today)
            state.store = store
            state.weekIndex = Dates.daysBetween(state.baseWeek, ws) / 7
            render(store, state, .weekly, state.weekIndex, dir.appendingPathComponent("weekly-\(Dates.key(ws)).png"))
            let w = store.week(ws)
            print("주간 \(Dates.key(ws)) 목표 ‘\(w.goal)’ · 별 \(w.stars) · 돌아보기 ‘\(w.review)’")
            ws = Dates.add(days: 7, to: ws)
        }

        // 책 맨 앞의 표지 · 첫 장 (하고 싶은 말)
        for kind in [PageKind.daily, .weekly] {
            let state = AppState(kind: kind, today: today)
            state.store = store
            for page in FrontPage.allCases {
                render(store, state, kind, state.frontIndex(page, kind),
                       dir.appendingPathComponent("\(kind.rawValue)-\(page == .cover ? "cover" : "motto").png"))
            }
        }
        check("첫 장에 하고 싶은 말이 적혀 있다 (‘\(store.data.prefs.motto.replacingOccurrences(of: "\n", with: " / "))’)",
              store.data.prefs.motto == SampleBook.motto)

        let home = AppState(kind: .home, today: today)
        home.store = store
        render(store, home, .home, 0, dir.appendingPathComponent("home.png"))

        // 튜토리얼 마지막 장: 첫 플래너를 만든 뒤 예시 플래너가 옆에 꽂힌 책장
        let fresh = PlannerStore(inMemory: true)
        fresh.addSampleBook(today: today)
        let draft = OnboardingModel(store: fresh)
        check("예시만 있을 때 튜토리얼은 처음처럼: 플래너 만들기 · ‘내 플래너’ · 체리 표지",
              draft.needsBook && draft.plannerMode == .create && draft.draft.name == BookDraft.defaultName && draft.draft.cover == 0)
        fresh.createBook(name: draft.draft.resolvedName, start: today, end: nil, cover: draft.draft.cover)
        check("튜토리얼에서 만든 책이 펼쳐지고, 예시는 책장 끝에",
              fresh.activeBook?.isSample == false && fresh.books.last?.isSample == true && fresh.userBooks.count == 1)
        let ready = ImageRenderer(content: OnboardingView(model: OnboardingModel(store: fresh, step: .ready))
            .environmentObject(fresh).environmentObject(AppState()))
        ready.scale = 2
        if let img = ready.cgImage { Snapshotter.write(img, dir.appendingPathComponent("onboarding-ready.png")) }

        // 설정 → 플래너: 예시 표시, 지운 뒤 ‘예시 플래너 다시 넣기’
        await renderSettings(fresh, dir.appendingPathComponent("settings-books.png"))
        if let sample = fresh.books.first(where: \.isSample) { fresh.deleteBook(sample.id) }
        await renderSettings(fresh, dir.appendingPathComponent("settings-books-no-sample.png"))
        check("예시를 지우면 ‘다시 넣기’로 새로 꽂히고 펼친 책은 그대로",
              !fresh.hasSampleBook && fresh.addSampleBook(today: today) != nil && fresh.activeBook?.isSample == false)

        simulateStore(in: dir.appendingPathComponent("store-sim"), today: today)
        print(failures == 0 ? "모든 확인 통과" : "확인 실패 \(failures)개")
        print("결과: \(dir.path)")
        return failures == 0 ? 0 : 1
    }

    /// 요일이 어떻게 놓여도 지켜야 할 것. 어긋난 것을 글로 돌려준다 (없으면 빈 배열).
    static func problems(_ data: PlannerData, today now: Date) -> [String] {
        var out: [String] = []
        let today = Dates.day(now)
        let cats = Dictionary(uniqueKeysWithValues: data.prefs.categories.map { ($0.id, $0) })
        let start = Dates.add(days: -(SampleBook.dayCount - 1), to: today)
        let s = SampleBook.firstStoryDay(today: today)
        if !(1...7).contains(s) { out.append("첫날 장 번호 \(s)") }
        if !(s..<(s + SampleBook.dayCount)).contains(SampleBook.dayOffStoryDay) { out.append("쉬는 날이 14일 안에 없음") }
        let storyOff = (0..<SampleBook.storyDayCount).filter { SampleBook.page(storyDay: $0).dayOff }
        if storyOff != [SampleBook.dayOffStoryDay] { out.append("이야기의 DAY OFF 장이 \(storyOff) (dayOffStoryDay 하나여야)") }
        if data.days.count != SampleBook.dayCount { out.append("기록한 날이 \(data.days.count)일 (14일 밖에 넘어간 것)") }
        var previousTheme: Int? = nil
        var carriedCount = 0
        var blankDays = 0
        for i in 0..<SampleBook.dayCount {
            let d = Dates.add(days: i, to: start), k = Dates.key(d)
            guard let r = data.days[k] else { out.append("\(k) 기록 없음"); continue }
            let isToday = i == SampleBook.dayCount - 1
            let weekend = SampleBook.weekday(d) >= 5
            let j = s + i
            // 이야기 순서: 장의 요일 = 날짜의 요일, 오늘 = 둘째 주, 주간 목표 = 그날이 든 이야기 주
            if j % 7 != SampleBook.weekday(d) { out.append("\(k) 요일과 장(\(j))이 어긋남") }
            if isToday && j / 7 != 2 { out.append("오늘이 둘째 주 장이 아님") }
            if data.weeks[Dates.key(Dates.weekStart(d))]?.goal != SampleBook.weeks[j / 7].goal { out.append("\(k) 주간 목표가 그 주 이야기와 어긋남") }
            let minutes = r.slots.filter { cats[$0]?.counts == true }.count * 10
            if j == SampleBook.dayOffStoryDay {
                // 쉬는 날: 할 일은 조금, TOTAL 은 비워 둔다
                if !weekend || isToday { out.append("\(k) 쉬는 날이 주말이 아니거나 오늘") }
                if r.tasks.count > 3 { out.append("\(k) 쉬는 날인데 할 일 \(r.tasks.count)개") }
                if minutes > 0 { out.append("\(k) 쉬는 날인데 TOTAL \(minutes)분") }
            } else {
                if !(3...8).contains(r.tasks.count) { out.append("\(k) 할 일 \(r.tasks.count)개") }
                if weekend ? !(60...180).contains(minutes) : !(240...600).contains(minutes) { out.append("\(k) TOTAL \(minutes)분") }
            }
            // 할 일 줄 (1.0.5): 15줄 안에서 줄 순서대로 겹치지 않게, 같은 형광펜끼리 이어서 (빈 줄은 건너뛰고 본다)
            if !r.taskRowsReady || r.tasks.contains(where: { ($0.row ?? .max) >= DailyForm.taskCount }) {
                out.append("\(k) 할 일 줄이 어긋남 \(r.tasks.map { $0.row ?? -1 })")
            }
            if PlannerStore.grouped(r.tasks) != r.tasks { out.append("\(k) 형광펜끼리 모이지 않음") }
            if let last = r.tasks.last?.row, last + 1 > r.tasks.count { blankDays += 1 }
            if r.comment.isEmpty { out.append("\(k) COMMENT 없음") }
            // → : 앱처럼 다음 날에 이 할 일에서 넘어온 것(carriedFrom = 이 id)이 꼭 하나 — 같은 글 · 같은 형광펜 ·
            // 이야기에서 정한 표시. 오늘은 플래너의 마지막 날이라 앱도 넘기지 않으므로 → 가 없어야 한다.
            let next = data.days[Dates.key(Dates.add(days: 1, to: d))]?.tasks ?? []
            for t in r.tasks where t.mark == .moved {
                if isToday { out.append("오늘 ‘\(t.text)’ 가 → (마지막 날은 넘기지 않음)"); continue }
                let copies = next.filter { $0.carriedFrom == t.id }
                let then = SampleBook.page(storyDay: j).tasks.first { $0.mark == .moved && $0.text == t.text && $0.cat == t.cat }?.then ?? .done
                if copies.count != 1 {
                    out.append("\(k) ‘\(t.text)’ → 가 다음 날에 \(copies.count)개 넘어감")
                } else if let c = copies.first, c.text != t.text || c.cat != t.cat || c.mark != then {
                    out.append("\(k) ‘\(t.text)’ → 복사본이 글 · 형광펜 · 표시(\(sym(then)))와 다름")
                }
                if next.filter({ $0.text == t.text && $0.cat == t.cat }).count != 1 { out.append("\(k) ‘\(t.text)’ 가 다음 날에 겹쳐 있음") }
            }
            // 넘어온 할 일: 전날의 → 할 일(같은 글 · 같은 형광펜)을 가리킨다
            let prev = i > 0 ? data.days[Dates.key(Dates.add(days: -1, to: d))]?.tasks ?? [] : []
            for t in r.tasks where t.carriedFrom != nil {
                carriedCount += 1
                let o = prev.first { $0.id == t.carriedFrom }
                if o?.mark != .moved || o?.text != t.text || o?.cat != t.cat { out.append("\(k) ‘\(t.text)’ 가 전날의 → 할 일에서 넘어오지 않음") }
            }
            // DAY OFF 는 이야기의 쉬는 날 하루만
            if r.dayOff != (j == SampleBook.dayOffStoryDay) { out.append("\(k) DAY OFF 가 \(r.dayOff ? "쉬는 날이 아닌 날에" : "쉬는 날에 없음")") }
            for t in r.tasks where t.mark == .done {
                if let c = t.cat, cats[c]?.counts == true, !r.slots.contains(c) { out.append("\(k) ‘\(t.text)’ ○ 인데 그 색 시간이 없음") }
            }
            // 고르지 않은 날(nil)은 기본 컬러로 보이므로 그것까지 견준다
            let theme = r.theme ?? data.prefs.defaultTheme
            if theme == previousTheme { out.append("\(k) 전날과 같은 컬러") }
            previousTheme = theme
            if r.ddays.contains(where: { $0.date <= today }) { out.append("\(k) 지난 D-day") }
            if isToday {
                if r.tasks.filter({ $0.mark == .none }).count < 2 { out.append("오늘 남은 할 일이 두 개보다 적음") }
                if r.tasks.filter({ $0.mark == .done }).count < 2 { out.append("오늘 끝낸 일이 두 개보다 적음") }
                if r.ddays.isEmpty { out.append("오늘 D-day 없음") }
                if r.slots[SampleBook.slot(SampleBook.todayCutoff)...].contains(where: { $0 >= 0 }) { out.append("오늘 저녁이 칠해져 있음") }
            }
        }
        if carriedCount == 0 { out.append("다음 날로 넘어간 할 일이 없음") }
        if blankDays == 0 { out.append("한 줄 비우고 쓴 날이 없음 (아무 줄에나 쓰는 예시)") }
        if data.days.values.filter(\.dayOff).count != 1 { out.append("DAY OFF 가 \(data.days.values.filter(\.dayOff).count)일") }
        if Set(data.days.values.map(\.ddays.count)) != [0, 1, 2] { out.append("D-day 0/1/2개 날이 다 있지 않음") }
        if Set(data.days.values.compactMap(\.theme)).count < 5 || !data.days.values.contains(where: { $0.theme == nil }) {
            out.append("컬러가 다양하지 않음")
        }
        if data.prefs.ddays.contains(where: { $0.date <= today }) { out.append("저장한 D-day 가 오늘보다 앞") }
        var ws = Dates.weekStart(start)
        while ws <= today {
            let w = data.weeks[Dates.key(ws)]
            if (w?.goal ?? "").isEmpty || (w?.stars ?? 0) == 0 { out.append("주간 \(Dates.key(ws)) 목표·별점 없음") }
            ws = Dates.add(days: 7, to: ws)
        }
        return out
    }

    /// 예시의 → 마다 앱의 PlannerStore.setMark 를 그대로 거쳐 본다. 어긋난 것을 글로 돌려준다.
    ///  1) 예시 그대로 → 를 또 눌러도 다음 날 할 일이 늘지 않는다 (앱이 넘어간 것으로 알아본다)
    ///  2) 넘어간 할 일을 지우고 표시를 뗀 뒤 → 를 누르고, 넘어간 것에 이야기대로 표시하면 예시와 똑같아진다
    ///     (글 · 형광펜 · 표시 · carriedFrom · 줄. 새로 만든 할 일의 id 만 다르다)
    static func carryMismatches(today: Date) -> [String] {
        let (book, data) = PlannerStore.makeSampleBook(today: today)
        func shape(_ days: [String: DayRecord]) -> [String: [String]] {
            days.mapValues { $0.tasks.map { "\($0.text)|\($0.cat ?? -1)|\($0.mark.rawValue)|\($0.carriedFrom?.uuidString ?? "-")|\($0.row ?? -1)" } }
        }
        var out: [String] = []
        let same = PlannerStore(inMemory: true)
        same.useBook(book, data: data)
        let redo = PlannerStore(inMemory: true)
        redo.useBook(book, data: data)
        for key in data.days.keys.sorted() {
            guard let d = Dates.parse(key) else { continue }
            let nextKey = Dates.key(Dates.add(days: 1, to: d))
            for t in data.days[key]?.tasks ?? [] where t.mark == .moved {
                same.setMark(d, t.id, .moved)
                if same.day(Dates.add(days: 1, to: d)).tasks != data.days[nextKey]?.tasks { out.append("\(key) ‘\(t.text)’ 를 또 → 하면 다음 날이 바뀜") }

                guard let copy = data.days[nextKey]?.tasks.first(where: { $0.carriedFrom == t.id }) else {
                    out.append("\(key) ‘\(t.text)’ 넘어간 것이 없음"); continue
                }
                let next = Dates.add(days: 1, to: d)
                redo.editDay(next) { $0.tasks.removeAll { $0.id == copy.id } }
                redo.editDay(d) { r in if let i = r.tasks.firstIndex(where: { $0.id == t.id }) { r.tasks[i].mark = .none } }
                redo.setMark(d, t.id, .moved)
                guard let made = redo.carriedCopy(of: t.id, from: d) else { out.append("\(key) ‘\(t.text)’ 앱이 넘기지 않음"); continue }
                redo.setMark(next, made.id, copy.mark)
            }
        }
        let want = shape(data.days), got = shape(redo.data.days)
        for key in Set(want.keys).union(got.keys).sorted() where want[key] != got[key] {
            out.append("\(key) 앱으로 다시 넘긴 할 일이 예시와 다름: \(got[key] ?? []) ≠ \(want[key] ?? [])")
        }
        return out
    }

    /// 체크 표시 한 글자 (· = 표시 없음)
    private static func sym(_ m: Mark) -> String { ["·", "○", "△", "×", "→"][m.rawValue] }

    private static func check(_ what: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗ 실패") \(what)")
    }

    private static func render(_ store: PlannerStore, _ state: AppState, _ kind: PageKind, _ index: Int, _ url: URL) {
        let snap = PageSnapshotter(store: store, state: state)
        if let img = snap.image(kind: kind, index: index, size: kind.design, scale: 1) { Snapshotter.write(img, url) }
    }

    /// 설정 → 플래너 화면을 화면 밖 창에 그려 PNG 로 (Form 은 ImageRenderer 로 그려지지 않는다)
    private static func renderSettings(_ store: PlannerStore, _ url: URL) async {
        let state = AppState()
        state.store = store
        state.fontsReady = true
        // 설정 창을 가장 좁게 줄였을 때의 오른쪽 칸 폭
        let size = CGSize(width: 490, height: 600)
        let host = NSHostingView(rootView: SettingsBooksPanePreview()
            .environmentObject(store).environmentObject(state)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
        w.orderOut(nil)
    }

    /// 임시 폴더를 앱의 저장 폴더처럼 써서, 켤 때마다 하는 일(책장 읽기 → 예시 꽂기)을 흉내 낸다
    private static func simulateStore(in root: URL, today: Date) {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        func launch(_ dir: URL) -> PlannerStore {
            let s = PlannerStore(folder: dir)
            s.seedSampleBookIfNeeded(today: today)
            return s
        }
        func library(_ dir: URL) -> [String: Any] {
            (try? Data(contentsOf: dir.appendingPathComponent("library.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }

        // 1) 처음 설치: 예시만 꽂히고 펼치지 않는다 → 튜토리얼
        let first = root.appendingPathComponent("first-run")
        var s = launch(first)
        check("처음 켜기: 예시 플래너 한 권이 꽂히고 펼치지 않는다 (튜토리얼 필요)",
              s.books.count == 1 && s.hasSampleBook && s.activeBook == nil && s.userBooks.isEmpty)
        check("처음 켜기: 예시 책 파일이 books 폴더에 있다",
              s.books.first.map { fm.fileExists(atPath: first.appendingPathComponent("books/\($0.id.uuidString).json").path) } ?? false)
        // 튜토리얼 도중 끄고 다시 켜도 예시는 한 권, 여전히 튜토리얼
        s = launch(first)
        check("튜토리얼 전에 다시 켜기: 예시는 그대로 한 권, 펼친 책 없음",
              s.books.count == 1 && s.activeBook == nil && s.userBooks.isEmpty)
        s.createBook(name: BookDraft.defaultName, start: today, end: nil)
        s = launch(first)
        check("내 플래너를 만든 뒤 다시 켜기: 내 플래너가 펼쳐지고 예시는 그대로",
              s.activeBook?.name == BookDraft.defaultName && s.books.count == 2 && s.books.last?.isSample == true)
        // 예시를 펼쳐 둔 채 지우면 내 플래너가 펼쳐진다
        if let sample = s.books.first(where: \.isSample) { s.activate(sample.id); s.deleteBook(sample.id) }
        check("펼친 예시를 지우면 내 플래너가 펼쳐진다", s.activeBook?.isSample == false && !s.hasSampleBook)
        s = launch(first)
        check("예시를 지운 뒤 다시 켜기: 다시 꽂지 않는다", !s.hasSampleBook && s.books.count == 1)
        check("library.json 에 sampleSeeded = true", library(first)["sampleSeeded"] as? Bool == true)

        // 2) 1.0.3 에서 업데이트: 쓰던 책은 그대로 펼친 채, 예시가 끝에 한 번 꽂힌다
        let update = root.appendingPathComponent("update-from-1.0.3")
        try? fm.createDirectory(at: update.appendingPathComponent("books"), withIntermediateDirectories: true)
        let oldID = UUID()
        let oldLibrary = """
        {"activeID":"\(oldID.uuidString)","books":[{"cover":1,"created":"2026-01-01T00:00:00Z","id":"\(oldID.uuidString)",\
        "name":"회사 플래너","start":"2026-01-01T00:00:00Z"}]}
        """
        try? oldLibrary.data(using: .utf8)?.write(to: update.appendingPathComponent("library.json"))
        try? #"{"days":{},"weeks":{},"prefs":{"ddaysPerDay":true}}"#.data(using: .utf8)?
            .write(to: update.appendingPathComponent("books/\(oldID.uuidString).json"))
        s = launch(update)
        check("업데이트: 쓰던 책은 그대로 펼쳐 있고 예시가 끝에 꽂힌다",
              s.activeBook?.id == oldID && s.books.count == 2 && s.books.last?.isSample == true && s.books.first?.isSample == false)
        s = launch(update)
        check("업데이트 뒤 다시 켜기: 예시는 한 권뿐", s.books.filter(\.isSample).count == 1)
        let saved = (library(update)["books"] as? [[String: Any]]) ?? []
        check("library.json: 예시 책에만 isSample 이 적힌다",
              saved.filter { $0["isSample"] as? Bool == true }.count == 1 && saved.filter { $0["isSample"] == nil }.count == 1)

        // 3) 읽지 못하는 library.json: 덮어쓰지 않는다
        let broken = root.appendingPathComponent("unreadable-library")
        try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
        let junk = Data("{ 이건 JSON 이 아니에요".utf8)
        try? junk.write(to: broken.appendingPathComponent("library.json"))
        s = launch(broken)
        check("읽지 못하는 library.json 은 그대로 두고 예시를 꽂지 않는다",
              !s.hasSampleBook && (try? Data(contentsOf: broken.appendingPathComponent("library.json"))) == junk)
    }
}
