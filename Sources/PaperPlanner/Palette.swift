import AppKit
import SwiftUI

/// 창 오른쪽 옆에 떠 있는 도구 팔레트.
/// 본 창의 child window 라서 창을 옮기면 같이 움직이고, 앱을 활성화시키지 않는다.
@MainActor
final class PaletteController {
    private let panel: PalettePanel
    private let host: NSHostingView<AnyView>
    private weak var parent: NSWindow?

    init(parent: NSWindow, store: PlannerStore, state: AppState) {
        self.parent = parent
        host = NSHostingView(rootView: AnyView(PaletteView().environmentObject(store).environmentObject(state)))
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: MainWindowController.paletteWidth, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = host
    }

    func attach() {
        guard let parent, panel.parent == nil else { reposition(); return }
        parent.addChildWindow(panel, ordered: .above)
        reposition()
        panel.orderFront(nil)
    }

    func reposition() {
        guard let parent else { return }
        let size = host.fittingSize
        let f = parent.frame
        let vis = (parent.screen ?? NSScreen.main)?.visibleFrame ?? f
        var x = f.maxX + MainWindowController.paletteGap
        // 오른쪽에 자리가 없으면 창 왼쪽에 붙인다
        if x + size.width > vis.maxX { x = f.minX - MainWindowController.paletteGap - size.width }
        var y = f.midY - size.height / 2
        y = min(max(y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }
}

/// 텍스트 입력(펜 이름 바꾸기)을 위해 key 가 될 수 있는 비활성화 패널
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Palette UI

struct PaletteView: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var editing: Int? = nil
    @State private var editingDDay = false

    var body: some View {
        VStack(spacing: 12) {
            BookMenu()

            VStack(spacing: 4) {
                kindButton(.home, "홈", "chart.bar.xaxis", "H")
                kindButton(.weekly, "주간", "rectangle.split.3x1", "W")
                kindButton(.daily, "일간", "doc.plaintext", "D")
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    IconButton(icon: "chevron.left", help: "이전 장 (←)") { state.flip(.backward) }
                    IconButton(icon: "chevron.right", help: "다음 장 (→)") { state.flip(.forward) }
                }
                Button { state.goToday() } label: {
                    Text("오늘")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("오늘로 (T)")
                Button { editingDDay = true } label: {
                    Label("D-day", systemImage: "flag.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $editingDDay, arrowEdge: .leading) { DDayEditor().environmentObject(store) }
                .help("D-day 설정")
            }

            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 6)

            ConceptPicker()

            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 6)

            VStack(spacing: 6) {
                ForEach(store.categories) { c in
                    PenRow(color: c.color, name: c.name, selected: state.tool == c.id)
                        .onTapGesture(count: 2) { editing = c.id }
                        .onTapGesture { select(c.id) }
                        .popover(isPresented: Binding(get: { editing == c.id }, set: { if !$0 { editing = nil } }),
                                 arrowEdge: .leading) {
                            PenEditor(id: c.id).environmentObject(store)
                        }
                        .help("\(c.name) 형광펜 — 클릭: 선택 · 더블클릭: 이름·색 바꾸기")
                }
                EraserRow(selected: state.tool == -1)
                    .onTapGesture { select(-1) }
                    .help("지우개 (E) — 칠한 칸, 글씨, 밥시간을 지운다")
                HStack(spacing: 4) {
                    ToolChip(icon: "pencil.line", title: "글씨", selected: state.tool == AppState.textTool)
                        .onTapGesture { select(AppState.textTool) }
                        .help("타임테이블에 글씨 쓰기 — 칸을 누르거나 끌어서 쓰기 시작")
                    ToolChip(icon: "fork.knife", title: "밥", selected: state.tool == AppState.mealTool)
                        .onTapGesture { select(AppState.mealTool) }
                        .help("밥시간 — 시작 칸부터 끝 칸까지 끌기 (누르기만 하면 1시간)")
                }
            }

            Button { SettingsWindowController.shared.show(store: store, state: state) } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("설정 (⌘,) — 형광펜 이름·색, 기본 컬러, D-day")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: MainWindowController.paletteWidth)
        .modifier(PaletteBackground())
        .padding(6) // 그림자 여유
    }

    private func select(_ id: Int) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { state.tool = id }
    }

    private func kindButton(_ k: PageKind, _ title: String, _ icon: String, _ key: String) -> some View {
        let on = state.kind == k
        return Button { state.switchKind(k) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color(hex: "3C3357") : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) 보기 (\(key))")
        .animation(.snappy(duration: 0.25), value: on)
    }
}

/// 지금 펼친 플래너(책). 눌러서 다른 권으로 바꾸거나 관리 화면을 연다.
private struct BookMenu: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        let book = store.activeBook
        Menu {
            ForEach(store.books) { b in
                Button { store.activate(b.id) } label: {
                    Text((b.id == book?.id ? "✓ " : "   ") + b.name)
                }
            }
            Divider()
            Button("플래너 관리…") { SettingsWindowController.shared.show(store: store, state: state) }
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ColorConcept.of(book?.cover ?? 0).accent)
                    .frame(width: 22, height: 28)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.18)).frame(width: 3)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                Text(book?.name ?? "플래너 없음")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(book.map { "\($0.name) · \($0.periodText)" } ?? "플래너를 만들어 주세요")
    }
}

/// 그날의 컬러 컨셉 (일간: 이 날만, 주간: 기본값). 오른쪽 클릭으로 기본값 지정.
private struct ConceptPicker: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        let daily = state.kind == .daily
        let date = state.dayDate(state.dayIndex)
        let dayTheme = store.day(date).theme
        let def = store.data.prefs.defaultTheme
        let current = daily ? (dayTheme ?? def) : def
        VStack(spacing: 6) {
            Text(daily ? "오늘의 컬러" : "기본 컬러")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.6))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 5), count: 3), spacing: 5) {
                ForEach(ColorConcept.all) { c in
                    Circle()
                        .fill(c.accent)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(current == c.id ? 0.85 : 0), lineWidth: 2).padding(-3))
                        .overlay {
                            if c.id == def {
                                Circle().fill(.white).frame(width: 4, height: 4)
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.2)) {
                                if daily { store.setTheme(date, c.id == def ? nil : c.id) } else { store.editPrefs { $0.defaultTheme = c.id } }
                            }
                        }
                        .contextMenu {
                            Button("기본 컬러로 정하기") { store.editPrefs { $0.defaultTheme = c.id } }
                            if daily { Button("이 날은 기본 컬러 따르기") { store.setTheme(date, nil) } }
                        }
                        .help("\(c.name)\(c.id == def ? " · 기본" : "") — 오른쪽 클릭: 기본 컬러로")
                }
            }
        }
    }
}

private struct PaletteBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 0.6))
        }
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hover ? 0.12 : 0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 누워 있는 형광펜: 왼쪽(종이 쪽)으로 납작한 심, 색 뚜껑, 흰 몸통
private struct PenRow: View {
    let color: Color
    let name: String
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                // 심 (chisel tip)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 4))
                    p.addLine(to: CGPoint(x: 7, y: 0))
                    p.addLine(to: CGPoint(x: 7, y: 12))
                    p.addLine(to: CGPoint(x: 0, y: 9))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.95))
                .frame(width: 7, height: 12)
                // 뚜껑
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 1.5,
                                       topTrailingRadius: 1.5, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.8), color, color.opacity(0.85)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 16)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 10, height: 2).offset(y: 3)
                    }
                // 몸통
                UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5, bottomTrailingRadius: 5,
                                       topTrailingRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(hex: "E9E7E2")], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: 14)
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).padding(.leading, 4) }
            }
            .shadow(color: selected ? color.opacity(0.9) : .black.opacity(0.18), radius: selected ? 6 : 1.5, y: 1)
            .offset(x: selected ? -4 : hover ? -2 : 0)

            Text(name)
                .font(.system(size: 9, weight: selected ? .bold : .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// 타임테이블 도구 (글씨 · 밥)
private struct ToolChip: View {
    let icon: String
    let title: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 9, weight: selected ? .bold : .medium, design: .rounded))
        }
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color(hex: "3C3357") : Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }
}

private struct EraserRow: View {
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(hex: "7FA7E0"))
                    .frame(width: 26, height: 18)
                    .overlay(Text("ERASE").font(.system(size: 5.5, weight: .black, design: .rounded)).foregroundStyle(.white))
            }
            .shadow(color: selected ? Color(hex: "7FA7E0").opacity(0.9) : .black.opacity(0.18), radius: selected ? 6 : 1.5, y: 1)
            .offset(x: selected ? -4 : hover ? -2 : 0)
            Text("지우개")
                .font(.system(size: 9, weight: selected ? .bold : .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

private struct PenEditor: View {
    let id: Int
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let c = store.category(id) ?? Category(id: id, name: "", hex: "CCCCCC", counts: false)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(c.color).frame(width: 12, height: 12)
                Text("형광펜").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            TextField("이름", text: Binding(get: { c.name }, set: { v in store.updateCategory(id) { $0.name = v } }))
                .textFieldStyle(.roundedBorder)
            ColorPicker("색", selection: Binding(get: { c.color }, set: { v in store.updateCategory(id) { $0.hex = v.hexString } }),
                        supportsOpacity: false)
            Toggle("TOTAL TIME 에 포함", isOn: Binding(get: { c.counts },
                                                     set: { v in store.updateCategory(id) { $0.counts = v } }))
        }
        .padding(14)
        .frame(width: 220)
    }
}
