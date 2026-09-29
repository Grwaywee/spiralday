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
    /// 1 이면 한 줄, 그 이상이면 여러 줄 (위에서부터)
    var lines: Int = 1
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
        lines > 1 ? Alignment(horizontal: alignment.horizontal, vertical: .top) : alignment
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .contentShape(Rectangle())
            .onTapGesture { state.editingKey = tapKey ?? key }
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
        .help("클릭: ○ 완료 → △ 일부 → × 못함 → → 미룸")
    }
}

// MARK: - Task context menu

struct TaskMenu: View {
    let date: Date
    let task: PlanTask
    @EnvironmentObject private var store: PlannerStore

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
                Button(m.label) { store.setMark(date, task.id, m) }
            }
        }
        Divider()
        Button("내일로 미루기") { store.postpone(date, task.id) }
        Divider()
        Button("삭제", role: .destructive) { store.delete(date, task.id) }
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

// MARK: - Time-table highlighter layer

/// 인쇄된 타임테이블 격자 "위에" 올리는 투명 레이어.
/// 24 행(06시 → 다음날 05시) × 6 칸(10분). 드래그로 선택한 형광펜 색을 칠한다.
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
    @State private var snapshot: [Int]? = nil
    @State private var anchor = 0
    @State private var paint = -1

    static func hourLabel(_ row: Int) -> String {
        let h = (6 + row) % 24
        return String(h % 12 == 0 ? 12 : h % 12)
    }

    var body: some View {
        let slots = store.day(date).slots
        let colors = store.categories.map(\.color)
        Canvas { ctx, _ in
            ctx.blendMode = .multiply
            for r in 0..<24 {
                var c = 0
                while c < 6 {
                    let v = slots[r * 6 + c]
                    guard v >= 0, v < colors.count else { c += 1; continue }
                    var e = c
                    while e + 1 < 6 && slots[r * 6 + e + 1] == v { e += 1 }
                    let rect = CGRect(x: CGFloat(c) * cellW + 1, y: CGFloat(r) * rowH + rowH * inset,
                                      width: CGFloat(e - c + 1) * cellW - 2, height: rowH * (1 - 2 * inset))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, rowH * 0.18)),
                             with: .color(colors[v].opacity(0.86)))
                    c = e + 1
                }
            }
        }
        .frame(width: cellW * 6, height: rowH * 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in drag(v.location, slots) }
                .onEnded { _ in snapshot = nil }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.crosshair.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private func slot(at p: CGPoint) -> Int {
        let r = min(max(Int(p.y / rowH), 0), 23)
        let c = min(max(Int(p.x / cellW), 0), 5)
        return r * 6 + c
    }

    private func drag(_ p: CGPoint, _ current: [Int]) {
        let s = slot(at: p)
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
}

// MARK: - D-day editor (페이지의 D-day, 팔레트 버튼에서 같이 쓴다)

struct DDayEditor: View {
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let p = store.data.prefs
        VStack(alignment: .leading, spacing: 12) {
            Text("D-day").font(.system(size: 15, weight: .bold, design: .rounded))
            TextField("무엇까지? (예: 런칭)", text: Binding(get: { p.ddayTitle },
                                                        set: { v in store.editPrefs { $0.ddayTitle = v } }))
                .textFieldStyle(.roundedBorder)
            Toggle("날짜 정하기", isOn: Binding(get: { p.ddayDate != nil }, set: { on in
                store.editPrefs { $0.ddayDate = on ? ($0.ddayDate ?? Dates.add(days: 30, to: Dates.day(Date()))) : nil }
            }))
            if p.ddayDate != nil {
                DatePicker("", selection: Binding(get: { p.ddayDate ?? Date() },
                                                  set: { v in store.editPrefs { $0.ddayDate = Dates.day(v) } }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
