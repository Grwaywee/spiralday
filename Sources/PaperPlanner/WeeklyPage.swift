import SwiftUI
import AppKit

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

private enum WK {
    static let page = PageKind.weekly.design
    // 2 × 42 + 7 × 260 + 6 × 16 = 2000
    static let margin: CGFloat = 42
    static let gap: CGFloat = 16
    static let colW: CGFloat = 260
    static func colX(_ i: Int) -> CGFloat { margin + CGFloat(i) * (colW + gap) }

    // 머리줄: 칸 하나를 세로선으로 나눈 모양 두 개
    static let headTop: CGFloat = 86
    static let headH: CGFloat = 38
    /// MY GOAL │ 목표 — 월요일 왼쪽부터 금요일 오른쪽까지
    static let goalFrame = CGRect(x: margin, y: headTop, width: colX(4) + colW - margin, height: headH)
    static let goalSplit: CGFloat = margin + 130
    static let flagX: CGFloat = goalSplit + 20
    /// REVIEW OF THE WEEK │ 별 — 토요일 · 일요일 위, 가운데 세로선은 두 칸 사이
    static let reviewFrame = CGRect(x: colX(5), y: headTop, width: colX(6) + colW - colX(5), height: headH)
    static let reviewSplit: CGFloat = colX(6) - gap / 2
    static let starsBox = CGRect(x: reviewSplit, y: headTop, width: reviewFrame.maxX - reviewSplit, height: headH)

    // 요일 칸 — 아래 값은 칸 왼쪽 위 기준
    static let colTop: CGFloat = 156
    static let dayHeadH: CGFloat = 56
    static let taskH: CGFloat = 35
    static let taskLines = 10
    static let ttTop: CGFloat = dayHeadH + taskH * CGFloat(taskLines) + 16
    static let rowH: CGFloat = 24
    static let ttBottom: CGFloat = ttTop + rowH * 24
    static let boxBottom: CGFloat = ttBottom + 12
    /// 합계 아래 줄. 종이 아래 모서리의 넘김 영역(아래 58 단위) 보다 위에 둔다.
    static let footRule: CGFloat = 1214 - colTop
    static let pad: CGFloat = 12
    static let hourW: CGFloat = 26
    static let cellsX: CGFloat = pad + hourW
    /// (260 − 38 − 12) / 6 = 35
    static let cellW: CGFloat = (colW - cellsX - pad) / 6

    // 할 일 줄 안쪽
    static let tickX: CGFloat = 14
    static let textX: CGFloat = 24
    static let markSize: CGFloat = 19
    static let markMidX: CGFloat = colW - 26
    static let textEnd: CGFloat = colW - 44

    // 합계: 인쇄된 H / M 의 가운데, 손글씨는 그 앞 빈칸 가운데에 쓴다
    static let hX: CGFloat = 120
    static let mX: CGFloat = colW - 20
    static let hourSlot = CGRect(x: pad, y: footRule - 40, width: hX - 9 - pad, height: 44)
    static let minuteSlot = CGRect(x: hX + 9, y: footRule - 40, width: mX - 9 - (hX + 9), height: 44)

    static func taskY(_ i: Int) -> CGFloat { dayHeadH + taskH * CGFloat(i) }

    static let weekdays = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    static func weekdayColor(_ i: Int) -> Color { i == 5 ? Ink.saturday : i == 6 ? Ink.red : Ink.soft }
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
struct WeeklyPage: View {
    let weekStart: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let ws = weekStart
        let g = WK.goalFrame
        ZStack(alignment: .topLeading) {
            WeeklyForm(u: u).equatable()

            InlineField(text: store.weekField(ws, \.goal), placeholder: "이번 주 목표",
                        font: Fonts.hand(34 * u), key: "wg|\(Dates.key(ws))")
                .place(CGRect(x: WK.flagX + 26, y: g.minY - 3, width: g.maxX - 12 - (WK.flagX + 26), height: g.height + 6), u)

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

// MARK: - Day column (손글씨 부분)

private struct WeekDayColumn: View {
    let date: Date
    let u: CGFloat

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var hover = false

    var body: some View {
        let tasks = store.day(date).tasks
        let dk = Dates.key(date)
        ZStack(alignment: .topLeading) {
            header
            ForEach(0..<WK.taskLines, id: \.self) { i in
                taskLine(i, tasks, dk)
            }
            // 형광펜처럼 인쇄된 칸 선이 비쳐 보이게 종이와 곱하기로 합성
            SlotPainter(date: date, cellW: WK.cellW * u, rowH: WK.rowH * u)
                .blendMode(.multiply)
                .offset(x: WK.cellsX * u, y: WK.ttTop * u)
            footer
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
        }
        .frame(width: WK.colW * u, height: WK.dayHeadH * u, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { state.openDay(date) }
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .onDisappear { if hover { NSCursor.arrow.set() } }
        .help("이 날 일간 페이지 열기")
    }

    // 할 일 한 줄: 카테고리 색 표시 · 손글씨 · 펜 표시
    @ViewBuilder private func taskLine(_ i: Int, _ tasks: [PlanTask], _ dk: String) -> some View {
        let key = "t|\(dk)|\(i)"
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

        InlineField(text: store.taskText(d, i, defaultCat: { st.tool >= 0 ? st.tool : nil }),
                    font: Fonts.hand(30 * u),
                    key: key,
                    tapKey: task == nil ? "t|\(dk)|\(min(tasks.count, WK.taskLines - 1))" : nil,
                    onSubmit: {
                        if i + 1 < WK.taskLines { st.editingKey = "t|\(dk)|\(i + 1)" } else { st.endEditing() }
                    },
                    onEnd: { store.cleanup(d) })
            .contextMenu {
                // 편집 중에는 글상자 기본 메뉴(복사·붙여넣기)를 가리지 않는다
                if let task, st.editingKey != key { TaskMenu(date: d, task: task) }
            }
            .place(CGRect(x: WK.textX, y: y + 3,
                          width: WK.textEnd - WK.textX - (more > 0 ? 42 : 0), height: WK.taskH - 4), u)

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
            MarkButton(mark: task.mark, size: WK.markSize * u, color: Ink.pen,
                       lineWidth: max(1.1, 2.3 * u), showsPlaceholder: true) {
                store.cycleMark(d, task.id)
            }
            .offset(x: (WK.markMidX - WK.markSize / 2) * u, y: (y + (WK.taskH - WK.markSize) / 2 + 1) * u)
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

        // 분홍 깃발 (깃대 + 깃발)
        let x = WK.flagX, top = g.minY + 8, bottom = g.maxY - 7
        var pole = Path()
        pole.addRoundedRect(in: CGRect(x: x, y: top, width: 3, height: bottom - top), cornerSize: CGSize(width: 1.5, height: 1.5))
        ctx.fill(pole, with: .color(Ink.pen))
        var flag = Path()
        flag.move(to: CGPoint(x: x + 2, y: top))
        flag.addLine(to: CGPoint(x: x + 15, y: top))
        flag.addLine(to: CGPoint(x: x + 11.5, y: top + 5.5))
        flag.addLine(to: CGPoint(x: x + 15, y: top + 11))
        flag.addLine(to: CGPoint(x: x + 2, y: top + 11))
        flag.closeSubpath()
        ctx.fill(flag, with: .color(Ink.pen))

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
