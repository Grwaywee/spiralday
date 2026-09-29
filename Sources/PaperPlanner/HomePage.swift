import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// 홈 — 전체 통계 한 장. 가로 2000 × 1277 디자인 단위, 스프링은 위쪽.
//
//   OVERVIEW ─ 오늘 날짜 (손글씨)                        │ D-DAY ─ 카운트다운
//   [THIS WEEK │ THIS MONTH │ DAILY AVERAGE │ RECORDED]   │ [STREAK │ DONE RATE]
//   LAST 12 WEEKS ─ 주간 합계 형광펜 막대 (누르면 그 주)  │ HIGHLIGHTERS ─ 이번 달 형광펜별
//   TIME OF DAY ─ 지난 4주 시간대 띠                     │ LAST 35 DAYS ─ 잔디 달력
//   WEEKDAYS ─ 요일별 평균 │ TASK MARKS ─ ○△×→ 개수      │   (누르면 그날)
//
// 인쇄된 양식(머리선, 칸, 라벨)은 u 가 바뀔 때만 다시 그리는 Canvas 한 장,
// 숫자·막대·손글씨는 그 위의 Canvas 한 장, 누르는 자리는 맨 위 투명 뷰로 올린다.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Layout (디자인 단위)

private enum HM {
    static let page = PageKind.home.design
    static let left: CGFloat = 48
    static let right: CGFloat = 1952
    /// 왼쪽 넓은 칸 | 오른쪽 칸
    static let leftEnd: CGFloat = 1208
    static let rightStart: CGFloat = 1256

    // 머리선 높이 (라벨 대문자의 가운데가 이 선에 걸린다)
    static let headRule: CGFloat = 100
    static let rowA: CGFloat = 392
    static let rowB: CGFloat = 818
    static let rowC: CGFloat = 1006
    static let bottom: CGFloat = 1237

    static let dateBox = CGRect(x: left, y: 112, width: leftEnd - left, height: 72)
    /// 날짜 오른쪽: 이번 주 목표 (주간 페이지의 MY GOAL)
    static let goalBox = CGRect(x: 560, y: 116, width: leftEnd - 560, height: 64)
    static let ddayBox = CGRect(x: rightStart, y: 112, width: right - rightStart, height: 72)

    // 요약 칸: 왼쪽 4칸 · 오른쪽 2칸
    static let keyTop: CGFloat = 206
    static let keyH: CGFloat = 138
    static func keyCell(_ i: Int) -> CGRect {
        if i < 4 {
            let w = (leftEnd - left) / 4
            return CGRect(x: left + CGFloat(i) * w, y: keyTop, width: w, height: keyH)
        }
        let w = (right - rightStart) / 2
        return CGRect(x: rightStart + CGFloat(i - 4) * w, y: keyTop, width: w, height: keyH)
    }

    // 최근 12주
    static let weeksAxis: CGFloat = left + 56
    static let weeksX0: CGFloat = left + 76
    static var weekSlot: CGFloat { (leftEnd - weeksX0) / CGFloat(HomeStats.weekCount) }
    static let weeksTop: CGFloat = 462
    static let weeksBase: CGFloat = 726
    static let weekBarW: CGFloat = 48
    static func weekColumn(_ i: Int) -> CGRect {
        CGRect(x: weeksX0 + CGFloat(i) * weekSlot, y: rowA + 20, width: weekSlot, height: 772 - rowA - 20)
    }

    // 형광펜별
    static let catTop: CGFloat = 414
    static let catBottom: CGFloat = 772
    static let catBarX: CGFloat = rightStart + 150
    static let catBarEnd: CGFloat = right - 146

    // 시간대 띠
    static let heat = CGRect(x: left, y: 846, width: leftEnd - left, height: 52)

    // 요일별 · 할 일 표시
    static let weekdayRect = CGRect(x: left, y: 1030, width: 540, height: bottom - 1030)
    static let marksRect = CGRect(x: 636, y: 1030, width: leftEnd - 636, height: bottom - 1030)

    // 잔디 달력
    static let calX0: CGFloat = rightStart + 80
    static let calY0: CGFloat = 874
    static let calCell: CGFloat = 64
    static let calGap: CGFloat = 11
    static func dayCell(_ i: Int) -> CGRect {
        CGRect(x: calX0 + CGFloat(i % 7) * (calCell + calGap), y: calY0 + CGFloat(i / 7) * (calCell + calGap),
               width: calCell, height: calCell)
    }
    static let legendX: CGFloat = right - 58

    static let weekdays = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    static func weekdayColor(_ i: Int) -> Color { i == 5 ? Ink.saturday : i == 6 ? Ink.red : Ink.soft }
}

private extension View {
    /// 디자인 단위 사각형 자리에 놓는다 (부모는 topLeading ZStack)
    func place(_ r: CGRect, _ u: CGFloat, alignment: Alignment = .center) -> some View {
        frame(width: r.width * u, height: r.height * u, alignment: alignment)
            .offset(x: r.minX * u, y: r.minY * u)
    }
}

// MARK: - Page

/// 홈 (디자인 2000 × 1277, 위쪽 스프링). 전체 통계를 보여주는 한 장짜리 표지.
struct HomePage: View {
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    @State private var editingDDay = false

    var body: some View {
        let today = Dates.day(Date())
        let stats = HomeStats.make(store.data, today: today)
        let concept = ColorConcept.of(store.data.prefs.defaultTheme)
        let thisWeek = Dates.weekStart(today)
        ZStack(alignment: .topLeading) {
            HomeForm(u: u).equatable()

            HomeInk(stats: stats, categories: store.categories, defaultTheme: store.data.prefs.defaultTheme,
                    ddays: store.data.prefs.ddays, goal: store.week(thisWeek).goal, today: today, u: u)
                .allowsHitTesting(false)

            // 이번 주 목표: 누르면 이번 주 주간 페이지
            PageTarget(help: "이번 주 주간 페이지 열기") { hover in
                RoundedRectangle(cornerRadius: 10 * u).fill(Ink.pen.opacity(hover ? 0.06 : 0))
            } action: {
                openWeek(thisWeek)
            }
            .place(HM.goalBox, u)

            // D-day 칸: 누르면 편집
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { editingDDay = true }
                .popover(isPresented: $editingDDay, arrowEdge: .bottom) { DDayEditor().environmentObject(store) }
                .help("D-day 설정 (최대 2개)")
                .place(HM.ddayBox, u)

            // 주 막대: 누르면 그 주 주간 페이지
            ForEach(stats.weeks.indices, id: \.self) { i in
                let w = stats.weeks[i]
                PageTarget(help: weekHelp(w)) { hover in
                    RoundedRectangle(cornerRadius: 10 * u)
                        .fill(Ink.pen.opacity(hover ? 0.07 : 0))
                        .padding(.horizontal, 6 * u)
                } action: {
                    openWeek(w.start)
                }
                .place(HM.weekColumn(i), u)
            }

            // 잔디 한 칸: 누르면 그날 일간 페이지
            ForEach(stats.calendar.indices, id: \.self) { i in
                let d = stats.calendar[i]
                PageTarget(help: dayHelp(d)) { hover in
                    RoundedRectangle(cornerRadius: 9 * u)
                        .stroke(concept.accent.opacity(hover ? 0.7 : 0), lineWidth: max(1, 2.4 * u))
                        .padding(-3 * u)
                } action: {
                    state.openDay(d.date)
                }
                .place(HM.dayCell(i), u)
            }
        }
        .frame(width: HM.page.width * u, height: HM.page.height * u, alignment: .topLeading)
    }

    private func openWeek(_ start: Date) {
        state.weekIndex = Dates.daysBetween(state.baseWeek, start) / 7
        state.switchKind(.weekly)
    }

    private func weekHelp(_ w: HomeStats.Week) -> String {
        let a = Dates.comp(w.start), b = Dates.comp(Dates.add(days: 6, to: w.start))
        let (h, m) = formatHM(w.minutes)
        return "\(a.month!)/\(a.day!) – \(b.month!)/\(b.day!) · \(h)시간 \(m)분 — 눌러서 주간 페이지 열기"
    }

    private func dayHelp(_ d: HomeStats.DayCell) -> String {
        let c = Dates.comp(d.date)
        let (h, m) = formatHM(d.minutes)
        return "\(c.month!)월 \(c.day!)일 · \(h)시간 \(m)분 — 눌러서 일간 페이지 열기"
    }
}

/// 누르는 자리 (투명). 마우스를 올리면 hover 모양을 보여주고 손가락 커서로 바뀐다.
/// hover 상태를 여기 안에 두어 페이지 전체(통계 계산, 그림)가 다시 그려지지 않게 한다.
private struct PageTarget<Hover: View>: View {
    let help: String
    @ViewBuilder let hover: (Bool) -> Hover
    let action: () -> Void

    @State private var on = false

    var body: some View {
        hover(on)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { on = h } }
            .pointingHand()
            .onDisappear { if on { NSCursor.arrow.set() } }
            .help(help)
    }
}

private extension View {
    func pointingHand() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - Printed form

/// 인쇄된 양식: 머리선 + 라벨, 요약 칸. 데이터와 무관해서 u 가 바뀔 때만 다시 그린다.
private struct HomeForm: View, Equatable {
    let u: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: u, y: u)
            Self.drawSections(ctx)
            Self.drawKeyBoxes(ctx)
        }
        .allowsHitTesting(false)
    }

    private static let sections: [(String, String?, CGFloat, CGFloat, CGFloat)] = [
        ("OVERVIEW", nil, HM.left, HM.leftEnd, HM.headRule),
        ("D-DAY", nil, HM.rightStart, HM.right, HM.headRule),
        ("LAST 12 WEEKS", "주간 합계 · 누르면 그 주로", HM.left, HM.leftEnd, HM.rowA),
        ("HIGHLIGHTERS", "이번 달 형광펜별", HM.rightStart, HM.right, HM.rowA),
        ("TIME OF DAY", "지난 4주 · 자주 칠한 시간", HM.left, HM.leftEnd, HM.rowB),
        ("LAST 35 DAYS", "누르면 그날로", HM.rightStart, HM.right, HM.rowB),
        ("WEEKDAYS", "요일별 평균 · 지난 8주", HM.weekdayRect.minX, HM.weekdayRect.maxX, HM.rowC),
        ("TASK MARKS", "이번 달 할 일", HM.marksRect.minX, HM.marksRect.maxX, HM.rowC),
    ]

    /// 일간 양식과 같은 "LABEL ──── 설명" 머리줄 (굵은 선, 대문자 가운데가 선 높이)
    private static func drawSections(_ ctx: GraphicsContext) {
        let cap = NSFont(name: Fonts.PrintWeight.demiBold.postScriptName, size: 19.8)?.capHeight ?? 14
        let gap: CGFloat = 13
        for (label, caption, x0, x1, y) in sections {
            let t = ctx.resolve(Text(label).font(Fonts.print(19.8, .demiBold)).tracking(-0.6).foregroundStyle(Ink.print))
            let box = CGSize(width: 2000, height: 200)
            let size = t.measure(in: box)
            let base = t.firstBaseline(in: box)
            ctx.draw(t, in: CGRect(x: x0, y: y - 1 + cap / 2 - base, width: size.width, height: size.height))
            var end = x1
            if let caption {
                let c = ctx.resolve(Text(caption).font(Fonts.print(15.5, .medium)).foregroundStyle(Ink.soft))
                let cs = c.measure(in: box)
                ctx.draw(c, at: CGPoint(x: x1, y: y - 1), anchor: .trailing)
                end = x1 - cs.width - gap
            }
            let rx = x0 + size.width - 0.6 + gap
            ctx.fill(Path(CGRect(x: rx, y: y - 1.35, width: end - rx, height: 2.7)), with: .color(Ink.print))
        }
    }

    private static let keyLabels = ["THIS WEEK", "THIS MONTH", "DAILY AVERAGE", "RECORDED DAYS", "STREAK", "DONE RATE"]

    /// 주간 양식 머리 칸과 같은 얇은 점선색 테두리 + 작은 자간 라벨
    private static func drawKeyBoxes(_ ctx: GraphicsContext) {
        let box = Ink.dot
        let l = HM.keyCell(0).union(HM.keyCell(3)), r = HM.keyCell(4).union(HM.keyCell(5))
        for f in [l, r] { ctx.stroke(Path(f.insetBy(dx: 0.5, dy: 0.5)), with: .color(box), lineWidth: 1) }
        for i in [1, 2, 3, 5] {
            let x = HM.keyCell(i).minX
            var p = Path()
            p.move(to: CGPoint(x: x, y: HM.keyTop + 16))
            p.addLine(to: CGPoint(x: x, y: HM.keyTop + HM.keyH - 16))
            ctx.stroke(p, with: .color(Ink.dot), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 6.6]))
        }
        for (i, s) in keyLabels.enumerated() {
            let c = HM.keyCell(i)
            ctx.draw(Text(s).font(Fonts.print(14.5, .demiBold)).tracking(2.2).foregroundStyle(Ink.soft),
                     at: CGPoint(x: c.minX + 24, y: c.minY + 28), anchor: .leading)
        }
    }
}

// MARK: - Ink (데이터)

/// 통계 숫자, 형광펜 막대, 손글씨. 한 Canvas 에 디자인 좌표로 그린다.
private struct HomeInk: View {
    let stats: HomeStats
    let categories: [Category]
    let defaultTheme: Int
    let ddays: [DDay]
    let goal: String
    let today: Date
    let u: CGFloat

    private var concept: ColorConcept { ColorConcept.of(defaultTheme) }

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: u, y: u)
            drawHeader(ctx)
            drawKeyNumbers(ctx)
            drawWeeks(ctx)
            drawCategories(ctx)
            drawHeat(ctx)
            drawWeekdays(ctx)
            drawMarks(ctx)
            drawCalendar(ctx)
        }
    }

    // MARK: text helpers

    private static let big = CGSize(width: 4000, height: 1000)

    /// 폭에 맞을 때까지 글자 크기를 줄여서 resolve
    private func fit(_ ctx: GraphicsContext, _ width: CGFloat, size: CGFloat,
                     _ make: (CGFloat) -> Text) -> GraphicsContext.ResolvedText {
        var s = size
        var r = ctx.resolve(make(s))
        while s > size * 0.5, r.measure(in: Self.big).width > width {
            s *= 0.92
            r = ctx.resolve(make(s))
        }
        return r
    }

    /// 한 줄 손글씨: 폭에 맞게 조금 줄이고, 그래도 길면 끝을 "…" 로 자른다
    private func line(_ ctx: GraphicsContext, _ s: String, width: CGFloat, font: (CGFloat) -> Font) -> Text {
        let fits = { (t: Text) in ctx.resolve(t).measure(in: Self.big).width <= width }
        for k in [1, 0.92, 0.85] as [CGFloat] where fits(Text(s).font(font(k))) { return Text(s).font(font(k)) }
        // 들어가는 가장 긴 앞부분 (이분 탐색)
        let chars = Array(s)
        func cut(_ n: Int) -> Text { Text(String(chars.prefix(n)).trimmingCharacters(in: .whitespaces) + "…").font(font(0.85)) }
        var lo = 0, hi = chars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(cut(mid)) { lo = mid } else { hi = mid - 1 }
        }
        return cut(lo)
    }

    /// "12H05M" — 일간 TOTAL TIME 과 같은 둥근 굵은 숫자
    private func hm(_ minutes: Int, _ size: CGFloat, unit: CGFloat? = nil) -> Text {
        let (h, m) = formatHM(minutes)
        let d = Fonts.rounded(size, .black), un = Fonts.rounded(unit ?? size * 0.52, .black)
        return Text(h).font(d) + Text("H").font(un) + Text(m).font(d) + Text("M").font(un)
    }

    private func color(_ id: Int?) -> Color? {
        guard let id, let c = categories.first(where: { $0.id == id }) else { return nil }
        return c.color
    }

    // MARK: highlighter stroke

    /// 형광펜으로 한 번 그은 윤곽 (HighlighterBar 와 같은 모양). vertical 이면 아래에서 위로 긋는다.
    private static func stroke(_ r: CGRect, vertical: Bool = false) -> Path {
        let len = vertical ? r.height : r.width, thick = vertical ? r.width : r.height
        func pt(_ a: CGFloat, _ c: CGFloat) -> CGPoint {
            vertical ? CGPoint(x: r.minX + c, y: r.maxY - a) : CGPoint(x: r.minX + a, y: r.minY + c)
        }
        var p = Path()
        guard len > 3 else { return Path(r) }
        p.move(to: pt(1, thick * 0.18))
        p.addLine(to: pt(len - 2, thick * 0.10))
        p.addQuadCurve(to: pt(len, thick * 0.86), control: pt(len + thick * 0.12, thick * 0.5))
        p.addLine(to: pt(2, thick * 0.94))
        p.addQuadCurve(to: pt(1, thick * 0.18), control: pt(-thick * 0.08, thick * 0.55))
        p.closeSubpath()
        return p
    }

    /// 주간 페이지 MY GOAL 칸의 분홍 깃발 (깃대 + 깃발), 위쪽 끝이 p
    private static func flag(_ ctx: GraphicsContext, at p: CGPoint, height h: CGFloat) {
        let k = h / 23
        ctx.fill(Path(roundedRect: CGRect(x: p.x, y: p.y, width: 3 * k, height: h), cornerRadius: 1.5 * k),
                 with: .color(Ink.pen))
        var f = Path()
        f.move(to: CGPoint(x: p.x + 2 * k, y: p.y))
        f.addLine(to: CGPoint(x: p.x + 15 * k, y: p.y))
        f.addLine(to: CGPoint(x: p.x + 11.5 * k, y: p.y + 5.5 * k))
        f.addLine(to: CGPoint(x: p.x + 15 * k, y: p.y + 11 * k))
        f.addLine(to: CGPoint(x: p.x + 2 * k, y: p.y + 11 * k))
        f.closeSubpath()
        ctx.fill(f, with: .color(Ink.pen))
    }

    private static func dotted(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color = Ink.dot,
                               width: CGFloat = 2, gap: CGFloat = 6.6) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.1, gap]))
    }

    private static func rule(_ ctx: GraphicsContext, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat,
                             _ color: Color = Ink.rule, _ width: CGFloat = 1.5) {
        ctx.fill(Path(CGRect(x: x0, y: y - width / 2, width: x1 - x0, height: width)), with: .color(color))
    }

    /// 빈 페이지 안내 (손글씨, 옅게)
    private static func hint(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, size: CGFloat = 28,
                             anchor: UnitPoint = .center) {
        ctx.draw(Text(s).font(Fonts.hand(size)).foregroundStyle(Ink.soft), at: p, anchor: anchor)
    }

    /// 가운데 눈금 두 줄 사이 (빈 차트 안내 글자가 점선에 걸리지 않게)
    private static func between(_ top: Double, _ step: Double) -> Double {
        ((top / step / 2).rounded(.down) + 0.5) * step
    }

    /// 눈금 간격: 칸이 4개 이하가 되는 가장 작은 보기 좋은 값 (시간)
    private static func scale(_ maxHours: Double, steps: [Double], empty: (Double, Double)) -> (top: Double, step: Double) {
        guard maxHours > 0 else { return empty }
        let step = steps.first { (maxHours / $0).rounded(.up) <= 4 } ?? steps.last!
        return (max(step, (maxHours / step).rounded(.up) * step), step)
    }

    // MARK: header

    private func drawHeader(_ ctx: GraphicsContext) {
        let c = Dates.comp(today)
        let wd = String(Dates.weekdayEN[c.weekday!].prefix(3))
        let digits = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        let date = ctx.resolve((Text(digits).foregroundStyle(Ink.text) + Text(" " + wd).foregroundStyle(concept.accent))
            .font(Fonts.hand(78)).tracking(2))
        let b = HM.dateBox
        let s = date.measure(in: Self.big)
        let x = b.minX + 14, midY = b.midY + 2
        // 날짜 밑 형광펜 (일간 페이지와 같은 컨셉 색)
        var hl = ctx
        hl.blendMode = .multiply
        hl.fill(Self.stroke(CGRect(x: x - 10, y: midY + s.height * 0.12, width: s.width + 20, height: 22)),
                with: .color(concept.tint.opacity(0.78)))
        ctx.draw(date, at: CGPoint(x: x, y: midY), anchor: .leading)

        // 이번 주 목표 (주간 페이지와 같은 분홍 깃발)
        let g = HM.goalBox
        Self.flag(ctx, at: CGPoint(x: g.minX + 16, y: g.midY - 14), height: 30)
        let tx = g.minX + 44
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = line(ctx, goalText.isEmpty ? "이번 주 목표" : goalText, width: g.maxX - 10 - tx) { k in
            Fonts.hand(38 * k)
        }
        ctx.draw(t.foregroundStyle(goalText.isEmpty ? Ink.faint : Ink.text), at: CGPoint(x: tx, y: g.midY + 1), anchor: .leading)

        // D-day
        let d = HM.ddayBox
        if ddays.isEmpty {
            ctx.draw(Text("+ D-day").font(Fonts.hand(48)).foregroundStyle(Ink.faint),
                     at: CGPoint(x: d.midX, y: d.midY + 2), anchor: .center)
            return
        }
        let w = d.width / CGFloat(ddays.count)
        for (i, dd) in ddays.enumerated() {
            let n = Dates.daysBetween(today, dd.date)
            let title = dd.title.isEmpty ? "D-day" : dd.title
            let count = n > 0 ? "D-\(n)" : n == 0 ? "D-DAY" : "D+\(-n)"
            let t = fit(ctx, w - 24, size: 1) { k in
                Text(title).font(Fonts.hand(44 * k)).foregroundStyle(Ink.text)
                    + Text("  " + count).font(Fonts.hand(64 * k)).foregroundStyle(concept.accent)
            }
            ctx.draw(t, at: CGPoint(x: d.minX + w * (CGFloat(i) + 0.5), y: d.midY + 2), anchor: .center)
        }
    }

    // MARK: key numbers

    private func drawKeyNumbers(_ ctx: GraphicsContext) {
        let s = stats
        let we = Dates.add(days: 6, to: s.weeks.last?.start ?? today)
        let ws = Dates.comp(s.weeks.last?.start ?? today), wec = Dates.comp(we)
        let last = s.weeks.count > 1 ? s.weeks[s.weeks.count - 2].minutes : 0
        let (lh, lm) = formatHM(last)

        let digits: CGFloat = 60, unit: CGFloat = 30
        let ink = Ink.text
        func num(_ v: Int, _ suffix: String, _ k: CGFloat) -> Text {
            Text("\(v)").font(Fonts.rounded(digits * k, .black)) + Text(suffix).font(Fonts.rounded(unit * k, .black))
        }

        let rate = s.completion.map { Int(($0 * 100).rounded()) }
        let values: [((CGFloat) -> Text, Bool)] = [
            ({ k in hm(s.weekMinutes, digits * k, unit: unit * k) }, s.weekMinutes > 0),
            ({ k in hm(s.monthMinutes, digits * k, unit: unit * k) }, s.monthMinutes > 0),
            ({ k in hm(s.dailyAverage, digits * k, unit: unit * k) }, s.dailyAverage > 0),
            ({ k in num(s.monthDays, " / \(s.daysInMonth)", k) }, s.monthDays > 0),
            ({ k in num(s.streak, s.streak == 1 ? " DAY" : " DAYS", k) }, s.streak > 0),
            ({ k in num(rate ?? 0, "%", k) }, rate != nil),
        ]
        let captions = [
            "\(ws.month!)/\(ws.day!) – \(wec.month!)/\(wec.day!)" + (last > 0 ? " · 지난주 \(lh)H\(lm)M" : ""),
            "\(s.month)월 1일부터",
            s.monthDays > 0 ? "기록한 \(s.monthDays)일 평균" : "기록한 날 평균",
            "\(s.month)월에 타임테이블을 칠한 날",
            s.streak == 0 ? "오늘 칠하면 1일째" : s.streakIncludesToday ? "오늘까지 이어서 기록" : "어제까지 · 오늘도 칠해요",
            s.marked > 0 ? "표시한 할 일 \(s.marked)개 중 ○ \(s.done)개" : "할 일에 ○△×→ 를 표시해요",
        ]
        for i in 0..<6 {
            let c = HM.keyCell(i)
            let (make, on) = values[i]
            // 기록이 있는 숫자는 컨셉 색, 0 은 일간 TOTAL TIME 처럼 아주 옅게
            let tint = on ? (i < 2 ? concept.accent : ink) : concept.accent.opacity(0.14)
            let r = fit(ctx, c.width - 44, size: 1) { k in make(k).foregroundStyle(tint) }
            ctx.draw(r, at: CGPoint(x: c.minX + 22, y: c.minY + 72), anchor: .leading)
            let cap = fit(ctx, c.width - 44, size: 25) { k in Text(captions[i]).font(Fonts.hand(k)).foregroundStyle(Ink.soft) }
            ctx.draw(cap, at: CGPoint(x: c.minX + 24, y: c.maxY - 21), anchor: .leading)
        }
    }

    // MARK: last 12 weeks

    private func drawWeeks(_ ctx: GraphicsContext) {
        let weeks = stats.weeks
        let maxH = Double(weeks.map(\.minutes).max() ?? 0) / 60
        let (top, step) = Self.scale(maxH, steps: [1, 2, 5, 10, 15, 20, 25, 50, 100], empty: (40, 10))
        let x0 = HM.weeksX0, x1 = HM.leftEnd
        let base = HM.weeksBase, span = HM.weeksBase - HM.weeksTop
        func y(_ hours: Double) -> CGFloat { base - CGFloat(hours / top) * span }

        // 눈금: 점선 + 시간
        var v = step
        while v <= top + 0.001 {
            Self.dotted(ctx, CGPoint(x: x0, y: y(v)), CGPoint(x: x1, y: y(v)))
            ctx.draw(Text("\(Int(v))H").font(Fonts.print(14.5, .demiBold)).foregroundStyle(Ink.soft),
                     at: CGPoint(x: HM.weeksAxis, y: y(v)), anchor: .trailing)
            v += step
        }
        ctx.draw(Text("0").font(Fonts.print(14.5, .demiBold)).foregroundStyle(Ink.soft),
                 at: CGPoint(x: HM.weeksAxis, y: base), anchor: .trailing)

        let slot = HM.weekSlot
        let cats = categories
        for (i, w) in weeks.enumerated() {
            let cx = x0 + (CGFloat(i) + 0.5) * slot
            let current = w.offset == 0
            // 막대: 형광펜 색을 팔레트 순서로 아래부터 쌓는다
            if w.minutes > 0 {
                let h = CGFloat(Double(w.minutes) / 60 / top) * span
                let bar = CGRect(x: cx - HM.weekBarW / 2, y: base - h, width: HM.weekBarW, height: h)
                var hl = ctx
                hl.blendMode = .multiply
                hl.clip(to: Self.stroke(bar, vertical: true))
                var yy = base
                for (k, c) in cats.enumerated() where k < w.byCategory.count && w.byCategory[k] > 0 {
                    let sh = CGFloat(Double(w.byCategory[k]) / Double(w.minutes)) * h
                    hl.fill(Path(CGRect(x: bar.minX - 4, y: yy - sh - 0.4, width: bar.width + 8, height: sh + 0.8)),
                            with: .color(c.color.opacity(0.86)))
                    yy -= sh
                }
                let size: CGFloat = current ? 21 : 17
                let ink = current ? concept.accent : Ink.text
                ctx.draw(fit(ctx, slot - 6, size: 1) { k in hm(w.minutes, size * k).foregroundStyle(ink) },
                         at: CGPoint(x: cx, y: base - h - 16), anchor: .center)
            }
            // 주 시작 날짜 (이번 주는 컨셉 색 + 형광펜)
            let c = Dates.comp(w.start)
            let text = current ? "이번 주" : "\(c.month!)/\(c.day!)"
            let t = ctx.resolve(Text(text).font(Fonts.hand(current ? 30 : 27))
                .foregroundStyle(current ? Ink.text : Ink.soft))
            if current {
                let s = t.measure(in: Self.big)
                var hl = ctx
                hl.blendMode = .multiply
                hl.fill(Self.stroke(CGRect(x: cx - s.width / 2 - 8, y: base + 30, width: s.width + 16, height: 14)),
                        with: .color(concept.tint.opacity(0.9)))
            }
            ctx.draw(t, at: CGPoint(x: cx, y: base + 28), anchor: .center)
        }
        Self.rule(ctx, x0 - 8, x1, base, Ink.print, 1.4)

        if maxH == 0 {
            // 점선 두 줄 사이 가운데에
            Self.hint(ctx, "타임테이블을 칠하면 여기에 통계가 쌓여요",
                      at: CGPoint(x: (x0 + x1) / 2, y: y(Self.between(top, step))))
        }
    }

    // MARK: highlighters (this month)

    private func drawCategories(_ ctx: GraphicsContext) {
        let list = stats.categories
        guard !list.isEmpty else { return }
        let excluded = list.contains { !$0.counts }
        let empty = list.allSatisfy { $0.minutes == 0 }
        let foot: CGFloat = excluded || empty ? 40 : 0
        let rowH = min(46, (HM.catBottom - HM.catTop - foot) / CGFloat(list.count))
        let maxM = max(1, list.map(\.minutes).max() ?? 0)
        let barMax = HM.catBarEnd - HM.catBarX
        let nameW = HM.catBarX - HM.rightStart - 16

        for (i, c) in list.enumerated() {
            guard let cat = categories.first(where: { $0.id == c.id }) else { continue }
            let y = HM.catTop + CGFloat(i) * rowH, mid = y + rowH / 2
            let faded = !c.counts
            Self.rule(ctx, HM.rightStart, HM.right, y + rowH, Ink.rule, 1.2)

            let name = fit(ctx, nameW, size: min(31, rowH * 0.74)) { k in
                Text(cat.name + (faded ? " *" : "")).font(Fonts.hand(k)).foregroundStyle(faded ? Ink.soft : Ink.text)
            }
            ctx.draw(name, at: CGPoint(x: HM.rightStart + 6, y: mid + 1), anchor: .leading)

            if c.minutes > 0 {
                let len = max(14, CGFloat(c.minutes) / CGFloat(maxM) * barMax)
                let th = min(30, rowH * 0.66)
                var hl = ctx
                hl.blendMode = .multiply
                hl.fill(Self.stroke(CGRect(x: HM.catBarX, y: mid - th / 2, width: len, height: th)),
                        with: .color(cat.color.opacity(faded ? 0.42 : 0.86)))
            } else {
                Self.dotted(ctx, CGPoint(x: HM.catBarX + 2, y: mid), CGPoint(x: HM.catBarEnd, y: mid))
            }
            let value = hm(c.minutes, min(21, rowH * 0.5))
                .foregroundStyle(c.minutes == 0 ? Ink.faint : faded ? Ink.soft : Ink.text)
            ctx.draw(value, at: CGPoint(x: HM.right - 4, y: mid + 1), anchor: .trailing)
        }

        let fy = HM.catBottom - 16
        if empty {
            Self.hint(ctx, "이번 달에 칠한 형광펜이 여기에 모여요", at: CGPoint(x: HM.rightStart + 6, y: fy), size: 25, anchor: .leading)
        } else if excluded {
            Self.hint(ctx, "* 흐린 형광펜은 TOTAL TIME 에 넣지 않아요", at: CGPoint(x: HM.rightStart + 6, y: fy),
                      size: 24, anchor: .leading)
        }
    }

    // MARK: time of day

    private func drawHeat(_ ctx: GraphicsContext) {
        let r = HM.heat
        let cw = r.width / CGFloat(DayRecord.slotCount), hw = r.width / 24

        // 인쇄된 띠: 위아래 선 + 한 시간마다 점선
        for k in 1..<24 {
            let x = r.minX + CGFloat(k) * hw
            Self.dotted(ctx, CGPoint(x: x, y: r.minY + 5), CGPoint(x: x, y: r.maxY - 5), gap: 6.2)
        }

        // 칸마다 가장 자주 칠한 형광펜 색, 자주 칠할수록 진하게 (가장 자주 칠한 칸 = 가장 진하게).
        // 같은 색·진하기는 한 번에 칠해 칸 사이 이음새를 없앤다.
        var hl = ctx
        hl.blendMode = .multiply
        hl.clip(to: Self.stroke(r.insetBy(dx: 0, dy: 3)))
        var k = 0
        let cells = stats.heat
        let peak = max(cells.map(\.ratio).max() ?? 0, 0.0001)
        func level(_ c: HomeStats.HeatCell) -> Int { c.ratio > 0 ? max(1, Int((c.ratio / peak * 10).rounded())) : 0 }
        while k < cells.count {
            let c = cells[k], lv = level(c)
            guard lv > 0, let col = color(c.category) else { k += 1; continue }
            var e = k
            while e + 1 < cells.count, cells[e + 1].category == c.category, level(cells[e + 1]) == lv { e += 1 }
            let alpha = Self.heatAlpha(Double(lv) / 10)
            hl.fill(Path(CGRect(x: r.minX + CGFloat(k) * cw, y: r.minY, width: CGFloat(e - k + 1) * cw, height: r.height)),
                    with: .color(col.opacity(alpha)))
            k = e + 1
        }

        Self.rule(ctx, r.minX, r.maxX, r.minY, Ink.print, 1.4)
        Self.rule(ctx, r.minX, r.maxX, r.maxY, Ink.print, 1.4)

        // 시각 (타임테이블과 같은 인쇄 숫자)
        for h in 0..<24 {
            ctx.draw(Text(SlotPainter.hourLabel(h)).font(Fonts.print(15, .bold)).foregroundStyle(Ink.print),
                     at: CGPoint(x: r.minX + (CGFloat(h) + 0.5) * hw, y: r.maxY + 17), anchor: .center)
        }

        // 아래 줄: 가장 자주 칠한 시간 / 진하기 범례
        let y = r.maxY + 52
        if let p = stats.peakHour {
            let t = Text("가장 자주 칠한 시간  ").font(Fonts.hand(26)).foregroundStyle(Ink.soft)
                + Text(Self.hourRange((6 + p) % 24)).font(Fonts.hand(30)).foregroundStyle(concept.accent)
            ctx.draw(t, at: CGPoint(x: r.minX + 4, y: y), anchor: .leading)
        } else {
            Self.hint(ctx, "자주 칠하는 시간대가 진하게 보여요", at: CGPoint(x: r.minX + 4, y: y), size: 26, anchor: .leading)
        }
        // 범례: 드물게 ▭▭▭▭▭ 자주
        let sw: CGFloat = 26, gap: CGFloat = 5
        let lx = r.maxX - 5 * sw - 4 * gap - 52
        ctx.draw(Text("드물게").font(Fonts.hand(24)).foregroundStyle(Ink.soft), at: CGPoint(x: lx - 10, y: y), anchor: .trailing)
        let sample = color(stats.heat.first(where: { $0.category != nil })?.category) ?? Ink.soft
        var lg = ctx
        lg.blendMode = .multiply
        for i in 0..<5 {
            let a = Self.heatAlpha(Double(i + 1) / 5)
            lg.fill(Path(roundedRect: CGRect(x: lx + CGFloat(i) * (sw + gap), y: y - 9, width: sw, height: 18),
                         cornerRadius: 3), with: .color(sample.opacity(a)))
        }
        ctx.draw(Text("자주").font(Fonts.hand(24)).foregroundStyle(Ink.soft),
                 at: CGPoint(x: r.maxX, y: y), anchor: .trailing)
    }

    /// 가장 자주 칠한 칸일수록 진하게 (0...1 → 불투명도)
    private static func heatAlpha(_ v: Double) -> Double { 0.06 + 0.9 * pow(v, 2) }

    /// 한 시간 구간: 9 → "오전 9시 – 10시", 11 → "오전 11시 – 정오", 23 → "오후 11시 – 자정"
    private static func hourRange(_ h: Int) -> String {
        func half(_ h: Int) -> String { h < 12 ? "오전" : "오후" }
        func clock(_ h: Int) -> String { h == 0 ? "자정" : h == 12 ? "정오" : "\(h % 12)시" }
        let e = (h + 1) % 24
        let end = e == 0 || e == 12 || half(e) != half(h) ? (e % 12 == 0 ? clock(e) : "\(half(e)) \(clock(e))") : clock(e)
        return h == 0 || h == 12 ? "\(clock(h)) – \(end)" : "\(half(h)) \(clock(h)) – \(end)"
    }

    // MARK: weekdays

    private func drawWeekdays(_ ctx: GraphicsContext) {
        let r = HM.weekdayRect
        let avg = stats.weekdayAverage
        let maxH = Double(avg.max() ?? 0) / 60
        let (top, step) = Self.scale(maxH, steps: [1, 2, 3, 4, 5, 6, 8, 10, 12], empty: (8, 2))
        let base = r.maxY - 42, span = base - (r.minY + 40)
        let slot = r.width / 7
        func y(_ hours: Double) -> CGFloat { base - CGFloat(hours / top) * span }

        var v = step
        while v <= top + 0.001 {
            Self.dotted(ctx, CGPoint(x: r.minX, y: y(v)), CGPoint(x: r.maxX, y: y(v)))
            v += step
        }
        let best = avg.max() ?? 0
        for i in 0..<7 {
            let cx = r.minX + (CGFloat(i) + 0.5) * slot
            if avg[i] > 0 {
                let h = CGFloat(Double(avg[i]) / 60 / top) * span
                var hl = ctx
                hl.blendMode = .multiply
                let isBest = avg[i] == best
                hl.fill(Self.stroke(CGRect(x: cx - 21, y: base - h, width: 42, height: h), vertical: true),
                        with: .color(isBest ? concept.accent.opacity(0.55) : concept.tint.opacity(0.9)))
                let ink = isBest ? concept.accent : Ink.text
                ctx.draw(fit(ctx, slot - 4, size: 1) { k in hm(avg[i], 16.5 * k).foregroundStyle(ink) },
                         at: CGPoint(x: cx, y: base - h - 14), anchor: .center)
            }
            ctx.draw(Text(HM.weekdays[i]).font(Fonts.print(14.5, .demiBold)).tracking(1.6)
                        .foregroundStyle(HM.weekdayColor(i)),
                     at: CGPoint(x: cx + 0.8, y: base + 22), anchor: .center)
        }
        Self.rule(ctx, r.minX, r.maxX, base, Ink.print, 1.4)
        if best == 0 {
            Self.hint(ctx, "요일마다 평균 몇 시간인지 보여요", at: CGPoint(x: r.midX, y: y(Self.between(top, step))), size: 26)
        }
    }

    // MARK: task marks

    private func drawMarks(_ ctx: GraphicsContext) {
        let r = HM.marksRect
        let s = stats
        let items: [(Mark, Int, String)] = [(.done, s.done, "완료"), (.partial, s.partial, "일부"),
                                            (.missed, s.missed, "못함"), (.moved, s.moved, "미룸")]
        let w = r.width / 4
        for (i, (mark, n, name)) in items.enumerated() {
            let cx = r.minX + (CGFloat(i) + 0.5) * w
            let box = CGRect(x: cx - 24, y: r.minY + 12, width: 48, height: 48)
            ctx.stroke(MarkShape(mark: mark).path(in: box), with: .color(n > 0 ? concept.accent : concept.accent.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round))
            ctx.draw(Text("\(n)").font(Fonts.hand(70)).foregroundStyle(n > 0 ? Ink.text : Ink.faint),
                     at: CGPoint(x: cx, y: r.minY + 100), anchor: .center)
            ctx.draw(Text(name).font(Fonts.hand(27)).foregroundStyle(Ink.soft),
                     at: CGPoint(x: cx, y: r.minY + 144), anchor: .center)
            if i > 0 {
                Self.dotted(ctx, CGPoint(x: r.minX + CGFloat(i) * w, y: r.minY + 16),
                            CGPoint(x: r.minX + CGFloat(i) * w, y: r.minY + 150))
            }
        }

        // 맨 아래: 비율을 형광펜 한 줄로 (완료가 가장 진하다)
        let y = r.maxY - 22
        if s.marked > 0 {
            let bar = CGRect(x: r.minX + 8, y: y - 12, width: r.width - 16, height: 24)
            var hl = ctx
            hl.blendMode = .multiply
            hl.clip(to: Self.stroke(bar))
            var x = bar.minX
            for (k, (_, n, _)) in items.enumerated() where n > 0 {
                let len = CGFloat(n) / CGFloat(s.marked) * bar.width
                hl.fill(Path(CGRect(x: x - 0.4, y: bar.minY - 2, width: len + 0.8, height: bar.height + 4)),
                        with: .color(concept.accent.opacity([0.62, 0.36, 0.2, 0.1][k])))
                x += len
            }
        } else {
            Self.hint(ctx, "할 일에 ○ △ × → 를 표시하면 세어 드려요", at: CGPoint(x: r.midX, y: y), size: 25)
        }
    }

    // MARK: calendar (잔디)

    private func drawCalendar(_ ctx: GraphicsContext) {
        // 요일 머리
        for i in 0..<7 {
            let c = HM.dayCell(i)
            ctx.draw(Text(HM.weekdays[i]).font(Fonts.print(14, .demiBold)).tracking(1.4)
                        .foregroundStyle(HM.weekdayColor(i)),
                     at: CGPoint(x: c.midX + 0.7, y: HM.calY0 - 20), anchor: .center)
        }
        let month = stats.month
        for (i, d) in stats.calendar.enumerated() {
            let r = HM.dayCell(i)
            let c = Dates.comp(d.date)
            // 줄 앞: 그 주 월요일 날짜
            if i % 7 == 0 {
                ctx.draw(Text("\(c.month!)/\(c.day!)").font(Fonts.hand(24)).foregroundStyle(Ink.soft),
                         at: CGPoint(x: HM.calX0 - 14, y: r.midY + 1), anchor: .trailing)
            }
            // 인쇄된 점선 칸
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 8), with: .color(Ink.dot),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [0.1, 5.4]))
            // 그날 기록만큼 그날 컨셉 색으로
            let lv = Self.level(d)
            if lv > 0 {
                let col = ColorConcept.of(d.theme ?? defaultTheme).accent
                var hl = ctx
                hl.blendMode = .multiply
                hl.fill(Path(roundedRect: r.insetBy(dx: 2, dy: 2), cornerRadius: 7),
                        with: .color(col.opacity(Self.grass[lv])))
            }
            let other = c.month != month
            let label = c.day == 1 ? "\(c.month!)/1" : "\(c.day!)"
            ctx.draw(Text(label).font(Fonts.hand(26))
                        .foregroundStyle(d.isFuture ? (lv > 0 ? Ink.soft : Ink.faint) : other ? Ink.soft : Ink.text),
                     at: CGPoint(x: r.minX + 9, y: r.minY + 16), anchor: .leading)
            if d.minutes > 0 {
                let t = fit(ctx, r.width - 12, size: 1) { k in
                    hm(d.minutes, 14.5 * k, unit: 9 * k).foregroundStyle(Ink.text.opacity(0.75))
                }
                ctx.draw(t, at: CGPoint(x: r.maxX - 6, y: r.maxY - 13), anchor: .trailing)
            }
            // 오늘: 펜으로 동그라미
            if d.isToday {
                var p = Path()
                p.addEllipse(in: r.insetBy(dx: -7, dy: -6))
                let t = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: -0.08)
                    .translatedBy(x: -r.midX, y: -r.midY)
                ctx.stroke(p.applying(t), with: .color(concept.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            }
        }

        // 범례 (칸 줄과 나란히): 0 · ~2H · ~4H · ~6H · 6H+
        let names = ["0", "~2H", "~4H", "~6H", "6H+"]
        let col = concept.accent
        for lv in 0..<5 {
            let row = HM.dayCell(lv * 7)
            let sq = CGRect(x: HM.legendX, y: row.midY - 25, width: 30, height: 30)
            if lv == 0 {
                ctx.stroke(Path(roundedRect: sq.insetBy(dx: 1, dy: 1), cornerRadius: 5), with: .color(Ink.dot),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.1, 4.6]))
            } else {
                var hl = ctx
                hl.blendMode = .multiply
                hl.fill(Path(roundedRect: sq, cornerRadius: 5), with: .color(col.opacity(Self.grass[lv])))
            }
            ctx.draw(Text(names[lv]).font(Fonts.print(13.5, .demiBold)).foregroundStyle(Ink.soft),
                     at: CGPoint(x: sq.midX, y: sq.maxY + 12), anchor: .center)
        }
    }

    private static let grass: [Double] = [0, 0.1, 0.2, 0.31, 0.44]

    /// 잔디 진하기: 0 없음, 1 ~2시간, 2 ~4시간, 3 ~6시간, 4 그 이상 (칠했지만 합계 제외 색뿐이면 1)
    private static func level(_ d: HomeStats.DayCell) -> Int {
        guard d.recorded else { return 0 }
        switch d.minutes {
        case ..<120: return 1
        case ..<240: return 2
        case ..<360: return 3
        default: return 4
        }
    }
}
