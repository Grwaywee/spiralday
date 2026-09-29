import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// 주간 페이지 — 가로 2000 × 1277 디자인 단위, 스프링은 위쪽.
//
//   머리줄   [MY GOAL] ▮ 이번 주 목표 ──────   [REVIEW OF THE WEEK] 한 줄 평 ── ★★★★★
//   요일 칸  월 → 일 7칸. 칸마다 날짜·요일 / 할 일 10줄 / 타임테이블 24행 × 10분 6칸
//   합계     칸 아래에 "10 H 50 M" + 줄
//
// 인쇄된 양식(선, 라벨, 시간 숫자)은 u 로 스케일한 Canvas 한 장에 그리고
// (데이터와 무관해서 u 가 바뀔 때만 다시 그린다), 손글씨·펜 표시·형광펜 칸은
// 그 위에 디자인 단위 × u 위치로 올린다.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Layout (디자인 단위)

private enum WK {
    static let page = PageKind.weekly.design
    static let margin: CGFloat = 40
    static let gap: CGFloat = 16
    static let colW: CGFloat = (page.width - 2 * margin - 6 * gap) / 7
    static func colX(_ i: Int) -> CGFloat { margin + CGFloat(i) * (colW + gap) }

    // 머리줄: 목표는 월–목, 리뷰는 금–일 칸 위에 맞춘다
    static let headTop: CGFloat = 86
    static let headRule: CGFloat = 124
    static let goalBox = CGRect(x: margin, y: headTop, width: 118, height: headRule - headTop)
    static let goalEnd = colX(3) + colW
    static let reviewBox = CGRect(x: colX(4), y: headTop, width: 212, height: headRule - headTop)
    static let pageEnd = page.width - margin
    static let starsW: CGFloat = 150

    // 요일 칸 — 아래 값은 칸 왼쪽 위 기준
    static let colTop: CGFloat = 156
    static let dayHeadH: CGFloat = 56
    static let taskH: CGFloat = 35
    static let taskLines = 10
    static let ttTop: CGFloat = dayHeadH + taskH * CGFloat(taskLines) + 16
    static let rowH: CGFloat = 24.25
    static let ttBottom: CGFloat = ttTop + rowH * 24
    static let boxBottom: CGFloat = ttBottom + 12
    /// 합계 아래 줄 (종이 아래 여백 36)
    static let footRule: CGFloat = page.height - 36 - colTop
    static let footMid: CGFloat = (boxBottom + footRule) / 2
    static let pad: CGFloat = 12
    static let hourW: CGFloat = 28
    static let cellsX: CGFloat = pad + hourW
    static let cellW: CGFloat = (colW - cellsX - pad) / 6

    // 할 일 줄 안쪽
    static let tickX: CGFloat = 14
    static let textX: CGFloat = 24
    static let markSize: CGFloat = 19
    static let markMidX: CGFloat = colW - 26
    static let textEnd: CGFloat = colW - 44

    // 합계 (인쇄된 H / M 의 가운데)
    static let hX: CGFloat = colW * 0.42
    static let mX: CGFloat = colW * 0.71

    static func taskY(_ i: Int) -> CGFloat { dayHeadH + taskH * CGFloat(i) }

    static let weekdays = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    static func weekdayColor(_ i: Int) -> Color { i == 5 ? Ink.saturday : i == 6 ? Ink.red : Ink.print }
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
        let k = Dates.key(weekStart)
        let ws = weekStart
        ZStack(alignment: .topLeading) {
            WeeklyForm(u: u).equatable()

            InlineField(text: store.weekField(ws, \.goal), placeholder: "이번 주 목표",
                        font: Fonts.hand(37 * u), key: "wg|\(k)")
                .place(CGRect(x: WK.goalBox.maxX + 50, y: WK.headTop - 9,
                              width: WK.goalEnd - WK.goalBox.maxX - 58, height: 48), u)

            InlineField(text: store.weekField(ws, \.review), placeholder: "한 줄 돌아보기",
                        font: Fonts.hand(33 * u), key: "wr|\(k)")
                .place(CGRect(x: WK.reviewBox.maxX + 20, y: WK.headTop - 9,
                              width: WK.pageEnd - WK.starsW - WK.reviewBox.maxX - 34, height: 48), u)

            Stars(value: store.week(ws).stars, size: 21 * u) { v in store.editWeek(ws) { $0.stars = v } }
                .place(CGRect(x: WK.pageEnd - WK.starsW, y: WK.headTop - 4,
                              width: WK.starsW - 4, height: WK.headRule - WK.headTop), u, alignment: .trailing)

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
    @ViewBuilder private func taskLine(_ i: Int, _ tasks: [PlanTask]) -> some View {
        let dk = Dates.key(date)
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

    // 하루 합계: 손글씨 숫자 + 인쇄된 H / M
    @ViewBuilder private var footer: some View {
        let total = store.minutes(date)
        if total > 0 {
            let (h, m) = formatHM(total)
            let top = WK.footMid - 25
            Text(h)
                .font(Fonts.hand(40 * u))
                .foregroundStyle(Ink.text)
                .place(CGRect(x: 0, y: top, width: WK.hX - 11, height: 44), u, alignment: .trailing)
            Text(m)
                .font(Fonts.hand(40 * u))
                .foregroundStyle(Ink.text)
                .place(CGRect(x: WK.hX + 11, y: top, width: WK.mX - WK.hX - 22, height: 44), u, alignment: .trailing)
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
            Self.drawHeader(ctx)
            for i in 0..<7 { Self.drawColumn(ctx, i) }
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

    /// 인쇄 글자. tracking 은 마지막 글자 뒤에도 붙으므로 기준점을 그만큼 보정한다.
    private static func label(_ ctx: GraphicsContext, _ s: String, size: CGFloat,
                              weight: Fonts.PrintWeight = .demiBold, tracking: CGFloat = 0,
                              color: Color = Ink.print, at p: CGPoint, anchor: UnitPoint) {
        let t = Text(s).font(Fonts.print(size, weight)).tracking(tracking).foregroundStyle(color)
        let shift = tracking * (1 - anchor.x)
        ctx.draw(t, at: CGPoint(x: p.x + shift, y: p.y), anchor: anchor)
    }

    // MARK: header

    private static func drawHeader(_ ctx: GraphicsContext) {
        let y = WK.headRule
        // MY GOAL ── 목표 줄
        let g = WK.goalBox
        ctx.stroke(Path(g), with: .color(Ink.print), lineWidth: 1.3)
        label(ctx, "MY GOAL", size: 13, tracking: 2.2, at: CGPoint(x: g.midX, y: g.midY + 0.5), anchor: .center)
        line(ctx, CGPoint(x: g.maxX, y: y), CGPoint(x: WK.goalEnd, y: y), Ink.print, 1.3)
        // 분홍 책갈피 표시
        let f = CGRect(x: g.maxX + 20, y: g.minY + 5, width: 15, height: 24)
        var flag = Path()
        flag.move(to: CGPoint(x: f.minX, y: f.minY))
        flag.addLine(to: CGPoint(x: f.maxX, y: f.minY))
        flag.addLine(to: CGPoint(x: f.maxX, y: f.maxY))
        flag.addLine(to: CGPoint(x: f.midX, y: f.maxY - 6))
        flag.addLine(to: CGPoint(x: f.minX, y: f.maxY))
        flag.closeSubpath()
        ctx.fill(flag, with: .color(Ink.pen))

        // REVIEW OF THE WEEK ── 한 줄 평 ── 별
        let r = WK.reviewBox
        ctx.stroke(Path(r), with: .color(Ink.print), lineWidth: 1.3)
        label(ctx, "REVIEW OF THE WEEK", size: 13, tracking: 2.2, at: CGPoint(x: r.midX, y: r.midY + 0.5), anchor: .center)
        line(ctx, CGPoint(x: r.maxX, y: y), CGPoint(x: WK.pageEnd, y: y), Ink.print, 1.3)
    }

    // MARK: day column

    private static func drawColumn(_ ctx: GraphicsContext, _ i: Int) {
        var c = ctx
        c.translateBy(x: WK.colX(i), y: WK.colTop)
        let w = WK.colW

        // 칸 테두리
        c.stroke(Path(CGRect(x: 0, y: 0, width: w, height: WK.boxBottom)), with: .color(Ink.rule), lineWidth: 1.4)

        // 요일 + 굵은 줄
        label(c, WK.weekdays[i], size: 12, tracking: 2.4, color: WK.weekdayColor(i),
              at: CGPoint(x: w - 15, y: WK.dayHeadH * 0.56), anchor: .trailing)
        line(c, CGPoint(x: 10, y: WK.dayHeadH), CGPoint(x: w - 10, y: WK.dayHeadH), Ink.print, 1.7)

        // 할 일 줄
        for k in 1...WK.taskLines {
            let y = WK.taskY(k)
            line(c, CGPoint(x: WK.pad, y: y), CGPoint(x: w - WK.pad, y: y), Ink.rule, 1)
        }

        // 타임테이블: 가로 줄 · 10분 점선 · 시간 칸 구분선 · 시간 숫자
        let left = WK.pad, right = w - WK.pad
        for r in 0...24 {
            let y = WK.ttTop + CGFloat(r) * WK.rowH
            let edge = r == 0 || r == 24
            line(c, CGPoint(x: left, y: y), CGPoint(x: right, y: y), edge ? Ink.print : Ink.rule, edge ? 1.3 : 1)
        }
        for k in 1...5 {
            let x = WK.cellsX + CGFloat(k) * WK.cellW
            line(c, CGPoint(x: x, y: WK.ttTop + 2), CGPoint(x: x, y: WK.ttBottom - 2), Ink.dot, 1, dash: [0.1, 3.2])
        }
        line(c, CGPoint(x: WK.cellsX, y: WK.ttTop), CGPoint(x: WK.cellsX, y: WK.ttBottom), Ink.print, 1.2)
        for r in 0..<24 {
            label(c, SlotPainter.hourLabel(r), size: 12, weight: .bold,
                  at: CGPoint(x: WK.pad + WK.hourW / 2, y: WK.ttTop + (CGFloat(r) + 0.5) * WK.rowH + 0.5),
                  anchor: .center)
        }

        // 합계: H / M 과 아래 줄
        let fy = WK.footMid + 7
        label(c, "H", size: 12, at: CGPoint(x: WK.hX, y: fy), anchor: .center)
        label(c, "M", size: 12, at: CGPoint(x: WK.mX, y: fy), anchor: .center)
        line(c, CGPoint(x: 6, y: WK.footRule), CGPoint(x: w - 6, y: WK.footRule), Ink.print, 1.3)
    }
}
