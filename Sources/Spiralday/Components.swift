import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Shared page components. All sizes passed in are already in POINTS
// (pages multiply design units by `u` before handing them over).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Inline editable text (Text 로 그리고, 탭하면 그 자리에서 편집)

struct InlineField: View {
    @Binding var text: String
    var placeholder: String = ""
    var font: Font
    /// 편집 상태를 구분하는 전역 키 (AppState.editingKey)
    var key: String
    /// 탭했을 때 편집을 시작할 키 (기본: key). 빈 줄을 누르면 첫 빈 줄을 편집하게 할 때 사용.
    var tapKey: String? = nil
    var color: Color = Ink.text
    var highlight: Color? = nil
    /// 완료된 할 일: 이 색 펜으로 글자 위에 줄을 긋는다
    var strike: Color? = nil
    /// 1 이면 한 줄, 그 이상이면 여러 줄 (alignment 가 .center 면 상하좌우 가운데, 아니면 위에서부터)
    var lines: Int = 1
    /// 여러 줄일 때 줄과 줄 사이 (인쇄된 줄 간격에 맞출 때)
    var lineSpacing: CGFloat = 0
    var alignment: Alignment = .leading
    var onSubmit: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if state.editingKey == key && !isSnapshot {
                editor
            } else {
                display
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        lines > 1 && alignment != .center ? Alignment(horizontal: alignment.horizontal, vertical: .top) : alignment
    }

    @ViewBuilder private var editor: some View {
        Group {
            if lines > 1 {
                TextField("", text: $text, axis: .vertical).lineLimit(lines, reservesSpace: false)
            } else {
                TextField("", text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(font)
        .lineSpacing(lineSpacing)
        .foregroundStyle(color)
        .multilineTextAlignment(alignment.horizontal == .center ? .center : .leading)
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onSubmit {
            if let onSubmit, !text.isEmpty { onSubmit() } else { state.endEditing() }
        }
        .onChange(of: focused) { _, f in
            if !f && state.editingKey == key { state.editingKey = nil }
        }
        .onDisappear { onEnd?() }
    }

    private var display: some View {
        let empty = text.isEmpty
        return Text(empty ? placeholder : text)
            .font(font)
            .foregroundStyle(empty ? Ink.faint : color)
            .lineLimit(lines)
            .multilineTextAlignment(alignment.horizontal == .center ? .center : .leading)
            .background {
                if let highlight, !empty {
                    HighlighterBar(color: highlight)
                        .padding(.horizontal, -4)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                }
            }
            .overlay {
                if let strike, !empty { StrikeLine(color: strike) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .contentShape(Rectangle())
            .onTapGesture { state.editingKey = tapKey ?? key }
    }
}

/// 완료한 일 위에 펜으로 한 번 그은 줄 (살짝 기울고 끝이 둥근)
struct StrikeLine: View {
    let color: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: -h * 0.12, y: h * 0.58))
                p.addQuadCurve(to: CGPoint(x: w + h * 0.12, y: h * 0.50),
                               control: CGPoint(x: w * 0.5, y: h * 0.51))
            }
            .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: max(1.4, h * 0.075), lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ○ △ × → marks

struct MarkShape: Shape {
    let mark: Mark

    func path(in r: CGRect) -> Path {
        var p = Path()
        let i = r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12)
        switch mark {
        case .none, .done:
            p.addEllipse(in: i)
        case .partial:
            p.move(to: CGPoint(x: i.midX, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.maxY - i.height * 0.04))
            p.addLine(to: CGPoint(x: i.minX, y: i.maxY - i.height * 0.04))
            p.closeSubpath()
        case .missed:
            p.move(to: CGPoint(x: i.minX, y: i.minY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            p.move(to: CGPoint(x: i.maxX, y: i.minY))
            p.addLine(to: CGPoint(x: i.minX, y: i.maxY))
        case .moved:
            p.move(to: CGPoint(x: i.minX, y: i.midY))
            p.addLine(to: CGPoint(x: i.maxX, y: i.midY))
            p.move(to: CGPoint(x: i.maxX - i.width * 0.4, y: i.minY + i.height * 0.1))
            p.addLine(to: CGPoint(x: i.maxX, y: i.midY))
            p.addLine(to: CGPoint(x: i.maxX - i.width * 0.4, y: i.maxY - i.height * 0.1))
        }
        return p
    }
}

/// 펜으로 그린 체크 표시. 클릭하면 ○ → △ → × → → → (없음) 순서로 바뀐다.
struct MarkButton: View {
    let mark: Mark
    /// 표시 크기 (pt)
    var size: CGFloat
    var color: Color = Ink.red
    var lineWidth: CGFloat = 2
    /// 표시가 없을 때 옅은 점선 동그라미를 보여줄지 (양식에 체크 박스가 인쇄돼 있으면 false)
    var showsPlaceholder = false
    let action: () -> Void

    @State private var hover = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ZStack {
            if mark != .none {
                MarkShape(mark: mark)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            } else if (showsPlaceholder || hover) && !isSnapshot {
                MarkShape(mark: .done)
                    .stroke(Ink.faint.opacity(hover ? 1 : 0.6),
                            style: StrokeStyle(lineWidth: max(1, lineWidth * 0.5), dash: [2, 2.2]))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle().inset(by: -size * 0.25))
        .scaleEffect(hover ? 1.12 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { action() }
        }
        .help("클릭: ○ 완료 → △ 일부 → × 못함 → → 미룸 (다음 날로 넘어가요)")
    }
}

// MARK: - Task context menu

struct TaskMenu: View {
    let date: Date
    let task: PlanTask
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        Menu("형광펜 색") {
            Button("없음") { store.setCategory(date, task.id, nil) }
            ForEach(store.categories) { c in
                Button { store.setCategory(date, task.id, c.id) } label: {
                    Text((task.cat == c.id ? "✓ " : "   ") + c.name)
                }
            }
        }
        Menu("체크 표시") {
            ForEach(Mark.allCases, id: \.self) { m in
                Button(m.label) { markNextDayEdit(); store.setMark(date, task.id, m) }
            }
        }
        Divider()
        // → 표시와 같다: 다음 날로 한 번만 넘어간다 (이 플래너의 마지막 날이면 표시만 한다)
        Button("내일로 미루기") { markNextDayEdit(); store.postpone(date, task.id) }
        Divider()
        Button("삭제", role: .destructive) { store.delete(date, task.id) }
    }

    /// → 로 다음 날 할 일이 늘거나 줄 수 있어서, 다음 날 할 일을 쓰는 중이면 먼저 끝낸다
    private func markNextDayEdit() { state.endEditingTasks(on: Dates.add(days: 1, to: date)) }
}

extension AppState {
    /// 그날 할 일을 쓰는 중이면 편집을 끝낸다. 주간 페이지의 할 일 칸은 순서로 묶여 있어서
    /// 쓰는 도중에 그날 할 일이 늘거나 줄면 (→ 로 넘기기 · 거두기) 다른 줄에 써질 수 있다.
    func endEditingTasks(on d: Date) {
        if editingKey?.hasPrefix("t|\(Dates.key(d))|") == true { endEditing() }
    }
}

// MARK: - Stars

struct Stars: View {
    let value: Int
    var size: CGFloat
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= value ? "star.fill" : "star")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(i <= value ? Ink.pen : Ink.faint)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { set(i == value ? 0 : i) }
                    }
            }
        }
    }
}

// MARK: - Time-table layer (형광펜 · 글씨 · 밥시간)

/// 인쇄된 타임테이블 격자 "위에" 올리는 레이어.
/// 24 행(06시 → 다음날 05시) × 6 칸(10분).
/// - 형광펜: 드래그로 칠하기 (같은 색을 다시 칠하면 지워짐)
/// - 글씨 도구: 칸을 누르거나 끌어서 그 자리에 손글씨 메모
/// - 밥 도구: 시작 칸에 🍴 아이콘, 끝나는 칸까지 화살표 (클릭만 하면 1시간)
/// - 지우개: 칠한 칸과 겹치는 메모/밥시간을 함께 지운다
/// 격자 자체(선, 숫자)는 각 페이지가 그린다.
struct SlotPainter: View {
    let date: Date
    /// 한 칸 너비 / 한 행 높이 (pt)
    let cellW: CGFloat
    let rowH: CGFloat
    /// 행 높이 대비 위아래 여백 비율
    var inset: CGFloat = 0.14

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var snapshot: [Int]? = nil
    @State private var anchor = 0
    @State private var paint = -1
    /// 글씨/밥 도구로 끌고 있는 범위
    @State private var pending: ClosedRange<Int>? = nil

    static func hourLabel(_ row: Int) -> String {
        let h = (6 + row) % 24
        return String(h % 12 == 0 ? 12 : h % 12)
    }

    var body: some View {
        let rec = store.day(date)
        let colors = Dictionary(uniqueKeysWithValues: store.categories.map { ($0.id, $0.color) })
        let accent = store.concept(date).accent
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                drawHighlights(&ctx, rec.slots, colors)
                for n in rec.notes where n.kind == .meal { drawMeal(&ctx, n, accent) }
                if let pending { drawPending(&ctx, pending, accent) }
            }
            .frame(width: cellW * 6, height: rowH * 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(v.location, rec.slots) }
                    .onEnded { v in dragEnded(v.location) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active: (state.tool == AppState.textTool ? NSCursor.iBeam : NSCursor.crosshair).set()
                case .ended: NSCursor.arrow.set()
                }
            }

            ForEach(rec.notes) { n in
                if n.kind == .text { textNote(n) } else { mealHandle(n) }
            }
        }
        .frame(width: cellW * 6, height: rowH * 24, alignment: .topLeading)
    }

    // MARK: drawing

    private func drawHighlights(_ ctx: inout GraphicsContext, _ slots: [Int], _ colors: [Int: Color]) {
        var c2 = ctx
        c2.blendMode = .multiply
        for r in 0..<24 {
            var c = 0
            while c < 6 {
                let v = slots[r * 6 + c]
                guard let color = colors[v] else { c += 1; continue }
                var e = c
                while e + 1 < 6 && slots[r * 6 + e + 1] == v { e += 1 }
                let rect = CGRect(x: CGFloat(c) * cellW + 1, y: CGFloat(r) * rowH + rowH * inset,
                                  width: CGFloat(e - c + 1) * cellW - 2, height: rowH * (1 - 2 * inset))
                c2.fill(Path(roundedRect: rect, cornerRadius: min(3, rowH * 0.18)), with: .color(color.opacity(0.86)))
                c = e + 1
            }
        }
    }

    private func cellCenter(_ s: Int) -> CGPoint {
        CGPoint(x: (CGFloat(s % 6) + 0.5) * cellW, y: (CGFloat(s / 6) + 0.5) * rowH)
    }

    private var iconSize: CGFloat { min(rowH * 0.8, cellW * 0.92) }

    /// 🍴 아이콘 → 끝 칸까지 이어지는 화살표. 줄이 바뀌면 다음 줄 처음에서 이어진다.
    private func drawMeal(_ ctx: inout GraphicsContext, _ n: TimeNote, _ accent: Color) {
        let s = min(n.start, n.end), e = max(n.start, n.end)
        let lw = max(1.3, rowH * 0.075)
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        let r0 = s / 6, r1 = e / 6
        if e > s {
            var p = Path()
            for r in r0...r1 {
                let y = (CGFloat(r) + 0.5) * rowH
                let xs = r == r0 ? CGFloat(s % 6) * cellW + cellW / 2 + iconSize * 0.62 : cellW * 0.12
                let xe = r == r1 ? CGFloat(e % 6 + 1) * cellW - lw * 1.5 : cellW * 6 - cellW * 0.12
                guard xe > xs + 1 else { continue }
                p.move(to: CGPoint(x: xs, y: y))
                p.addLine(to: CGPoint(x: xe, y: y))
                if r < r1 {
                    // 줄 끝에서 아래로 꺾이는 작은 갈고리
                    p.addLine(to: CGPoint(x: xe, y: y + rowH * 0.28))
                } else {
                    let a = max(rowH * 0.24, 4)
                    p.move(to: CGPoint(x: xe - a, y: y - a * 0.62))
                    p.addLine(to: CGPoint(x: xe, y: y))
                    p.addLine(to: CGPoint(x: xe - a, y: y + a * 0.62))
                }
                if r > r0 {
                    // 다음 줄 처음: 위에서 내려와 이어지는 모양
                    var hook = Path()
                    hook.move(to: CGPoint(x: xs, y: y - rowH * 0.28))
                    hook.addLine(to: CGPoint(x: xs, y: y))
                    ctx.stroke(hook, with: .color(accent), style: style)
                }
            }
            ctx.stroke(p, with: .color(accent), style: style)
        }
        // 아이콘 스티커
        let c = cellCenter(s)
        let d = iconSize
        let circle = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: circle), with: .color(Ink.paper))
        ctx.stroke(Path(ellipseIn: circle.insetBy(dx: lw * 0.5, dy: lw * 0.5)), with: .color(accent), lineWidth: lw)
        var icon = ctx.resolve(Image(systemName: "fork.knife"))
        icon.shading = .color(accent)
        ctx.draw(icon, in: circle.insetBy(dx: d * 0.22, dy: d * 0.22))
    }

    /// 글씨/밥 도구로 끌고 있는 범위 미리보기 (점선 밑줄)
    private func drawPending(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>, _ accent: Color) {
        let r0 = range.lowerBound / 6, r1 = range.upperBound / 6
        var p = Path()
        for r in r0...r1 {
            let c0 = r == r0 ? range.lowerBound % 6 : 0
            let c1 = r == r1 ? range.upperBound % 6 : 5
            let y = (CGFloat(r) + 0.86) * rowH
            p.move(to: CGPoint(x: CGFloat(c0) * cellW + 2, y: y))
            p.addLine(to: CGPoint(x: CGFloat(c1 + 1) * cellW - 2, y: y))
        }
        ctx.stroke(p, with: .color(accent.opacity(0.8)),
                   style: StrokeStyle(lineWidth: max(1.2, rowH * 0.06), lineCap: .round, dash: [3, 3]))
    }

    // MARK: notes (views)

    private func noteKey(_ n: TimeNote) -> String { "tn|\(Dates.key(date))|\(n.id.uuidString)" }

    /// 손글씨 메모: 시작 칸에서 그 줄 끝까지 쓸 수 있다
    @ViewBuilder
    private func textNote(_ n: TimeNote) -> some View {
        let s = min(n.start, n.end)
        let x = CGFloat(s % 6) * cellW + 3
        let y = CGFloat(s / 6) * rowH
        let w = CGFloat(6 - s % 6) * cellW - 5
        let key = noteKey(n)
        let font = Fonts.hand(rowH * 0.74)
        let binding = Binding(get: { store.day(date).notes.first { $0.id == n.id }?.text ?? "" },
                              set: { v in store.updateNote(date, n.id) { $0.text = v } })
        Group {
            if state.editingKey == key && !isSnapshot {
                InlineField(text: binding, font: font, key: key, onEnd: { [store, date] in store.cleanupNotes(date) })
                    .frame(width: w, height: rowH)
            } else {
                Text(n.text)
                    .font(font)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: rowH)
                    .contentShape(Rectangle())
                    .onTapGesture { state.editingKey = key }
                    .contextMenu { Button("메모 지우기", role: .destructive) { store.removeNote(date, n.id) } }
            }
        }
        .offset(x: x, y: y)
    }

    /// 밥시간 아이콘: 오른쪽 클릭으로 지우기
    private func mealHandle(_ n: TimeNote) -> some View {
        let c = cellCenter(min(n.start, n.end))
        return Color.clear
            .frame(width: iconSize, height: iconSize)
            .contentShape(Circle())
            .contextMenu { Button("밥시간 지우기", role: .destructive) { store.removeNote(date, n.id) } }
            .help("밥시간 — 오른쪽 클릭으로 지우기")
            .offset(x: c.x - iconSize / 2, y: c.y - iconSize / 2)
    }

    // MARK: input

    private func slot(at p: CGPoint) -> Int {
        let r = min(max(Int(p.y / rowH), 0), 23)
        let c = min(max(Int(p.x / cellW), 0), 5)
        return r * 6 + c
    }

    private var annotating: Bool { state.tool == AppState.textTool || state.tool == AppState.mealTool }

    private func drag(_ p: CGPoint, _ current: [Int]) {
        let s = slot(at: p)
        if annotating {
            if pending == nil { state.endEditing(); anchor = s }
            pending = min(anchor, s)...max(anchor, s)
            return
        }
        if snapshot == nil {
            state.endEditing()
            snapshot = current
            anchor = s
            paint = (state.tool < 0 || current[s] == state.tool) ? -1 : state.tool
        }
        guard var next = snapshot else { return }
        for i in min(anchor, s)...max(anchor, s) { next[i] = paint }
        if next != current { store.editDay(date) { $0.slots = next } }
    }

    private func dragEnded(_ p: CGPoint) {
        defer { snapshot = nil; pending = nil }
        let s = slot(at: p)
        let range = min(anchor, s)...max(anchor, s)
        switch state.tool {
        case AppState.textTool:
            let id = store.addNote(date, TimeNote(kind: .text, start: range.lowerBound, end: range.upperBound))
            state.editingKey = "tn|\(Dates.key(date))|\(id.uuidString)"
        case AppState.mealTool:
            // 누르기만 하면 한 시간
            let end = range.count == 1 ? min(range.lowerBound + 5, 143) : range.upperBound
            store.addNote(date, TimeNote(kind: .meal, start: range.lowerBound, end: end))
        case AppState.eraser:
            store.removeNotes(date, overlapping: range)
        default:
            break
        }
    }
}

// MARK: - D-day editor (이 날의 D-day: 일간 D-DAY 칸, 홈 D-DAY 칸, 팔레트 버튼에서 같이 쓴다)

/// 한 날에 붙일 D-day 를 고른다. 저장한 D-day 에서 고르거나 새로 만들어 붙이고,
/// 여기서 붙이고 떼고 고친 것은 이 날에만 남는다 (다른 날, 저장한 목록은 그대로).
struct DDayEditor: View {
    let date: Date

    @EnvironmentObject private var store: PlannerStore
    @State private var newTitle = ""
    @State private var newDate: Date
    @State private var saveToLibrary = true
    /// 달력을 펼친 줄: 붙인 D-day 의 id 또는 "new"
    @State private var picking: String? = nil
    @State private var showPast = false

    init(date: Date) {
        self.date = Dates.day(date)
        _newDate = State(initialValue: Dates.add(days: 30, to: Dates.day(date)))
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E)"
        return f
    }()

    private static let shortFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yy. M. d. (E)"
        return f
    }()

    private var accent: Color { store.concept(date).accent }

    var body: some View {
        let mine = store.ddays(date)
        let full = mine.count >= Prefs.maxDDays
        let used = Set(mine.compactMap(\.source))
        let library = store.ddayLibrary
        let choices = library.filter { !used.contains($0.id) }
        let upcoming = choices.filter { Dates.day($0.date) >= date }
        let past = choices.filter { Dates.day($0.date) < date }
        let prev = store.ddays(Dates.add(days: -1, to: date))

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("이 날의 D-day").font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("하루 최대 \(Prefs.maxDDays)개").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text((Dates.isToday(date) ? "오늘 · " : "") + Self.dayFormat.string(from: date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
            }

            // (a) 이 날에 붙인 것: 고치거나 떼도 이 날만 바뀐다
            DDayEditorSection(title: "붙인 D-day", trailing: "\(mine.count) / \(Prefs.maxDDays)") {
                if mine.isEmpty {
                    Text("아직 붙인 D-day 가 없어요. 아래에서 골라 붙여 보세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !prev.isEmpty {
                        Button { store.copyPreviousDDays(to: date) } label: {
                            Label("어제와 같게 · " + prev.map { $0.title.isEmpty ? "D-day" : $0.title }.joined(separator: ", "),
                                  systemImage: "arrow.turn.down.right")
                                .lineLimit(1)
                        }
                        .controlSize(.small)
                        .help("전날 붙인 D-day 를 이 날에도 똑같이 붙여요")
                    }
                }
                ForEach(mine) { d in attachedRow(d) }
            }

            // (b) 저장한 D-day 에서 고르기
            DDayEditorSection(title: "저장한 D-day 에서 고르기", trailing: nil) {
                if library.isEmpty {
                    note("저장한 D-day 가 없어요. 새로 만들 때 ‘목록에도 저장’을 켜 두면 여기에서 다른 날에도 고를 수 있어요.")
                } else if choices.isEmpty {
                    note("저장한 D-day 를 이 날에 모두 붙였어요.")
                } else if upcoming.isEmpty {
                    note("다가오는 D-day 가 없어요.")
                }
                if upcoming.count > 4 {
                    ScrollView { libraryRows(upcoming, full: full) }.frame(height: 4 * 42)
                } else if !upcoming.isEmpty {
                    libraryRows(upcoming, full: full)
                }
                if !past.isEmpty {
                    DisclosureGroup(isExpanded: $showPast) {
                        if past.count > 4 {
                            ScrollView { libraryRows(past, full: full) }.frame(height: 4 * 42)
                        } else {
                            libraryRows(past, full: full)
                        }
                    } label: {
                        Text("지난 D-day \(past.count)개").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }

            // (c) 새로 만들어 붙이기
            DDayEditorSection(title: "새로 만들기", trailing: nil) {
                HStack(spacing: 8) {
                    TextField("무엇까지? (예: 시험)", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !full { attachNew() } }
                    dateButton(newDate, key: "new")
                }
                if picking == "new" { calendar($newDate) }
                HStack {
                    Toggle("목록에도 저장", isOn: $saveToLibrary)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .help("켜 두면 저장한 D-day 목록에도 들어가서 다른 날에도 골라 붙일 수 있어요")
                    Spacer()
                    Button("붙이기") { attachNew() }
                        .controlSize(.small)
                        .disabled(full)
                        .help(full ? "하루에 \(Prefs.maxDDays)개까지예요. 하나를 떼면 더 붙일 수 있어요" : "이 날에 붙이기")
                }
            }

            Text(full ? "하루에 \(Prefs.maxDDays)개까지 붙일 수 있어요. 하나를 떼면 더 붙일 수 있어요."
                      : "여기서 붙이고 떼고 고친 것은 이 날에만 남아요. 다른 날과 저장한 목록은 그대로예요. 목록은 설정 → D-day 에서 고쳐요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
        .animation(.snappy(duration: 0.2), value: mine)
        .animation(.snappy(duration: 0.2), value: picking)
    }

    // MARK: rows

    /// 붙인 D-day 한 줄: 이 날에서 센 숫자 · 제목 · 날짜 · 떼기
    @ViewBuilder
    private func attachedRow(_ d: DDay) -> some View {
        HStack(spacing: 8) {
            Text(d.count(from: date))
                .font(Fonts.rounded(12, .heavy))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(0.12)))
            TextField("무엇까지?", text: Binding(get: { d.title },
                                              set: { v in store.editDDay(d.id, on: date) { $0.title = v } }))
                .textFieldStyle(.roundedBorder)
                .help("이 날에 붙인 것만 바뀌어요")
            dateButton(d.date, key: d.id.uuidString)
            Button { store.removeDDay(d.id, from: date) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("이 날에서만 떼기 (다른 날과 저장한 목록은 그대로)")
        }
        if picking == d.id.uuidString {
            calendar(Binding(get: { d.date }, set: { v in store.editDDay(d.id, on: date) { $0.date = v } }))
        }
    }

    private func libraryRows(_ items: [DDay], full: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                Button { store.applyDDay(item.id, to: date) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(full ? Color.secondary : accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title.isEmpty ? "D-day" : item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(Self.shortFormat.string(from: item.date))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(item.count(from: date))
                            .font(Fonts.rounded(12, .heavy))
                            .monospacedDigit()
                            .foregroundStyle(full ? Color.secondary : accent)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(full)
                .help(full ? "하루에 \(Prefs.maxDDays)개까지예요. 하나를 떼면 더 붙일 수 있어요" : "이 날에 붙이기 (숫자는 이 날에서 센 것)")
            }
        }
    }

    // MARK: bits

    /// 날짜는 달력에서 고른다 (글자 칸이 아니라서 플래너의 숫자·화살표 단축키와 부딪히지 않는다)
    private func dateButton(_ d: Date, key: String) -> some View {
        Button { picking = picking == key ? nil : key } label: {
            Label(Self.shortFormat.string(from: d), systemImage: "calendar")
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 112, alignment: .leading)
        }
        .controlSize(.small)
        .fixedSize()
        .help("날짜 고르기")
    }

    private func calendar(_ selection: Binding<Date>) -> some View {
        DatePicker("날짜", selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = Dates.day($0) }),
                   displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "ko_KR"))
            .frame(maxWidth: .infinity)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attachNew() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.addDDay(title: title, date: newDate, to: date, save: saveToLibrary) != nil else { return }
        newTitle = ""
        if picking == "new" { picking = nil }
    }
}

/// 편집기 안의 작은 제목 + 내용
private struct DDayEditorSection<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}
