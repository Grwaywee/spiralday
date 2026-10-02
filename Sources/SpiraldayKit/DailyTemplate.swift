import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// 일간 양식 (10분 단위 종이 플래너 한 장). 모든 좌표는 디자인 단위 (페이지 1277 × 2000).
// 선은 모두 수평·수직으로 곧게 그린다.
//
//   왼쪽 블록  : 한 줄 76.12 짜리 19줄 격자 (TASKS 15줄 · MEMO 머리 1줄 · MEMO 3줄)
//   타임테이블 : 같은 높이를 24줄 (06시 → 다음날 05시), 56.27 폭 7칸 (시각 1칸 + 10분 6칸)
// ─────────────────────────────────────────────────────────────────────────────

public enum DailyForm {
    // MARK: 세로 위치
    /// (양식 위 빈 여백에 추가) DATE / D-DAY 머리선. 칸은 이 선과 COMMENT 머리선 사이.
    public static let dateRuleY: CGFloat = 72
    /// COMMENT / TOTAL TIME 머리선 — DATE 칸과 COMMENT 칸의 높이가 같도록 DATE 머리선과 닫는 선의 한가운데
    public static var headerY: CGFloat { (dateRuleY + closeY) / 2 }
    /// 두 칸을 닫는 선
    public static let closeY: CGFloat = 366.7
    /// TASKS / TIMETABLE 머리선 = 격자 맨 위
    public static let gridTop: CGFloat = 444.5
    /// 왼쪽 블록 한 줄 높이
    public static let pitch: CGFloat = 76.12
    public static let leftRows = 19
    public static let taskCount = 15
    public static let memoCount = 3
    /// MEMO 머리선이 있는 줄 (0 = gridTop)
    public static let memoRow = 16
    public static var gridBottom: CGFloat { gridTop + CGFloat(leftRows) * pitch }
    /// 타임테이블 한 줄 높이 (왼쪽 19줄 높이를 24줄로)
    public static var hourPitch: CGFloat { (gridBottom - gridTop) / 24 }

    public static func lineY(_ row: Int) -> CGFloat { gridTop + CGFloat(row) * pitch }
    public static func hourY(_ row: Int) -> CGFloat { gridTop + CGFloat(row) * hourPitch }

    // MARK: 가로 위치
    /// 왼쪽 블록 (선의 시작 / 끝)
    public static let left: CGFloat = 55.4
    public static let leftEnd: CGFloat = 793.9
    /// 카테고리 칸을 나누는 점선
    public static let categoryX: CGFloat = 179.8
    /// 체크 박스 (점선 사각형, 점 중심 기준) 가로 위치와 크기
    public static let boxMinX: CGFloat = 737.1
    public static let boxSize: CGFloat = 43.0
    public static var boxMidX: CGFloat { boxMinX + boxSize / 2 }

    /// 타임테이블
    public static let timeLeft: CGFloat = 833.1
    public static let cell: CGFloat = 56.27
    public static var timeRight: CGFloat { timeLeft + 7 * cell }
    /// 시각 숫자 칸 오른쪽의 실선 = 형광펜 칸의 시작
    public static var slotsLeft: CGFloat { timeLeft + cell }

    // 라벨 뒤에서 시작하는 머리선
    public static let commentRuleX: CGFloat = 173.7
    /// 화면: COMMENT 라벨 바로 뒤의 ▾ 메뉴 (작성하기 · DAY OFF). 라벨은 x 56.1 ~ 160.3 (AvenirNext-Medium 19.35).
    /// ▾ 가 들어갈 만큼 머리선을 뒤로 민다. 넘김 스냅샷도 화면과 같고, PDF 에는 ▾ 가 없어서 머리선도 제자리다.
    public static let commentLabelEnd: CGFloat = 160.3
    public static let commentMenuShift: CGFloat = 19
    public static let totalRuleX: CGFloat = 949.1
    public static let tasksRuleX: CGFloat = 131.2
    public static let memoRuleX: CGFloat = 134.4
    public static let timetableRuleX: CGFloat = 943.3

    // MARK: 선 굵기
    public static let heavy: CGFloat = 2.7     // 머리선, 칸 닫는 선
    public static let medium: CGFloat = 1.35   // 5줄마다
    public static let hair: CGFloat = 1.5      // 얇은 회색 줄
    public static let hourRule: CGFloat = 1.35 // 시각 칸 세로 실선
    public static let dot: CGFloat = 2.1       // 카테고리 점선의 점 지름
    public static let slotDot: CGFloat = 2.3   // 10분 칸 점선
    public static let boxDot: CGFloat = 3.5    // 체크 박스 점 (조금 굵게: 사용자 요청)
    public static let dotGap: CGFloat = 6.63   // 점 간격

    // MARK: 인쇄 글자
    /// 오른쪽 아래에 인쇄되는 워드마크
    public static let wordmark = "spiralday"
    /// 워드마크 오른쪽 끝 / 기준선
    public static let wordmarkRight: CGFloat = 1227.2
    public static let wordmarkBaseline: CGFloat = 1932.2

    // MARK: 칸 (편집 영역)
    public static var commentBox: CGRect { CGRect(x: left, y: headerY, width: leftEnd - left, height: closeY - headerY) }
    public static var totalBox: CGRect { CGRect(x: timeLeft, y: headerY, width: timeRight - timeLeft, height: closeY - headerY) }
    /// DATE / D-DAY 칸 — COMMENT / TOTAL TIME 칸과 같은 크기 (머리선 ~ 다음 머리선)
    public static var dateBox: CGRect { CGRect(x: left, y: dateRuleY, width: leftEnd - left, height: headerY - dateRuleY) }
    public static var ddayBox: CGRect { CGRect(x: timeLeft, y: dateRuleY, width: timeRight - timeLeft, height: headerY - dateRuleY) }

    /// 할 일 i 번째 줄 (0...14)
    public static func taskRow(_ i: Int) -> CGRect {
        CGRect(x: left, y: lineY(i), width: leftEnd - left, height: pitch)
    }
    /// 메모 i 번째 줄 (0...2), MEMO 머리선 바로 아래부터
    public static func memoRow(_ i: Int) -> CGRect {
        CGRect(x: left, y: lineY(memoRow + i), width: leftEnd - left, height: pitch)
    }
    public static func box(_ i: Int) -> CGRect { box(i, rows: taskCount) }

    // 칸이 넘쳐서 줄 수가 늘어난 경우: 같은 높이를 rows 줄로 나눈다
    public static var tasksHeight: CGFloat { CGFloat(taskCount) * pitch }
    public static var memoTop: CGFloat { lineY(memoRow) }
    public static var memoHeight: CGFloat { CGFloat(memoCount) * pitch }
    public static func taskPitch(_ rows: Int) -> CGFloat { tasksHeight / CGFloat(max(rows, 1)) }
    public static func memoPitch(_ rows: Int) -> CGFloat { memoHeight / CGFloat(max(rows, 1)) }
    public static func taskRowRect(_ r: Int, rows: Int) -> CGRect {
        let p = taskPitch(rows)
        return CGRect(x: left, y: gridTop + CGFloat(r) * p, width: leftEnd - left, height: p)
    }
    public static func memoRowRect(_ r: Int, rows: Int) -> CGRect {
        let p = memoPitch(rows)
        return CGRect(x: left, y: memoTop + CGFloat(r) * p, width: leftEnd - left, height: p)
    }
    public static func box(_ r: Int, rows: Int) -> CGRect {
        let p = taskPitch(rows)
        let size = min(boxSize, p * 0.57)
        let mid = gridTop + (CGFloat(r) + 0.5) * p
        return CGRect(x: boxMidX - size / 2, y: mid - size / 2, width: size, height: size)
    }

    // MARK: 할 일 손글씨 (1.0.5: 줄마다 따로 쓴다)

    /// 할 일 글자 크기 (디자인 단위, 15줄일 때)
    public static let taskFont: CGFloat = 46
    /// 할 일 글을 쓰는 칸 (카테고리 점선 뒤 ~ 체크 박스 앞)
    public static var taskTextX: CGFloat { categoryX + 16 }
    public static var taskTextWidth: CGFloat { boxMinX - 14 - taskTextX }
    /// 줄바꿈 계산 폭: 편집 칸보다 살짝 좁게 잡아서 입력 중에도 줄 수가 어긋나지 않게 한다
    public static var taskWrapWidth: CGFloat { taskTextWidth - 12 }

    /// 할 일들을 제 줄에 놓는다 (tasks 는 row 순서, DayRecord.assignTaskRows 를 거친 것).
    /// 긴 할 일은 아래 빈 줄로 이어 쓰고, 막히면 가진 줄에 맞춰 글자를 줄인다.
    /// 할 일이 15번째 줄보다 아래에 있으면(할 일이 15개보다 많으면) 그 줄까지 칸을 늘려 같은 높이에 넣는다.
    public static func taskLayout(_ tasks: [PlanTask]) -> RuledText.RowLayout {
        Fonts.register()
        return RuledText.rowLayout(tasks.map { ($0.row ?? 0, $0.text) }, minRows: taskCount,
                                   fontSize: taskFont, width: taskWrapWidth)
    }

    /// 1.0.4 까지의 일간 페이지에서 할 일이 시작하던 줄: 위에서부터 차례로 흘려 쓰고 긴 할 일은 아래 칸으로 이어 썼다.
    /// 줄 번호가 없는 예전 기록을 처음 열 때 이 줄에 그대로 둔다 (한 줄짜리 할 일만 있으면 0, 1, 2, …).
    public static func legacyTaskRows(_ texts: [String]) -> [Int] {
        Fonts.register()
        return RuledText.layout(texts, minRows: taskCount, fontSize: taskFont, width: taskWrapWidth).start
    }
}

// MARK: - Printed form

/// 종이에 인쇄된 양식 전체 (라벨, 선, 점선, 체크 박스, 시각 숫자, 워드마크). 한 Canvas 로 그린다.
public struct DailyFormPrint: View {
    public let u: CGFloat
    /// 할 일 / 메모 칸 수 (기본 15 / 3, 넘치면 늘어난다)
    public var taskRows = DailyForm.taskCount
    public var memoRows = DailyForm.memoCount
    /// COMMENT ▾ 메뉴 자리를 비운다 (화면 · 넘김 스냅샷, PDF 는 아니다)
    public var commentMenu = false

    public init(u: CGFloat, taskRows: Int = DailyForm.taskCount, memoRows: Int = DailyForm.memoCount, commentMenu: Bool = false) {
        self.u = u
        self.taskRows = taskRows
        self.memoRows = memoRows
        self.commentMenu = commentMenu
    }

    private typealias F = DailyForm

    public var body: some View {
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
        hline(&ctx, F.commentRuleX + (commentMenu ? F.commentMenuShift : 0), F.leftEnd, F.headerY, F.heavy, ink)
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
        (PlatformFont(name: ps, size: size)?.capHeight ?? size * 0.708)
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
        // 굵은 소문자 워드마크를 오른쪽 끝 · 기준선에 맞춘다
        let size: CGFloat = 31.5
        text(&ctx, Text(F.wordmark).font(.system(size: size, weight: .bold)).tracking(0.78)
                .foregroundStyle(Ink.print),
             x: F.wordmarkRight, baseline: F.wordmarkBaseline, align: 1)
    }
}
