import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// 일간 페이지. 모든 좌표는 디자인 단위(1277 × 2000).
// 선은 모두 수평·수직으로 곧게 그린다.
//
//   왼쪽 블록  : 한 줄 76.12 짜리 19줄 격자 (TASKS 15줄 · MEMO 머리 1줄 · MEMO 3줄)
//   타임테이블 : 같은 높이를 24줄 (06시 → 다음날 05시), 56.27 폭 7칸 (시각 1칸 + 10분 6칸)
// ─────────────────────────────────────────────────────────────────────────────

enum DailyForm {
    // MARK: 세로 위치
    /// (양식 위 빈 여백에 추가) DATE / D-DAY 머리선. 칸은 이 선과 COMMENT 머리선 사이.
    static let dateRuleY: CGFloat = 72
    /// COMMENT / TOTAL TIME 머리선 — DATE 칸과 COMMENT 칸의 높이가 같도록 DATE 머리선과 닫는 선의 한가운데
    static var headerY: CGFloat { (dateRuleY + closeY) / 2 }
    /// 두 칸을 닫는 선
    static let closeY: CGFloat = 366.7
    /// TASKS / TIMETABLE 머리선 = 격자 맨 위
    static let gridTop: CGFloat = 444.5
    /// 왼쪽 블록 한 줄 높이
    static let pitch: CGFloat = 76.12
    static let leftRows = 19
    static let taskCount = 15
    static let memoCount = 3
    /// MEMO 머리선이 있는 줄 (0 = gridTop)
    static let memoRow = 16
    static var gridBottom: CGFloat { gridTop + CGFloat(leftRows) * pitch }
    /// 타임테이블 한 줄 높이 (왼쪽 19줄 높이를 24줄로)
    static var hourPitch: CGFloat { (gridBottom - gridTop) / 24 }

    static func lineY(_ row: Int) -> CGFloat { gridTop + CGFloat(row) * pitch }
    static func hourY(_ row: Int) -> CGFloat { gridTop + CGFloat(row) * hourPitch }

    // MARK: 가로 위치
    /// 왼쪽 블록 (선의 시작 / 끝)
    static let left: CGFloat = 55.4
    static let leftEnd: CGFloat = 793.9
    /// 카테고리 칸을 나누는 점선
    static let categoryX: CGFloat = 179.8
    /// 체크 박스 (점선 사각형, 점 중심 기준) 가로 위치와 크기
    static let boxMinX: CGFloat = 737.1
    static let boxSize: CGFloat = 43.0
    static var boxMidX: CGFloat { boxMinX + boxSize / 2 }

    /// 타임테이블
    static let timeLeft: CGFloat = 833.1
    static let cell: CGFloat = 56.27
    static var timeRight: CGFloat { timeLeft + 7 * cell }
    /// 시각 숫자 칸 오른쪽의 실선 = 형광펜 칸의 시작
    static var slotsLeft: CGFloat { timeLeft + cell }

    // 라벨 뒤에서 시작하는 머리선
    static let commentRuleX: CGFloat = 173.7
    static let totalRuleX: CGFloat = 949.1
    static let tasksRuleX: CGFloat = 131.2
    static let memoRuleX: CGFloat = 134.4
    static let timetableRuleX: CGFloat = 943.3

    // MARK: 선 굵기
    static let heavy: CGFloat = 2.7     // 머리선, 칸 닫는 선
    static let medium: CGFloat = 1.35   // 5줄마다
    static let hair: CGFloat = 1.5      // 얇은 회색 줄
    static let hourRule: CGFloat = 1.35 // 시각 칸 세로 실선
    static let dot: CGFloat = 2.1       // 카테고리 점선의 점 지름
    static let slotDot: CGFloat = 2.3   // 10분 칸 점선
    static let boxDot: CGFloat = 3.5    // 체크 박스 점 (조금 굵게)
    static let dotGap: CGFloat = 6.63   // 점 간격

    // MARK: 인쇄 글자
    /// 오른쪽 아래 워드마크
    static let wordmark = "spiralday"
    /// 워드마크 오른쪽 끝 / 기준선 (오른쪽 아래)
    static let wordmarkRight: CGFloat = 1227.2
    static let wordmarkBaseline: CGFloat = 1932.2

    // MARK: 칸 (편집 영역)
    static var commentBox: CGRect { CGRect(x: left, y: headerY, width: leftEnd - left, height: closeY - headerY) }
    static var totalBox: CGRect { CGRect(x: timeLeft, y: headerY, width: timeRight - timeLeft, height: closeY - headerY) }
    /// DATE / D-DAY 칸 — COMMENT / TOTAL TIME 칸과 같은 크기 (머리선 ~ 다음 머리선)
    static var dateBox: CGRect { CGRect(x: left, y: dateRuleY, width: leftEnd - left, height: headerY - dateRuleY) }
    static var ddayBox: CGRect { CGRect(x: timeLeft, y: dateRuleY, width: timeRight - timeLeft, height: headerY - dateRuleY) }

    /// 할 일 i 번째 줄 (0...14)
    static func taskRow(_ i: Int) -> CGRect {
        CGRect(x: left, y: lineY(i), width: leftEnd - left, height: pitch)
    }
    /// 메모 i 번째 줄 (0...2), MEMO 머리선 바로 아래부터
    static func memoRow(_ i: Int) -> CGRect {
        CGRect(x: left, y: lineY(memoRow + i), width: leftEnd - left, height: pitch)
    }
    static func box(_ i: Int) -> CGRect { box(i, rows: taskCount) }

    // 칸이 넘쳐서 줄 수가 늘어난 경우: 같은 높이를 rows 줄로 나눈다
    static var tasksHeight: CGFloat { CGFloat(taskCount) * pitch }
    static var memoTop: CGFloat { lineY(memoRow) }
    static var memoHeight: CGFloat { CGFloat(memoCount) * pitch }
    static func taskPitch(_ rows: Int) -> CGFloat { tasksHeight / CGFloat(max(rows, 1)) }
    static func memoPitch(_ rows: Int) -> CGFloat { memoHeight / CGFloat(max(rows, 1)) }
    static func taskRowRect(_ r: Int, rows: Int) -> CGRect {
        let p = taskPitch(rows)
        return CGRect(x: left, y: gridTop + CGFloat(r) * p, width: leftEnd - left, height: p)
    }
    static func memoRowRect(_ r: Int, rows: Int) -> CGRect {
        let p = memoPitch(rows)
        return CGRect(x: left, y: memoTop + CGFloat(r) * p, width: leftEnd - left, height: p)
    }
    static func box(_ r: Int, rows: Int) -> CGRect {
        let p = taskPitch(rows)
        let size = min(boxSize, p * 0.57)
        let mid = gridTop + (CGFloat(r) + 0.5) * p
        return CGRect(x: boxMidX - size / 2, y: mid - size / 2, width: size, height: size)
    }
}

// MARK: - Printed form

/// 종이에 인쇄된 양식 전체 (라벨, 선, 점선, 체크 박스, 시각 숫자, 워드마크). 한 Canvas 로 그린다.
struct DailyFormPrint: View {
    let u: CGFloat
    /// 할 일 / 메모 칸 수 (양식 그대로면 15 / 3, 넘치면 늘어난다)
    var taskRows = DailyForm.taskCount
    var memoRows = DailyForm.memoCount

    private typealias F = DailyForm

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: u, y: u)
            drawRules(&ctx)
            drawDots(&ctx)
            drawLabels(&ctx)
            drawHours(&ctx)
            drawWordmark(&ctx)
        }
        .allowsHitTesting(false)
    }

    // MARK: rules

    private func hline(_ ctx: inout GraphicsContext, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat,
                       _ width: CGFloat, _ color: Color) {
        ctx.fill(Path(CGRect(x: x0, y: y - width / 2, width: x1 - x0, height: width)), with: .color(color))
    }

    private func drawRules(_ ctx: inout GraphicsContext) {
        let ink = Ink.print, hair = Ink.rule
        // COMMENT · TOTAL TIME
        hline(&ctx, F.commentRuleX, F.leftEnd, F.headerY, F.heavy, ink)
        hline(&ctx, F.totalRuleX, F.timeRight, F.headerY, F.heavy, ink)
        hline(&ctx, F.left, F.leftEnd, F.closeY, F.heavy, ink)
        hline(&ctx, F.timeLeft, F.timeRight, F.closeY, F.heavy, ink)

        // TASKS (늘어나면 같은 높이 안에서 줄 간격이 좁아진다)
        hline(&ctx, F.tasksRuleX, F.leftEnd, F.lineY(0), F.heavy, ink)
        let tp = F.taskPitch(taskRows)
        for r in 1..<taskRows {
            let y = F.gridTop + CGFloat(r) * tp
            if r % 5 == 0 {
                hline(&ctx, F.left, F.leftEnd, y, F.medium, ink)
            } else {
                hline(&ctx, F.left, F.leftEnd, y, F.hair, hair)
            }
        }
        hline(&ctx, F.left, F.leftEnd, F.lineY(F.taskCount), F.heavy, ink)

        // MEMO
        hline(&ctx, F.memoRuleX, F.leftEnd, F.memoTop, F.heavy, ink)
        let mp = F.memoPitch(memoRows)
        for r in 1..<memoRows {
            hline(&ctx, F.left, F.leftEnd, F.memoTop + CGFloat(r) * mp, F.hair, hair)
        }
        hline(&ctx, F.left, F.leftEnd, F.gridBottom, F.heavy, ink)

        // TIMETABLE
        hline(&ctx, F.timetableRuleX, F.timeRight, F.hourY(0), F.heavy, ink)
        for r in 1..<24 {
            hline(&ctx, F.timeLeft, F.timeRight, F.hourY(r), F.hair, hair)
        }
        hline(&ctx, F.timeLeft, F.timeRight, F.hourY(24), F.heavy, ink)
        // 시각 칸 실선 (머리선 아래 조금 띄워서 시작)
        let solidTop = F.gridTop + 18.5, w = F.hourRule
        ctx.fill(Path(CGRect(x: F.slotsLeft - w / 2, y: solidTop, width: w, height: F.gridBottom - solidTop)),
                 with: .color(hair))
    }

    // MARK: dotted lines & boxes

    /// a → b 를 gap 에 가장 가까운 등간격으로 나눠 점을 찍는다
    private func dots(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, gap: CGFloat,
                      size: CGFloat, color: Color, includeEnds: Bool = true) {
        let len = hypot(b.x - a.x, b.y - a.y)
        let n = max(1, Int((len / gap).rounded()))
        var p = Path()
        let r = size / 2
        for i in (includeEnds ? 0 : 1)...(includeEnds ? n : n - 1) {
            let t = CGFloat(i) / CGFloat(n)
            let c = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.fill(p, with: .color(color))
    }

    private func drawDots(_ ctx: inout GraphicsContext) {
        let dot = Ink.dot
        let g = F.dotGap
        // 카테고리 칸 (TASKS)
        dots(&ctx, from: CGPoint(x: F.categoryX, y: F.lineY(0) + 7.2),
             to: CGPoint(x: F.categoryX, y: F.lineY(F.taskCount) - 1.2), gap: g, size: F.dot, color: dot)
        // MEMO 왼쪽 칸 (더 옅다)
        dots(&ctx, from: CGPoint(x: F.categoryX, y: F.lineY(F.memoRow) + 18.5),
             to: CGPoint(x: F.categoryX, y: F.gridBottom - 4.5), gap: g, size: F.dot, color: dot.opacity(0.55))
        // 10분 칸
        for k in 2...6 {
            let x = F.timeLeft + CGFloat(k) * F.cell
            dots(&ctx, from: CGPoint(x: x, y: F.gridTop + 6.8), to: CGPoint(x: x, y: F.gridBottom - 5.8),
                 gap: g, size: F.slotDot, color: dot)
        }
        // 체크 박스 (한 변에 점 7개)
        for i in 0..<taskRows {
            let b = F.box(i, rows: taskRows)
            let step = b.width / 6
            let c = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                     CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            for s in 0..<4 {
                dots(&ctx, from: c[s], to: c[(s + 1) % 4], gap: step, size: F.boxDot, color: dot,
                     includeEnds: s == 0 || s == 2)
            }
        }
    }

    // MARK: text

    /// 글자를 기준선(baseline) 에 맞춰 그린다. align: 0 = 왼쪽, 0.5 = 가운데, 1 = 오른쪽 (advance 기준)
    private func text(_ ctx: inout GraphicsContext, _ t: Text, x: CGFloat, baseline: CGFloat, align: CGFloat = 0) {
        let r = ctx.resolve(t)
        let box = CGSize(width: 2000, height: 400)
        let s = r.measure(in: box)
        let b = r.firstBaseline(in: box)
        ctx.draw(r, in: CGRect(x: x - s.width * align, y: baseline - b, width: s.width, height: s.height))
    }

    private static func capHeight(_ ps: String, _ size: CGFloat) -> CGFloat {
        (NSFont(name: ps, size: size)?.capHeight ?? size * 0.708)
    }

    /// 라벨: 블록 여백에서 시작하고, 대문자 가운데를 머리선 높이(+dy)에 맞춘다. 그린 폭을 돌려준다.
    @discardableResult
    private func label(_ ctx: inout GraphicsContext, _ s: String, _ weight: Fonts.PrintWeight, size: CGFloat,
                       tracking: CGFloat, x: CGFloat, ruleY: CGFloat, dy: CGFloat) -> CGFloat {
        let cap = Self.capHeight(weight.postScriptName, size)
        let t = Text(s).font(Fonts.print(size, weight)).tracking(tracking).foregroundStyle(Ink.print)
        text(&ctx, t, x: x, baseline: ruleY + dy + cap / 2)
        return ctx.resolve(t).measure(in: CGSize(width: 2000, height: 400)).width
    }

    private func drawLabels(_ ctx: inout GraphicsContext) {
        let light: CGFloat = 19.35, bold: CGFloat = 19.8
        label(&ctx, "COMMENT", .medium, size: light, tracking: 0.26, x: F.left + 0.7, ruleY: F.headerY, dy: 0.5)
        label(&ctx, "MEMO", .medium, size: light, tracking: 0.6, x: F.left, ruleY: F.lineY(F.memoRow), dy: -1.7)
        label(&ctx, "TASKS", .demiBold, size: bold, tracking: -0.9, x: F.left + 1.0, ruleY: F.gridTop, dy: -1.2)
        label(&ctx, "TOTAL TIME", .demiBold, size: bold, tracking: -1.2, x: F.timeLeft, ruleY: F.headerY, dy: -0.7)
        label(&ctx, "TIMETABLE", .demiBold, size: bold, tracking: -1.28, x: F.timeLeft, ruleY: F.gridTop, dy: -1.4)

        // 양식 위 여백에 더한 DATE / D-DAY 칸: 다른 칸과 같은 "라벨 ── 머리선" 모양
        let gap: CGFloat = 13
        let dw = label(&ctx, "DATE", .medium, size: light, tracking: 0.6, x: F.left + 0.7, ruleY: F.dateRuleY, dy: 0.5)
        hline(&ctx, F.left + 0.7 + dw + gap, F.leftEnd, F.dateRuleY, F.heavy, Ink.print)
        let kw = label(&ctx, "D-DAY", .demiBold, size: bold, tracking: -0.6, x: F.timeLeft, ruleY: F.dateRuleY, dy: -0.7)
        hline(&ctx, F.timeLeft + kw + gap, F.timeRight, F.dateRuleY, F.heavy, Ink.print)
    }

    private func drawHours(_ ctx: inout GraphicsContext) {
        let size: CGFloat = 23.1
        let weight = Fonts.PrintWeight.bold
        let cap = Self.capHeight(weight.postScriptName, size)
        // 숫자는 칸 가운데보다 살짝 오른쪽, 두 자리 수는 촘촘하게
        let cx = F.timeLeft + F.cell / 2 + 0.6
        for r in 0..<24 {
            let s = SlotPainter.hourLabel(r)
            let mid = F.hourY(r) + F.hourPitch / 2 + 0.7
            text(&ctx, Text(s).font(Fonts.print(size, weight)).tracking(s.count > 1 ? -3 : 0)
                    .foregroundStyle(Ink.print),
                 x: cx - (s.count > 1 ? 1 : 0), baseline: mid + cap / 2, align: 0.5)
        }
    }

    private func drawWordmark(_ ctx: inout GraphicsContext) {
        // 워드마크의 x-height · 굵기 · 글자 간격, 오른쪽 끝과 기준선
        let size: CGFloat = 31.5
        text(&ctx, Text(F.wordmark).font(.system(size: size, weight: .bold)).tracking(0.78)
                .foregroundStyle(Ink.print),
             x: F.wordmarkRight, baseline: F.wordmarkBaseline, align: 1)
    }
}
