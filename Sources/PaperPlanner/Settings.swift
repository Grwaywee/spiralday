import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

/// 설정 창 (플래너, 형광펜, 기본 컬러 컨셉, D-day, 단축키, 데이터). 팔레트의 톱니 버튼 / ⌘, 로 연다.
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

    /// 플래너(책) 목록을 펼친 채로 연다 (팔레트의 ‘플래너 관리…’)
    func showPlanners(store: PlannerStore, state: AppState) {
        UserDefaults.standard.set(SettingsPane.books.rawValue, forKey: SettingsView.paneKey)
        show(store: store, state: state)
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
    case books, pens, concept, dday, shortcuts, data

    var id: Self { self }

    var title: String {
        switch self {
        case .books: "플래너"
        case .pens: "형광펜"
        case .concept: "컬러 컨셉"
        case .dday: "D-day"
        case .shortcuts: "단축키"
        case .data: "데이터"
        }
    }

    var subtitle: String {
        switch self {
        case .books: "플래너 한 권이 책 한 권이에요. 권마다 기록과 설정이 따로 있고, 골라서 펼쳐 써요."
        case .pens: "타임테이블과 할 일에 칠하는 펜이에요. 이름과 색을 바꾸면 이미 칠한 칸에도 바로 반영돼요."
        case .concept: "TOTAL TIME, 요일, D-day 숫자, ○△× 표시에 쓰이는 강조색이에요."
        case .dday: "일간 페이지 위쪽 D-DAY 칸에 남은 날을 세어 적어 줘요."
        case .shortcuts: "손을 키보드에 둔 채로 넘기고, 바꾸고, 칠할 수 있어요."
        case .data: "기록은 이 Mac 에만 저장되고, 적는 즉시 자동으로 저장돼요."
        }
    }

    var symbol: String {
        switch self {
        case .books: "books.vertical.fill"
        case .pens: "highlighter"
        case .concept: "paintpalette.fill"
        case .dday: "flag.fill"
        case .shortcuts: "keyboard.fill"
        case .data: "externaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .books: Color(hex: "34A36B")
        case .pens: Color(hex: "F2A93B")
        case .concept: Color(hex: "E5577E")
        case .dday: Color(hex: "7B61D1")
        case .shortcuts: Color(hex: "8A8A93")
        case .data: Color(hex: "3A84F0")
        }
    }

    /// 펼친 책마다 따로 저장되는 설정인지
    var perBook: Bool { self == .pens || self == .concept || self == .dday }
}

struct SettingsView: View {
    static let paneKey = "settingsPane"
    /// 마지막으로 보던 항목 (실행 인자 `-settingsPane dday` 로도 고를 수 있다)
    @AppStorage(SettingsView.paneKey) private var paneRaw = SettingsPane.books.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .books }

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
                case .books: SettingsBooksPane()
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

// MARK: - 플래너 (책)

private struct SettingsBooksPane: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var editor: SettingsBookEditorRequest?
    @State private var pendingDelete: BookInfo?

    var body: some View {
        let books = store.books
        let openID = store.activeBook?.id
        ScrollViewReader { proxy in
            Form {
                Section {
                    if books.isEmpty {
                        SettingsBooksEmpty { editor = .create }
                    }
                    ForEach(books) { b in
                        let isOpen = b.id == openID
                        SettingsBookRow(book: b, isOpen: isOpen,
                                        recordDays: isOpen ? store.data.days.count : nil,
                                        canDelete: books.count > 1,
                                        open: { open(b.id) },
                                        edit: { editor = .edit(b) },
                                        delete: { pendingDelete = b })
                            .id(b.id)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsPaneHeader(pane: .books)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SettingsSectionTitle(title: "책장", trailing: books.isEmpty ? nil : "\(books.count)권")
                            Button { editor = .create } label: { Label("새 플래너 만들기", systemImage: "plus") }
                                .controlSize(.small)
                                .help("시작일을 정해 새 플래너를 만들고 바로 펼쳐요")
                        }
                    }
                } footer: {
                    SettingsFootnote(text: footnote(books.count))
                }

                Section {
                    SettingsBookRuleRow(symbol: "arrow.left.to.line", title: "시작일이 첫 장이에요",
                                        detail: "시작일보다 앞으로는 일간도 주간도 넘어가지 않아요. 시작일은 꼭 정해야 해요.")
                    SettingsBookRuleRow(symbol: "arrow.right.to.line", title: "종료일을 정하면 그날에서 멈춰요",
                                        detail: "종료일이 마지막 장이 돼요. 나중에 편집에서 늘리거나 없앨 수 있어요.")
                    SettingsBookRuleRow(symbol: "infinity", title: "종료일이 없으면 계속 넘어가요",
                                        detail: "끝을 정하지 않은 플래너는 오늘 이후로도 끝없이 이어져요.")
                } header: {
                    SettingsSectionTitle(title: "책처럼 넘겨요")
                }
            }
            .onChange(of: openID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .sheet(item: $editor) { req in
            SettingsBookEditor(book: req.book,
                               suggestedName: SettingsBookDefaults.name(store.books.map(\.name)),
                               suggestedCover: SettingsBookDefaults.cover(store.books.map(\.cover)))
                .environmentObject(store)
                .environmentObject(state)
        }
        .confirmationDialog(pendingDelete.map { "‘\($0.name)’\(SettingsJosa.pick($0.name, "을", "를")) 지울까요?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { b in
            Button("영구히 지우기", role: .destructive) { delete(b.id) }
            Button("취소", role: .cancel) {}
        } message: { b in
            Text(deleteMessage(b))
        }
    }

    private func footnote(_ count: Int) -> String {
        var s = "플래너마다 기록, 형광펜, 기본 컬러, D-day 가 따로 있어요. 새 플래너는 지금 펼친 플래너의 형광펜과 기본 컬러를 이어받아요."
        if count == 1 { s += " 플래너가 한 권뿐일 때는 지울 수 없어요. 새 플래너를 만든 뒤에 지울 수 있어요." }
        return s
    }

    private func open(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) { store.activate(id) }
    }

    private func deleteMessage(_ b: BookInfo) -> String {
        var lines: [String] = []
        if b.id == store.activeBook?.id {
            let n = store.data.days.count
            lines.append("이 플래너의 기록\(n > 0 ? "(기록한 날 \(n)일)" : "")과 형광펜·D-day 설정이 모두 영구히 지워져요. 되돌릴 수 없어요.")
            if let next = store.books.first(where: { $0.id != b.id }) {
                lines.append("지우고 나면 ‘\(next.name)’\(SettingsJosa.pick(next.name, "을", "를")) 펼쳐요.")
            }
        } else {
            lines.append("이 플래너의 기록과 형광펜·D-day 설정이 모두 영구히 지워져요. 되돌릴 수 없어요.")
        }
        lines.append("남겨 두고 싶다면 먼저 펼친 뒤 ‘데이터 → 백업 내보내기’로 보관하세요.")
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ id: UUID) {
        guard store.books.count > 1 else { return }
        withAnimation(.snappy(duration: 0.25)) { store.deleteBook(id) }
    }
}

/// 만들기 / 편집 시트를 여는 요청
private enum SettingsBookEditorRequest: Identifiable {
    case create
    case edit(BookInfo)

    var id: String {
        switch self {
        case .create: "new"
        case .edit(let b): b.id.uuidString
        }
    }

    var book: BookInfo? {
        if case .edit(let b) = self { return b }
        return nil
    }
}

/// 책장의 한 권: 표지 · 이름(펼침 표시) · 기간 · 기록 · 펼치기 / 편집 / 삭제
private struct SettingsBookRow: View {
    let book: BookInfo
    let isOpen: Bool
    /// 기록한 날 수 (펼친 책만 알 수 있다)
    let recordDays: Int?
    let canDelete: Bool
    let open: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SettingsBookCover(cover: book.cover, width: 34, ribbon: isOpen)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(book.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isOpen {
                        SettingsOpenBadge(cover: book.cover)
                    }
                }
                Text(period)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if !isOpen {
                Button("펼치기", action: open)
                    .help("이 플래너를 펼쳐서 써요")
            }
            Button(action: edit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("이름, 기간, 표지 색 편집")
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "이 플래너 지우기" : "플래너는 적어도 한 권은 있어야 해요. 새 플래너를 만든 뒤에 지울 수 있어요.")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("펼치기", action: open).disabled(isOpen)
            Button("편집…", action: edit)
            Divider()
            Button("지우기…", role: .destructive, action: delete).disabled(!canDelete)
        }
    }

    private var period: String {
        guard let end = book.end else { return book.periodText }
        return "\(book.periodText) · \(Dates.daysBetween(book.start, end) + 1)일"
    }

    /// 오늘이 몇 번째 날인지(시작 전 / 끝남) · 종료일 없음 · 기록한 날
    private var status: String {
        let today = Dates.day(Date())
        var parts: [String] = []
        if today < Dates.day(book.start) {
            parts.append("\(Dates.daysBetween(today, book.start))일 뒤에 시작해요")
        } else if let end = book.end, today > Dates.day(end) {
            parts.append("끝난 플래너예요")
        } else {
            parts.append("오늘은 \(Dates.daysBetween(book.start, today) + 1)일째")
        }
        if book.end == nil { parts.append("종료일 없음 — 계속 넘어가요") }
        if let recordDays { parts.append(recordDays == 0 ? "아직 기록이 없어요" : "기록한 날 \(recordDays)일") }
        return parts.joined(separator: " · ")
    }
}

/// 펼쳐 둔 책 표시
private struct SettingsOpenBadge: View {
    let cover: Int

    var body: some View {
        Text("펼침")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(ColorConcept.of(cover).accent))
            .help("지금 이 플래너가 펼쳐져 있어요")
    }
}

/// 아직 책이 한 권도 없을 때
private struct SettingsBooksEmpty: View {
    let create: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsBookCover(cover: 0, width: 34)
                .saturation(0)
                .opacity(0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text("아직 플래너가 없어요")
                Text("시작일을 정해 첫 플래너를 만들어 보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("새 플래너 만들기", action: create)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 4)
    }
}

/// 넘기는 규칙 한 줄
private struct SettingsBookRuleRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 표지 색으로 칠한 작은 책: 왼쪽 책등 그림자, 오른쪽으로 비치는 종이 단면, 가운데 이름표.
/// title 을 주면 이름표에 손글씨로 적고(큰 미리보기), ribbon 이면 펼친 책의 가름끈이 아래로 늘어진다.
private struct SettingsBookCover: View {
    let cover: Int
    var width: CGFloat = 34
    var title: String? = nil
    var caption: String? = nil
    var ribbon = false

    @EnvironmentObject private var state: AppState

    var body: some View {
        let c = ColorConcept.of(cover)
        let w = width, h = (width * 1.34).rounded()
        let r = max(1.2, w * 0.07)
        let peek = max(1, (w * 0.045).rounded())
        let spine = max(1.5, w * 0.13)
        let coverShape = UnevenRoundedRectangle(topLeadingRadius: r * 0.45, bottomLeadingRadius: r * 0.45,
                                                bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        ZStack(alignment: .topLeading) {
            // 종이 단면 (오른쪽과 아래로 살짝 비친다)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r * 0.8,
                                   topTrailingRadius: r * 0.8, style: .continuous)
                .fill(Ink.paper)
                .overlay(alignment: .trailing) {
                    if w >= 20 {
                        Rectangle().fill(Ink.rule.opacity(0.9)).frame(width: 0.5).padding(.vertical, r)
                            .padding(.trailing, peek * 0.5)
                    }
                }
                .frame(width: w - spine, height: h - peek * 1.5)
                .offset(x: spine, y: peek * 0.75)

            // 표지
            coverShape
                .fill(LinearGradient(colors: [c.accent.opacity(0.86), c.accent], startPoint: .topTrailing, endPoint: .bottomLeading))
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.26), .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: spine)
                        Rectangle().fill(.white.opacity(0.28)).frame(width: max(0.5, w * 0.012))
                    }
                }
                .overlay { label(w: w - peek, h: h, spine: spine) }
                .clipShape(coverShape)
                .frame(width: w - peek, height: h)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if ribbon {
                SettingsRibbon()
                    .fill(Color(hex: "E9B949"))
                    .frame(width: max(3, w * 0.13), height: max(5, h * 0.16))
                    .offset(x: -w * 0.24, y: max(5, h * 0.16) - 1)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(w > 40 ? 0.22 : 0.2), radius: w > 40 ? 4 : 1.2, x: w > 40 ? 1 : 0.4, y: w > 40 ? 3 : 0.8)
    }

    @ViewBuilder
    private func label(w: CGFloat, h: CGFloat, spine: CGFloat) -> some View {
        let area = w - spine
        if let title {
            VStack(spacing: h * 0.06) {
                Text(title)
                    .font(Fonts.hand(w * 0.2))
                    .foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.45)
                    .padding(.horizontal, area * 0.06)
                    .padding(.vertical, h * 0.035)
                    .frame(width: area * 0.78)
                    .frame(minHeight: h * 0.2)
                    .background(RoundedRectangle(cornerRadius: w * 0.03, style: .continuous).fill(Ink.paper))
                    .id(state.fontsReady)
                if let caption {
                    Text(caption)
                        .font(Fonts.print(max(7, w * 0.085), .demiBold))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: area * 0.86)
                }
            }
            .frame(width: area)
            .padding(.leading, spine)
            .offset(y: -h * 0.06)
        } else if w >= 16 {
            RoundedRectangle(cornerRadius: max(0.8, w * 0.03), style: .continuous)
                .fill(Ink.paper.opacity(0.94))
                .overlay {
                    VStack(alignment: .leading, spacing: h * 0.045) {
                        Capsule().fill(Ink.soft.opacity(0.7)).frame(height: max(0.8, h * 0.028))
                        Capsule().fill(Ink.faint).frame(width: area * 0.34, height: max(0.8, h * 0.028))
                    }
                    .padding(.horizontal, area * 0.1)
                }
                .frame(width: area * 0.64, height: h * 0.2)
                .padding(.leading, spine)
                .offset(y: -h * 0.12)
        }
    }
}

/// 끝이 V 자로 파인 가름끈
private struct SettingsRibbon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.width * 0.55))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 새 책의 이름과 표지 색 (아직 쓰지 않은 색부터)
private enum SettingsBookDefaults {
    static func name(_ names: [String]) -> String {
        let base = "새 플래너"
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func cover(_ used: [Int]) -> Int {
        ColorConcept.all.first { !used.contains($0.id) }?.id ?? ColorConcept.all[used.count % ColorConcept.all.count].id
    }
}

/// 받침에 따라 ‘을/를’, ‘으로/로’ 같은 조사를 고른다 (한글·숫자로 끝나지 않으면 둘 다 적는다)
private enum SettingsJosa {
    /// 0–9 를 읽었을 때의 받침 (영 ㅇ, 일 ㄹ, 이, 삼 ㅁ, 사, 오, 육 ㄱ, 칠 ㄹ, 팔 ㄹ, 구)
    private static let digitBatchim: [Character: UInt32] = ["0": 21, "1": 8, "2": 0, "3": 16, "4": 0,
                                                            "5": 0, "6": 1, "7": 8, "8": 8, "9": 0]

    static func pick(_ word: String, _ withBatchim: String, _ without: String) -> String {
        switch batchim(word) {
        case .some(0): without
        case .some: withBatchim
        case .none: "\(withBatchim)(\(without))"
        }
    }

    /// ‘으로/로’ (ㄹ 받침 뒤에도 ‘로’)
    static func ro(_ word: String) -> String {
        switch batchim(word) {
        case .some(0), .some(8): "로"
        case .some: "으로"
        case .none: "(으)로"
        }
    }

    /// 마지막 글자의 받침 번호 (0 = 없음, 8 = ㄹ). 한글·숫자가 아니면 nil
    private static func batchim(_ word: String) -> UInt32? {
        guard let last = word.trimmingCharacters(in: .whitespaces).last else { return 0 }
        if let d = digitBatchim[last] { return d }
        guard let s = last.unicodeScalars.first, (0xAC00...0xD7A3).contains(s.value) else { return nil }
        return (s.value - 0xAC00) % 28
    }
}

// MARK: 만들기 / 편집 시트

private struct SettingsBookEditor: View {
    /// nil 이면 새로 만든다
    let book: BookInfo?

    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var cover: Int
    /// 저장은 한 번만 (Return 이 겹쳐 눌려도 책이 두 권 생기지 않게)
    @State private var saved = false
    @FocusState private var nameFocused: Bool

    init(book: BookInfo?, suggestedName: String, suggestedCover: Int) {
        self.book = book
        let start = Dates.day(book?.start ?? Date())
        _name = State(initialValue: book?.name ?? suggestedName)
        _start = State(initialValue: start)
        _hasEnd = State(initialValue: book?.end != nil)
        _end = State(initialValue: book?.end.map(Dates.day) ?? SettingsBookPreset.defaultEnd(from: start))
        _cover = State(initialValue: book?.cover ?? suggestedCover)
    }

    private var isNew: Bool { book == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameMissing: Bool { trimmedName.isEmpty }
    private var endTooEarly: Bool { hasEnd && Dates.day(end) < Dates.day(start) }
    private var valid: Bool { !nameMissing && !endTooEarly }
    private var sameName: Bool {
        store.books.contains { $0.id != book?.id && $0.name.trimmingCharacters(in: .whitespaces) == trimmedName }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                SettingsBookCover(cover: cover, width: 76, title: nameMissing ? "이름 없음" : trimmedName, caption: coverCaption)
                    .animation(.snappy(duration: 0.2), value: cover)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isNew ? "새 플래너 만들기" : "플래너 편집")
                        .font(.system(size: 18, weight: .bold))
                    Text(isNew ? "플래너 한 권은 시작일부터 한 장씩 넘겨 쓰는 책이에요. 만들면 바로 펼쳐져요."
                               : "이름, 기간, 표지 색을 바꿔요. 적어 둔 기록은 그대로 남아요.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 6)

            Form {
                Section {
                    LabeledContent {
                        TextField("이름", text: $name, prompt: Text("예: 2026 다이어리"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                            .focused($nameFocused)
                            .onSubmit(save)
                    } label: {
                        if nameMissing {
                            SettingsFieldLabel(title: "이름", detail: "이름을 적어 주세요", tone: .error)
                        } else if sameName {
                            SettingsFieldLabel(title: "이름", detail: "같은 이름의 플래너가 이미 있어요", tone: .warning)
                        } else {
                            SettingsFieldLabel(title: "이름", detail: "표지와 팔레트에 적혀요")
                        }
                    }
                    HStack(spacing: 12) {
                        SettingsFieldLabel(title: "표지 색", detail: ColorConcept.of(cover).name)
                        Spacer(minLength: 8)
                        SettingsCoverPicker(selection: $cover)
                    }
                }

                Section {
                    LabeledContent {
                        SettingsDateButton(date: $start)
                    } label: {
                        SettingsFieldLabel(title: "시작일", detail: "첫 장이 되는 날 · 꼭 정해요")
                    }
                    Toggle(isOn: $hasEnd.animation(.snappy(duration: 0.2))) {
                        SettingsFieldLabel(title: "종료일 정하기", detail: "정하지 않으면 끝없이 이어져요")
                    }
                    if hasEnd {
                        LabeledContent {
                            SettingsDateButton(date: $end, from: start)
                        } label: {
                            if endTooEarly {
                                SettingsFieldLabel(title: "종료일", detail: "시작일과 같거나 그 뒤여야 해요", tone: .error)
                            } else {
                                SettingsFieldLabel(title: "종료일", detail: "마지막 장이 되는 날")
                            }
                        }
                        LabeledContent {
                            HStack(spacing: 5) {
                                ForEach(SettingsBookPreset.allCases) { p in
                                    let target = p.end(from: start)
                                    SettingsChip(title: p.title, on: !endTooEarly && Dates.day(end) == target) {
                                        withAnimation(.snappy(duration: 0.2)) { end = target }
                                    }
                                    .help("종료일: \(SettingsDateButton.format.string(from: target))")
                                }
                            }
                        } label: {
                            Text("빠르게 정하기")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsFootnote(text: rangeSummary)
                        if let outside = outsideWarning {
                            Label {
                                Text(outside).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "만들고 펼치기" : "저장", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: sheetHeight)
        .onAppear { if isNew { nameFocused = true } }
    }

    /// 내용에 맞춘 시트 높이 (종료일 줄, 기간 밖 기록 안내가 있을 때 늘어난다)
    private var sheetHeight: CGFloat {
        var h: CGFloat = 470
        if hasEnd { h += 90 }
        if outsideWarning != nil { h += 36 }
        return h
    }

    /// 표지 아래 연도: "2026" · "2026 – 2027"
    private var coverCaption: String {
        let a = Dates.comp(start).year ?? 0
        guard hasEnd, !endTooEarly, let b = Dates.comp(end).year, b != a else { return "\(a)" }
        return "\(a) – \(b)"
    }

    private var rangeSummary: String {
        let s = SettingsBookPreset.short.string(from: start)
        guard hasEnd else {
            return "\(s) 이전으로는 넘어가지 않아요. 종료일이 없으니 앞으로는 끝없이 계속 넘어가요."
        }
        guard !endTooEarly else { return "시작일 이전으로는 넘어가지 않고, 종료일에서 멈춰요." }
        let e = SettingsBookPreset.short.string(from: end)
        return "\(s)부터 \(e)까지, \(Dates.daysBetween(start, end) + 1)일 동안만 넘어가요."
    }

    /// 펼친 책의 기간을 줄여서 기록이 있는 날이 밖으로 나가면 알려 준다 (기록은 지우지 않는다)
    private var outsideWarning: String? {
        guard let book, book.id == store.activeBook?.id, !endTooEarly else { return nil }
        var probe = book
        probe.start = Dates.day(start)
        probe.end = hasEnd ? Dates.day(end) : nil
        let n = store.data.days.keys.compactMap(Dates.parse).filter { !probe.contains($0) }.count
        guard n > 0 else { return nil }
        return "기록이 있는 날 \(n)일이 새 기간 밖에 있어요. 기록은 지워지지 않지만, 기간을 다시 넓히기 전까지는 그 장을 펼칠 수 없어요."
    }

    private func save() {
        guard valid, !saved else { return }
        saved = true
        let n = trimmedName
        let s = Dates.day(start)
        let e = hasEnd ? Dates.day(end) : nil
        if let book {
            store.updateBook(book.id) { b in
                b.name = n
                b.start = s
                b.end = e
                b.cover = cover
            }
            if book.id == store.activeBook?.id { SettingsBookRange.settle(state) }
        } else {
            store.createBook(name: n, start: s, end: e, cover: cover)
        }
        dismiss()
    }
}

/// 필드 이름 + 작은 설명 (고쳐야 할 때는 빨강, 알아 두면 좋을 때는 주황)
private struct SettingsFieldLabel: View {
    enum Tone { case normal, warning, error }

    let title: String
    let detail: String
    var tone: Tone = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            HStack(spacing: 3) {
                if tone != .normal {
                    Image(systemName: tone == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                Text(detail)
            }
            .font(.system(size: 11, weight: tone == .normal ? .regular : .medium))
            .foregroundStyle(tone == .error ? AnyShapeStyle(Color.red)
                             : tone == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
    }
}

/// 작은 알약 모양 선택 버튼
private struct SettingsChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(hover ? 0.11 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 표지 색 고르기 (컬러 컨셉의 강조색)
private struct SettingsCoverPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ColorConcept.all) { c in
                let on = c.id == selection
                Button { selection = c.id } label: {
                    SettingsBookCover(cover: c.id, width: 17)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? c.accent : .clear, lineWidth: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.name)
                .accessibilityLabel("표지 색 \(c.name)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 날짜 한 칸: 눌러서 달력에서 고른다 (글자 칸이 아니라서 플래너의 숫자·화살표 단축키와 부딪히지 않는다)
private struct SettingsDateButton: View {
    @Binding var date: Date
    /// 이 날보다 앞은 고를 수 없다
    var from: Date? = nil
    @State private var picking = false

    static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E)"
        return f
    }()

    var body: some View {
        Button { picking = true } label: {
            Label(Self.format.string(from: date), systemImage: "calendar")
                .monospacedDigit()
                .frame(minWidth: 158, alignment: .leading)
        }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                calendar
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .environment(\.calendar, Dates.cal)
                let today = Dates.day(Date())
                Button("오늘") { date = today }
                    .controlSize(.small)
                    .disabled((from.map { today < Dates.day($0) } ?? false) || Dates.day(date) == today)
            }
            .padding(12)
        }
        .help("날짜 고르기")
    }

    @ViewBuilder private var calendar: some View {
        let pick = Binding(get: { date }, set: { date = Dates.day($0) })
        if let from {
            DatePicker("날짜", selection: pick, in: Dates.day(from)..., displayedComponents: .date)
        } else {
            DatePicker("날짜", selection: pick, displayedComponents: .date)
        }
    }
}

/// 종료일 빠르게 정하기 (시작일부터)
private enum SettingsBookPreset: String, CaseIterable, Identifiable {
    case month1, month3, month6, year1, yearEnd

    var id: Self { self }

    var title: String {
        switch self {
        case .month1: "1개월"
        case .month3: "3개월"
        case .month6: "6개월"
        case .year1: "1년"
        case .yearEnd: "올해 말"
        }
    }

    /// 시작일을 첫날로 세어 그 기간의 마지막 날
    func end(from start: Date) -> Date {
        let s = Dates.day(start)
        let months: Int
        switch self {
        case .month1: months = 1
        case .month3: months = 3
        case .month6: months = 6
        case .year1: months = 12
        case .yearEnd:
            let y = Dates.comp(s).year ?? 2026
            return Dates.cal.date(from: DateComponents(year: y, month: 12, day: 31)).map(Dates.day) ?? s
        }
        let next = Dates.cal.date(byAdding: .month, value: months, to: s) ?? s
        // 1월 31일 + 1개월처럼 달 끝에 맞춰 잘린 날은 그 달의 마지막 날까지 쓴다
        let clipped = Dates.comp(next).day != Dates.comp(s).day
        return max(s, clipped ? Dates.day(next) : Dates.add(days: -1, to: next))
    }

    /// 종료일을 처음 켰을 때: 올해 말까지 한 달 넘게 남았으면 올해 말, 아니면 1년
    static func defaultEnd(from start: Date) -> Date {
        let ye = SettingsBookPreset.yearEnd.end(from: start)
        return Dates.daysBetween(start, ye) >= 30 ? ye : SettingsBookPreset.year1.end(from: start)
    }

    static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy. M. d."
        return f
    }()
}

/// 펼친 책의 기간을 바꾼 뒤: 보던 장이 새 기간 밖이면 가장 가까운 장으로 옮기고, 창 제목(책 이름)도 새로 적는다
@MainActor
private enum SettingsBookRange {
    static func settle(_ state: AppState) {
        let d = state.dayRange, w = state.weekRange
        let day = min(max(state.dayIndex, d.lowerBound), d.upperBound)
        let week = min(max(state.weekIndex, w.lowerBound), w.upperBound)
        if day != state.dayIndex || week != state.weekIndex {
            state.endEditing()
            state.dayIndex = day
            state.weekIndex = week
        }
        state.onPageChange?()
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
    @EnvironmentObject private var state: AppState
    @State private var result: SettingsDataResult?

    private static let isDemo = CommandLine.arguments.contains("--demo")

    var body: some View {
        let book = store.activeBook
        let bookName = book?.name ?? "펼친 플래너"
        Form {
            Section {
                LabeledContent("저장 폴더") {
                    if let folder = store.folder {
                        Text(SettingsDataFile.displayPath(folder))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("저장하지 않음").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("플래너 파일") {
                    Text("books 폴더에 한 권당 하나씩 · \(store.books.count)권")
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    LabeledContent("마지막 저장") {
                        Text(SettingsDataFile.summary(store.activeBookURL))
                            .foregroundStyle(.secondary)
                    }
                }
                if Self.isDemo {
                    Label("데모 데이터로 실행 중이라 파일에는 저장하지 않아요.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button { store.folder.map(SettingsDataFile.reveal) } label: { Label("Finder에서 보기", systemImage: "folder") }
                        .disabled(store.folder == nil)
                        .help("플래너 파일이 든 폴더를 Finder 에서 열어요")
                    Button { export() } label: { Label("백업 내보내기…", systemImage: "square.and.arrow.up") }
                        .disabled(book == nil)
                        .help("지금 펼친 ‘\(bookName)’\(SettingsJosa.pick(bookName, "을", "를")) 파일 하나로 저장해요")
                    Button { importBackup() } label: { Label("백업 가져오기…", systemImage: "square.and.arrow.down") }
                        .help("백업 파일을 새 플래너 한 권으로 되살려요")
                    Spacer(minLength: 0)
                }
                if let result {
                    SettingsDataResultRow(result: result)
                }
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPaneHeader(pane: .data)
                    SettingsSectionTitle(title: "데이터 폴더")
                }
            } footer: {
                SettingsFootnote(text: "백업 내보내기는 지금 펼친 ‘\(bookName)’ 한 권을 파일 하나로 저장해요. "
                                 + "백업 가져오기는 그 파일을 새 플래너로 되살리고, 지금 있는 플래너는 그대로 둬요.")
            }

            Section {
                let s = SettingsDataFile.stats(store)
                LabeledContent("기록한 날", value: "\(s.days)일")
                LabeledContent("적은 할 일", value: "\(s.tasks)개")
                LabeledContent("칠한 시간", value: s.hours)
            } header: {
                SettingsSectionTitle(title: "‘\(bookName)’에 담긴 기록")
            }

            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("처음 사용 안내")
                        Text("플래너 만들기부터 넘기기, 칠하기까지 처음에 본 안내를 다시 보여 줘요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("튜토리얼 다시 보기") { replayTutorial() }
                }
                .padding(.vertical, 2)
            } header: {
                SettingsSectionTitle(title: "도움말")
            }

            Section {
                LabeledContent("버전", value: SettingsDataFile.version)
                LabeledContent("손글씨 글꼴", value: "Poor Story · SIL OFL 1.1")
            } header: {
                SettingsSectionTitle(title: "정보")
            }
        }
    }

    /// 펼친 책의 저장 파일을 그대로 복사한다 (메모리 전용이면 지금 내용을 적는다)
    private func export() {
        guard let book = store.activeBook else { return }
        store.saveNow()
        let panel = NSSavePanel()
        panel.title = "백업 내보내기"
        panel.message = "지금 펼친 ‘\(book.name)’ 플래너를 파일 하나로 저장해요."
        panel.prompt = "내보내기"
        panel.nameFieldStringValue = SettingsDataFile.backupName(book)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        present(panel) { dest in
            do {
                if let src = store.activeBookURL, FileManager.default.fileExists(atPath: src.path) {
                    try Data(contentsOf: src).write(to: dest, options: .atomic)
                } else {
                    try SettingsDataFile.encode(store.data).write(to: dest, options: .atomic)
                }
                result = .exported(dest)
            } catch {
                result = .failed("저장하지 못했어요: \(error.localizedDescription)")
            }
        }
    }

    /// 백업 파일을 새 책으로 만들어 펼친다. 이미 있는 책은 건드리지 않는다.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "백업 가져오기"
        panel.message = "백업 파일을 새 플래너로 되살려요. 지금 있는 플래너는 그대로예요."
        panel.prompt = "가져오기"
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "backup")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel) { src in
            if let name = SettingsDataFile.restore(src, into: store) {
                result = .imported(name)
            } else {
                result = .failed("Paper Planner 백업 파일이 아니라서 가져오지 못했어요.")
            }
        }
    }

    private func present(_ panel: NSSavePanel, _ done: @escaping (URL) -> Void) {
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            done(url)
        }
        if let w = SettingsWindowController.shared.window, w.isVisible {
            panel.beginSheetModal(for: w) { r in MainActor.assumeIsolated { finish(r) } }
        } else {
            finish(panel.runModal())
        }
    }

    private func replayTutorial() {
        UserDefaults.standard.set(false, forKey: "onboardingDone")
        // 안내가 플래너 창과 팔레트를 가리키므로, 설정 창은 닫고 비켜 준다
        SettingsWindowController.shared.window?.close()
        OnboardingController.shared.show(store: store, state: state, completion: {})
    }
}

private enum SettingsDataResult: Equatable {
    case exported(URL)
    case imported(String)
    case failed(String)
}

/// 내보내기 / 가져오기 결과 한 줄
private struct SettingsDataResultRow: View {
    let result: SettingsDataResult

    var body: some View {
        switch result {
        case .exported(let url):
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("\(url.lastPathComponent) 저장됨", systemImage: "checkmark.circle.fill")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Finder 에서 백업 파일 보기")
        case .imported(let name):
            Label("‘\(name)’\(SettingsJosa.ro(name)) 가져와서 펼쳤어요. 시작일은 첫 기록 날로 정했어요.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

/// 데이터 폴더 표시, 백업 파일 이름, 정보 표시용 계산
@MainActor
private enum SettingsDataFile {
    private static let backupPrefix = "PaperPlanner 백업 - "

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

    static func summary(_ url: URL?) -> String {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "아직 저장된 파일이 없어요" }
        let size = ByteCountFormatter.string(fromByteCount: (a[.size] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
        guard let d = a[.modificationDate] as? Date else { return size }
        return "\(size) · \(savedFormat.string(from: d))"
    }

    /// 폴더를 Finder 창으로 연다
    static func reveal(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    /// "PaperPlanner 백업 - 내 플래너 2026-09-29.json"
    static func backupName(_ book: BookInfo) -> String {
        let safe = book.name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(backupPrefix)\(safe.isEmpty ? "플래너" : safe) \(Dates.key(Date())).json"
    }

    /// 백업 파일 이름에서 책 이름을 되찾는다
    static func bookName(from url: URL) -> String? {
        var base = url.deletingPathExtension().lastPathComponent
        guard base.hasPrefix(backupPrefix) else { return nil }
        base.removeFirst(backupPrefix.count)
        if let r = base.range(of: #"\s*\d{4}-\d{2}-\d{2}( \d+)?$"#, options: .regularExpression) { base.removeSubrange(r) }
        base = base.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? nil : base
    }

    /// 백업 파일을 새 책으로 만들어 펼친다 (이미 있는 책은 건드리지 않는다). 시작일은 가장 이른 기록 날.
    /// 되살린 책의 이름을 돌려주고, 플래너 백업이 아니면 nil.
    static func restore(_ src: URL, into store: PlannerStore) -> String? {
        guard let raw = try? Data(contentsOf: src), var data = try? decode(raw) else { return nil }
        for (k, r) in data.days where PlannerStore.grouped(r.tasks) != r.tasks {
            data.days[k]?.tasks = PlannerStore.grouped(r.tasks)
        }
        var name = bookName(from: src) ?? "가져온 플래너"
        if store.books.contains(where: { $0.name == name }) { name += " (백업)" }
        let today = Dates.day(Date())
        let first = (Array(data.days.keys) + Array(data.weeks.keys)).compactMap(Dates.parse).min()
        store.createBook(name: name, start: min(first ?? today, today), end: nil,
                         cover: SettingsBookDefaults.cover(store.books.map(\.cover)))
        store.data = data
        store.scheduleSave()
        store.saveNow()
        return name
    }

    static func encode(_ data: PlannerData) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(data)
    }

    static func decode(_ raw: Data) throws -> PlannerData {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PlannerData.self, from: raw)
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
                if pane.perBook {
                    SettingsBookScope()
                        .padding(.top, 4)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// 이 설정이 어느 책(펼친 플래너)의 것인지: "▮ 지금 펼친 ‘내 플래너’에만 적용돼요"
private struct SettingsBookScope: View {
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        if let b = store.activeBook {
            HStack(spacing: 6) {
                SettingsBookCover(cover: b.cover, width: 10)
                Text("지금 펼친 ‘\(b.name)’에만 적용돼요")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .help("플래너마다 형광펜, 기본 컬러, D-day 가 따로 있어요. 다른 플래너를 펼치면 그 플래너의 설정이 보여요.")
        }
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
