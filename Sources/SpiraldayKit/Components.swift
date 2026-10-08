import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Shared page components. All sizes passed in are already in POINTS
// (pages multiply design units by `u` before handing them over).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Inline editable text (Text 로 그리고, 탭하면 그 자리에서 편집)

public struct InlineField: View {
    @Binding public var text: String
    public var placeholder: String = ""
    public var font: Font
    /// 편집 상태를 구분하는 전역 키 (AppState.editingKey)
    public var key: String
    /// 탭했을 때 편집을 시작할 키 (기본: key). 빈 줄을 누르면 첫 빈 줄을 편집하게 할 때 사용.
    public var tapKey: String? = nil
    public var color: Color = Ink.text
    public var highlight: Color? = nil
    /// 완료된 할 일: 이 색 펜으로 글자 위에 줄을 긋는다
    public var strike: Color? = nil
    /// 1 이면 한 줄, 그 이상이면 여러 줄 (alignment 가 .center 면 상하좌우 가운데, 아니면 위에서부터)
    public var lines: Int = 1
    /// 여러 줄일 때 줄과 줄 사이 (인쇄된 줄 간격에 맞출 때)
    public var lineSpacing: CGFloat = 0
    public var alignment: Alignment = .leading
    public var onSubmit: (() -> Void)? = nil
    public var onEnd: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    public init(text: Binding<String>, placeholder: String = "", font: Font, key: String, tapKey: String? = nil, color: Color = Ink.text, highlight: Color? = nil, strike: Color? = nil, lines: Int = 1, lineSpacing: CGFloat = 0, alignment: Alignment = .leading, onSubmit: (() -> Void)? = nil, onEnd: (() -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.key = key
        self.tapKey = tapKey
        self.color = color
        self.highlight = highlight
        self.strike = strike
        self.lines = lines
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.onSubmit = onSubmit
        self.onEnd = onEnd
    }

    public var body: some View {
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
        #if !os(macOS)
        // iOS: 여러 줄 글상자는 Return 이 줄바꿈이 된다. 다음 줄로 넘어가는 칸(할 일 · 메모)은 Mac 처럼 Return = 다음 줄
        .submitLabel(onSubmit != nil ? .next : .done)
        .onChange(of: text) { _, new in
            guard lines > 1, onSubmit != nil, new.contains("\n") else { return }
            text = new.replacingOccurrences(of: "\n", with: "")
            submit()
        }
        #endif
        .onDisappear { onEnd?() }
    }

    /// Return: 다음 줄로 (onSubmit) — 글이 비었거나 다음이 없으면 쓰기를 마친다
    private func submit() {
        if let onSubmit, !text.isEmpty { onSubmit() } else { state.endEditing() }
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
public struct StrikeLine: View {
    public let color: Color

    public init(color: Color) {
        self.color = color
    }
    public var body: some View {
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

public struct MarkShape: Shape {
    public let mark: Mark

    public init(mark: Mark) {
        self.mark = mark
    }

    public func path(in r: CGRect) -> Path {
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
public struct MarkButton: View {
    public let mark: Mark
    /// 표시 크기 (pt)
    public var size: CGFloat
    public var color: Color = Ink.red
    public var lineWidth: CGFloat = 2
    /// 표시가 없을 때 옅은 점선 동그라미를 보여줄지 (양식에 체크 박스가 인쇄돼 있으면 false)
    public var showsPlaceholder = false
    public let action: () -> Void

    @State private var hover = false
    @Environment(\.isSnapshot) private var isSnapshot

    public init(mark: Mark, size: CGFloat, color: Color = Ink.red, lineWidth: CGFloat = 2, showsPlaceholder: Bool = false, action: @escaping () -> Void) {
        self.mark = mark
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
        self.showsPlaceholder = showsPlaceholder
        self.action = action
    }

    public var body: some View {
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

public struct TaskMenu: View {
    public let date: Date
    public let task: PlanTask
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    public init(date: Date, task: PlanTask) {
        self.date = date
        self.task = task
    }

    public var body: some View {
        // 할 일 왼쪽 칸(주간: 왼쪽 색 막대)을 누르면 뜨는 메뉴와 같은 것
        Menu("형광펜 (분류)") {
            ForEach(store.categories) { c in
                Button { store.setCategory(date, task.id, c.id) } label: {
                    Text((task.cat == c.id ? "✓ " : "   ") + c.name)
                }
            }
            Divider()
            Button((store.category(task.cat) == nil ? "✓ " : "   ") + "없음") { store.setCategory(date, task.id, nil) }
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
    /// 할 일 편집 키: "t|yyyy-MM-dd|<할 일 id>" (일간 · 주간이 같이 쓴다)
    public static func taskKey(_ d: Date, _ id: UUID) -> String { "t|\(Dates.key(d))|\(id.uuidString)" }

    /// 그날 할 일을 쓰는 중이면 그 할 일의 id
    public func editingTaskID(on d: Date) -> UUID? {
        let dk = "t|\(Dates.key(d))|"
        guard let k = editingKey, k.hasPrefix(dk) else { return nil }
        return UUID(uuidString: String(k.dropFirst(dk.count)))
    }

    /// 그날 할 일을 쓰는 중이면 편집을 끝낸다. → 로 넘기기 · 거두기로 그날 할 일이 늘거나 줄면
    /// 쓰던 줄 아래가 막히거나 주간 칸의 순서가 바뀌므로, 쓰던 것을 먼저 마친다.
    public func endEditingTasks(on d: Date) {
        if editingKey?.hasPrefix("t|\(Dates.key(d))|") == true { endEditing() }
    }
}

// MARK: - 형광펜(분류) 고르기 메뉴 (1.0.5)

/// 할 일을 먼저 쓰고, 형광펜(분류)은 나중에 고른다. 일간 TASKS 의 왼쪽 칸이나 주간 할 일 줄의 왼쪽 색 막대를 누르면
/// 마우스 자리에 작은 메뉴가 뜬다: 형광펜마다 색 견본 + 이름, 그리고 "없음". 지금 것에 체크.
/// (macOS: NSMenu 를 마우스 자리에. iOS 는 TaskCategoryPicker 를 SwiftUI Menu 로 띄운다)
#if os(macOS)
@MainActor
public enum TaskCategoryMenu {
    /// 시험용: 메뉴를 마우스 자리에 띄우는 대신 이 클로저에 넘긴다 (NSMenu.popUp 은 메뉴를 닫을 때까지 돌아오지 않는다)
    static var presentForTesting: ((NSMenu) -> Void)?

    public static func show(store: PlannerStore, date: Date, taskID: UUID) {
        guard let menu = menu(store: store, date: date, taskID: taskID) else { return }
        if let presentForTesting { presentForTesting(menu); return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 그 할 일의 형광펜 메뉴 (할 일이 없으면 nil)
    static func menu(store: PlannerStore, date: Date, taskID: UUID) -> NSMenu? {
        guard let task = store.day(date).tasks.first(where: { $0.id == taskID }) else { return nil }
        let current = store.category(task.cat)?.id
        let menu = NSMenu(title: "형광펜")
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: "형광펜 (분류)"))
        for c in store.categories {
            let item = ActionMenuItem(title: c.name) { store.setCategory(date, taskID, c.id) }
            item.image = swatch(c.color)
            item.state = current == c.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = ActionMenuItem(title: "없음") { store.setCategory(date, taskID, nil) }
        none.image = swatch(nil)
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        return menu
    }

    /// 형광펜으로 짧게 한 번 그은 색 견본 (없음: 옅은 점선 테두리만)
    private static func swatch(_ color: Color?) -> NSImage? {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let view = ZStack {
            if let color {
                shape.fill(color)
                shape.stroke(Color.black.opacity(0.12), lineWidth: 0.6)
            } else {
                shape.stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 1.6]))
            }
        }
        .frame(width: 20, height: 11)
        .padding(.vertical, 1)
        let r = ImageRenderer(content: view)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage
        img?.isTemplate = false
        return img
    }
}

/// 눌렀을 때 클로저를 부르는 메뉴 항목
private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(ActionMenuItem.fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) 는 쓰지 않는다") }

    @objc private func fire() { run() }
}
#endif

/// 형광펜(분류) 고르기 목록: 형광펜마다 색 견본 + 이름, 그리고 "없음". 지금 것에 체크.
/// SwiftUI Menu / contextMenu 안에 넣어 쓴다 (iOS 의 할 일 왼쪽 칸, 폰의 키보드 도구 막대).
public struct TaskCategoryPicker: View {
    public let date: Date
    public let taskID: UUID

    @EnvironmentObject private var store: PlannerStore

    public init(date: Date, taskID: UUID) {
        self.date = date
        self.taskID = taskID
    }

    public var body: some View {
        let current = store.category(store.day(date).tasks.first { $0.id == taskID }?.cat)?.id
        Picker("형광펜 (분류)", selection: Binding(get: { current }, set: { store.setCategory(date, taskID, $0) })) {
            ForEach(store.categories) { c in
                Label { Text(c.name) } icon: { CategorySwatch.image(c.color) }
                    .tag(Optional(c.id))
            }
            Label { Text("없음") } icon: { CategorySwatch.image(nil) }
                .tag(Int?.none)
        }
        .pickerStyle(.inline)
    }
}

/// 형광펜으로 짧게 한 번 그은 색 견본 (없음: 옅은 점선 테두리만). 메뉴 항목의 그림으로 쓴다.
public enum CategorySwatch {
    @MainActor
    public static func image(_ color: Color?) -> Image {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let view = ZStack {
            if let color {
                shape.fill(color)
                shape.stroke(Color.black.opacity(0.12), lineWidth: 0.6)
            } else {
                shape.stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 1.6]))
            }
        }
        .frame(width: 20, height: 11)
        .padding(.vertical, 1)
        let r = ImageRenderer(content: view)
        r.scale = 3
        guard let cg = r.cgImage else { return Image(systemName: "circle") }
        return Image(decorative: cg, scale: 3).renderingMode(.original)
    }
}

/// 할 일 왼쪽 칸 (일간: 카테고리 칸, 주간: 색 막대 자리). 누르면 형광펜 메뉴가 뜬다.
/// 화면에서만 있고 (넘김 스냅샷 · PDF 에는 없다), 마우스를 올리면 옅게 드러난다.
/// 놓인 사각형 전체를 누를 수 있고, 옅게 칠하는 모양은 highlightInsets 만큼 안쪽에 그린다 (인쇄된 칸 안에만).
public struct TaskCategoryCell: View {
    public let date: Date
    public let taskID: UUID
    /// 형광펜이 없는 할 일이면 마우스를 올렸을 때 "분류" 글씨를 옅게 보여 준다 (nil = 보여 주지 않는다)
    public var hint: Font? = nil
    public var cornerRadius: CGFloat = 6
    /// 누르는 자리(놓인 사각형)에서 옅게 칠하는 모양까지 안쪽 여백 (pt)
    public var highlightInsets: EdgeInsets = EdgeInsets()

    @EnvironmentObject private var store: PlannerStore
    @State private var hover = false

    public init(date: Date, taskID: UUID, hint: Font? = nil, cornerRadius: CGFloat = 6,
                highlightInsets: EdgeInsets = EdgeInsets()) {
        self.date = date
        self.taskID = taskID
        self.hint = hint
        self.cornerRadius = cornerRadius
        self.highlightInsets = highlightInsets
    }

    public var body: some View {
        let cat = store.category(store.day(date).tasks.first { $0.id == taskID }?.cat)
        let cell = ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Ink.pen.opacity(hover ? 0.08 : 0))
            if hover, cat == nil, let hint {
                Text("분류 ▾")
                    .font(hint)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .padding(highlightInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        #if os(macOS)
        // 단추로 받는다: 누른 채 포인터가 몇 pt 미끄러지거나(트랙패드를 눌러서 클릭) 천천히 눌러도 칸 안에서 떼면 열린다.
        // (1.1.0 까지의 탭 제스처는 약 5pt 넘게 움직이거나 0.8초 넘게 누르면 아무 알림 없이 취소돼 '종종 안 눌렸다')
        // 포커스를 받지 않으니 쓰던 글 칸 · 한글 조합 · 막 시작한 빈 할 일이 그대로 남는다.
        Button { TaskCategoryMenu.show(store: store, date: date, taskID: taskID) } label: { cell }
            .buttonStyle(TaskCategoryCellButtonStyle())
            .focusable(false)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            .pointerCursor(.pointingHand)
            .onDisappear { if hover { PointerCursor.arrow.set() } }
            .help(cat.map { "형광펜: \($0.name) — 눌러서 바꾸기" } ?? "눌러서 형광펜(분류) 고르기")
            .accessibilityLabel(cat.map { "형광펜: \($0.name)" } ?? "형광펜(분류) 고르기")
        #else
        // 누르면 그 자리에 형광펜 메뉴 (iPad 포인터를 올리면 옅게 드러난다)
        Menu {
            TaskCategoryPicker(date: date, taskID: taskID)
        } label: {
            cell
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityLabel(cat.map { "형광펜: \($0.name)" } ?? "형광펜(분류) 고르기")
        #endif
    }
}

#if os(macOS)
/// 누르는 동안 칸을 흐리게 하지 않는 단추 모양 (옅은 칠 · "분류 ▾" 글씨는 마우스를 올렸을 때 그대로)
private struct TaskCategoryCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif

// MARK: - Stars

public struct Stars: View {
    public let value: Int
    public var size: CGFloat
    public let set: (Int) -> Void

    public init(value: Int, size: CGFloat, set: @escaping (Int) -> Void) {
        self.value = value
        self.size = size
        self.set = set
    }

    public var body: some View {
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
public struct SlotPainter: View {
    public let date: Date
    /// 한 칸 너비 / 한 행 높이 (pt)
    public let cellW: CGFloat
    public let rowH: CGFloat
    /// 행 높이 대비 위아래 여백 비율
    public var inset: CGFloat = 0.14

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var snapshot: [Int]? = nil
    /// 지난 걸음에 칠한 범위 (이번 범위 밖으로 줄어든 칸만 붓질 전 값으로 되돌린다)
    @State private var painted: ClosedRange<Int>? = nil
    @State private var anchor = 0
    @State private var paint = -1
    /// 글씨/밥 도구로 끌고 있는 범위
    @State private var pending: ClosedRange<Int>? = nil

    public init(date: Date, cellW: CGFloat, rowH: CGFloat, inset: CGFloat = 0.14) {
        self.date = date
        self.cellW = cellW
        self.rowH = rowH
        self.inset = inset
    }

    public static func hourLabel(_ row: Int) -> String {
        let h = (6 + row) % 24
        return String(h % 12 == 0 ? 12 : h % 12)
    }

    public var body: some View {
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
                    // 지금 저장소의 칸 위에 (그린 뒤 밖에서 들어온 칸을 붓질 전 값으로 덮지 않게)
                    .onChanged { v in drag(v.location, store.day(date).slots) }
                    .onEnded { v in dragEnded(v.location) }
            )
            .pointerCursor(state.tool == AppState.textTool ? .iBeam : .crosshair)

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
                InlineField(text: binding, font: font, key: key, onEnd: { [store, date] in store.afterEditing { store.cleanupNotes(date) } })
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
            painted = nil
            anchor = s
            paint = (state.tool < 0 || current[s] == state.tool) ? -1 : state.tool
        }
        guard let before = snapshot else { return }
        // 지금 칸 위에 이번 범위만 (붓질하는 사이 밖에서 바뀐 다른 칸은 그대로)
        let range = min(anchor, s)...max(anchor, s)
        let next = DayRecord.repainted(current, before: before, previous: painted, range: range, value: paint)
        painted = range
        if next != current { store.editDay(date) { $0.slots = next } }
    }

    private func dragEnded(_ p: CGPoint) {
        defer { snapshot = nil; painted = nil; pending = nil }
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
public struct DDayEditor: View {
    public let date: Date

    @EnvironmentObject private var store: PlannerStore
    @State private var newTitle = ""
    @State private var newDate: Date
    @State private var saveToLibrary = true
    /// 달력을 펼친 줄: 붙인 D-day 의 id 또는 "new"
    @State private var picking: String? = nil
    @State private var showPast = false

    public init(date: Date) {
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

    public var body: some View {
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
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
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
