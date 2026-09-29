import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

/// 설정 창 (형광펜, 기본 컬러 컨셉, D-day, 단축키, 데이터). 팔레트의 톱니 버튼 / ⌘, 로 연다.
/// 패널이라 플래너의 트랙패드 넘김 처리에서 빠지고, 닫으면 초점이 곧바로 플래너 창으로 돌아간다.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    /// 플래너의 키보드 처리에서 이 창의 이벤트를 걸러낼 때 쓰는 식별자
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PaperPlanner.settings")
    private static let frameName = "PaperPlanner.settings"
    private static let size = NSSize(width: 720, height: 560)

    private(set) var window: NSWindow?

    func show(store: PlannerStore, state: AppState) {
        let fresh = window == nil || window?.isVisible == false
        let w = window ?? makeWindow(store: store, state: state)
        window = w
        // 팔레트는 앱을 깨우지 않으므로, 다른 앱을 쓰던 중일 때만 앞으로 가져온다
        if !NSApp.isActive { NSApp.activate() }
        w.makeKeyAndOrderFront(nil)
        guard fresh else { return }
        // 새로 연 창에서 첫 입력 칸이 저절로 잡혀 이름이 선택된 채로 있지 않게 한다
        DispatchQueue.main.async { [weak w] in
            if w?.firstResponder is NSText { w?.makeFirstResponder(nil) }
        }
    }

    private func makeWindow(store: PlannerStore, state: AppState) -> NSWindow {
        let w = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.title = "설정"
        w.identifier = Self.windowIdentifier
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.tabbingMode = .disallowed
        w.collectionBehavior = [.fullScreenNone]

        let host = NSHostingController(rootView: SettingsView().environmentObject(store).environmentObject(state))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(Self.size)
        w.contentMinSize = NSSize(width: 680, height: 460)
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }
}

/// 제목 막대가 있는 평범한 창 모양의 패널 (앱이 비활성일 때도 숨지 않는다)
private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Sections

private enum SettingsPane: String, CaseIterable, Identifiable {
    case pens, concept, dday, shortcuts, data

    var id: Self { self }

    var title: String {
        switch self {
        case .pens: "형광펜"
        case .concept: "컬러 컨셉"
        case .dday: "D-day"
        case .shortcuts: "단축키"
        case .data: "데이터"
        }
    }

    var subtitle: String {
        switch self {
        case .pens: "타임테이블과 할 일에 칠하는 펜이에요. 이름과 색을 바꾸면 이미 칠한 칸에도 바로 반영돼요."
        case .concept: "TOTAL TIME, 요일, D-day 숫자, ○△× 표시에 쓰이는 강조색이에요."
        case .dday: "일간 페이지 위쪽 D-DAY 칸에 남은 날을 세어 적어 줘요."
        case .shortcuts: "손을 키보드에 둔 채로 넘기고, 바꾸고, 칠할 수 있어요."
        case .data: "기록은 이 Mac 에만 저장되고, 적는 즉시 자동으로 저장돼요."
        }
    }

    var symbol: String {
        switch self {
        case .pens: "highlighter"
        case .concept: "paintpalette.fill"
        case .dday: "flag.fill"
        case .shortcuts: "keyboard.fill"
        case .data: "externaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pens: Color(hex: "F2A93B")
        case .concept: Color(hex: "E5577E")
        case .dday: Color(hex: "7B61D1")
        case .shortcuts: Color(hex: "8A8A93")
        case .data: Color(hex: "3A84F0")
        }
    }
}

struct SettingsView: View {
    /// 마지막으로 보던 항목 (실행 인자 `-settingsPane dday` 로도 고를 수 있다)
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.pens.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .pens }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let p = $0 { paneRaw = p.rawValue } })) {
                ForEach(SettingsPane.allCases) { p in
                    HStack(spacing: 9) {
                        SettingsIconTile(symbol: p.symbol, tint: p.tint, size: 22)
                        Text(p.title)
                    }
                    .padding(.vertical, 1)
                    .tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .pens: SettingsPensPane()
                case .concept: SettingsConceptPane()
                case .dday: SettingsDDayPane()
                case .shortcuts: SettingsShortcutsPane()
                case .data: SettingsDataPane()
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - 형광펜

private struct SettingsPensPane: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @FocusState private var focused: Int?
    @State private var pendingDelete: Category?

    var body: some View {
        let cats = store.categories
        let full = cats.count >= Prefs.maxCategories
        ScrollViewReader { proxy in
            Form {
                Section {
                    ForEach(Array(cats.enumerated()), id: \.element.id) { i, c in
                        SettingsPenRow(pen: c, index: i, count: cats.count, focused: $focused,
                                       move: { move(c.id, by: $0) }, delete: { pendingDelete = c })
                            .id(c.id)
                    }
                    .onMove { store.moveCategories(from: $0, to: $1) }
                } header: {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsPaneHeader(pane: .pens)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SettingsSectionTitle(title: "펜 목록", trailing: "\(cats.count) / \(Prefs.maxCategories)")
                            Button { add(proxy) } label: { Label("형광펜 추가", systemImage: "plus") }
                                .controlSize(.small)
                                .disabled(full)
                                .help(full ? "형광펜은 \(Prefs.maxCategories)개까지 만들 수 있어요" : "아직 쓰지 않은 색으로 하나 더 만들어요")
                        }
                    }
                } footer: {
                    SettingsFootnote(text: "줄을 끌어서 순서를 바꿔요. 숫자 키 1–7 은 위에서부터 일곱 개의 펜을, E 는 지우개를 골라요. "
                                     + "TOTAL TIME 에 포함하지 않은 펜(개인, 휴식 같은)은 하루 합계에서 빠져요.")
                }
            }
        }
        .confirmationDialog(pendingDelete.map { "‘\($0.name)’ 형광펜을 지울까요?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { c in
            Button("지우기", role: .destructive) { delete(c.id) }
            Button("취소", role: .cancel) {}
        } message: { c in
            Text(deleteMessage(c))
        }
    }

    private func add(_ proxy: ScrollViewProxy) {
        let cats = store.categories
        guard let id = store.addCategory(name: SettingsPenColors.newName(cats.map(\.name)),
                                         hex: SettingsPenColors.suggest(avoiding: cats.map(\.hex))) else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            focused = id
        }
    }

    private func move(_ id: Int, by delta: Int) {
        guard let i = store.categories.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard store.categories.indices.contains(j) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            store.moveCategories(from: IndexSet(integer: i), to: delta > 0 ? j + 1 : j)
        }
    }

    private func deleteMessage(_ c: Category) -> String {
        let (cells, tasks) = SettingsPenUsage.count(store, c.id)
        if cells == 0 && tasks == 0 { return "아직 이 펜으로 칠한 칸이나 할 일이 없어요." }
        let (h, m) = formatHM(cells * 10)
        var parts: [String] = []
        if cells > 0 { parts.append("칠한 칸 \(h)시간 \(m)분은 빈 칸이") }
        if tasks > 0 { parts.append("할 일 \(tasks)개는 색 없음이") }
        return "이 펜으로 " + parts.joined(separator: ", ") + " 돼요. 되돌릴 수 없어요."
    }

    private func delete(_ id: Int) {
        withAnimation(.snappy(duration: 0.25)) { SettingsPenUsage.delete(store, id) }
        if state.tool == id { state.tool = store.categories.first?.id ?? -1 }
    }
}

private struct SettingsPenRow: View {
    let pen: Category
    let index: Int
    let count: Int
    var focused: FocusState<Int?>.Binding
    let move: (Int) -> Void
    let delete: () -> Void

    @EnvironmentObject private var store: PlannerStore
    @State private var hoverName = false

    var body: some View {
        let editing = focused.wrappedValue == pen.id
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help("끌어서 순서 바꾸기")
            SettingsKeyCap(label: index < 7 ? "\(index + 1)" : "", compact: true)
                .opacity(index < 7 ? 1 : 0)
                .help(index < 7 ? "숫자 키 \(index + 1): 이 펜 고르기" : "")
            SettingsPenSwatch(color: pen.color)
            TextField("", text: name, prompt: Text("이름"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused(focused, equals: pen.id)
                .onSubmit { fixEmptyName() }
                .onChange(of: focused.wrappedValue) { old, _ in if old == pen.id { fixEmptyName() } }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(editing ? 0.06 : hoverName ? 0.04 : 0))
                }
                .overlay(alignment: .trailing) {
                    if hoverName && !editing {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.leading, -6)
                .onHover { hoverName = $0 }
                .help("눌러서 이름 바꾸기")
            Toggle(isOn: Binding(get: { pen.counts }, set: { v in store.updateCategory(pen.id) { $0.counts = v } })) {
                Text("TOTAL TIME에 포함")
                    .foregroundStyle(pen.counts ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
            .help("켜면 이 펜으로 칠한 시간이 하루 TOTAL TIME 에 더해져요")
            ColorPicker("색", selection: Binding(get: { pen.color },
                                                set: { v in store.updateCategory(pen.id) { $0.hex = v.hexString } }),
                        supportsOpacity: false)
                .labelsHidden()
                .help("색 바꾸기")
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(count <= 1)
            .help(count <= 1 ? "형광펜은 적어도 하나는 있어야 해요" : "이 형광펜 지우기")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("위로 옮기기") { move(-1) }.disabled(index == 0)
            Button("아래로 옮기기") { move(1) }.disabled(index == count - 1)
            Divider()
            Button("지우기…", role: .destructive, action: delete).disabled(count <= 1)
        }
    }

    private var name: Binding<String> {
        Binding(get: { pen.name }, set: { v in store.updateCategory(pen.id) { $0.name = v } })
    }

    private func fixEmptyName() {
        guard pen.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.updateCategory(pen.id) { $0.name = "형광펜 \(index + 1)" }
    }
}

/// 형광펜으로 한 번 그은 짧은 줄 (페이지의 HighlighterBar 와 같은 모양을 틀 안에 맞춰, 어두운 모드에서도 제 색으로)
private struct SettingsPenSwatch: View {
    let color: Color

    var body: some View {
        SettingsStrokeShape()
            .fill(color.opacity(0.92))
            .frame(width: 44, height: 15)
            .rotationEffect(.degrees(-2))
    }
}

private struct SettingsStrokeShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: h * 0.12, y: h * 0.18))
        p.addLine(to: CGPoint(x: w - h * 0.22, y: h * 0.08))
        p.addQuadCurve(to: CGPoint(x: w - h * 0.12, y: h * 0.88), control: CGPoint(x: w, y: h * 0.48))
        p.addLine(to: CGPoint(x: h * 0.16, y: h * 0.95))
        p.addQuadCurve(to: CGPoint(x: h * 0.12, y: h * 0.18), control: CGPoint(x: 0, y: h * 0.56))
        return p.offsetBy(dx: r.minX, dy: r.minY)
    }
}

/// 형광펜 삭제 / 사용량 (지운 펜의 칸과 할 일 색을 같이 비워서, 나중에 같은 id 가 다시 생겨도 되살아나지 않게)
@MainActor
private enum SettingsPenUsage {
    static func count(_ store: PlannerStore, _ id: Int) -> (cells: Int, tasks: Int) {
        store.data.days.values.reduce(into: (0, 0)) { acc, r in
            acc.0 += r.slots.lazy.filter { $0 == id }.count
            acc.1 += r.tasks.lazy.filter { $0.cat == id }.count
        }
    }

    static func delete(_ store: PlannerStore, _ id: Int) {
        guard store.categories.count > 1 else { return }
        var days = store.data.days
        for (k, var r) in days where r.slots.contains(id) || r.tasks.contains(where: { $0.cat == id }) {
            r.slots = r.slots.map { $0 == id ? -1 : $0 }
            for i in r.tasks.indices where r.tasks[i].cat == id { r.tasks[i].cat = nil }
            days[k] = r.isEmpty ? nil : r
        }
        if days != store.data.days { store.data.days = days }
        store.removeCategory(id)
    }
}

/// 새 형광펜의 이름과 색 (이미 쓰는 색과 가장 멀리 떨어진 형광 파스텔)
private enum SettingsPenColors {
    static let candidates = ["B9E4A8", "FFC98C", "9ED3F4", "F5A7BA", "D6C4F3", "F7E07A",
                             "A7E3D1", "FFB4A0", "CBE28A", "B5C2F6", "F2C3E0", "E6D2AE", "9FDFE3", "FFD8A6"]

    static func suggest(avoiding used: [String]) -> String {
        let taken = used.map(rgb)
        var best = candidates[0], bestDistance = -1.0
        for c in candidates {
            let p = rgb(c)
            let d = taken.map { distance(p, $0) }.min() ?? .infinity
            if d > bestDistance { best = c; bestDistance = d }
        }
        return best
    }

    static func newName(_ names: [String]) -> String {
        let base = "새 형광펜"
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// 사람 눈에 가까운 가중 RGB 거리
    private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let r = (a.0 + b.0) / 2
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return ((2 + r / 256) * dr * dr + 4 * dg * dg + (2 + (255 - r) / 256) * db * db).squareRoot()
    }
}

// MARK: - 컬러 컨셉

private struct SettingsConceptPane: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var confirmReset = false

    var body: some View {
        let def = store.data.prefs.defaultTheme
        let current = ColorConcept.of(def)
        let custom = store.data.days.values.filter { $0.theme != nil }.count
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(ColorConcept.all) { c in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { store.editPrefs { $0.defaultTheme = c.id } }
                        } label: {
                            SettingsConceptCard(concept: c, selected: c.id == current.id)
                        }
                        .buttonStyle(.plain)
                        .help("기본 컬러로 정하기: \(c.name)")
                    }
                }
                .padding(.vertical, 6)
                // 손글씨 글꼴이 등록되기 전에 그려졌으면 다시 그린다
                .id(state.fontsReady)
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .concept)
                    SettingsSectionTitle(title: "기본 컬러", trailing: current.name)
                }
            } footer: {
                SettingsFootnote(text: "따로 고르지 않은 날은 모두 이 컬러를 따라가요. 하루만 바꾸고 싶으면 그날 일간 페이지를 연 채로 "
                                 + "팔레트의 ‘오늘의 컬러’에서 고르세요.")
            }

            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("따로 컬러를 고른 날")
                        Text(custom == 0 ? "모든 날이 기본 컬러를 따르고 있어요" : "\(custom)일이 자기만의 컬러를 쓰고 있어요")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("모두 기본 컬러로…") { confirmReset = true }
                        .disabled(custom == 0)
                }
            }
        }
        .confirmationDialog("\(custom)일의 컬러를 기본 컬러로 되돌릴까요?", isPresented: $confirmReset) {
            Button("되돌리기", role: .destructive) { resetDays() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("그날그날 고른 컬러가 지워지고 모두 기본 컬러(\(current.name))를 따라가요.")
        }
    }

    private func resetDays() {
        var days = store.data.days
        for (k, var r) in days where r.theme != nil {
            r.theme = nil
            days[k] = r.isEmpty ? nil : r
        }
        withAnimation(.snappy(duration: 0.2)) { store.data.days = days }
        store.scheduleSave()
    }
}

/// 종이 위에 쓴 날짜(요일은 강조색, 밑에 옅은 형광펜) + TOTAL TIME 스탬프
private struct SettingsConceptCard: View {
    let concept: ColorConcept
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                Ink.paper
                VStack(spacing: 3) {
                    (Text("0929 ").foregroundStyle(Ink.text) + Text("TUE").foregroundStyle(concept.accent))
                        .font(Fonts.hand(21))
                        .background(alignment: .bottom) {
                            HighlighterBar(color: concept.tint)
                                .frame(height: 8)
                                .padding(.horizontal, -4)
                                .offset(y: -1)
                        }
                    (Text("8").font(Fonts.rounded(25, .black)) + Text("H").font(Fonts.rounded(13, .black))
                        + Text("36").font(Fonts.rounded(25, .black)) + Text("M").font(Fonts.rounded(13, .black)))
                        .kerning(-0.4)
                        .foregroundStyle(concept.accent)
                }
            }
            .compositingGroup()
            .frame(height: 78)

            HStack(spacing: 6) {
                Text(concept.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? concept.accent : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? concept.accent : Color.primary.opacity(hover ? 0.25 : 0.12),
                                    lineWidth: selected ? 2 : 1))
        .contentShape(shape)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - D-day

private struct SettingsDDayPane: View {
    @EnvironmentObject private var store: PlannerStore
    @FocusState private var focused: UUID?

    var body: some View {
        let list = store.data.prefs.ddays
        let accent = ColorConcept.of(store.data.prefs.defaultTheme).accent
        Form {
            Section {
                if list.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("아직 D-day 가 없어요")
                            Text("시험, 런칭, 여행처럼 기다리는 날을 더해 보세요.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(list) { d in
                    SettingsDDayRow(dday: d, accent: accent, focused: $focused,
                                    edit: { f in edit(d.id, f) },
                                    remove: { remove(d.id) })
                }
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .dday)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettingsSectionTitle(title: "기다리는 날", trailing: "\(list.count) / \(Prefs.maxDDays)")
                        Button { add() } label: { Label("D-day 추가", systemImage: "plus") }
                            .controlSize(.small)
                            .disabled(list.count >= Prefs.maxDDays)
                            .help(list.count >= Prefs.maxDDays ? "D-day 는 \(Prefs.maxDDays)개까지 적을 수 있어요" : "기다리는 날 더하기")
                    }
                }
            } footer: {
                SettingsFootnote(text: "두 개까지 적을 수 있어요. 날짜가 지나면 D+ 로 세고, 숫자는 그날의 컬러로 적혀요.")
            }

            Section {
                SettingsDDayPreview(list: list, accent: accent)
            } header: {
                SettingsSectionTitle(title: "일간 페이지에서는")
            }
        }
    }

    private func add() {
        let d = DDay(title: "", date: Dates.add(days: 30, to: Dates.day(Date())))
        withAnimation(.snappy(duration: 0.25)) { store.editPrefs { $0.ddays.append(d) } }
        DispatchQueue.main.async { focused = d.id }
    }

    private func edit(_ id: UUID, _ f: (inout DDay) -> Void) {
        store.editPrefs { p in
            if let i = p.ddays.firstIndex(where: { $0.id == id }) { f(&p.ddays[i]) }
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy(duration: 0.25)) { store.editPrefs { $0.ddays.removeAll { $0.id == id } } }
    }
}

private struct SettingsDDayRow: View {
    let dday: DDay
    let accent: Color
    var focused: FocusState<UUID?>.Binding
    let edit: ((inout DDay) -> Void) -> Void
    let remove: () -> Void

    @State private var picking = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E)"
        return f
    }()

    var body: some View {
        let n = Dates.daysBetween(Date(), dday.date)
        HStack(spacing: 12) {
            Text(n > 0 ? "D-\(n)" : n == 0 ? "D-DAY" : "D+\(-n)")
                .font(Fonts.rounded(15, .heavy))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 64, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(get: { dday.title }, set: { v in edit { $0.title = v } }),
                          prompt: Text("무엇까지? (예: 런칭)"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused(focused, equals: dday.id)
                Text(n > 0 ? "\(n)일 남았어요" : n == 0 ? "바로 오늘이에요" : "\(-n)일 지났어요")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 날짜는 달력에서 고른다 (글자 칸이 아니라서 플래너의 숫자·화살표 단축키와 부딪히지 않는다)
            Button { picking = true } label: {
                Label(Self.dateFormat.string(from: dday.date), systemImage: "calendar")
                    .monospacedDigit()
                    .frame(minWidth: 172, alignment: .leading)
            }
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                DatePicker("날짜", selection: Binding(get: { dday.date }, set: { v in edit { $0.date = Dates.day(v) } }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .padding(12)
            }
            .help("날짜 고르기")
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("이 D-day 지우기")
        }
        .padding(.vertical, 3)
    }
}

/// 일간 페이지의 D-DAY 칸 그대로: 인쇄된 "D-DAY ──" 머리선 아래 손글씨 제목 + 강조색 숫자
private struct SettingsDDayPreview: View {
    let list: [DDay]
    let accent: Color
    @EnvironmentObject private var state: AppState

    var body: some View {
        let two = list.count > 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("D-DAY")
                    .font(Fonts.print(11, .demiBold))
                    .tracking(-0.3)
                    .foregroundStyle(Ink.print)
                Rectangle().fill(Ink.print).frame(height: 1.3)
            }
            VStack(spacing: two ? 0 : 2) {
                if list.isEmpty {
                    Text("+ D-day")
                        .font(Fonts.hand(28))
                        .foregroundStyle(Ink.faint)
                }
                ForEach(list) { d in
                    let n = Dates.daysBetween(Date(), d.date)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(d.title.isEmpty ? "D-day" : d.title)
                            .font(Fonts.hand(two ? 24 : 30))
                            .foregroundStyle(Ink.text)
                        Text(n > 0 ? "D-\(n)" : n == 0 ? "D-DAY" : "D+\(-n)")
                            .font(Fonts.hand(two ? 29 : 40))
                            .foregroundStyle(accent)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .id(state.fontsReady)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Ink.paper)
                .overlay(NoiseLayer(opacity: 0.5).blendMode(.multiply).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 단축키

private struct SettingsShortcutsPane: View {
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        Form {
            Section {
                SettingsShortcutRow(keys: ["←", "→"], title: "이전 장 · 다음 장",
                                    detail: "트랙패드를 두 손가락으로 가로로 쓸어도 종이가 넘어가요", alt: "⌘[ ⌘]")
                SettingsShortcutRow(keys: ["T"], title: "오늘로 가기", alt: "⌘T")
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .shortcuts)
                    SettingsSectionTitle(title: "넘기기")
                }
            }

            Section {
                SettingsShortcutRow(keys: ["H"], title: "홈 (전체 통계)", alt: "⌘0")
                SettingsShortcutRow(keys: ["W"], title: "주간", alt: "⌘1")
                SettingsShortcutRow(keys: ["D"], title: "일간", alt: "⌘2")
            } header: {
                SettingsSectionTitle(title: "보기")
            }

            Section {
                SettingsShortcutRow(keys: ["1", "–", "7"], title: "형광펜 고르기") {
                    penLegend
                }
                SettingsShortcutRow(keys: ["E"], title: "지우개")
                SettingsShortcutRow(keys: ["esc"], title: "글쓰기 마치기")
            } header: {
                SettingsSectionTitle(title: "도구")
            }

            Section {
                SettingsShortcutRow(keys: ["⌘", ","], title: "설정 열기")
            } header: {
                SettingsSectionTitle(title: "앱")
            } footer: {
                SettingsFootnote(text: "한글 입력 상태에서도 그대로 동작해요. 글자를 쓰는 동안에는 글자·숫자 단축키가 잠시 쉬어요.")
            }
        }
    }

    /// 숫자 키에 걸린 펜들: "1 ▬ 집중 업무  2 ▬ 미팅 …"
    private var penLegend: some View {
        let pens = Array(store.categories.prefix(7).enumerated())
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6, alignment: .leading)],
                         alignment: .leading, spacing: 4) {
            ForEach(pens, id: \.element.id) { i, c in
                HStack(spacing: 5) {
                    Text("\(i + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(c.color)
                        .frame(width: 12, height: 8)
                    Text(c.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct SettingsShortcutRow<Detail: View>: View {
    let keys: [String]
    let title: String
    var detail: String? = nil
    var alt: String? = nil
    @ViewBuilder var extra: () -> Detail

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                extra()
            }
            Spacer(minLength: 12)
            if let alt {
                Text(alt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("메뉴 단축키")
            }
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                    if k == "–" {
                        Text("–").foregroundStyle(.secondary)
                    } else {
                        SettingsKeyCap(label: k)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension SettingsShortcutRow where Detail == EmptyView {
    init(keys: [String], title: String, detail: String? = nil, alt: String? = nil) {
        self.init(keys: keys, title: title, detail: detail, alt: alt) { EmptyView() }
    }
}

// MARK: - 데이터

private struct SettingsDataPane: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var exported: URL?
    @State private var exportError: String?

    private static let isDemo = CommandLine.arguments.contains("--demo")

    var body: some View {
        let file = SettingsDataFile.url
        Form {
            Section {
                LabeledContent("위치") {
                    Text(SettingsDataFile.displayPath(file))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    LabeledContent("마지막 저장") {
                        Text(SettingsDataFile.summary(file))
                            .foregroundStyle(.secondary)
                    }
                }
                if Self.isDemo {
                    Label("데모 데이터로 실행 중이라 이 파일에는 저장하지 않아요.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button { SettingsDataFile.reveal(file) } label: { Label("Finder에서 보기", systemImage: "folder") }
                    Button { export() } label: { Label("백업 내보내기…", systemImage: "square.and.arrow.up") }
                    Spacer(minLength: 8)
                    if let exported {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([exported]) } label: {
                            Label("\(exported.lastPathComponent) 저장됨", systemImage: "checkmark.circle.fill")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.green)
                        .help("Finder 에서 백업 파일 보기")
                    } else if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .data)
                    SettingsSectionTitle(title: "데이터 파일")
                }
            } footer: {
                SettingsFootnote(text: "복원하려면 앱을 종료한 뒤 백업 파일을 이 위치의 planner.json 으로 바꿔 넣으세요.")
            }

            Section {
                let s = SettingsDataFile.stats(store)
                LabeledContent("기록한 날", value: "\(s.days)일")
                LabeledContent("적은 할 일", value: "\(s.tasks)개")
                LabeledContent("칠한 시간", value: s.hours)
            } header: {
                SettingsSectionTitle(title: "담긴 기록")
            }

            Section {
                LabeledContent("버전", value: SettingsDataFile.version)
                LabeledContent("손글씨 글꼴", value: "Poor Story · SIL OFL 1.1")
            } header: {
                SettingsSectionTitle(title: "정보")
            }
        }
    }

    private func export() {
        store.saveNow()
        let panel = NSSavePanel()
        panel.title = "백업 내보내기"
        panel.prompt = "내보내기"
        panel.nameFieldStringValue = "PaperPlanner 백업 \(Dates.key(Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try SettingsDataFile.encode(store.data).write(to: dest, options: .atomic)
                exported = dest
                exportError = nil
            } catch {
                exported = nil
                exportError = "저장하지 못했어요: \(error.localizedDescription)"
            }
        }
        if let w = SettingsWindowController.shared.window, w.isVisible {
            panel.beginSheetModal(for: w) { r in MainActor.assumeIsolated { finish(r) } }
        } else {
            finish(panel.runModal())
        }
    }
}

/// 데이터 파일 위치 (PlannerStore 와 같은 경로) 와 정보 표시용 계산
@MainActor
private enum SettingsDataFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperPlanner", isDirectory: true)
            .appendingPathComponent("planner.json")
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private static let savedFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 a h:mm"
        return f
    }()

    static func summary(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "아직 저장된 파일이 없어요" }
        let size = ByteCountFormatter.string(fromByteCount: (a[.size] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
        guard let d = a[.modificationDate] as? Date else { return size }
        return "\(size) · \(savedFormat.string(from: d))"
    }

    /// 파일이 있으면 파일을, 없으면 있는 곳까지 올라간 폴더를 Finder 에서 연다
    static func reveal(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    static func encode(_ data: PlannerData) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(data)
    }

    static func stats(_ store: PlannerStore) -> (days: Int, tasks: Int, hours: String) {
        let known = Set(store.categories.map(\.id))
        var tasks = 0, cells = 0
        for r in store.data.days.values {
            tasks += r.tasks.count
            cells += r.slots.lazy.filter { known.contains($0) }.count
        }
        let (h, m) = formatHM(cells * 10)
        return (store.data.days.count, tasks, "\(h)시간 \(m)분")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "개발 빌드" }
        if let b = info?["CFBundleVersion"] as? String, b != v { return "\(v) (\(b))" }
        return v
    }
}

// MARK: - Shared bits

/// System Settings 처럼 색 바탕에 흰 기호가 있는 둥근 사각형
private struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.88), tint], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
    }
}

private struct SettingsPaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: pane.symbol, tint: pane.tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Text(pane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}

private struct SettingsSectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 자판 한 개
private struct SettingsKeyCap: View {
    let label: String
    var compact = false

    var body: some View {
        let side: CGFloat = compact ? 18 : 24
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 5.5, style: .continuous)
        Text(label)
            .font(.system(size: compact ? 10.5 : 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, label.count > 1 ? 7 : 0)
            .frame(minWidth: side, minHeight: side)
            .background(shape.fill(.background).shadow(color: .black.opacity(0.22), radius: 0, y: compact ? 0.5 : 1))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }
}
