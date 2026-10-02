import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// 주간 페이지 — 가로 2000 × 1277 디자인 단위, 스프링은 위쪽.
//
//   머리줄   [MY GOAL │ ⚑ 이번 주 목표 ········]  (월–금 위)   [REVIEW OF THE WEEK │ ★★★★★]  (토–일 위)
//   요일 칸  월 → 일 7칸. 칸마다 날짜·요일 / 할 일 10줄 / 타임테이블 24행 × 10분 6칸
//   합계     칸 아래에 "10 H 50 M" + 줄
//
// 인쇄된 양식(선, 라벨, 시간 숫자)은 u 로 스케일한 Canvas 한 장에 그리고
// (데이터와 무관해서 u 가 바뀔 때만 다시 그린다), 손글씨·펜 표시·형광펜 칸은
// 그 위에 디자인 단위 × u 위치로 올린다.
//
// 좌표는 모두 정수 디자인 단위라서 1× 스냅샷에서 선이 픽셀 한 줄에 딱 맞는다.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Layout (디자인 단위)

public enum WK {
    public static let page = PageKind.weekly.design
    // 2 × 42 + 7 × 260 + 6 × 16 = 2000
    public static let margin: CGFloat = 42
    public static let gap: CGFloat = 16
    public static let colW: CGFloat = 260
    public static func colX(_ i: Int) -> CGFloat { margin + CGFloat(i) * (colW + gap) }

    // 세로 배치 (1.0.5 에서 위아래 여백을 48 줄이고 그만큼 타임테이블 행을 24 → 26 으로 키웠다)
    //   0–60     위 여백 (스프링 구멍 9–21, 가장 작은 창에서도 창 버튼 아래)
    //   60–98    머리줄
    //   116–1174 요일 칸 (날짜 56 · 할 일 350 · 16 · 타임테이블 26 × 24 = 624 · 12)
    //   1218     합계 줄 — 그 아래 59 는 넘김 모서리 자리

    // 머리줄: 칸 하나를 세로선으로 나눈 모양 두 개
    public static let headTop: CGFloat = 60
    public static let headH: CGFloat = 38
    /// MY GOAL │ 목표 — 월요일 왼쪽부터 금요일 오른쪽까지
    public static let goalFrame = CGRect(x: margin, y: headTop, width: colX(4) + colW - margin, height: headH)
    public static let goalSplit: CGFloat = margin + 130
    /// 목표 글 시작 (앞에 ┌ 강조 표시 자리)
    public static let goalTextX: CGFloat = goalSplit + 34
    /// REVIEW OF THE WEEK │ 별 — 토요일 · 일요일 위, 가운데 세로선은 두 칸 사이
    public static let reviewFrame = CGRect(x: colX(5), y: headTop, width: colX(6) + colW - colX(5), height: headH)
    public static let reviewSplit: CGFloat = colX(6) - gap / 2
    public static let starsBox = CGRect(x: reviewSplit, y: headTop, width: reviewFrame.maxX - reviewSplit, height: headH)

    // 요일 칸 — 아래 값은 칸 왼쪽 위 기준
    public static let colTop: CGFloat = headTop + headH + 18
    public static let dayHeadH: CGFloat = 56
    public static let taskH: CGFloat = 35
    public static let taskLines = 10
    public static let ttTop: CGFloat = dayHeadH + taskH * CGFloat(taskLines) + 16
    public static let rowH: CGFloat = 26
    public static let ttBottom: CGFloat = ttTop + rowH * 24
    public static let boxBottom: CGFloat = ttBottom + 12
    /// 합계 아래 줄. 종이 아래 모서리의 넘김 영역(1219 부터 아래 58 단위) 보다 위에 둔다.
    public static let footRule: CGFloat = 1218 - colTop
    public static let pad: CGFloat = 12
    public static let hourW: CGFloat = 26
    public static let cellsX: CGFloat = pad + hourW
    /// (260 − 38 − 12) / 6 = 35
    public static let cellW: CGFloat = (colW - cellsX - pad) / 6

    // 할 일 줄 안쪽
    public static let tickX: CGFloat = 14
    public static let textX: CGFloat = 24
    public static let markSize: CGFloat = 19
    public static let markMidX: CGFloat = colW - 26
    public static let textEnd: CGFloat = colW - 44

    // 합계: 인쇄된 H / M 의 가운데, 손글씨는 그 앞 빈칸 가운데에 쓴다
    public static let hX: CGFloat = 120
    public static let mX: CGFloat = colW - 20
    public static let hourSlot = CGRect(x: pad, y: footRule - 40, width: hX - 9 - pad, height: 44)
    public static let minuteSlot = CGRect(x: hX + 9, y: footRule - 40, width: mX - 9 - (hX + 9), height: 44)

    public static func taskY(_ i: Int) -> CGFloat { dayHeadH + taskH * CGFloat(i) }
    /// 할 일 줄의 점선 체크 박스 (칸 기준 좌표). 일간과 같은 비율 (줄 높이의 0.57)
    public static func box(_ i: Int) -> CGRect {
        let s = (taskH * 0.57).rounded()
        return CGRect(x: markMidX - s / 2, y: taskY(i) + (taskH - s) / 2, width: s, height: s)
    }

    public static let weekdays = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    public static func weekdayColor(_ i: Int) -> Color { i == 5 ? Ink.saturday : i == 6 ? Ink.red : Ink.soft }
    /// DAY OFF 꼬리표의 세로 가운데 (칸 위 테두리와 인쇄된 요일 사이, 요일 가운데는 dayHeadH × 0.56)
    public static let dayOffTagMidY: CGFloat = 13
}

/// 쉬는 날 꼬리표: 인쇄 글자 "DAY OFF" 를 그날 컬러 테두리로 감싼다
private struct DayOffTag: View {
    let color: Color
    let u: CGFloat

    var body: some View {
        Text("DAY OFF")
            .font(Fonts.print(10 * u, .bold))
            .tracking(1.2 * u)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 5 * u)
            .padding(.trailing, 3.8 * u)
            .padding(.vertical, 1.2 * u)
            .background(RoundedRectangle(cornerRadius: 3 * u).fill(color.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 3 * u).stroke(color, lineWidth: max(0.6, 1.1 * u)))
            .allowsHitTesting(false)
    }
}

private extension View {
    /// 디자인 단위 사각형 자리에 놓는다 (부모는 topLeading ZStack)
    func place(_ r: CGRect, _ u: CGFloat, alignment: Alignment = .leading) -> some View {
        frame(width: r.width * u, height: r.height * u, alignment: alignment)
            .offset(x: r.minX * u, y: r.minY * u)
    }
}

// MARK: - Page

/// 주간 페이지 (디자인 2000 × 1277).
public struct WeeklyPage: View {
    public let weekStart: Date
    public let u: CGFloat

    @EnvironmentObject private var store: PlannerStore

    public init(weekStart: Date, u: CGFloat) {
        self.weekStart = weekStart
        self.u = u
    }

    public var body: some View {
        let ws = weekStart
        let g = WK.goalFrame
        ZStack(alignment: .topLeading) {
            WeeklyForm(u: u).equatable()

            GoalField(weekStart: ws, u: u)
                .place(CGRect(x: WK.goalTextX, y: g.minY - 3, width: g.maxX - 24 - WK.goalTextX, height: g.height + 6), u)

            Stars(value: store.week(ws).stars, size: 23 * u) { v in store.editWeek(ws) { $0.stars = v } }
                .place(WK.starsBox.insetBy(dx: 8, dy: 2), u, alignment: .center)

            ForEach(0..<7, id: \.self) { i in
                WeekDayColumn(date: Dates.add(days: i, to: ws), u: u)
                    .offset(x: WK.colX(i) * u, y: WK.colTop * u)
            }
        }
        .frame(width: WK.page.width * u, height: WK.page.height * u, alignment: .topLeading)
    }
}

// MARK: - Goal (강조 꺾쇠 ┌ … ┘)

/// 이번 주 목표. 글 앞 왼쪽 위에 ┌, 글 끝 오른쪽 아래에 ┘ 를 펜으로 그어 강조한다.
private struct GoalField: View {
    let weekStart: Date
    let u: CGFloat
    @EnvironmentObject private var store: PlannerStore

    static let font: CGFloat = 34

    var body: some View {
        let text = store.week(weekStart).goal
        let w = RuledText.width(text, fontSize: Self.font)
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .topLeading) {
                InlineField(text: store.weekField(weekStart, \.goal), placeholder: "이번 주 목표",
                            font: Fonts.hand(Self.font * u), key: "wg|\(Dates.key(weekStart))")
                if !text.isEmpty {
                    let arm = 13 * u, lw = 3.2 * u
                    let top = h * 0.12, bottom = h * 0.9
                    let endX = min(w * u + 8 * u, g.size.width + 14 * u)
                    Path { p in
                        // ┌ 글 앞 왼쪽 위
                        p.move(to: CGPoint(x: -12 * u, y: top + arm))
                        p.addLine(to: CGPoint(x: -12 * u, y: top))
                        p.addLine(to: CGPoint(x: -12 * u + arm, y: top))
                        // ┘ 글 끝 오른쪽 아래
                        p.move(to: CGPoint(x: endX, y: bottom - arm))
                        p.addLine(to: CGPoint(x: endX, y: bottom))
                        p.addLine(to: CGPoint(x: endX - arm, y: bottom))
                    }
                    .stroke(Ink.pen, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Day column (손글씨 부분)

private struct WeekDayColumn: View {
    let date: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hover = false

    var body: some View {
        let tasks = store.day(date).tasks
        ZStack(alignment: .topLeading) {
            header
            ForEach(0..<WK.taskLines, id: \.self) { i in
                taskLine(i, tasks)
            }
            // 형광펜처럼 인쇄된 칸 선이 비쳐 보이게 종이와 곱하기로 합성
            SlotPainter(date: date, cellW: WK.cellW * u, rowH: WK.rowH * u)
                .blendMode(.multiply)
                .offset(x: WK.cellsX * u, y: WK.ttTop * u)
            footer
            // 이 플래너의 기간 밖인 날: 흐리게, 쓸 수 없게
            if !(store.activeBook?.contains(date) ?? true) {
                Ink.paper.opacity(0.78)
                    .frame(width: WK.colW * u, height: (WK.footRule + 2) * u)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .help("이 플래너의 기간이 아닌 날이에요")
            }
        }
        .frame(width: WK.colW * u, height: (WK.footRule + 2) * u, alignment: .topLeading)
    }

    // 날짜 머리: 누르면 그날 일간 페이지로
    private var header: some View {
        let c = Dates.comp(date)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5 * u)
                .fill(Ink.pen.opacity(hover ? 0.08 : 0))
                .padding(5 * u)
            HStack(alignment: .center, spacing: 9 * u) {
                Text("\(c.month ?? 0)/\(c.day ?? 0)")
                    .font(Fonts.hand(40 * u))
                    .foregroundStyle(Ink.text)
                    .background(alignment: .bottom) {
                        if Dates.isToday(date) {
                            HighlighterBar(color: Ink.pen.opacity(0.62))
                                .frame(height: 13 * u)
                                .padding(.horizontal, -6 * u)
                                .offset(y: -3 * u)
                        }
                    }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13 * u, weight: .semibold))
                    .foregroundStyle(Ink.pen)
                    .opacity(hover ? 1 : 0)
                    .offset(x: hover ? 0 : -4 * u, y: -1 * u)
            }
            .frame(height: WK.dayHeadH * u)
            .offset(x: 16 * u, y: 1 * u)
            // 쉬는 날: 인쇄된 요일 위에 작은 DAY OFF 꼬리표 (그날 컬러)
            if store.day(date).dayOff {
                DayOffTag(color: store.concept(date).accent, u: u)
                    .frame(width: (WK.colW - WK.pad - 3) * u, height: WK.dayOffTagMidY * 2 * u, alignment: .trailing)
            }
        }
        .frame(width: WK.colW * u, height: WK.dayHeadH * u, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { state.openDay(date) }
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
        .pointerCursor(.pointingHand)
        .onDisappear { if hover { PointerCursor.arrow.set() } }
        .help("이 날 일간 페이지 열기")
    }

    // 할 일 한 줄: 카테고리 색 표시 · 손글씨 · 펜 표시.
    // 그날 할 일을 일간의 줄 순서대로, 빈 줄은 건너뛰고 위에서부터 채운다 (tasks 는 줄 순서).
    @ViewBuilder private func taskLine(_ i: Int, _ tasks: [PlanTask]) -> some View {
        let task: PlanTask? = i < tasks.count ? tasks[i] : nil
        let more = i == WK.taskLines - 1 ? tasks.count - WK.taskLines : 0
        let y = WK.taskY(i)
        let st = state
        let d = date

        if let task, let cat = store.category(task.cat) {
            RoundedRectangle(cornerRadius: 1.6 * u)
                .fill(cat.color)
                .frame(width: 4 * u, height: 17 * u)
                .offset(x: WK.tickX * u, y: (y + 11) * u)
        }
        // 왼쪽 색 막대 자리: 누르면 형광펜(분류) 메뉴 (화면에서만)
        if let task, !isSnapshot {
            TaskCategoryCell(date: d, taskID: task.id, cornerRadius: 3 * u)
                .place(CGRect(x: WK.tickX - 8, y: y + 3, width: WK.textX - WK.tickX + 6, height: WK.taskH - 6), u)
        }

        if let task {
            let key = AppState.taskKey(d, task.id)
            // 한 줄에 다 들어가도록 필요한 만큼 글씨를 줄인다
            let textW = WK.textEnd - WK.textX - (more > 0 ? 42 : 0)
            let fit = RuledText.oneLineScale(task.text, fontSize: 28, width: textW - 6)
            let cat = store.category(task.cat)
            InlineField(text: store.taskText(d, id: task.id),
                        font: Fonts.hand(28 * fit * u),
                        key: key,
                        // 형광펜은 끝낸(○) 일에만, 그 할 일의 형광펜 색으로 (형광펜이 없으면 긋지 않는다)
                        highlight: task.mark == .done ? cat?.color : nil,
                        onSubmit: { Self.submit(store, st, d, after: task.id) },
                        onEnd: { store.afterEditing { store.cleanup(d, keep: st.editingTaskID(on: d)) } })
                .contextMenu {
                    // 편집 중에는 글상자 기본 메뉴(복사·붙여넣기)를 가리지 않는다
                    if st.editingKey != key { TaskMenu(date: d, task: task) }
                }
                .place(CGRect(x: WK.textX, y: y + 3, width: textW, height: WK.taskH - 4), u)
        } else {
            // 빈 줄: 누르면 일간에서 마지막으로 쓴 줄 다음의 빈 줄에 새 할 일 → 이 칸의 첫 빈 줄에서 쓴다
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { st.editingKey = AppState.taskKey(d, store.addTaskAfterLast(d)) }
                .place(CGRect(x: WK.textX, y: y + 3, width: WK.textEnd - WK.textX, height: WK.taskH - 4), u)
        }

        if more > 0 {
            Text("+\(more)")
                .font(Fonts.print(12.5 * u, .bold))
                .foregroundStyle(Ink.pen)
                .padding(.horizontal, 7 * u)
                .frame(height: 21 * u)
                .background(Capsule().fill(Ink.pen.opacity(0.1)))
                .overlay(Capsule().stroke(Ink.pen.opacity(0.55), lineWidth: max(0.7, 1.1 * u)))
                .contentShape(Capsule())
                .onTapGesture { state.openDay(d) }
                .help("할 일 \(more)개 더 — 일간 페이지에서 보기")
                .place(CGRect(x: WK.textEnd - 40, y: y + 7.5, width: 40, height: 20), u, alignment: .center)
        }

        if let task {
            // 일간과 같은 펜 표시: 점선 박스 한가운데, 그날 컬러, 같은 굵기 비율
            let b = WK.box(i)
            MarkButton(mark: task.mark, size: b.width * 0.98 * u, color: store.concept(d).accent,
                       lineWidth: b.width * 0.133 * u, showsPlaceholder: false) {
                // → 로 다음 날 칸에 할 일이 늘거나 줄 수 있어서, 그 칸을 쓰는 중이면 먼저 끝낸다
                st.endEditingTasks(on: Dates.add(days: 1, to: d))
                store.cycleMark(d, task.id)
            }
            .position(x: b.midX * u, y: b.midY * u)
        }
    }

    /// Return: 아래 칸에 할 일이 있으면 그 할 일을 이어서 쓰고, 비어 있으면 새 할 일 (형광펜이 있으면 같은 형광펜).
    /// 마지막 칸이면 쓰기를 마친다.
    private static func submit(_ store: PlannerStore, _ state: AppState, _ d: Date, after id: UUID) {
        let tasks = store.day(d).tasks
        guard let i = tasks.firstIndex(where: { $0.id == id }), i + 1 < WK.taskLines else { state.endEditing(); return }
        if i + 1 < tasks.count {
            state.editingKey = AppState.taskKey(d, tasks[i + 1].id)
        } else {
            state.editingKey = AppState.taskKey(d, store.addTaskAfterLast(d, cat: tasks[i].cat))
        }
    }

    // 하루 합계: 손글씨 숫자 (인쇄된 H / M 앞 빈칸 가운데, 줄 위에 얹힌다)
    @ViewBuilder private var footer: some View {
        let total = store.minutes(date)
        if total > 0 {
            let (h, m) = formatHM(total)
            Text(h)
                .font(Fonts.hand(40 * u))
                .foregroundStyle(Ink.text)
                .place(WK.hourSlot, u, alignment: .center)
            Text(m)
                .font(Fonts.hand(40 * u))
                .foregroundStyle(Ink.text)
                .place(WK.minuteSlot, u, alignment: .center)
        }
    }
}

// MARK: - Printed form

/// 인쇄된 양식 전체. 데이터와 무관하므로 u 가 바뀔 때만 다시 그린다.
private struct WeeklyForm: View, Equatable {
    let u: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: u, y: u)
            // 정수 좌표의 1 단위 선이 1× 에서 두 픽셀로 번지지 않게 픽셀 가운데로
            ctx.translateBy(x: 0.5, y: 0.5)
            let t = Labels(ctx)
            Self.drawHeader(ctx, t)
            for i in 0..<7 { Self.drawColumn(ctx, i, t) }
        }
        .allowsHitTesting(false)
    }

    // MARK: primitives

    private static func line(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint,
                             _ color: Color, _ width: CGFloat, dash: [CGFloat] = []) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: dash.isEmpty ? .butt : .round, dash: dash))
    }

    /// 인쇄 글자는 한 번만 resolve 해서 일곱 칸에 같이 쓴다 (시간 숫자만 24 × 7 번 그려진다).
    private struct Labels {
        let hours: [PrintLabel]
        let weekdays: [PrintLabel]
        let goal, review, h, m: PrintLabel

        init(_ ctx: GraphicsContext) {
            hours = (0..<24).map { PrintLabel(ctx, SlotPainter.hourLabel($0), size: 12, weight: .demiBold, color: Ink.print) }
            weekdays = WK.weekdays.indices.map {
                PrintLabel(ctx, WK.weekdays[$0], size: 12, tracking: 2.4, color: WK.weekdayColor($0))
            }
            goal = PrintLabel(ctx, "MY GOAL", size: 12.5, tracking: 2.2)
            review = PrintLabel(ctx, "REVIEW OF THE WEEK", size: 12.5, tracking: 2.2)
            h = PrintLabel(ctx, "H", size: 12)
            m = PrintLabel(ctx, "M", size: 12)
        }
    }

    /// 인쇄 글자. tracking 은 마지막 글자 뒤에도 붙으므로 그 몫만큼 기준점을 옮겨 잉크 기준으로 맞춘다.
    private struct PrintLabel {
        let text: GraphicsContext.ResolvedText
        let tracking: CGFloat

        init(_ ctx: GraphicsContext, _ s: String, size: CGFloat, weight: Fonts.PrintWeight = .demiBold,
             tracking: CGFloat = 0, color: Color = Ink.soft) {
            text = ctx.resolve(Text(s).font(Fonts.print(size, weight)).tracking(tracking).foregroundStyle(color))
            self.tracking = tracking
        }

        func draw(_ ctx: GraphicsContext, at p: CGPoint, anchor: UnitPoint) {
            ctx.draw(text, at: CGPoint(x: p.x + tracking * anchor.x, y: p.y), anchor: anchor)
        }
    }

    // MARK: header

    private static func drawHeader(_ ctx: GraphicsContext, _ t: Labels) {
        let box = Ink.dot, bw: CGFloat = 1

        // [MY GOAL │ ⚑ ……]
        let g = WK.goalFrame
        ctx.stroke(Path(g), with: .color(box), lineWidth: bw)
        line(ctx, CGPoint(x: WK.goalSplit, y: g.minY), CGPoint(x: WK.goalSplit, y: g.maxY), box, bw)
        t.goal.draw(ctx, at: CGPoint(x: (g.minX + WK.goalSplit) / 2, y: g.midY), anchor: .center)

        // [REVIEW OF THE WEEK │ ★★★★★]
        let r = WK.reviewFrame
        ctx.stroke(Path(r), with: .color(box), lineWidth: bw)
        line(ctx, CGPoint(x: WK.reviewSplit, y: r.minY), CGPoint(x: WK.reviewSplit, y: r.maxY), box, bw)
        t.review.draw(ctx, at: CGPoint(x: (r.minX + WK.reviewSplit) / 2, y: r.midY), anchor: .center)
    }

    // MARK: day column

    private static func drawColumn(_ ctx: GraphicsContext, _ i: Int, _ t: Labels) {
        var c = ctx
        c.translateBy(x: WK.colX(i), y: WK.colTop)
        let w = WK.colW, left = WK.pad, right = w - WK.pad

        // 칸 테두리
        c.stroke(Path(CGRect(x: 0, y: 0, width: w, height: WK.boxBottom)), with: .color(Ink.rule), lineWidth: 1.2)

        // 요일 + 머리 아래 줄
        t.weekdays[i].draw(c, at: CGPoint(x: right - 3, y: WK.dayHeadH * 0.56), anchor: .trailing)
        line(c, CGPoint(x: left, y: WK.dayHeadH), CGPoint(x: right, y: WK.dayHeadH), Ink.soft, 1.2)

        // 할 일 줄
        for k in 1...WK.taskLines {
            let y = WK.taskY(k)
            line(c, CGPoint(x: left, y: y), CGPoint(x: right, y: y), Ink.rule, 1)
        }
        // 일간과 같은 점선 체크 박스 (한 변에 점 7개)
        for k in 0..<WK.taskLines {
            let b = WK.box(k)
            let step = b.width / 6
            let dot: CGFloat = 1.7
            var p = Path()
            for j in 0...6 {
                let o = CGFloat(j) * step
                for pt in [CGPoint(x: b.minX + o, y: b.minY), CGPoint(x: b.minX + o, y: b.maxY),
                           CGPoint(x: b.minX, y: b.minY + o), CGPoint(x: b.maxX, y: b.minY + o)] {
                    p.addEllipse(in: CGRect(x: pt.x - dot / 2, y: pt.y - dot / 2, width: dot, height: dot))
                }
            }
            c.fill(p, with: .color(Ink.dot))
        }

        // 타임테이블: 가로 줄 · 10분 점선 · 시간 칸 구분선 · 시간 숫자
        for r in 0...24 {
            let y = WK.ttTop + CGFloat(r) * WK.rowH
            let edge = r == 0 || r == 24
            line(c, CGPoint(x: left, y: y), CGPoint(x: right, y: y), edge ? Ink.print : Ink.rule, edge ? 1.3 : 1)
        }
        for k in 1...5 {
            let x = WK.cellsX + CGFloat(k) * WK.cellW
            line(c, CGPoint(x: x, y: WK.ttTop + 2), CGPoint(x: x, y: WK.ttBottom - 2), Ink.dot, 1, dash: [0.1, 3])
        }
        line(c, CGPoint(x: WK.cellsX, y: WK.ttTop), CGPoint(x: WK.cellsX, y: WK.ttBottom), Ink.print, 1.2)
        for r in 0..<24 {
            t.hours[r].draw(c, at: CGPoint(x: left + WK.hourW / 2, y: WK.ttTop + (CGFloat(r) + 0.5) * WK.rowH),
                            anchor: .center)
        }

        // 합계: H / M 과 아래 줄
        let fy = WK.footRule - 9.5
        t.h.draw(c, at: CGPoint(x: WK.hX, y: fy), anchor: .center)
        t.m.draw(c, at: CGPoint(x: WK.mX, y: fy), anchor: .center)
        line(c, CGPoint(x: left, y: WK.footRule), CGPoint(x: right, y: WK.footRule), Ink.dot, 1.1)
    }
}
