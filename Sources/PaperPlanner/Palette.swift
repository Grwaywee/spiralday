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

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
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
            }

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
                        .help("\(c.name) 형광펜 — 클릭: 선택 · 더블클릭: 이름 바꾸기 (\(c.id + 1))")
                }
                EraserRow(selected: state.tool == -1)
                    .onTapGesture { select(-1) }
                    .help("지우개 (E)")
            }
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
            .offset(x: selected ? -7 : hover ? -3 : 0)

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
            .offset(x: selected ? -7 : hover ? -3 : 0)
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
        let c = store.categories[id]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(c.color).frame(width: 12, height: 12)
                Text("형광펜").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            TextField("이름", text: Binding(get: { c.name }, set: { v in store.editPrefs { $0.categories[id].name = v } }))
                .textFieldStyle(.roundedBorder)
            Toggle("TOTAL TIME 에 포함", isOn: Binding(get: { c.counts },
                                                     set: { v in store.editPrefs { $0.categories[id].counts = v } }))
        }
        .padding(14)
        .frame(width: 220)
    }
}
