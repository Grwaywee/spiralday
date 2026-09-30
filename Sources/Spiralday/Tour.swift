import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// 플래너 둘러보기 (1.0.5). 본 창의 종이 위에 코치 마크를 띄워 차례로 안내한다.
//   일간 → 주간 → 홈 → 표지와 첫 장 → 끝 (설정 → 튜토리얼에서 한 부분만 볼 수도 있다)
//
//   · 가리키는 곳만 밝게 두고 나머지 종이는 어둡게, 옆에 말풍선 (n / N · 이전 · 다음 · 끝내기)
//   · 키: → / Return 다음, ← 이전, Esc 끝내기. 도는 동안 플래너 단축키 · 종이 누르기 · 팔레트는 쉰다
//     (단계가 허락한 곳만 누를 수 있다: 첫 장의 글 칸)
//   · 팔레트의 도구를 가리킬 때는 팔레트의 그 도구가 빛나고 말풍선이 팔레트 쪽을 가리킨다
//   · 예시 플래너가 있으면 잠깐 그 책을 펼쳐 보여 주고 (마지막 날 전날 · 일곱 날이 다 찬 마지막 주),
//     끝나면 보던 책 · 보던 장으로 돌아간다. 없으면 지금 책의 보던 날 · 주로 둘러본다
//   · 저절로는 한 번만 (본 창을 처음 열 때: 새 사용자는 처음 안내 뒤, 기존 사용자는 1.0.5 첫 실행).
//     그 뒤로는 도움말 → 플래너 둘러보기, 설정 → 튜토리얼에서
//
// 가리키는 자리는 디자인 단위 (DailyForm · WK · HM · FrontMatterLayout) × u 라서 창 크기를 따라간다.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - 둘러보기 종류 · 단계

/// 설정 → 튜토리얼에서 고를 수 있는 둘러보기
enum TourKind: String, CaseIterable, Identifiable {
    case full, daily, weekly, home, front

    var id: Self { self }

    var title: String {
        switch self {
        case .full: "플래너 둘러보기 — 전체"
        case .daily: "일간만"
        case .weekly: "주간만"
        case .home: "홈만"
        case .front: "표지와 첫 장만"
        }
    }

    var detail: String {
        switch self {
        case .full: "일간 → 주간 → 홈 → 표지와 첫 장을 차례로 둘러봐요."
        case .daily: "D-day · COMMENT · 할 일과 표시 · MEMO · 타임테이블 · 팔레트 도구 · 넘기기"
        case .weekly: "이번 주 목표 · 한 주 돌아보기 · 요일 칸"
        case .home: "홈의 통계 칸이 각각 무엇을 보여 주는지"
        case .front: "첫 장에 하고 싶은 말 적기 · 표지와 PDF"
        }
    }

    var symbol: String {
        switch self {
        case .full: "map.fill"
        case .daily: "doc.plaintext"
        case .weekly: "rectangle.split.3x1"
        case .home: "chart.bar.xaxis"
        case .front: "book.closed.fill"
        }
    }

    fileprivate var sections: [TourSection] {
        switch self {
        case .full: [.daily, .weekly, .home, .front, .end]
        case .daily: [.daily]
        case .weekly: [.weekly]
        case .home: [.home]
        case .front: [.front]
        }
    }

    /// 마지막 단계의 버튼
    var finishTitle: String { self == .full ? "플래너로 돌아가기" : "마치기" }

    /// 단계 수 (설정 → 튜토리얼에 적는다. 어느 책으로 보든 같다)
    var stepCount: Int { TourScript.steps(self, TourContext(day: Dates.day(Date()), usesSample: false)).count }
}

enum TourSection {
    case daily, weekly, home, front, end

    /// 말풍선 머리에 인쇄된 글자
    var label: String {
        switch self {
        case .daily: "DAILY"
        case .weekly: "WEEKLY"
        case .home: "HOME"
        case .front: "FIRST PAGES"
        case .end: "SPIRALDAY"
        }
    }

    /// 제목 밑에 긋는 형광펜 (처음 안내와 같은 색들)
    var tint: Color {
        switch self {
        case .daily: Color(hex: "F5E2A0")
        case .weekly: Color(hex: "C6DCF5")
        case .home: Color(hex: "BDE8DD")
        case .front: Color(hex: "F8CADB")
        case .end: Color(hex: "DCD1F4")
        }
    }
}

/// 단계가 펼쳐 둘 장
enum TourScene: Equatable {
    /// 둘러보는 날의 일간
    case day
    /// 그 날이 든 주의 주간
    case week
    case home
    /// 일간 맨 앞의 표지 / 첫 장
    case front(FrontPage)

    var kind: PageKind {
        switch self {
        case .day, .front: .daily
        case .week: .weekly
        case .home: .home
        }
    }
}

/// 팔레트에서 빛나게 할 도구
enum TourPaletteTarget: String, CaseIterable {
    case book, home, weekly, daily, arrows, today, dday, concept, pens, eraser, text, meal, settings
}

/// 밝게 비출 곳
enum TourSpot {
    /// 비추지 않는다 (종이 전체가 어둡고 말풍선은 가운데)
    case none
    /// 종이의 이 자리들 (디자인 단위, 그 장면의 쪽 기준)
    case page([CGRect])
    /// 팔레트의 이 도구 (말풍선이 팔레트 쪽을 가리킨다)
    case palette(TourPaletteTarget)
}

/// 말풍선을 놓을 쪽 (비춘 곳 기준)
enum TourSide { case below, above, trailing, leading }

struct TourStep: Identifiable {
    let id: String
    let section: TourSection
    let scene: TourScene
    let title: String
    let body: String
    var keys: [String] = []
    var spot: TourSpot = .none
    var glow: Set<TourPaletteTarget> = []
    var prefer: [TourSide]? = nil
    /// 비춘 곳을 누를 수 있다 (첫 장의 글 칸)
    var interactive = false
}

/// 둘러보는 책과 날
struct TourContext {
    /// 일간에서 보여 줄 날
    var day: Date
    /// 주간에서 보여 줄 주 (월요일)
    var weekStart: Date
    /// 예시 플래너를 잠깐 펼쳐 보여 주는지
    var usesSample: Bool

    init(day: Date, weekStart: Date? = nil, usesSample: Bool) {
        self.day = day
        self.weekStart = weekStart ?? Dates.weekStart(day)
        self.usesSample = usesSample
    }

    /// 예시 플래너: 마지막 날(만든 날, 저녁 6시까지만 쓴 날)의 전날과, 일곱 날이 다 찬 마지막 주
    init(sample book: BookInfo) {
        let first = Dates.day(book.start)
        let last = book.end.map(Dates.day) ?? Dates.day(Date())
        let lastWeek = Dates.weekStart(last)
        let fullWeek = Dates.daysBetween(lastWeek, last) == 6 ? lastWeek : Dates.add(days: -7, to: lastWeek)
        self.init(day: max(first, Dates.add(days: -1, to: last)), weekStart: max(Dates.weekStart(first), fullWeek),
                  usesSample: true)
    }

    /// 주간에서 비출 요일 칸 (월 = 0): 일간에서 본 날과 같은 요일
    var weekday: Int { Dates.daysBetween(Dates.weekStart(day), day) }

    /// 그날 → (미룸) 을 친 할 일이 쓰는 줄 (일간 디자인 단위). 없으면 nil
    var carryRect: CGRect?

    /// 보여 줄 날의 → 할 일 자리를 찾아 둔다 (둘러보기 · --tour-test 가 대본을 만들기 전에)
    @MainActor
    mutating func locateCarry(in store: PlannerStore) {
        let tasks = store.day(day).tasks
        guard let i = tasks.firstIndex(where: { $0.mark == .moved }) else { carryRect = nil; return }
        let layout = DailyForm.taskLayout(tasks)
        let item = layout.items[i]
        let first = DailyForm.taskRowRect(item.row, rows: layout.rows)
        carryRect = CGRect(x: first.minX, y: first.minY, width: first.width, height: first.height * CGFloat(item.span))
    }
}

// MARK: - 대본

enum TourScript {
    static func steps(_ kind: TourKind, _ ctx: TourContext) -> [TourStep] {
        kind.sections.flatMap { section -> [TourStep] in
            switch section {
            case .daily: daily(ctx)
            case .weekly: weekly(ctx)
            case .home: home()
            case .front: front(ctx)
            case .end: [end(ctx)]
            }
        }
    }

    private typealias F = DailyForm

    /// 인쇄된 라벨은 가운데가 머리선에 걸린다: 라벨 윗부분까지 들어가게 조금 위로 늘린다
    private static func labeled(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: r.minY - 6, width: r.width, height: r.height + 6)
    }
    /// 바로 아래 머리선의 라벨 (COMMENT · TOTAL TIME) 은 비추지 않는다
    private static func aboveNextLabel(_ r: CGRect) -> CGRect {
        labeled(CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 30))
    }

    // 일간 자리 (디자인 단위 1277 × 2000)
    private static var dateArea: CGRect { aboveNextLabel(F.dateBox) }
    private static var ddayArea: CGRect { aboveNextLabel(F.ddayBox) }
    private static var commentArea: CGRect { labeled(F.commentBox) }
    /// COMMENT 라벨과 ▾ (CommentModeMenu.rect 와 같은 자리)
    private static var commentMenu: CGRect {
        CGRect(x: F.left - 6, y: F.headerY - 19, width: F.commentLabelEnd + 30 - (F.left - 6), height: 34)
    }
    private static var taskText: CGRect {
        CGRect(x: F.taskTextX - 8, y: F.gridTop, width: F.boxMinX - 6 - (F.taskTextX - 8), height: F.tasksHeight)
    }
    private static var taskCategory: CGRect {
        labeled(CGRect(x: F.left, y: F.gridTop, width: F.categoryX - F.left, height: F.tasksHeight))
    }
    private static var marks: CGRect { CGRect(x: F.boxMinX - 8, y: F.gridTop, width: F.boxSize + 16, height: F.tasksHeight) }
    private static var memoArea: CGRect { labeled(CGRect(x: F.left, y: F.memoTop, width: F.leftEnd - F.left, height: F.memoHeight)) }
    private static var timetable: CGRect {
        labeled(CGRect(x: F.timeLeft, y: F.gridTop, width: F.timeRight - F.timeLeft, height: F.gridBottom - F.gridTop))
    }
    private static var totalArea: CGRect { labeled(F.totalBox) }

    /// 종이 아래 두 모서리 (CornerZones 와 같은 자리: 일간 150 × 104, 뒤로 가는 쪽은 스프링 옆 28 부터 / 주간 150 × 58)
    static func corners(_ kind: PageKind) -> [CGRect] {
        let d = kind.design
        let h: CGFloat = kind == .daily ? 104 : 58
        let back: CGFloat = kind == .daily ? 28 : 0
        return [CGRect(x: back, y: d.height - h, width: 150, height: h),
                CGRect(x: d.width - 150, y: d.height - h, width: 150, height: h)]
    }

    private static func daily(_ ctx: TourContext) -> [TourStep] {
        let intro = ctx.usesSample
            ? "하루를 종이 한 장에 적는 페이지예요. 예시 플래너를 잠깐 펼쳐 위에서부터 차례로 보여 드리고, 다 보면 보던 플래너로 돌아가요."
            : "하루를 종이 한 장에 적는 페이지예요. 위에서부터 차례로 둘러볼게요. 맨 위 DATE 에는 그날 날짜가 적혀 있어요."
        return [
            TourStep(id: "daily.intro", section: .daily, scene: .day, title: "하루 한 장, 일간", body: intro,
                     spot: .page([dateArea]), glow: ctx.usesSample ? [.book] : []),
            TourStep(id: "daily.dday", section: .daily, scene: .day, title: "D-DAY 붙이기",
                     body: "D-DAY 칸을 누르면 이 날에 붙일 D-day 를 골라요. 저장해 둔 D-day 에서 고르거나 새로 만들 수 있고, 하루에 두 개까지 붙어요.",
                     spot: .page([ddayArea])),
            TourStep(id: "daily.dday-rule", section: .daily, scene: .day, title: "D-day 는 날마다 따로",
                     body: "D-day 는 붙인 날에만 있고 다음 날로 저절로 넘어가지 않아요. 전날 것을 그대로 쓰려면 ‘어제와 같게’ 를 눌러요. 자주 쓰는 D-day 는 설정 → D-day 에 저장해 두고, 팔레트의 D-day 로도 붙여요.",
                     spot: .page([ddayArea]), glow: [.dday]),
            TourStep(id: "daily.comment", section: .daily, scene: .day, title: "COMMENT",
                     body: "오늘을 한 줄로 남기는 칸이에요. 칸을 누르면 바로 쓸 수 있고, 길어지면 글자가 알아서 작아져요.",
                     spot: .page([commentArea])),
            TourStep(id: "daily.dayoff", section: .daily, scene: .day, title: "DAY OFF",
                     body: "COMMENT 옆 ▾ 에서 DAY OFF 를 고르면 칸에 DAY OFF 가 크게 찍혀요. 쉬는 날은 연속 기록을 끊지 않고, 적어 둔 COMMENT 도 그대로 남아요.",
                     spot: .page([commentMenu])),
            TourStep(id: "daily.task-write", section: .daily, scene: .day, title: "TASKS — 먼저 쓰기",
                     body: "할 일은 아무 줄이나 눌러 바로 적어요. 가운데 줄에 적어도 그 줄에 그대로 남아요. Return 은 아랫줄로, ↑ ↓ 는 윗줄·아랫줄로 옮겨요.",
                     keys: ["return", "↑", "↓"], spot: .page([taskText]), prefer: [.trailing, .below, .above, .leading]),
            TourStep(id: "daily.task-category", section: .daily, scene: .day, title: "분류는 나중에",
                     body: "다 쓴 뒤 할 일의 왼쪽 칸을 누르면 형광펜(분류)을 골라요. 펜 색을 정하고 쓰는 게 아니라, 쓰고 나서 색을 정해요. 이미 쓰는 형광펜을 고르면 그 묶음 아래로 모여요.",
                     spot: .page([taskCategory]), prefer: [.trailing, .below, .above]),
            TourStep(id: "daily.marks", section: .daily, scene: .day, title: "○ △ × → 표시",
                     body: "오른쪽 점선 칸을 누를 때마다 ○ 완료, △ 일부, × 못함, → 미룸, 빈 칸 순서로 바뀌어요. ○ 를 치면 그 할 일에 분류 색 형광펜이 그어져요.",
                     spot: .page([marks]), prefer: [.leading, .trailing, .below, .above]),
            TourStep(id: "daily.carry", section: .daily, scene: .day, title: "→ 는 다음 날로",
                     body: "→ 미룸을 치면 그 할 일이 다음 날로 저절로 넘어가요. 다음 날에는 같은 형광펜 묶음 바로 아래로 들어가요. 다른 표시로 바꾸면, 아직 손대지 않은 넘긴 할 일은 다시 거둬 와요.",
                     spot: .page([ctx.carryRect ?? marks]), prefer: [.below, .above, .leading]),
            TourStep(id: "daily.memo", section: .daily, scene: .day, title: "MEMO",
                     body: "할 일 아래 세 줄은 메모예요. 왼쪽 작은 칸엔 꼬리표를, 오른쪽엔 내용을 적어요.",
                     spot: .page([memoArea]), prefer: [.above, .below, .trailing]),
            TourStep(id: "daily.timetable", section: .daily, scene: .day, title: "TIMETABLE 칠하기",
                     body: "팔레트에서 형광펜을 고르고 칸을 끌어 칠해요. 한 줄이 한 시간(아침 6시부터), 한 칸이 10분이에요. 같은 색으로 다시 칠하면 지워지고, 지우개(E)로도 지워요.",
                     keys: ["1", "–", "7", "E"], spot: .page([timetable]), glow: [.pens, .eraser],
                     prefer: [.leading, .above, .below]),
            TourStep(id: "daily.total", section: .daily, scene: .day, title: "TOTAL TIME",
                     body: "타임테이블에 칠한 시간을 더한 값이에요. 어떤 형광펜을 더할지는 설정 → 형광펜의 ‘TOTAL TIME 포함’ 으로 정해요. 빼 둔 형광펜(처음에는 개인 · 휴식·이동)은 칠해도 더하지 않아요.",
                     spot: .page([totalArea]), prefer: [.below, .leading]),
            TourStep(id: "daily.pens", section: .daily, scene: .day, title: "펜 이름과 색",
                     body: "팔레트의 형광펜은 타임테이블을 칠할 때 써요. 숫자 키로도 골라요. 펜을 두 번 누르면 이름 · 색 · TOTAL TIME 포함을 바꿀 수 있고, 이미 칠한 칸과 할 일에도 바로 반영돼요.",
                     spot: .palette(.pens), glow: [.pens]),
            TourStep(id: "daily.text-meal", section: .daily, scene: .day, title: "글씨 · 밥",
                     body: "글씨를 고르고 타임테이블 칸을 누르면 그 자리에 짧게 적을 수 있어요. 밥은 시작 칸부터 끝 칸까지 끌면 밥 아이콘과 끝나는 시각까지 화살표가 그려져요. 누르기만 하면 1시간이에요.",
                     spot: .palette(.text), glow: [.text, .meal]),
            TourStep(id: "daily.color", section: .daily, scene: .day, title: "오늘의 컬러",
                     body: "이 날의 강조색을 골라요. TOTAL TIME, 날짜의 요일, D-day 숫자, ○△× 표시가 이 색으로 바뀌어요. 색을 오른쪽 클릭하면 기본 컬러로 정해요.",
                     spot: .palette(.concept), glow: [.concept]),
            TourStep(id: "daily.turn", section: .daily, scene: .day, title: "넘기기",
                     body: "← → 나 ⌘[ ⌘], 팔레트의 ‹ › 로 넘겨요. 종이 아래 모서리를 누르거나 잡고 끌어도, 트랙패드를 두 손가락으로 옆으로 쓸어도 넘어가요. T 나 팔레트의 ‘오늘’ 을 누르면 오늘로 가요.",
                     keys: ["←", "→", "⌘[", "⌘]", "T"], spot: .page(corners(.daily)), glow: [.arrows, .today],
                     prefer: [.above]),
        ]
    }

    private static func weekly(_ ctx: TourContext) -> [TourStep] {
        let column = CGRect(x: WK.colX(ctx.weekday), y: WK.colTop, width: WK.colW, height: WK.footRule + 2)
        return [
            TourStep(id: "weekly.intro", section: .weekly, scene: .week, title: "한 주 한 장, 주간",
                     body: "주간은 한 주를 한 장에 봐요. W 나 ⌘1, 팔레트의 ‘주간’ 으로 바꾸고, 일간으로는 D 나 ⌘2 로 돌아가요.",
                     keys: ["W", "D", "⌘1", "⌘2"], spot: .palette(.weekly), glow: [.weekly, .daily]),
            TourStep(id: "weekly.goal", section: .weekly, scene: .week, title: "MY GOAL",
                     body: "맨 위 칸에 이번 주 목표를 적어 보세요. 홈의 OVERVIEW 에도 이번 주 목표로 보여요.",
                     spot: .page([WK.goalFrame]), prefer: [.below]),
            TourStep(id: "weekly.review", section: .weekly, scene: .week, title: "REVIEW OF THE WEEK",
                     body: "토 · 일 칸 위의 별로 이번 주를 매겨요. 한 주를 마무리하는 날 별을 눌러 돌아보고, 같은 별을 한 번 더 누르면 지워져요.",
                     spot: .page([WK.reviewFrame]), prefer: [.below]),
            TourStep(id: "weekly.days", section: .weekly, scene: .week, title: "아래는 일간과 같아요",
                     body: "요일 칸의 할 일, ○△×→ 표시, 타임테이블은 일간과 같은 기록이라 어느 쪽에서 적어도 함께 바뀌어요. 날짜를 누르면 그날 일간으로 가요.",
                     spot: .page([column]), prefer: [.trailing, .leading]),
        ]
    }

    private static func home() -> [TourStep] {
        let label: CGFloat = 24
        let overview = CGRect(x: HM.left, y: HM.headRule - label, width: HM.leftEnd - HM.left,
                              height: HM.dateBox.maxY - (HM.headRule - label))
        let dday = CGRect(x: HM.rightStart, y: HM.headRule - label, width: HM.right - HM.rightStart,
                          height: HM.ddayBox.maxY - (HM.headRule - label))
        func band(_ x0: CGFloat, _ x1: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> CGRect {
            CGRect(x: x0, y: top - label, width: x1 - x0, height: bottom - (top - label))
        }
        let weeks = band(HM.left, HM.leftEnd, HM.rowA, HM.rowB - 36)
        let cats = band(HM.rightStart, HM.right, HM.rowA, HM.rowB - 36)
        let heat = band(HM.left, HM.leftEnd, HM.rowB, HM.rowC - 36)
        let weekdays = band(HM.weekdayRect.minX, HM.weekdayRect.maxX, HM.rowC, HM.bottom + 6)
        let taskMarks = band(HM.marksRect.minX, HM.marksRect.maxX, HM.rowC, HM.bottom + 6)
        let calendar = band(HM.rightStart, HM.right, HM.rowB, HM.dayCell(34).maxY + 14)
        return [
            TourStep(id: "home.intro", section: .home, scene: .home, title: "한눈에, 홈",
                     body: "홈은 플래너 전체를 한 장에 모아 보는 통계예요. H 나 ⌘0, 팔레트의 ‘홈’ 으로 열어요. 칸마다 무엇을 보여 주는지 볼게요.",
                     keys: ["H", "⌘0"], spot: .palette(.home), glow: [.home]),
            TourStep(id: "home.overview", section: .home, scene: .home, title: "OVERVIEW",
                     body: "오늘 날짜와 이번 주 목표예요. 목표를 누르면 이번 주 주간 페이지가 열려요.",
                     spot: .page([overview]), prefer: [.below]),
            TourStep(id: "home.dday", section: .home, scene: .home, title: "D-DAY",
                     body: "오늘 붙인 D-day 예요. 누르면 오늘의 D-day 를 고르거나 새로 만들어요.",
                     spot: .page([dday]), prefer: [.below, .leading]),
            TourStep(id: "home.time", section: .home, scene: .home, title: "칠한 시간 · 기록한 날",
                     body: "이번 주와 이번 달에 칠한 시간, 기록한 날의 하루 평균, 이번 달에 타임테이블을 칠한 날 수예요. 시간은 TOTAL TIME 에 넣는 형광펜만 더해요.",
                     spot: .page([HM.keyCell(0).union(HM.keyCell(3))]), prefer: [.below]),
            TourStep(id: "home.streak", section: .home, scene: .home, title: "STREAK · DONE RATE",
                     body: "STREAK 는 오늘(아직 칠하지 않았으면 어제)까지 며칠째 이어서 기록했는지예요. DAY OFF 인 날은 끊지 않아요. DONE RATE 는 이번 달에 표시한 할 일 중 ○ 완료의 비율이에요.",
                     spot: .page([HM.keyCell(4).union(HM.keyCell(5))]), prefer: [.below, .leading]),
            TourStep(id: "home.weeks", section: .home, scene: .home, title: "LAST 12 WEEKS",
                     body: "최근 12주 동안 주마다 칠한 시간이에요. 막대는 형광펜 색대로 쌓이고, 누르면 그 주로 가요.",
                     spot: .page([weeks]), prefer: [.below, .above, .trailing]),
            TourStep(id: "home.highlighters", section: .home, scene: .home, title: "HIGHLIGHTERS",
                     body: "이번 달 형광펜별로 칠한 시간이에요. TOTAL TIME 에 넣지 않는 색은 흐리게 보여요.",
                     spot: .page([cats]), prefer: [.leading, .below]),
            TourStep(id: "home.time-of-day", section: .home, scene: .home, title: "TIME OF DAY",
                     body: "지난 4주 동안 어느 시간대를 자주 칠했는지 진하기로 보여 줘요. 가장 자주 칠한 시간도 알려 줘요.",
                     spot: .page([heat]), prefer: [.above, .below]),
            TourStep(id: "home.weekdays", section: .home, scene: .home, title: "WEEKDAYS",
                     body: "지난 8주 동안 요일마다 하루 평균 몇 시간을 칠했는지예요. 가장 많은 요일이 강조색이에요.",
                     spot: .page([weekdays]), prefer: [.above, .trailing]),
            TourStep(id: "home.marks", section: .home, scene: .home, title: "TASK MARKS",
                     body: "이번 달 할 일에 친 ○ △ × → 를 세어요. 아래 띠는 그 비율이에요.",
                     spot: .page([taskMarks]), prefer: [.above, .leading]),
            TourStep(id: "home.calendar", section: .home, scene: .home, title: "LAST 35 DAYS",
                     body: "최근 35일의 잔디 달력이에요. 많이 칠한 날일수록 진하고, 날짜를 누르면 그날 일간으로 가요.",
                     spot: .page([calendar]), prefer: [.leading, .above]),
        ]
    }

    private static func front(_ ctx: TourContext) -> [TourStep] {
        let band = FrontMatterLayout.coverBand(.daily)
        // 색 띠와 그 아래 기간까지
        let cover = CGRect(x: band.minX, y: band.minY, width: band.width, height: band.height + 150)
        return [
            // 예시 플래너로 둘러볼 때는 여기에 쓰면 예시 책에 들어가므로 누르지 못하게 하고, 내 플래너에서 쓰는 법을 알려 준다
            TourStep(id: "front.motto", section: .front, scene: .front(.motto), title: "첫 장에 하고 싶은 말",
                     body: ctx.usesSample
                        ? "일간 맨 앞, 표지 다음 장이에요. 여기에 적고 싶은 말을 적을 수 있어요. 내 플래너에서는 첫날에서 ← 로 한 장 넘기면 나오는 이 장의 가운데를 눌러 바로 써요."
                        : "일간 맨 앞, 표지 다음 장이에요. 여기에 적고 싶은 말을 적을 수 있어요. 가운데를 눌러 바로 써 보세요.",
                     spot: .page([FrontMatterLayout.mottoBlock(.daily)]), prefer: [.below, .above], interactive: !ctx.usesSample),
            TourStep(id: "front.cover", section: .front, scene: .front(.cover), title: "표지",
                     body: "맨 앞 장은 표지예요. 설정 → PDF 로 표지부터 뽑아 인쇄하면 실제 책처럼 가질 수 있어요. 이름과 표지 색은 설정 → 플래너에서 바꿔요.",
                     spot: .page([cover]), glow: [.settings], prefer: [.below, .above]),
        ]
    }

    private static func end(_ ctx: TourContext) -> TourStep {
        TourStep(id: "end", section: .end, scene: .front(.cover), title: "다 둘러봤어요",
                 body: (ctx.usesSample
                        ? "이제 보던 플래너로 돌아갈게요. 예시 플래너는 책장에 그대로 있어서 언제든 펼쳐 볼 수 있어요. "
                        : "이제 보던 페이지로 돌아갈게요. ")
                     + "둘러보기는 도움말 메뉴나 설정 → 튜토리얼에서 언제든 다시 볼 수 있어요.",
                 glow: ctx.usesSample ? [.book] : [])
    }
}

// MARK: - Controller

/// 둘러보기를 돌리는 곳 (하나뿐). 장면 옮기기 · 키 막기 · 보던 책과 장 되돌리기를 맡는다.
@MainActor
final class TourController: ObservableObject {
    static let shared = TourController()
    /// 한 번 보여 줬는지 (1.0.5 첫 실행 · 처음 안내 뒤에 한 번만 저절로 시작한다)
    static let doneKey = "plannerTourDone"

    @Published private(set) var kind: TourKind?
    @Published private(set) var steps: [TourStep] = []
    @Published private(set) var index = 0
    /// 지금 단계의 장면에 도착했는지. 넘기거나 쪽을 바꾸는 동안에는 말풍선을 감춘다.
    @Published private(set) var arrived = false
    /// 팔레트에서 빛나는 도구 (지금 단계의 것. 스냅샷 점검에서는 직접 넣는다)
    @Published var glow: Set<TourPaletteTarget> = []
    /// 팔레트 도구들의 자리 (팔레트 창 내용 기준, 왼쪽 위 원점, pt). 팔레트가 알려 준다.
    @Published private(set) var paletteFrames: [TourPaletteTarget: CGRect] = [:]
    /// 팔레트 창이 없을 때(스냅샷 점검) 팔레트가 종이 가운데 높이에 붙어 있다고 치고 쓰는 크기
    var assumedPaletteSize: CGSize?

    var isRunning: Bool { kind != nil }
    var step: TourStep? { steps.indices.contains(index) ? steps[index] : nil }
    private(set) var context: TourContext?

    /// 본 창이 열릴 때 attach 로 받는다
    private weak var store: PlannerStore?
    private weak var state: AppState?
    private weak var plannerWindow: NSWindow?
    private var saved: Saved?
    private var monitors: [Any] = []
    private var terminateObserver: Any?
    /// 장면 옮기기를 새로 시작할 때마다 올린다 (앞선 기다림은 멈춘다)
    private var generation = 0

    /// 둘러보기 전에 보던 곳
    private struct Saved {
        var bookID: UUID?
        var kind: PageKind
        var day: Int
        var week: Int
        /// 예시 플래너로 바꿔 펼쳤는지
        var switchedBook: Bool
    }

    private init() {}

    // MARK: start · end

    /// 본 창이 열리면 (AppDelegate.openPlanner) 둘러볼 책 · 쪽 · 창을 알려 준다
    func attach(store: PlannerStore, state: AppState, window: NSWindow) {
        self.store = store
        self.state = state
        plannerWindow = window
    }

    /// 처음 한 번만 저절로 전체 둘러보기 (본 창을 처음 열 때 부른다): 새 사용자는 처음 안내를 마친 뒤,
    /// 기존 사용자는 1.0.5 를 처음 켰을 때. 한 번 시작하면 (끝까지 보든 끝내기를 누르든) 다시는 저절로 뜨지 않는다.
    func startFirstTimeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        // 본 창이 자리 잡고 (처음 안내 창이 닫히고) 글꼴이 준비된 뒤에
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.start(.full, firstTime: true) }
    }

    /// 둘러보기를 시작한다. 본 창이 없거나 이미 도는 중이면 아무것도 하지 않는다.
    /// firstTime: 저절로 시작한 둘러보기 — 시작하면 다시는 저절로 뜨지 않게 적어 둔다.
    func start(_ kind: TourKind, firstTime: Bool = false, tries: Int = 0) {
        guard self.kind == nil, let store, let state, let window = plannerWindow,
              store.activeBook != nil || store.hasSampleBook else { return }
        // 넘기거나 쪽을 바꾸는 중이면 끝난 뒤에
        guard state.curl.isIdle, !state.morphing else {
            if tries < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start(kind, firstTime: firstTime, tries: tries + 1)
                }
            }
            return
        }
        if firstTime { UserDefaults.standard.set(true, forKey: Self.doneKey) }
        if !NSApp.isActive { NSApp.activate() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        state.endEditing()
        var saved = Saved(bookID: store.library.activeID, kind: state.kind, day: state.dayIndex, week: state.weekIndex,
                          switchedBook: false)

        // 예시 플래너가 있으면 그 책을 잠깐 펼쳐 꽉 찬 날 · 꽉 찬 주를 보여 준다
        var ctx: TourContext
        if let sample = store.books.first(where: \.isSample) {
            if store.library.activeID != sample.id {
                store.activate(sample.id)
                saved.switchedBook = true
            }
            ctx = TourContext(sample: sample)
        } else {
            // 지금 책: 보고 있던 날 · 주 (표지 · 첫 장 · 홈이면 오늘, 책 밖이면 가장 가까운 날)
            let r = state.dayRange
            let i = state.kind == .daily && state.front == nil ? state.dayIndex : min(max(0, r.lowerBound), r.upperBound)
            let week = state.kind == .weekly && state.front == nil ? state.weekStart(state.weekIndex) : nil
            ctx = TourContext(day: state.dayDate(i), weekStart: week, usesSample: false)
        }
        ctx.locateCarry(in: store)
        self.saved = saved
        context = ctx
        steps = TourScript.steps(kind, ctx)
        index = 0
        arrived = false
        self.kind = kind
        installMonitors()
        // 예시 플래너로 바꿨으면 AppState 가 새 책의 장을 고른 다음(다음 런루프)에 옮긴다
        DispatchQueue.main.async { [weak self] in self?.go(0) }
    }

    /// 끝내기 (마지막 단계의 버튼, Esc, 끝내기 버튼). 보던 책 · 보던 장으로 돌아간다.
    func end() {
        guard kind != nil else { return }
        generation += 1
        removeMonitors()
        let s = saved
        saved = nil
        kind = nil
        steps = []
        index = 0
        arrived = false
        glow = []
        state?.endEditing()
        restore(s)
    }

    func next() {
        guard isRunning else { return }
        if index + 1 < steps.count { go(index + 1) } else { end() }
    }

    func back() {
        guard isRunning, index > 0 else { return }
        go(index - 1)
    }

    // MARK: palette

    func setPaletteFrames(_ frames: [TourPaletteTarget: CGRect]) {
        if frames != paletteFrames { paletteFrames = frames }
    }

    /// 팔레트가 본 창의 어느 쪽에 있고, 가리킬 도구가 본 창 기준 어느 높이인지 (본 창 내용 좌표, 위가 0)
    func paletteGeometry(_ target: TourPaletteTarget?, in size: CGSize) -> TourPaletteGeometry {
        let frame = target.flatMap { paletteFrames[$0] }
        if let win = plannerWindow, let panel = win.childWindows?.first(where: { $0 is PalettePanel }), panel.isVisible {
            let trailing = panel.frame.midX >= win.frame.midX
            // 팔레트 내용의 왼쪽 위 = 패널의 (minX, maxY). 본 창 내용은 창 전체(제목 막대 포함)를 덮는다.
            let y = frame.map { win.frame.maxY - (panel.frame.maxY - $0.midY) }
            return TourPaletteGeometry(trailing: trailing, y: y)
        }
        // 팔레트 창이 없으면 (스냅샷): 창 오른쪽 옆, 세로 가운데에 붙어 있다고 친다 (PaletteController.reposition)
        guard let frame, let ps = assumedPaletteSize else { return TourPaletteGeometry() }
        return TourPaletteGeometry(trailing: true, y: (size.height - ps.height) / 2 + frame.midY)
    }

    // MARK: scenes

    private func go(_ i: Int) {
        guard isRunning, steps.indices.contains(i), let state else { return }
        state.endEditing()
        index = i
        glow = steps[i].glow
        generation += 1
        let scene = steps[i].scene
        if state.curl.isIdle && !state.morphing && matches(scene) {
            if !arrived { withAnimation(.easeOut(duration: 0.22)) { arrived = true } }
            return
        }
        arrived = false
        settle(scene, gen: generation)
    }

    /// 장면에 가 있는지 (쪽 · 장)
    private func matches(_ scene: TourScene) -> Bool {
        guard let state, let ctx = context else { return false }
        switch scene {
        case .day: return state.kind == .daily && state.front == nil && state.dayIndex == dayIndex(ctx, state)
        case .week: return state.kind == .weekly && state.front == nil && state.weekIndex == weekIndex(ctx, state)
        case .home: return state.kind == .home
        case .front(let p): return state.kind == .daily && state.front == p
        }
    }

    private func dayIndex(_ ctx: TourContext, _ state: AppState) -> Int { Dates.daysBetween(state.baseDay, ctx.day) }
    private func weekIndex(_ ctx: TourContext, _ state: AppState) -> Int {
        Dates.daysBetween(state.baseWeek, ctx.weekStart) / 7
    }

    /// 장면으로 옮기고 도착할 때까지 기다린다. 넘기는 중이면 끝나기를 기다렸다가 옮긴다.
    /// 오래 걸리면 (8초) 도착하지 못했어도 말풍선은 보여 준다.
    private func settle(_ scene: TourScene, gen: Int, tries: Int = 0, drove: Int = 0) {
        guard gen == generation, isRunning, let state else { return }
        let idle = state.curl.isIdle && !state.morphing
        if idle && matches(scene) || tries > 100 {
            withAnimation(.easeOut(duration: 0.22)) { arrived = true }
            return
        }
        var drove = drove
        // 한가한데 아직 못 갔으면 옮긴다 (막혀서 안 됐으면 조금 뒤에 다시)
        if idle && (drove == 0 || tries - drove > 12) {
            drive(scene)
            drove = max(tries, 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.settle(scene, gen: gen, tries: tries + 1, drove: drove)
        }
    }

    private func drive(_ scene: TourScene) {
        guard let state, let ctx = context else { return }
        state.endEditing()
        switch scene {
        case .day:
            if state.kind == .daily {
                // 같은 일간이면 종이를 넘겨서 (여러 장이면 한 번에)
                let d = dayIndex(ctx, state) - state.dayIndex
                if d != 0 { state.curl.flip(d > 0 ? .forward : .backward, landingOffset: abs(d) == 1 ? nil : d) }
            } else {
                state.openDay(ctx.day)
            }
        case .week:
            let w = weekIndex(ctx, state)
            if state.kind == .weekly {
                state.weekIndex = w
                state.onPageChange?()
            } else {
                // 쪽을 바꾸는 애니메이션이 새 쪽을 펴기 전에 볼 주를 정해 둔다
                state.switchKind(.weekly)
                state.weekIndex = w
            }
        case .home:
            state.switchKind(.home)
        case .front(let p):
            state.showFront(p, in: .daily)
        }
    }

    /// 보던 책을 다시 펼치고 (예시 플래너로 바꿨을 때), 보던 쪽 · 장으로 돌아간다
    private func restore(_ s: Saved?) {
        guard let s, let store else { return }
        var switched = false
        if s.switchedBook, let id = s.bookID, store.library.activeID != id, store.books.contains(where: { $0.id == id }) {
            store.activate(id)
            switched = true
        }
        // 책을 바꿨으면 AppState 가 새 책의 장을 고른 다음(다음 런루프)에
        DispatchQueue.main.async { [weak self] in self?.restorePage(s, switched: switched, tries: 0) }
    }

    private func restorePage(_ s: Saved, switched: Bool, tries: Int) {
        guard kind == nil, let state else { return }
        guard state.curl.isIdle, !state.morphing else {
            if tries < 80 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.restorePage(s, switched: switched, tries: tries + 1)
                }
            }
            return
        }
        if state.kind == s.kind {
            switch s.kind {
            case .daily:
                let d = s.day - state.dayIndex
                guard d != 0 else { return }
                if switched {
                    state.dayIndex = s.day
                    state.onPageChange?()
                } else {
                    state.curl.flip(d > 0 ? .forward : .backward, landingOffset: abs(d) == 1 ? nil : d)
                }
            case .weekly:
                let d = s.week - state.weekIndex
                guard d != 0 else { return }
                if switched {
                    state.weekIndex = s.week
                    state.onPageChange?()
                } else {
                    state.curl.flip(d > 0 ? .forward : .backward, landingOffset: abs(d) == 1 ? nil : d)
                }
            case .home:
                // 홈에서 일간 · 주간으로 돌아갈 때 펼칠 날 · 주 (책을 바꿨으면 오늘로 돌아가 있다)
                state.dayIndex = s.day
                state.weekIndex = s.week
            }
        } else {
            // 쪽을 바꾸는 애니메이션이 새 쪽을 펴기 전에 보던 날 · 주를 정해 둔다
            state.switchKind(s.kind)
            state.dayIndex = s.day
            state.weekIndex = s.week
        }
    }

    // MARK: keys

    private func installMonitors() {
        removeMonitors()
        // 나중에 단 모니터가 먼저 불리므로 플래너의 단축키(AppState)보다 먼저 받는다
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let eat = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return eat ? nil : e
        } as Any)
        // 트랙패드 넘기기 · 가로 휠도 쉰다
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            let eat = MainActor.assumeIsolated { self?.isPlanner(e.window) ?? false }
            return eat ? nil : e
        } as Any)
        // 둘러보는 중에 앱을 끝내면 보던 책을 다시 펼쳐 두고 끝낸다
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.saved, s.switchedBook, let id = s.bookID, let store = self.store,
                      store.library.activeID != id, store.books.contains(where: { $0.id == id }) else { return }
                store.activate(id)
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    private func isPlanner(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        return w === plannerWindow || w is PalettePanel
    }

    /// → / Return 다음, ← 이전, Esc 끝내기. 플래너 창의 다른 키는 모두 쉰다.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard isRunning else { return false }
        // 설정 창, 알림 같은 다른 창의 키는 그대로
        guard e.window == nil || isPlanner(e.window) else { return false }
        // 첫 장에 쓰는 중: 글자와 편집 키(⌘C · ⌘V …)는 글상자로, Esc 는 쓰기만 마친다
        // (넘기기 · 쪽 바꾸기 메뉴는 둘러보는 동안 메뉴 쪽에서 쉰다)
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.window === plannerWindow {
            guard e.keyCode == 53, !tv.hasMarkedText() else { return false }
            state?.endEditing()
            return true
        }
        if e.modifierFlags.contains(.command) {
            // 앱 끝내기 · 숨기기 · 창 내리기 · 닫기만 그대로 (넘기기 ⌘[ ⌘], 쪽 바꾸기 ⌘0–2, 오늘 ⌘T, PDF ⌘P, 설정 ⌘, 은 쉰다)
            let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
            return !["q", "h", "m", "w"].contains(c)
        }
        switch e.keyCode {
        case 124, 36, 76: // → Return Enter
            if !e.isARepeat { next() }
        case 123: // ←
            if !e.isARepeat { back() }
        case 53: // Esc
            end()
        default:
            break
        }
        return true
    }
}

/// 팔레트의 자리 (본 창 내용 좌표)
struct TourPaletteGeometry {
    /// 팔레트가 본 창 오른쪽에 있는지 (자리가 없으면 왼쪽에 붙는다)
    var trailing = true
    /// 가리킬 도구의 세로 가운데 (모르면 nil)
    var y: CGFloat? = nil
}

struct TourActions {
    var next: () -> Void
    var back: () -> Void
    var end: () -> Void
}

// MARK: - Overlay (RootView 맨 위)

/// 본 창의 종이 위에 올리는 둘러보기 레이어. 둘러보는 중이 아니면 아무것도 없다.
struct TourOverlay: View {
    let size: CGSize
    @ObservedObject private var tour = TourController.shared
    @EnvironmentObject private var state: AppState

    var body: some View {
        if tour.isRunning, let step = tour.step, let kind = tour.kind {
            TourLiveStage(size: size, step: step, curl: state.curl, finishTitle: kind.finishTitle)
        }
    }
}

private struct TourLiveStage: View {
    let size: CGSize
    let step: TourStep
    @ObservedObject var curl: CurlController
    let finishTitle: String
    @ObservedObject private var tour = TourController.shared
    @EnvironmentObject private var state: AppState

    var body: some View {
        let target: TourPaletteTarget? = if case .palette(let t) = step.spot { t } else { nil }
        let last = tour.index == tour.steps.count - 1
        TourStage(size: size, pageKind: state.kind, step: step, number: tour.index + 1, count: tour.steps.count,
                  primaryTitle: last ? finishTitle : "다음",
                  palette: tour.paletteGeometry(target, in: size),
                  visible: tour.arrived && !curl.isActive && !state.morphing,
                  actions: TourActions(next: { tour.next() }, back: { tour.back() }, end: { tour.end() }))
    }
}

/// 어두운 막 + 밝힌 곳 + 말풍선. 화면(TourOverlay)과 스냅샷 점검(--tour-test)이 같이 쓴다.
struct TourStage: View {
    let size: CGSize
    /// 지금 펼친 쪽 (디자인 단위 → pt 비율 u)
    let pageKind: PageKind
    let step: TourStep
    let number: Int
    let count: Int
    let primaryTitle: String
    var palette = TourPaletteGeometry()
    var visible = true
    /// nil 이면 버튼이 그려지기만 한다 (스냅샷)
    var actions: TourActions? = nil

    var body: some View {
        let holes = TourLayout.holes(step.spot, pageKind: pageKind, size: size)
        let place = TourLayout.place(step, holes: holes, size: size, palette: palette, number: number)
        ZStack(alignment: .topLeading) {
            // 종이를 누르지 못하게 (허락한 단계면 밝힌 곳만 뚫는다)
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(TourHoles(holes: step.interactive && visible ? holes : []), eoFill: true)
                .onTapGesture {}
                .onContinuousHover { _ in NSCursor.arrow.set() }

            ZStack(alignment: .topLeading) {
                TourCurtain(size: size, holes: holes)
                TourBubble(step: step, number: number, count: count, primaryTitle: primaryTitle,
                           width: place.width, arrow: place.arrow, actions: actions)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, height: size.height, alignment: place.alignment)
                    .offset(x: place.x, y: place.offsetY(size))
            }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.22), value: visible)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: step.id)
    }
}

/// 밝힌 곳을 뺀 나머지 (누르기 막기용, even-odd)
private struct TourHoles: Shape {
    let holes: [CGRect]

    func path(in r: CGRect) -> Path {
        var p = Path(r)
        for h in holes { p.addRoundedRect(in: h, cornerSize: CGSize(width: TourLayout.radius, height: TourLayout.radius)) }
        return p
    }
}

/// 종이를 어둡게 덮고, 밝힐 곳만 둥글게 뚫는다
private struct TourCurtain: View {
    let size: CGSize
    let holes: [CGRect]

    static let dim = Color(hex: "1D1A26").opacity(0.5)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Self.dim)
            ForEach(holes.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: TourLayout.radius, style: .continuous)
                    .frame(width: holes[i].width, height: holes[i].height)
                    .offset(x: holes[i].minX, y: holes[i].minY)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .overlay(alignment: .topLeading) {
            ForEach(holes.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: TourLayout.radius, style: .continuous)
                    .stroke(.white.opacity(0.92), lineWidth: 2)
                    .shadow(color: .white.opacity(0.55), radius: 5)
                    .frame(width: holes[i].width, height: holes[i].height)
                    .offset(x: holes[i].minX, y: holes[i].minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Layout

enum TourLayout {
    /// 창 가장자리와 말풍선 사이
    static let margin: CGFloat = 12
    /// 위쪽은 창 버튼(빨노초) 자리를 비운다
    static let topMargin: CGFloat = 34
    /// 밝힌 곳과 말풍선 사이 (꼬리 길이 포함)
    static let gap: CGFloat = 16
    /// 밝힌 곳의 여유 (pt)
    static let pad: CGFloat = 7
    static let radius: CGFloat = 10
    static let maxWidth: CGFloat = 292
    static let minWidth: CGFloat = 232

    struct Arrow: Equatable {
        enum Edge { case top, bottom, leading, trailing }
        var edge: Edge
        /// 위 · 아래 꼬리: 말풍선 왼쪽에서부터, 옆 꼬리: 말풍선 세로 가운데에서부터 (pt)
        var pos: CGFloat
    }

    struct Placement {
        enum Anchor { case top(CGFloat), bottom(CGFloat), center(CGFloat) }
        var width: CGFloat
        var x: CGFloat
        var anchor: Anchor
        var arrow: Arrow?

        var alignment: Alignment {
            switch anchor {
            case .top: .topLeading
            case .bottom: .bottomLeading
            case .center: .leading
            }
        }

        func offsetY(_ size: CGSize) -> CGFloat {
            switch anchor {
            case .top(let y): y
            case .bottom(let y): y - size.height
            case .center(let y): y - size.height / 2
            }
        }
    }

    /// 밝힐 곳 (pt, 여유 포함). 여유는 종이와 같이 줄어들고 (작은 창에서 옆 칸까지 비추지 않게),
    /// 창 가장자리에 닿는 곳(넘기기 모서리 · 표지 띠)은 테두리가 다 보이게 창 안으로 들인다.
    static func holes(_ spot: TourSpot, pageKind: PageKind, size: CGSize) -> [CGRect] {
        guard case .page(let rects) = spot else { return [] }
        let u = size.width / pageKind.design.width
        let p = min(pad, max(4, 14 * u))
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
        return rects.map { r in
            CGRect(x: r.minX * u, y: r.minY * u, width: r.width * u, height: r.height * u)
                .insetBy(dx: -p, dy: -p)
                .intersection(bounds)
        }
    }

    static func place(_ step: TourStep, holes: [CGRect], size: CGSize, palette: TourPaletteGeometry,
                      number: Int) -> Placement {
        let m = margin
        let fullW = max(160, min(maxWidth, size.width - 2 * m))
        func height(_ w: CGFloat) -> CGFloat { TourBubble.estimatedHeight(step, width: w, first: number == 1) }
        func centerY(_ y: CGFloat, _ h: CGFloat) -> CGFloat {
            min(max(y, topMargin + h / 2), max(topMargin + h / 2, size.height - m - h / 2))
        }

        // 팔레트: 팔레트 쪽 가장자리에 붙이고 꼬리로 그 도구를 가리킨다
        if case .palette = step.spot {
            let h = height(fullW)
            let ty = palette.y ?? size.height / 2
            let cy = centerY(ty, h)
            let x = palette.trailing ? size.width - m - fullW : m
            return Placement(width: fullW, x: x, anchor: .center(cy),
                             arrow: Arrow(edge: palette.trailing ? .trailing : .leading, pos: ty - cy))
        }
        guard let first = holes.first else {
            // 비춘 곳이 없으면 가운데
            let h = height(fullW)
            return Placement(width: fullW, x: (size.width - fullW) / 2, anchor: .center(centerY(size.height / 2, h)))
        }
        let S = holes.dropFirst().reduce(first) { $0.union($1) }
        // 여러 곳이면 꼬리는 마지막 곳을 (넘기기: 다음 장 모서리)
        let aim = holes.count > 1 ? holes[holes.count - 1] : S
        let g = gap
        let order = step.prefer ?? [.below, .above, .trailing, .leading]

        for side in order + [.below, .above, .trailing, .leading] {
            switch side {
            case .below, .above:
                let h = height(fullW)
                let x = min(max(aim.midX - fullW / 2, m), size.width - m - fullW)
                let arrow = min(max(aim.midX - x, 26), fullW - 26)
                if side == .below, S.maxY + g + h <= size.height - m {
                    return Placement(width: fullW, x: x, anchor: .top(S.maxY + g), arrow: Arrow(edge: .top, pos: arrow))
                }
                if side == .above, S.minY - g - h >= topMargin {
                    return Placement(width: fullW, x: x, anchor: .bottom(S.minY - g), arrow: Arrow(edge: .bottom, pos: arrow))
                }
            case .trailing, .leading:
                let room = side == .trailing ? size.width - m - (S.maxX + g) : S.minX - g - m
                let w = min(fullW, room)
                guard w >= min(minWidth, fullW) else { continue }
                let h = height(w)
                guard h <= size.height - topMargin - m else { continue }
                let cy = centerY(aim.midY, h)
                let x = side == .trailing ? S.maxX + g : S.minX - g - w
                return Placement(width: w, x: x, anchor: .center(cy),
                                 arrow: Arrow(edge: side == .trailing ? .leading : .trailing, pos: aim.midY - cy))
            }
        }

        // 어디에도 다 들어가지 않으면 (작은 창): 밝힌 곳을 가장 덜 가리는 쪽에 꼬리 없이
        let h = height(fullW)
        let cx = min(max(aim.midX - fullW / 2, m), size.width - m - fullW)
        let candidates: [CGRect] = [
            CGRect(x: cx, y: min(S.maxY + g, size.height - m - h), width: fullW, height: h),
            CGRect(x: cx, y: max(S.minY - g - h, topMargin), width: fullW, height: h),
            CGRect(x: min(S.maxX + g, size.width - m - fullW), y: centerY(S.midY, h) - h / 2, width: fullW, height: h),
            CGRect(x: max(S.minX - g - fullW, m), y: centerY(S.midY, h) - h / 2, width: fullW, height: h),
        ]
        func covered(_ r: CGRect) -> CGFloat {
            let i = r.intersection(S)
            return i.isNull ? 0 : i.width * i.height
        }
        let best = candidates.min { covered($0) < covered($1) } ?? candidates[0]
        return Placement(width: fullW, x: best.minX, anchor: .top(best.minY), arrow: nil)
    }
}

// MARK: - Bubble

/// 종이 쪽지 모양의 말풍선: 인쇄된 머리 (구역 ━━ n / N), 손글씨 제목과 형광펜, 설명, 자판, 버튼
struct TourBubble: View {
    let step: TourStep
    let number: Int
    let count: Int
    let primaryTitle: String
    let width: CGFloat
    var arrow: TourLayout.Arrow? = nil
    var actions: TourActions? = nil

    static let hPad: CGFloat = 18
    static let topPad: CGFloat = 14
    static let bottomPad: CGFloat = 13
    static let bodySize: CGFloat = 12.5
    static let bodyLineSpacing: CGFloat = 3
    static let titleSize: CGFloat = 25
    static let bodyColor = Color(hex: "625E69")

    var body: some View {
        let shape = TourBubbleShape(arrow: arrow)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(step.section.label)
                    .font(Fonts.print(9.5, .demiBold))
                    .kerning(1.5)
                    .foregroundStyle(Ink.print)
                    .fixedSize()
                Rectangle().fill(Ink.print).frame(height: 1.3)
                Text("\(number) / \(count)")
                    .font(Fonts.print(9.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Ink.soft)
                    .fixedSize()
            }
            .frame(height: 13)

            Text(step.title)
                .font(Fonts.hand(Self.titleSize))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .background(alignment: .bottom) {
                    HighlighterBar(color: step.section.tint)
                        .frame(height: 9)
                        .padding(.horizontal, -5)
                        .offset(y: -2)
                }
                .padding(.top, 10)

            Text(step.body)
                .font(Fonts.print(Self.bodySize))
                .foregroundStyle(Self.bodyColor)
                .lineSpacing(Self.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if !step.keys.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(step.keys.enumerated()), id: \.offset) { _, k in
                        if k == "–" {
                            Text("–").font(Fonts.print(11, .medium)).foregroundStyle(Ink.soft)
                        } else {
                            TourKeyCap(label: k)
                        }
                    }
                }
                .padding(.top, 10)
            }

            HStack(spacing: 4) {
                // 마지막 단계에서는 버튼(마치기)이 곧 끝내기다
                if number < count {
                    TourQuietButton(title: "끝내기", icon: nil) { actions?.end() }
                        .help("둘러보기 끝내기 (esc)")
                }
                Spacer(minLength: 0)
                if number > 1 {
                    TourQuietButton(title: "이전", icon: "chevron.left") { actions?.back() }
                        .help("이전 (←)")
                }
                TourPrimaryButton(title: primaryTitle) { actions?.next() }
                    .help(number < count ? "다음 (→ 또는 Return)" : "둘러보기 마치기 (→ 또는 Return)")
                    .layoutPriority(1)
            }
            .padding(.top, 13)

            if number == 1 {
                Text("→ · Return 다음    ← 이전    esc 끝내기")
                    .font(Fonts.print(10, .medium))
                    .foregroundStyle(Ink.soft)
                    .padding(.top, 7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.hPad)
        .padding(.top, Self.topPad)
        .padding(.bottom, Self.bottomPad)
        .frame(width: width, alignment: .leading)
        .background {
            ZStack {
                shape.fill(Ink.paper)
                NoiseLayer(opacity: 0.45).blendMode(.multiply).clipShape(shape)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
        }
        .overlay { shape.stroke(Ink.rule.opacity(0.9), lineWidth: 0.8) }
        .environment(\.colorScheme, .light)
    }

    /// 그리기 전에 말풍선 높이를 가늠한다 (놓을 자리를 고를 때)
    static func estimatedHeight(_ step: TourStep, width: CGFloat, first: Bool) -> CGFloat {
        let font = NSFont(name: Fonts.PrintWeight.medium.postScriptName, size: bodySize) ?? .systemFont(ofSize: bodySize)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = bodyLineSpacing
        let s = NSAttributedString(string: step.body, attributes: [.font: font, .paragraphStyle: p])
        let body = s.boundingRect(with: CGSize(width: width - 2 * hPad, height: 10_000),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
        var h = topPad + 13 + 10 + 30 + 7 + body + 13 + 30 + bottomPad + 6
        if !step.keys.isEmpty { h += 10 + 22 }
        if first { h += 7 + 14 }
        return h
    }
}

/// 둥근 쪽지 + 가리키는 꼬리
struct TourBubbleShape: Shape {
    var arrow: TourLayout.Arrow?

    static let radius: CGFloat = 14
    static let length: CGFloat = 9
    static let half: CGFloat = 9

    func path(in r: CGRect) -> Path {
        let body = Path(roundedRect: r, cornerRadius: Self.radius, style: .continuous)
        guard let arrow else { return body }
        let l = Self.length, h = Self.half, inset = Self.radius + h
        var t = Path()
        switch arrow.edge {
        case .top, .bottom:
            let x = min(max(r.minX + arrow.pos, r.minX + inset), r.maxX - inset)
            let top = arrow.edge == .top
            let y = top ? r.minY : r.maxY
            t.move(to: CGPoint(x: x - h, y: top ? y + 2 : y - 2))
            t.addLine(to: CGPoint(x: x, y: top ? y - l : y + l))
            t.addLine(to: CGPoint(x: x + h, y: top ? y + 2 : y - 2))
        case .leading, .trailing:
            let yy = min(max(r.midY + arrow.pos, r.minY + inset), r.maxY - inset)
            let lead = arrow.edge == .leading
            let x = lead ? r.minX : r.maxX
            t.move(to: CGPoint(x: lead ? x + 2 : x - 2, y: yy - h))
            t.addLine(to: CGPoint(x: lead ? x - l : x + l, y: yy))
            t.addLine(to: CGPoint(x: lead ? x + 2 : x - 2, y: yy + h))
        }
        t.closeSubpath()
        return body.union(t)
    }
}

private struct TourKeyCap: View {
    let label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(label)
            .font(Fonts.print(10.5, .demiBold))
            .foregroundStyle(Ink.print.opacity(0.85))
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .frame(minWidth: 21, minHeight: 21)
            .background(shape.fill(.white).shadow(color: .black.opacity(0.2), radius: 0, y: 1))
            .overlay(shape.strokeBorder(Ink.rule, lineWidth: 0.6))
    }
}

private struct TourPrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).fixedSize()
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
            }
            .font(Fonts.print(12.5, .demiBold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 30)
            .background(Capsule().fill(Ink.plum.opacity(hover ? 0.88 : 1)))
            .shadow(color: Ink.plum.opacity(0.25), radius: 5, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(TourPressStyle())
        .onHover { hover = $0 }
    }
}

private struct TourQuietButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title)
            }
            .font(Fonts.print(12, .medium))
            .foregroundStyle(hover ? Ink.print : TourBubble.bodyColor)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Ink.print.opacity(hover ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(TourPressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

private struct TourPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 팔레트 걸이 (Palette.swift 에서 붙인다)

private struct TourPaletteFramesKey: PreferenceKey {
    static let defaultValue: [TourPaletteTarget: CGRect] = [:]
    static func reduce(value: inout [TourPaletteTarget: CGRect], nextValue: () -> [TourPaletteTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 팔레트의 도구: 둘러보기가 가리키면 빛나고, 자리를 알려 준다
    func tourTarget(_ target: TourPaletteTarget) -> some View {
        modifier(TourTargetModifier(target: target))
    }

    /// 팔레트 전체: 도구 자리를 모아 알려 주고, 둘러보는 동안에는 누르지 못하게 한다
    func tourPaletteRoot() -> some View {
        modifier(TourPaletteRootModifier())
    }
}

private struct TourTargetModifier: ViewModifier {
    let target: TourPaletteTarget
    @ObservedObject private var tour = TourController.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if tour.glow.contains(target) { TourGlowRing() }
            }
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: TourPaletteFramesKey.self, value: [target: g.frame(in: .global)])
                }
            }
    }
}

/// 빛나는 테두리 (천천히 숨 쉰다)
private struct TourGlowRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Ink.pen.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Ink.pen, lineWidth: 2))
            .shadow(color: Ink.pen.opacity(0.85), radius: 6)
            .padding(-4)
            .phaseAnimator([true, false]) { v, on in
                v.opacity(on ? 1 : 0.5)
            } animation: { _ in .easeInOut(duration: 0.85) }
            .allowsHitTesting(false)
    }
}

private struct TourPaletteRootModifier: ViewModifier {
    @ObservedObject private var tour = TourController.shared

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!tour.isRunning)
            .onPreferenceChange(TourPaletteFramesKey.self) { v in
                MainActor.assumeIsolated { TourController.shared.setPaletteFrames(v) }
            }
    }
}

// MARK: - QA (--tour-test)

/// `Spiralday --tour-test <dir>`: 메모리의 예시 플래너로 둘러보기의 모든 단계를 순서대로 PNG 로 찍고 단계 목록을 찍는다.
///   NN_<id>.png        보통 창 크기 (일간 560 × 877, 주간 · 홈 1270 × 811 pt) × 2. 팔레트 단계면 옆에 팔레트도 그린다.
///   small/NN_<id>.png  가장 작은 창 (일간 358 × 560, 주간 · 홈 860 × 549 pt)
/// 실제 데이터는 건드리지 않는다.
@MainActor
enum TourTest {
    static func run(to dir: URL) -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("small"), withIntermediateDirectories: true)
        let store = PlannerStore(inMemory: true)
        guard let id = store.addSampleBook(today: Date()) else { print("예시 플래너를 만들지 못했어요"); return 1 }
        store.activate(id)
        guard let sample = store.activeBook else { return 1 }
        var ctx = TourContext(sample: sample)
        ctx.locateCarry(in: store)
        let steps = TourScript.steps(.full, ctx)

        print("둘러보기 (예시 플래너 \(Dates.key(sample.start)) ~ \(sample.end.map(Dates.key) ?? "-"), "
              + "보여 줄 날 \(Dates.key(ctx.day)) · 주 \(Dates.key(ctx.weekStart)))")
        for k in TourKind.allCases { print("  \(k.title): \(k.stepCount)단계") }
        for (i, s) in steps.enumerated() { print(String(format: "%02d", i + 1) + "  " + describe(s)) }

        let normal: [PageKind: CGSize] = [.daily: CGSize(width: 560, height: 877), .weekly: CGSize(width: 1270, height: 811),
                                          .home: CGSize(width: 1270, height: 811)]
        let small: [PageKind: CGSize] = [.daily: CGSize(width: 358, height: 560), .weekly: CGSize(width: 860, height: 549),
                                         .home: CGSize(width: 860, height: 549)]
        let tour = TourController.shared
        for (i, step) in steps.enumerated() {
            let kind = step.scene.kind
            let state = AppState(kind: kind)
            state.store = store
            switch step.scene {
            case .day: state.dayIndex = Dates.daysBetween(state.baseDay, ctx.day)
            case .week: state.weekIndex = Dates.daysBetween(state.baseWeek, ctx.weekStart) / 7
            case .home: break
            case .front(let p): state.dayIndex = state.frontIndex(p, .daily)
            }
            // 팔레트 (빛나는 도구와 그 자리)
            tour.glow = step.glow
            let pal = palette(store: store, state: state)
            tour.assumedPaletteSize = pal.size
            let name = String(format: "%02d_%@.png", i + 1, step.id)
            for (sizes, sub) in [(normal, ""), (small, "small/")] {
                guard let size = sizes[kind],
                      let img = render(step, number: i + 1, count: steps.count, kind: kind, index: state.index, size: size,
                                       store: store, state: state, palette: pal.image, paletteSize: pal.size)
                else { print("✗ \(name) 을 그리지 못했어요"); continue }
                Snapshotter.write(img, dir.appendingPathComponent(sub + name))
            }
        }
        tour.glow = []
        tour.assumedPaletteSize = nil
        print("✓ \(steps.count)장 → \(dir.path)")
        return 0
    }

    private static func describe(_ s: TourStep) -> String {
        let scene: String = switch s.scene {
        case .day: "일간"
        case .week: "주간"
        case .home: "홈"
        case .front(let p): "일간 \(p.title)"
        }
        let spot: String = switch s.spot {
        case .none: "가운데"
        case .page(let r): "종이 \(r.count)곳"
        case .palette(let t): "팔레트 \(t.rawValue)"
        }
        let glow = s.glow.isEmpty ? "" : " · 빛남 " + s.glow.map(\.rawValue).sorted().joined(separator: ",")
        return "[\(s.section.label)] \(s.title) — \(scene) · \(spot)\(glow)\(s.interactive ? " · 누를 수 있음" : "")  (\(s.id))"
    }

    /// 팔레트를 화면 밖 창에 그려서 그림과 도구 자리를 얻는다
    private static func palette(store: PlannerStore, state: AppState) -> (image: CGImage?, size: CGSize) {
        let host = NSHostingView(rootView: PaletteView().environmentObject(store).environmentObject(state))
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        var image: CGImage?
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            image = rep.cgImage
        }
        w.contentView = nil
        w.close()
        return (image, size)
    }

    /// 종이 + 둘러보기 레이어 (+ 팔레트) 를 한 장으로
    private static func render(_ step: TourStep, number: Int, count: Int, kind: PageKind, index: Int, size: CGSize,
                               store: PlannerStore, state: AppState, palette: CGImage?, paletteSize: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        let snap = PageSnapshotter(store: store, state: state)
        guard let page = snap.image(kind: kind, index: index, size: size, scale: scale) else { return nil }
        let target: TourPaletteTarget? = if case .palette(let t) = step.spot { t } else { nil }
        let stage = TourStage(size: size, pageKind: kind, step: step, number: number, count: count,
                              primaryTitle: number == count ? TourKind.full.finishTitle : "다음",
                              palette: TourController.shared.paletteGeometry(target, in: size))
            .environmentObject(store)
            .environmentObject(state)
        let r = ImageRenderer(content: stage)
        r.scale = scale
        r.isOpaque = false
        guard let overlay = r.cgImage else { return nil }

        // 팔레트는 창 오른쪽 옆, 세로 가운데 (PaletteController.reposition 과 같게). 창보다 크면 위아래로 삐져나온다.
        let showPalette = palette != nil && (!step.glow.isEmpty || target != nil)
        let gap = MainWindowController.paletteGap - 6   // 팔레트 그림에는 그림자 여유 6 이 들어 있다
        let py = (size.height - paletteSize.height) / 2
        let top = showPalette ? min(0, py) : 0
        let bottom = showPalette ? max(size.height, py + paletteSize.height) : size.height
        let W = size.width + (showPalette ? gap + paletteSize.width + 10 : 0)
        let pw = Int(W * scale), ph = Int((bottom - top) * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 바탕 (데스크톱처럼 옅은 회색). CG 는 아래가 0 이라 위에서부터 잰 y 를 뒤집는다.
        ctx.setFillColor(NSColor(calibratedWhite: 0.84, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        func flip(_ y: CGFloat, _ h: CGFloat) -> CGFloat { CGFloat(ph) - (y - top + h) * scale }
        let pageRect = CGRect(x: 0, y: flip(0, size.height), width: size.width * scale, height: size.height * scale)
        ctx.draw(page, in: pageRect)
        ctx.draw(overlay, in: pageRect)
        if showPalette, let palette {
            ctx.draw(palette, in: CGRect(x: (size.width + gap) * scale, y: flip(py, paletteSize.height),
                                         width: paletteSize.width * scale, height: paletteSize.height * scale))
        }
        return ctx.makeImage()
    }
}
