import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// 처음 실행할 때의 안내. 본 창처럼 스프링이 달린 종이 한 장 위에 그린 작은 창에서
//   1 환영 → 2 플래너 만들기 → 3–6 사용법 네 장 → 7 시작하기
// 플래너(책)가 한 권도 없으면 2 에서 만들기 전에는 앞으로 넘어갈 수 없다.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Window

/// 안내 창. App 이 본 창을 열기 전에 띄우고, 끝나면 completion 에서 본 창을 연다.
/// 설정의 ‘튜토리얼 다시 보기’로 본 창이 열려 있을 때 다시 띄울 수도 있다.
/// 빨간 버튼으로 닫아도 앱을 쓸 수 있게: 플래너가 없으면 기본 플래너를 한 권 만들고 끝낸다.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    static let doneKey = "onboardingDone"
    /// 플래너의 키보드 처리에서 이 창의 이벤트를 걸러낼 때 쓰는 식별자
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PaperPlanner.onboarding")
    static let size = CGSize(width: 760, height: 560)

    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    private var window: NSWindow?
    private var rings: RingWindowController?
    private var store: PlannerStore?
    private var model: OnboardingModel?
    private var completions: [() -> Void] = []
    private var keyMonitor: Any?

    private override init() { super.init() }

    func show(store: PlannerStore, state: AppState, completion: @escaping () -> Void) {
        completions.append(completion)
        if !NSApp.isActive { NSApp.activate() }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 첫 실행에서는 이 창이 본 창보다 먼저 그려지므로 손글씨 글꼴부터 등록한다
        Fonts.activate {}
        self.store = store
        let model = OnboardingModel(store: store)
        model.onFinish = { [weak self] in self?.finish(closing: false) }
        self.model = model

        let w = OnboardingPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        w.identifier = Self.windowIdentifier
        w.title = "Paper Planner 시작하기"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .aqua)   // 종이는 늘 밝다
        w.backgroundColor = NSColor(Ink.paper)
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.tabbingMode = .disallowed
        w.collectionBehavior = [.fullScreenNone]
        w.animationBehavior = .documentWindow
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self

        let host = NSHostingView(rootView: OnboardingView(model: model)
            .environmentObject(store)
            .environmentObject(state))
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(Self.size)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)

        // 본 창의 주간 페이지와 같은 스프링을 위쪽 가장자리에
        let r = RingWindowController(parent: w)
        r.attach(.weekly)
        rings = r
        installKeyMonitor()
    }

    /// ‘시작하기’ 또는 창 닫기
    private func finish(closing: Bool) {
        guard let window else { return }
        if let store, store.books.isEmpty {
            store.createBook(name: BookDraft.defaultName, start: Date(), end: nil)
        }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        self.window = nil
        model = nil
        store = nil
        let done = completions
        completions = []
        // 본 창을 먼저 열고 나서 이 창을 닫는다 (창이 하나도 없는 순간 앱이 끝나지 않도록)
        done.forEach { $0() }
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            child.orderOut(nil)
        }
        rings = nil
        if !closing { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        finish(closing: true)
    }

    // MARK: keyboard

    /// Return = 다음 · 만들기 · 시작하기, Esc = 이전, ← → = 넘기기.
    /// 나중에 단 모니터가 먼저 불리므로, 본 창이 열려 있어도 이 창의 키는 여기서 먼저 처리해
    /// 플래너의 단축키(넘기기, W·D·H, 숫자 키 …)가 가로채지 않게 한다.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let consumed = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return consumed ? nil : e
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let window, let model, let target = e.window else { return false }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let editor = target.firstResponder as? NSTextView
        // 한글을 조합하는 중이면 입력기에 맡긴다 (Return 이 글자를 확정하는 데 쓰인다)
        if let editor, editor.hasMarkedText() { return false }

        // 날짜 고르기 팝오버처럼 이 창에 딸린 창: Return·Esc 는 그 창의 몫, 나머지는 곧장 그 창으로
        if target !== window {
            guard target.parent === window, editor == nil, ![36, 76, 53].contains(e.keyCode) else { return false }
            target.sendEvent(e)
            return true
        }

        switch e.keyCode {
        case 36, 76: // Return, Enter
            if editor != nil { window.makeFirstResponder(nil) }
            if !e.isARepeat { model.primary() }
            return true
        case 53: // Esc: 쓰던 칸에서 먼저 빠져나오고, 그다음부터 이전 장
            if editor != nil {
                window.makeFirstResponder(nil)
            } else if !e.isARepeat {
                model.back()
            }
            return true
        case 123, 124: // ← →: 쓰는 중이면 글자 사이를 움직인다
            guard editor == nil else { return false }
            if !e.isARepeat {
                if e.keyCode == 123 { model.back() } else { model.forwardKey() }
            }
            return true
        default:
            guard editor == nil else { return false }
            window.sendEvent(e)
            return true
        }
    }
}

/// 제목 막대가 있는 창 모양의 패널 (앱이 비활성일 때도 숨지 않고, 플래너의 트랙패드 넘김에서 빠진다)
private final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, planner, turn, highlight, tasks, views, ready

        var id: Int { rawValue }
        var next: Step? { Step(rawValue: rawValue + 1) }

        /// 양식에 인쇄된 머리 글자
        var label: String {
            switch self {
            case .welcome: "WELCOME"
            case .planner: "MY PLANNER"
            case .turn: "PAGE TURN"
            case .highlight: "TIMETABLE"
            case .tasks: "TASKS"
            case .views: "VIEWS"
            case .ready: "READY"
            }
        }

        var title: String {
            switch self {
            case .welcome: "환영해요"
            case .planner: "플래너 만들기"
            case .turn: "넘기기"
            case .highlight: "형광펜 · 타임테이블"
            case .tasks: "할 일"
            case .views: "주간 · 일간 · 홈"
            case .ready: "시작하기"
            }
        }

        /// 제목 밑에 긋는 형광펜 색
        var tint: Color {
            switch self {
            case .welcome: Color(hex: "F7C3C5")
            case .planner: Color(hex: "F5E2A0")
            case .turn: Color(hex: "C6DCF5")
            case .highlight: Color(hex: "BDE8DD")
            case .tasks: Color(hex: "F5E2A0")
            case .views: Color(hex: "DCD1F4")
            case .ready: Color(hex: "F8CADB")
            }
        }
    }

    enum PlannerMode { case create, existing }

    static let turn = Animation.spring(response: 0.46, dampingFraction: 0.88)

    @Published private(set) var step: Step = .welcome
    /// 마지막으로 넘긴 방향 (앞으로 = 새 장이 오른쪽에서 들어온다)
    @Published private(set) var forward = true
    @Published private(set) var plannerMode: PlannerMode
    @Published var draft: BookDraft
    /// 이 안내에서 만든 책 (다시 돌아오면 "만들었어요" 로 보여 준다)
    @Published private(set) var createdID: UUID?

    let store: PlannerStore
    var onFinish: (() -> Void)?
    private var turning = false

    init(store: PlannerStore) {
        self.store = store
        draft = BookDraft.fresh(avoiding: store.books)
        plannerMode = store.books.isEmpty ? .create : .existing
        // TEMPDEBUG
        if let s = Step(rawValue: UserDefaults.standard.integer(forKey: "obStep")) { step = s }
        if UserDefaults.standard.bool(forKey: "obCreate") { plannerMode = .create; forceEmpty = true }
        if UserDefaults.standard.bool(forKey: "obEnd") { draft.hasEnd = true }
    }
    var forceEmpty = false // TEMPDEBUG

    /// 플래너가 한 권도 없다 → 만들기 전에는 앞으로 못 간다
    var needsBook: Bool { store.books.isEmpty || forceEmpty }
    var isCreating: Bool { step == .planner && plannerMode == .create }
    /// 이미 책이 있는데 한 권 더 만드는 중
    var isComposingExtra: Bool { plannerMode == .create && !store.books.isEmpty }

    func canVisit(_ s: Step) -> Bool { s.rawValue <= Step.planner.rawValue || !needsBook }

    var primaryTitle: String {
        switch step {
        case .planner where plannerMode == .create: "플래너 만들기"
        case .ready: "시작하기"
        default: "다음"
        }
    }

    var canPrimary: Bool { !isCreating || draft.isValid }
    var showsBack: Bool { step != .welcome }
    var backTitle: String { step == .planner && isComposingExtra ? "취소" : "이전" }
    var showsSkip: Bool { !needsBook && step != .ready && !isCreating }

    // MARK: actions

    func primary() {
        switch step {
        case .planner where plannerMode == .create: create()
        case .ready: onFinish?()
        default: go(step.next)
        }
    }

    /// → 키: 만들기·시작하기처럼 무언가 일어나는 단계에서는 넘기기만 하지 않는다
    func forwardKey() {
        guard !isCreating, step != .ready else { return }
        go(step.next)
    }

    func back() {
        if step == .planner && isComposingExtra {
            withAnimation(.snappy(duration: 0.3)) { plannerMode = .existing }
            return
        }
        go(Step(rawValue: step.rawValue - 1))
    }

    func skip() { go(.ready) }

    func composeAnother() {
        draft = BookDraft.fresh(avoiding: store.books)
        withAnimation(.snappy(duration: 0.3)) { plannerMode = .create }
    }

    func go(_ target: Step?) {
        guard let target, target != step, canVisit(target), !turning else { return }
        turning = true
        forward = target.rawValue > step.rawValue
        // 방향을 먼저 반영한 뒤에 장을 바꾼다 (나가는 장이 알맞은 쪽으로 빠지도록)
        DispatchQueue.main.async { [self] in
            if target == .planner { plannerMode = needsBook ? .create : .existing }
            withAnimation(Self.turn) { step = target }
            turning = false
        }
    }

    private func create() {
        guard draft.isValid else { return }
        createdID = store.createBook(name: draft.resolvedName, start: draft.start, end: draft.endValue, cover: draft.cover)
        go(.turn)
    }
}

/// 만들 책의 초안 (이름이 비면 자리 글자를 이름으로 쓴다)
struct BookDraft: Equatable {
    static let defaultName = "내 플래너"

    var name: String
    var placeholder: String
    var start: Date
    var hasEnd = false
    var end: Date
    var cover: Int

    static let maxName = 30

    var resolvedName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((t.isEmpty ? placeholder : t).prefix(Self.maxName))
    }

    var endValue: Date? { hasEnd ? end : nil }
    var isValid: Bool { !hasEnd || Dates.day(end) >= Dates.day(start) }
    var preview: BookInfo { BookInfo(name: resolvedName, start: Dates.day(start), end: endValue.map(Dates.day), cover: cover) }

    /// 이미 있는 책과 이름·표지 색이 겹치지 않는 새 초안 (시작일은 오늘)
    static func fresh(avoiding books: [BookInfo]) -> BookDraft {
        let names = Set(books.map(\.name))
        var name = BookDraft.defaultName
        var n = 2
        while names.contains(name) {
            name = "\(BookDraft.defaultName) \(n)"
            n += 1
        }
        let used = Set(books.map(\.cover))
        let cover = ColorConcept.all.first { !used.contains($0.id) }?.id ?? 0
        let today = Dates.day(Date())
        return BookDraft(name: name, placeholder: name, start: today, end: end(after: today, months: 12), cover: cover)
    }

    /// 시작일부터 n 달 (마지막 날 포함)
    static func end(after start: Date, months: Int) -> Date {
        let next = Dates.cal.date(byAdding: .month, value: months, to: Dates.day(start)) ?? start
        return Dates.add(days: -1, to: next)
    }
}

// MARK: - Look

private enum OB {
    /// 본문 (인쇄 글자보다 한 톤 옅게)
    static let body = Color(hex: "625E69")
    static let barHeight: CGFloat = 72
    static let side: CGFloat = 48
    static let cats: [Color] = Prefs.defaultCategories.map(\.color)

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = Dates.cal
        f.dateFormat = "yyyy. M. d. (E)"
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = Dates.cal
        f.dateFormat = "yyyy. M. d."
        return f
    }()

    /// 기간의 길이 ("92일", "1년")
    static func length(_ book: BookInfo) -> String? {
        guard let end = book.end else { return nil }
        let days = Dates.daysBetween(book.start, end) + 1
        let c = Dates.cal.dateComponents([.year, .month, .day], from: book.start, to: Dates.add(days: 1, to: end))
        if c.day == 0, let y = c.year, let m = c.month {
            if m == 0 && y > 0 { return "\(y)년 · \(days)일" }
            if y == 0 && m > 0 { return "\(m)개월 · \(days)일" }
        }
        return "\(days)일"
    }
}

private func ease(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}

// MARK: - Root

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let size = OnboardingController.size
        ZStack(alignment: .topLeading) {
            PaperSurface(kind: .weekly, u: size.width / PageKind.weekly.design.width)
            ZStack(alignment: .topLeading) {
                OnboardingPage(step: model.step, model: model)
                    .id(model.step)
                    .transition(.onboardingTurn(forward: model.forward))
            }
            .frame(width: size.width, height: size.height - OB.barHeight, alignment: .topLeading)
            OnboardingBar(model: model)
                .frame(width: size.width, height: OB.barHeight)
                .offset(y: size.height - OB.barHeight)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .ignoresSafeArea()
        .environment(\.locale, Locale(identifier: "ko_KR"))
        .environment(\.calendar, Dates.cal)
    }
}

/// 장 넘김: 새 장은 넘기는 쪽에서 살짝 밀려 들어오고, 보던 장은 반대쪽으로 빠진다
private struct PageShift: ViewModifier {
    let x: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .scaleEffect(scale, anchor: .center)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    static func onboardingTurn(forward: Bool) -> AnyTransition {
        let d: CGFloat = 64
        let rest = PageShift(x: 0, opacity: 1, scale: 1)
        return .asymmetric(
            insertion: .modifier(active: PageShift(x: forward ? d : -d, opacity: 0, scale: 0.985), identity: rest),
            removal: .modifier(active: PageShift(x: forward ? -d : d, opacity: 0, scale: 0.985), identity: rest))
    }
}

// MARK: - Page frame

private struct OnboardingPage: View {
    let step: OnboardingModel.Step
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(step: step)
                .padding(.bottom, 26)
            Group {
                switch step {
                case .welcome: WelcomePage()
                case .planner: PlannerPage(model: model)
                case .turn: TurnPage()
                case .highlight: HighlightPage()
                case .tasks: TasksPage()
                case .views: ViewsPage()
                case .ready: ReadyPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 50)
        .padding(.horizontal, OB.side)
    }
}

/// 양식의 머리: 인쇄된 라벨 ━━━━━ 쪽 번호
private struct PageHeader: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(step.label)
                .font(Fonts.print(10.5, .demiBold))
                .kerning(1.6)
                .foregroundStyle(Ink.print)
            Rectangle()
                .fill(Ink.print)
                .frame(height: 1.8)
            Text("\(step.rawValue + 1) / \(OnboardingModel.Step.allCases.count)")
                .font(Fonts.print(10.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Ink.soft)
        }
    }
}

/// 손글씨 제목 + 밑에 그은 형광펜
private struct Headline: View {
    let text: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Text(text)
            .font(Fonts.hand(size))
            .foregroundStyle(Ink.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .bottom) {
                HighlighterBar(color: tint)
                    .frame(height: size * 0.36)
                    .padding(.horizontal, -6)
                    .offset(y: -size * 0.05)
            }
    }
}

private struct BodyText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        Text(text)
            .font(Fonts.print(size))
            .foregroundStyle(OB.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 펜으로 덧붙인 한 줄 메모
private struct PenNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(Fonts.hand(18))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Ink.pen)
    }
}

/// 사용법 한 줄: 작은 종이 타일 그림 + 제목 + 설명
private struct TipRow<Icon: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            icon
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.rule, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Fonts.print(13.5, .demiBold))
                    .foregroundStyle(Ink.print)
                Text(detail)
                    .font(Fonts.print(12.5))
                    .foregroundStyle(OB.body)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }
    }
}

/// 키보드 자판 모양
private struct KeyCap: View {
    let label: String
    var size: CGFloat = 22

    var body: some View {
        Text(label)
            .font(Fonts.print(size * 0.5, .demiBold))
            .foregroundStyle(Ink.print)
            .padding(.horizontal, size * 0.3)
            .frame(minWidth: size, minHeight: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(hex: "D9D6CF"))
                    .offset(y: size * 0.07)
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(hex: "F4F2ED")], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color(hex: "CFCBC3"), lineWidth: 0.7)
            }
            .fixedSize()
    }
}

// MARK: - Bottom bar

private struct OnboardingBar: View {
    @ObservedObject var model: OnboardingModel
    /// 책이 생기면 건너뛰기·점이 바로 풀리도록
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        ZStack {
            PageDots(model: model)
            HStack(spacing: 10) {
                if model.showsBack {
                    QuietButton(title: model.backTitle, icon: "chevron.left", action: model.back)
                        .help("Esc")
                }
                Spacer(minLength: 0)
                if model.showsSkip {
                    QuietButton(title: "건너뛰기", icon: nil, action: model.skip)
                        .help("사용법을 건너뛰고 마지막 장으로")
                }
                PrimaryButton(title: model.primaryTitle, enabled: model.canPrimary, action: model.primary)
                    .help("Return")
            }
        }
        .padding(.horizontal, OB.side - 8)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            DottedRule()
                .frame(height: 2)
                .padding(.horizontal, OB.side)
        }
        .animation(.snappy(duration: 0.25), value: model.step)
        .animation(.snappy(duration: 0.25), value: model.plannerMode)
    }
}

/// 양식의 점선
private struct DottedRule: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 1
            while x < size.width {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: size.height / 2 - 1, width: 2, height: 2)), with: .color(Ink.dot))
                x += 6.5
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PageDots: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingModel.Step.allCases) { s in
                let on = s == model.step
                let open = model.canVisit(s)
                Capsule()
                    .fill(on ? Ink.plum : open ? Ink.dot : Ink.faint.opacity(0.55))
                    .frame(width: on ? 20 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -5))
                    .onTapGesture { model.go(s) }
                    .help(open ? s.title : "플래너를 먼저 만들어 주세요")
                    .accessibilityLabel("\(s.rawValue + 1)쪽, \(s.title)")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .contentTransition(.opacity)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(Fonts.print(13.5, .demiBold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(Capsule().fill(Ink.plum.opacity(hover && enabled ? 0.9 : 1)))
            .shadow(color: Ink.plum.opacity(enabled ? 0.28 : 0), radius: 7, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
    }
}

private struct QuietButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title)
            }
            .font(Fonts.print(13, .medium))
            .foregroundStyle(hover ? Ink.print : OB.body)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Ink.print.opacity(hover ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 1 환영

private struct WelcomePage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("반가워요!")
                    .font(Fonts.hand(26))
                    .foregroundStyle(Ink.pen)
                    .rotationEffect(.degrees(-3), anchor: .leading)
                    .padding(.bottom, 4)
                Text("Paper Planner")
                    .font(Fonts.print(46, .bold))
                    .kerning(-0.8)
                    .foregroundStyle(Ink.print)
                    .fixedSize()
                    .background(alignment: .bottom) {
                        HighlighterBar(color: OnboardingModel.Step.welcome.tint)
                            .frame(height: 17)
                            .padding(.horizontal, -6)
                            .offset(y: -6)
                    }
                Text("종이 플래너를 그대로 옮긴 macOS 플래너")
                    .font(Fonts.print(17, .medium))
                    .foregroundStyle(Ink.print)
                    .padding(.top, 16)
                Text("창 하나가 종이 한 장이에요.")
                    .font(Fonts.hand(26))
                    .foregroundStyle(Ink.text)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    promise(.done, "10분 칸 타임테이블에 형광펜으로 하루를 칠하고")
                    promise(.partial, "할 일은 펜으로 ○ △ × → 체크하고")
                    promise(.moved, "시작일부터 한 장씩, 책처럼 넘겨 써요")
                }
                .padding(.top, 30)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            WelcomeIllustration()
                .frame(width: 262, height: 340)
                .offset(y: -8)
        }
    }

    private func promise(_ mark: Mark, _ text: String) -> some View {
        HStack(spacing: 11) {
            MarkShape(mark: mark)
                .stroke(Ink.red, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 15)
            Text(text)
                .font(Fonts.print(13.5))
                .foregroundStyle(OB.body)
        }
    }
}

private struct WelcomeIllustration: View {
    var body: some View {
        ZStack {
            // 뒤에 깔린 한 장 (책의 두께)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Ink.paperBack)
                .overlay(NoiseLayer(opacity: 0.4).blendMode(.multiply).clipShape(RoundedRectangle(cornerRadius: 3)))
                .frame(width: MiniDailyPage.paper.width, height: MiniDailyPage.paper.height)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                .rotationEffect(.degrees(-5))
                .offset(x: -6, y: 6)
            MiniDailyPage(day: .sample)
                .rotationEffect(.degrees(2.5))
            HighlighterPen(color: OB.cats[0])
                .scaleEffect(1.5)
                .rotationEffect(.degrees(-38))
                .offset(x: 96, y: 138)
        }
    }
}

// MARK: - 2 플래너 만들기

private struct PlannerPage: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let creating = model.plannerMode == .create
        let book = creating ? model.draft.preview : (store.activeBook ?? model.draft.preview)
        HStack(alignment: .top, spacing: 34) {
            VStack(spacing: 16) {
                BookCover(book: book, width: 170)
                    .rotationEffect(.degrees(-2))
                    .animation(.snappy(duration: 0.3), value: book.cover)
                Text(creating ? "표지 색과 이름은 나중에\n설정에서 바꿀 수 있어요" : "팔레트 맨 위에서\n다른 플래너로 바꿔 펼 수 있어요")
                    .font(Fonts.hand(16))
                    .foregroundStyle(Ink.soft)
                    .multilineTextAlignment(.center)
                    .fixedSize()
            }
            .frame(width: 186)
            .padding(.top, 4)

            Group {
                if creating {
                    CreateForm(model: model)
                } else if let active = store.activeBook {
                    ExistingBook(model: model, book: active)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
    }
}

private struct CreateForm: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let accent = ColorConcept.of(model.draft.cover).accent
        VStack(alignment: .leading, spacing: 0) {
            Headline(text: store.books.isEmpty ? "첫 플래너를 만들어요" : "플래너를 한 권 더 만들어요",
                     tint: OnboardingModel.Step.planner.tint, size: 32)
            BodyText(text: "플래너는 한 권의 책이에요. 시작일이 첫 장이 되고, 종료일을 정하면 그날이 마지막 장이 돼요.",
                     size: 12.5)
                .padding(.top, 8)

            VStack(spacing: 0) {
                FormRow(label: "이름") {
                    NameField(text: $model.draft.name, placeholder: model.draft.placeholder)
                }
                FormRow(label: "시작일", required: true) {
                    HStack(spacing: 8) {
                        DateLine(date: $model.draft.start, title: "시작일 · 첫 장", minimum: nil)
                        if !Dates.isToday(model.draft.start) {
                            ChipButton(title: "오늘") { model.draft.start = Dates.day(Date()) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                FormRow(label: "종료일") {
                    HStack(spacing: 8) {
                        Toggle("종료일 정하기", isOn: $model.draft.hasEnd.animation(.snappy(duration: 0.25)))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .tint(accent)
                            .help("끄면 종료일 없이 계속 넘어가요")
                        if model.draft.hasEnd {
                            DateLine(date: $model.draft.end, title: "종료일 · 마지막 장", minimum: model.draft.start)
                            Spacer(minLength: 0)
                            ForEach([3, 6, 12], id: \.self) { m in
                                ChipButton(title: m == 12 ? "1년" : "\(m)개월") {
                                    model.draft.end = BookDraft.end(after: model.draft.start, months: m)
                                }
                            }
                        } else {
                            Text("정하지 않음 — 계속 넘어가요")
                                .font(Fonts.hand(18))
                                .foregroundStyle(Ink.soft)
                            Spacer(minLength: 0)
                        }
                    }
                }
                FormRow(label: "표지", ruled: false) {
                    CoverPicker(selection: $model.draft.cover)
                }
            }
            .padding(.top, 14)

            if !model.draft.isValid {
                Label("종료일은 시작일과 같거나 그 뒤여야 해요", systemImage: "exclamationmark.circle.fill")
                    .font(Fonts.print(11.5, .medium))
                    .foregroundStyle(Ink.red)
                    .padding(.top, 4)
            }

            RangeStrip(book: model.draft.preview)
                .frame(height: 78)
                .padding(.top, 14)
        }
        .onChange(of: model.draft.start) { old, new in
            // 시작일을 종료일 뒤로 옮기면 기간 길이를 그대로 두고 종료일도 따라간다
            guard model.draft.end < new else { return }
            model.draft.end = Dates.add(days: max(0, Dates.daysBetween(old, model.draft.end)), to: new)
        }
    }
}

private struct ExistingBook: View {
    @ObservedObject var model: OnboardingModel
    let book: BookInfo
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let created = model.createdID == book.id
        VStack(alignment: .leading, spacing: 0) {
            Headline(text: created ? "플래너를 만들었어요" : "이미 플래너가 있어요",
                     tint: OnboardingModel.Step.planner.tint, size: 32)
            BodyText(text: created ? "‘\(book.name)’을(를) 펼쳐 두었어요. 이대로 써 나가면 돼요."
                                   : "지금 펼쳐 둔 ‘\(book.name)’ 플래너로 이어 쓰면 돼요. 한 권 더 만들어도 좋아요.",
                     size: 12.5)
                .padding(.top, 8)

            VStack(spacing: 0) {
                FormRow(label: "이름") {
                    Text(book.name)
                        .font(Fonts.hand(22))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                FormRow(label: "기간") {
                    Text(book.periodText)
                        .font(Fonts.hand(20))
                        .foregroundStyle(Ink.text)
                    if let len = OB.length(book) {
                        Text(len)
                            .font(Fonts.print(11, .medium))
                            .foregroundStyle(Ink.soft)
                    }
                    Spacer(minLength: 0)
                }
                if store.books.count > 1 {
                    FormRow(label: "책장") {
                        Text("플래너 \(store.books.count)권")
                            .font(Fonts.hand(20))
                            .foregroundStyle(Ink.text)
                        Text("설정에서 관리해요")
                            .font(Fonts.print(11, .medium))
                            .foregroundStyle(Ink.soft)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 14)

            RangeStrip(book: book)
                .frame(height: 78)
                .padding(.top, 16)

            Button(action: model.composeAnother) {
                Label("새 플래너 한 권 더 만들기", systemImage: "plus")
                    .font(Fonts.print(12.5, .demiBold))
                    .foregroundStyle(Ink.print)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Capsule().strokeBorder(Ink.print.opacity(0.28), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .padding(.top, 14)
        }
    }
}

/// 양식의 한 줄: 인쇄된 라벨 | 내용, 아래에 얇은 줄
private struct FormRow<Content: View>: View {
    let label: String
    var required = false
    var ruled = true
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(label)
                    .font(Fonts.print(12, .demiBold))
                    .foregroundStyle(Ink.print)
                if required {
                    Text("필수")
                        .font(Fonts.print(8.5, .bold))
                        .foregroundStyle(Ink.red)
                        .baselineOffset(5)
                }
            }
            .frame(width: 72, alignment: .leading)
            HStack(spacing: 8) { content }
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            if ruled { Rectangle().fill(Ink.rule).frame(height: 1) }
        }
    }
}

/// 이름: 줄 위에 손글씨로
private struct NameField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        TextField("이름", text: $text, prompt: Text(placeholder).foregroundStyle(Ink.faint))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(Fonts.hand(23))
            .foregroundStyle(Ink.text)
            .focused($focused)
            .padding(.vertical, 3)
            .overlay(alignment: .trailing) {
                if !focused {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hover ? Ink.print : Ink.soft)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hover = $0 }
            .help("눌러서 이름 쓰기")
    }
}

/// 손글씨로 적힌 날짜. 누르면 달력이 열린다.
private struct DateLine: View {
    @Binding var date: Date
    let title: String
    let minimum: Date?
    @State private var open = false
    @State private var hover = false
    @State private var closeWork: DispatchWorkItem?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(OB.longDate.string(from: date))
                    .font(Fonts.hand(21))
                    .foregroundStyle(Ink.text)
                    .fixedSize()
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover ? Ink.print : Ink.soft)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Ink.print.opacity(hover || open ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -7)
        .onHover { hover = $0 }
        .help("눌러서 날짜 고르기")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Fonts.print(12, .demiBold))
                    .foregroundStyle(Ink.print)
                picker
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            .padding(14)
            .environment(\.locale, Locale(identifier: "ko_KR"))
            .environment(\.calendar, Dates.cal)
        }
        .onChange(of: date) { _, _ in
            // 날짜를 고르면 잠깐 보여 주고 닫는다 (달을 넘길 때는 그대로)
            guard open else { return }
            closeWork?.cancel()
            let w = DispatchWorkItem { open = false }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    @ViewBuilder private var picker: some View {
        let day = Binding(get: { date }, set: { date = Dates.day($0) })
        if let minimum {
            DatePicker("날짜", selection: day, in: Dates.day(minimum)..., displayedComponents: .date)
        } else {
            DatePicker("날짜", selection: day, displayedComponents: .date)
        }
    }
}

private struct ChipButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.print(11, .medium))
                .foregroundStyle(hover ? Ink.print : OB.body)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Ink.print.opacity(hover ? 0.08 : 0.045)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

/// 표지 색: 작은 책 아홉 권
private struct CoverPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 9) {
            ForEach(ColorConcept.all) { c in
                let on = c.id == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { selection = c.id }
                } label: {
                    MiniCover(color: c.accent)
                        .frame(width: 17, height: 23)
                        .offset(y: on ? -3 : 0)
                        .shadow(color: .black.opacity(on ? 0.25 : 0.12), radius: on ? 3 : 1, y: on ? 3 : 1)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(Ink.print)
                                .frame(width: on ? 13 : 0, height: 2)
                                .offset(y: 6)
                        }
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.name)
                .accessibilityLabel("표지 색 \(c.name)")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

private struct MiniCover: View {
    let color: Color

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5, bottomTrailingRadius: 3.5,
                               topTrailingRadius: 3.5, style: .continuous)
            .fill(color)
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.2)).frame(width: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Ink.paper.opacity(0.92))
                    .frame(width: 8, height: 5)
                    .offset(x: 1, y: -3)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5, bottomTrailingRadius: 3.5,
                                              topTrailingRadius: 3.5, style: .continuous))
    }
}

/// 플래너 표지: 색 표지 + 스프링 + 고무 밴드 + 이름 스티커
private struct BookCover: View {
    let book: BookInfo
    var width: CGFloat = 170

    var body: some View {
        let s = width / 170
        let h = width * 1.34
        let concept = ColorConcept.of(book.cover)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3 * s, bottomLeadingRadius: 3 * s,
                                           bottomTrailingRadius: 10 * s, topTrailingRadius: 10 * s, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: [concept.accent.opacity(0.9), concept.accent],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            NoiseLayer(opacity: 1).blendMode(.multiply).clipShape(shape)
            // 빛
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.08)],
                                      startPoint: .top, endPoint: .bottom))
            // 스프링 쪽 띠
            Rectangle()
                .fill(.black.opacity(0.14))
                .frame(width: 17 * s, height: h)
            // 고무 밴드
            Rectangle()
                .fill(LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 5 * s, height: h)
                .offset(x: width - 24 * s)
            // 이름 스티커
            VStack(spacing: 5 * s) {
                Text("PLANNER")
                    .font(Fonts.print(7 * s, .demiBold))
                    .kerning(2.2 * s)
                    .foregroundStyle(Ink.soft)
                Text(book.name)
                    .font(Fonts.hand(24 * s))
                    .foregroundStyle(Ink.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Rectangle()
                    .fill(Ink.rule)
                    .frame(height: 0.8)
                    .padding(.horizontal, 8 * s)
                Text(book.periodText)
                    .font(Fonts.print(8 * s, .medium))
                    .foregroundStyle(OB.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 11 * s)
            .frame(width: width * 0.64)
            .background {
                RoundedRectangle(cornerRadius: 3 * s, style: .continuous)
                    .fill(Ink.paper)
                    .shadow(color: .black.opacity(0.18), radius: 1.5 * s, y: 1 * s)
            }
            .position(x: width * 0.52, y: h * 0.36)
            // 스프링
            Canvas { ctx, size in
                let pitch = 11 * s
                var y = 9 * s
                while y < size.height - 6 * s {
                    let hole = CGRect(x: 7 * s, y: y - 2 * s, width: 4 * s, height: 4 * s)
                    ctx.fill(Path(ellipseIn: hole), with: .color(.black.opacity(0.45)))
                    var loop = Path()
                    loop.move(to: CGPoint(x: -3 * s, y: y + 1.6 * s))
                    loop.addLine(to: CGPoint(x: hole.midX, y: y + 0.6 * s))
                    ctx.stroke(loop, with: .color(Color(hex: "5E6168")), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
                    ctx.stroke(loop, with: .color(Color(hex: "C9CCD2")), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
                    y += pitch
                }
            }
            .frame(width: 20 * s, height: h)
            .offset(x: -3 * s)
        }
        .frame(width: width, height: h)
        .shadow(color: .black.opacity(0.22), radius: 9 * s, y: 6 * s)
        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
    }
}

/// 책의 범위: 시작일 이전 ✕ ┃ 넘길 수 있는 장들 ┃ 종료일 이후 ✕ (종료일이 없으면 끝없이)
private struct RangeStrip: View {
    let book: BookInfo

    var body: some View {
        let concept = ColorConcept.of(book.cover)
        Canvas { ctx, size in
            let w = size.width
            let top: CGFloat = 8, bottom: CGFloat = 34
            let left: CGFloat = 46
            let right: CGFloat = book.end == nil ? w : w - 46

            // 넘길 수 없는 장 (흐린 점선)
            func ghost(_ x: CGFloat) {
                let r = CGRect(x: x, y: top + 3, width: 4, height: bottom - top - 6)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 1), with: .color(Ink.dot.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 1.5]))
            }
            func cross(_ cx: CGFloat) {
                let r = CGRect(x: cx - 8, y: (top + bottom) / 2 - 8, width: 16, height: 16)
                ctx.stroke(MarkShape(mark: .missed).path(in: r), with: .color(Ink.red),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            for x in stride(from: 4.0, to: left - 8, by: 7) { ghost(x) }
            cross(left / 2 - 2)

            // 넘길 수 있는 장
            var x = left + 6
            while x < right - 8 {
                let fade = book.end == nil ? min(1, max(0, (w - 20 - x) / (w * 0.35))) : 1
                if fade <= 0.02 { break }
                let r = CGRect(x: x, y: top, width: 3.6, height: bottom - top)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(concept.tint.opacity(fade)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 1), with: .color(concept.accent.opacity(0.35 * fade)), lineWidth: 0.6)
                x += 6.4
            }

            // 시작일 깃발
            flag(&ctx, x: left, pointsRight: true, color: concept.accent, top: top - 6, bottom: bottom + 4)
            ctx.draw(Text(OB.shortDate.string(from: book.start)).font(Fonts.print(10.5, .demiBold)).foregroundColor(Ink.print),
                     at: CGPoint(x: left - 4, y: bottom + 16), anchor: .leading)
            ctx.draw(Text("시작일 이전으로는 안 넘어가요").font(Fonts.hand(15)).foregroundColor(Ink.red),
                     at: CGPoint(x: left - 4, y: bottom + 34), anchor: .leading)

            if let end = book.end {
                for gx in stride(from: w - 8, to: right + 8, by: -7) { ghost(gx) }
                cross(w - left / 2 + 2)
                flag(&ctx, x: right, pointsRight: false, color: concept.accent, top: top - 6, bottom: bottom + 4)
                ctx.draw(Text(OB.shortDate.string(from: end)).font(Fonts.print(10.5, .demiBold)).foregroundColor(Ink.print),
                         at: CGPoint(x: right + 4, y: bottom + 16), anchor: .trailing)
                ctx.draw(Text("종료일에서 멈춰요").font(Fonts.hand(15)).foregroundColor(Ink.red),
                         at: CGPoint(x: right + 4, y: bottom + 34), anchor: .trailing)
            } else {
                var arrow = Path()
                let y = (top + bottom) / 2
                arrow.move(to: CGPoint(x: w - 16, y: y - 5))
                arrow.addLine(to: CGPoint(x: w - 10, y: y))
                arrow.addLine(to: CGPoint(x: w - 16, y: y + 5))
                ctx.stroke(arrow, with: .color(concept.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                ctx.draw(Text("종료일 없음").font(Fonts.print(10.5, .demiBold)).foregroundColor(Ink.print),
                         at: CGPoint(x: w, y: bottom + 16), anchor: .trailing)
                ctx.draw(Text("계속 넘어가요").font(Fonts.hand(15)).foregroundColor(concept.accent),
                         at: CGPoint(x: w, y: bottom + 34), anchor: .trailing)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(book.end == nil ? "시작일 \(book.periodText). 시작일 이전으로는 넘어가지 않고, 종료일이 없어 계속 넘어가요."
                                            : "기간 \(book.periodText). 시작일 이전과 종료일 이후로는 넘어가지 않아요.")
        .animation(.snappy(duration: 0.3), value: book)
    }

    private func flag(_ ctx: inout GraphicsContext, x: CGFloat, pointsRight: Bool, color: Color, top: CGFloat, bottom: CGFloat) {
        var pole = Path()
        pole.move(to: CGPoint(x: x, y: top))
        pole.addLine(to: CGPoint(x: x, y: bottom))
        ctx.stroke(pole, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        var f = Path()
        let d: CGFloat = pointsRight ? 1 : -1
        f.move(to: CGPoint(x: x, y: top))
        f.addLine(to: CGPoint(x: x + 11 * d, y: top + 4))
        f.addLine(to: CGPoint(x: x, y: top + 8))
        f.closeSubpath()
        ctx.fill(f, with: .color(color))
    }
}

// MARK: - 3 넘기기

private struct TurnPage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Headline(text: "종이처럼 넘겨요", tint: OnboardingModel.Step.turn.tint)
                VStack(alignment: .leading, spacing: 17) {
                    TipRow(title: "모서리를 잡고 넘기기",
                           detail: "종이 가장자리를 잡고 끌어요. 일간은 옆으로, 주간은 아래에서 위로 넘어가요.") {
                        FoldGlyph()
                    }
                    TipRow(title: "두 손가락으로 쓸기",
                           detail: "트랙패드에서 두 손가락으로 옆으로 쓸면 손끝을 따라 넘어가요.") {
                        TrackpadGlyph()
                    }
                    TipRow(title: "← → 키", detail: "한 장씩 앞뒤로 넘겨요.") {
                        HStack(spacing: 2) {
                            KeyCap(label: "←", size: 15)
                            KeyCap(label: "→", size: 15)
                        }
                    }
                }
                .padding(.top, 22)
                PenNote(text: "시작일 이전, 종료일 이후로는 넘어가지 않아요")
                    .padding(.top, 20)
                    .padding(.leading, 4)
            }
            .frame(width: 338, alignment: .leading)
            Spacer(minLength: 0)
            TurnIllustration()
                .frame(width: 262, height: 340)
                .offset(y: -10)
        }
    }
}

private struct FoldGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(x: size.width / 2 - 8, y: size.height / 2 - 10, width: 16, height: 20)
            let f: CGFloat = 7
            var page = Path()
            page.move(to: CGPoint(x: r.minX, y: r.minY))
            page.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            page.addLine(to: CGPoint(x: r.maxX, y: r.maxY - f))
            page.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY))
            page.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            page.closeSubpath()
            ctx.stroke(page, with: .color(Ink.print), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            var flap = Path()
            flap.move(to: CGPoint(x: r.maxX, y: r.maxY - f))
            flap.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY - f))
            flap.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY))
            flap.closeSubpath()
            ctx.fill(flap, with: .color(Ink.paperBack))
            ctx.stroke(flap, with: .color(Ink.print), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            for i in 0..<3 {
                var l = Path()
                let y = r.minY + 5 + CGFloat(i) * 4
                l.move(to: CGPoint(x: r.minX + 3.5, y: y))
                l.addLine(to: CGPoint(x: r.maxX - 3.5, y: y))
                ctx.stroke(l, with: .color(Ink.dot), lineWidth: 1)
            }
        }
    }
}

private struct TrackpadGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let pad = CGRect(x: size.width / 2 - 12, y: size.height / 2 - 8.5, width: 24, height: 17)
            ctx.stroke(Path(roundedRect: pad, cornerRadius: 3.5), with: .color(Ink.print), lineWidth: 1.4)
            for dy: CGFloat in [-2.6, 2.6] {
                ctx.fill(Path(ellipseIn: CGRect(x: pad.midX + 1, y: pad.midY + dy - 1.9, width: 3.8, height: 3.8)),
                         with: .color(Ink.pen))
            }
            var a = Path()
            a.move(to: CGPoint(x: pad.midX - 1.5, y: pad.midY))
            a.addLine(to: CGPoint(x: pad.minX + 4, y: pad.midY))
            a.move(to: CGPoint(x: pad.minX + 7, y: pad.midY - 2.6))
            a.addLine(to: CGPoint(x: pad.minX + 4, y: pad.midY))
            a.addLine(to: CGPoint(x: pad.minX + 7, y: pad.midY + 2.6))
            ctx.stroke(a, with: .color(Ink.pen), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 오른쪽 아래 모서리가 들렸다 내려앉는 종이 (아래로 다음 장이 비친다)
private struct TurnIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { tl in
            let lift = reduceMotion ? 0.62 : Self.lift(tl.date.timeIntervalSince(start))
            let paper = MiniDailyPage.paperRect
            let a = 16 + 104 * lift
            let b = a * 1.28
            let fold = Fold(page: paper, a: a, b: b)
            ZStack(alignment: .topLeading) {
                MiniDailyPage(day: .sampleNext)
                MiniDailyPage(day: .sample)
                    .clipShape(fold.remaining)
                // 넘어오는 종이의 그림자와 뒷면
                fold.flap
                    .fill(Color.black.opacity(0.18))
                    .blur(radius: 4)
                    .offset(x: -2, y: -1)
                fold.flap
                    .fill(LinearGradient(colors: [Color(hex: "E9E5DC"), Ink.paperBack, Color(hex: "FBFAF6")],
                                         startPoint: fold.foldMid, endPoint: fold.tipUnit))
                fold.flap
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
                // 손끝
                Circle()
                    .fill(Ink.print.opacity(0.14))
                    .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.6))
                    .frame(width: 18, height: 18)
                    .position(fold.tip)
                    .opacity(0.4 + 0.6 * lift)
            }
            .frame(width: MiniDailyPage.size.width, height: MiniDailyPage.size.height, alignment: .topLeading)
            .rotationEffect(.degrees(-1.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                Text("잡고 넘기기")
                    .font(Fonts.hand(19))
                    .foregroundStyle(Ink.pen)
                    .rotationEffect(.degrees(-8))
                    .offset(x: 6, y: -2)
            }
        }
    }

    /// 0 = 누운 종이, 1 = 가장 크게 들린 모서리. 3.6초마다 되풀이.
    static func lift(_ t: TimeInterval) -> Double {
        let p = t.truncatingRemainder(dividingBy: 3.6) / 3.6
        switch p {
        case ..<0.18: return 0
        case ..<0.58: return ease((p - 0.18) / 0.40)
        case ..<0.74: return 1
        default: return 1 - ease((p - 0.74) / 0.26)
        }
    }
}

/// 종이 모서리 접기: 모서리 C 를 접는 선(아래 가장자리에서 a, 오른쪽 가장자리에서 b)에 대해 뒤집는다
private struct Fold {
    let page: CGRect
    let a: CGFloat
    let b: CGFloat

    private var p1: CGPoint { CGPoint(x: page.maxX - a, y: page.maxY) }
    private var p2: CGPoint { CGPoint(x: page.maxX, y: page.maxY - b) }

    /// 뒤집힌 모서리의 끝
    var tip: CGPoint {
        let c = CGPoint(x: page.maxX, y: page.maxY)
        let d = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let v = CGPoint(x: c.x - p1.x, y: c.y - p1.y)
        let t = (v.x * d.x + v.y * d.y) / (d.x * d.x + d.y * d.y)
        let proj = CGPoint(x: p1.x + d.x * t, y: p1.y + d.y * t)
        return CGPoint(x: 2 * proj.x - c.x, y: 2 * proj.y - c.y)
    }

    var remaining: Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: page.maxX, y: 0))
        p.addLine(to: p2)
        p.addLine(to: p1)
        p.addLine(to: CGPoint(x: 0, y: page.maxY))
        p.closeSubpath()
        return p
    }

    var flap: Path {
        var p = Path()
        p.move(to: p1)
        p.addLine(to: p2)
        p.addLine(to: tip)
        p.closeSubpath()
        return p
    }

    /// 그라데이션 방향 (접힌 선 가운데 → 끝), 뷰 크기 기준의 단위 좌표
    var foldMid: UnitPoint {
        let s = MiniDailyPage.size
        return UnitPoint(x: (p1.x + p2.x) / 2 / s.width, y: (p1.y + p2.y) / 2 / s.height)
    }

    var tipUnit: UnitPoint {
        let s = MiniDailyPage.size
        return UnitPoint(x: tip.x / s.width, y: tip.y / s.height)
    }
}

// MARK: - 4 형광펜 · 타임테이블

private struct HighlightPage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Headline(text: "형광펜으로 하루를 칠해요", tint: OnboardingModel.Step.highlight.tint)
                VStack(alignment: .leading, spacing: 17) {
                    TipRow(title: "10분 칸 칠하기",
                           detail: "오른쪽 팔레트에서 형광펜을 고르고, 타임테이블 칸을 끌어서 칠해요.") {
                        HighlighterPen(color: OB.cats[0])
                            .scaleEffect(0.58)
                            .rotationEffect(.degrees(-30))
                    }
                    TipRow(title: "TOTAL TIME",
                           detail: "칠한 칸이 모여 하루 합계가 저절로 계산돼요.") {
                        (Text("8").font(Fonts.rounded(15, .black)) + Text("H").font(Fonts.rounded(8, .black)))
                            .foregroundStyle(Ink.red)
                    }
                    TipRow(title: "글씨 · 밥 도구",
                           detail: "칸 위에 짧게 적어 두거나, 밥 먹은 시간을 화살표로 남겨요.") {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil.line")
                            Image(systemName: "fork.knife")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.print)
                    }
                }
                .padding(.top, 22)
                PenNote(text: "숫자 키 1–7 로 형광펜을, E 로 지우개를 골라요")
                    .padding(.top, 20)
                    .padding(.leading, 4)
            }
            .frame(width: 338, alignment: .leading)
            Spacer(minLength: 0)
            TimetableIllustration()
                .frame(width: 262, height: 340)
                .offset(y: -10)
        }
    }
}

/// 형광펜이 칸을 하나씩 칠하고, TOTAL TIME 이 따라 올라간다
private struct TimetableIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let hours = ["9", "10", "11", "12", "1", "2"]
    /// 칠할 칸 (줄, 첫 칸, 끝 칸, 펜) — 이 순서대로 칠한다
    private static let strokes: [(row: Int, from: Int, to: Int, pen: Int)] = [
        (0, 0, 5, 0), (1, 0, 2, 0), (1, 3, 5, 1), (2, 0, 3, 1), (4, 1, 5, 2),
    ]
    private static var cellCount: Int { strokes.reduce(0) { $0 + $1.to - $1.from + 1 } }
    private static let cycle: Double = 7.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let painted = reduceMotion ? Double(Self.cellCount) : Self.progress(tl.date.timeIntervalSince(start))
            HStack(alignment: .center, spacing: 12) {
                sheet(painted)
                MiniPalette(active: activePen(painted))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func progress(_ t: TimeInterval) -> Double {
        let p = t.truncatingRemainder(dividingBy: cycle)
        let paint = 5.2
        if p < 0.5 { return 0 }
        if p < 0.5 + paint { return Double(cellCount) * (p - 0.5) / paint }
        if p < cycle - 0.45 { return Double(cellCount) }
        return Double(cellCount) * (1 - ease((p - (cycle - 0.45)) / 0.45))
    }

    private func activePen(_ painted: Double) -> Int {
        var n = painted
        for s in Self.strokes {
            let len = Double(s.to - s.from + 1)
            if n < len { return s.pen }
            n -= len
        }
        return Self.strokes.last?.pen ?? 0
    }

    private func sheet(_ painted: Double) -> some View {
        let minutes = Int(painted.rounded(.down)) * 10
        let (h, m) = formatHM(minutes)
        let accent = Ink.red
        return VStack(alignment: .leading, spacing: 0) {
            FormLabel(text: "TOTAL TIME")
            (Text(h).font(Fonts.rounded(34, .black)) + Text("H").font(Fonts.rounded(17, .black))
                + Text(m).font(Fonts.rounded(34, .black)) + Text("M").font(Fonts.rounded(17, .black)))
                .kerning(-0.6)
                .monospacedDigit()
                .foregroundStyle(minutes == 0 ? accent.opacity(0.15) : accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 12)
            FormLabel(text: "TIMETABLE")
            Canvas { ctx, size in draw(&ctx, size, painted) }
                .frame(height: 6 * 32)
        }
        .padding(14)
        .frame(width: 184)
        .modifier(PaperCard())
        .rotationEffect(.degrees(1.5))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ painted: Double) {
        let hourW: CGFloat = 20
        let rowH = size.height / 6
        let cellW = (size.width - hourW) / 6
        // 칠하기 (종이에 스미도록 곱하기)
        var ink = ctx
        ink.blendMode = .multiply
        var left = painted
        var head: CGPoint?
        for s in Self.strokes where left > 0 {
            let len = Double(s.to - s.from + 1)
            let amount = min(len, left)
            left -= amount
            let x0 = hourW + CGFloat(s.from) * cellW + 1
            let w = CGFloat(amount) * cellW - 2
            let r = CGRect(x: x0, y: CGFloat(s.row) * rowH + rowH * 0.16, width: max(0, w), height: rowH * 0.68)
            ink.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(OB.cats[s.pen].opacity(0.86)))
            if amount < len { head = CGPoint(x: r.maxX, y: r.midY) }
        }
        // 격자
        for r in 0...6 {
            var l = Path()
            let y = CGFloat(r) * rowH
            l.move(to: CGPoint(x: 0, y: y))
            l.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(l, with: .color(r == 0 ? Ink.print : Ink.rule), lineWidth: r == 0 ? 1.2 : 0.8)
        }
        var v = Path()
        v.move(to: CGPoint(x: hourW, y: 0))
        v.addLine(to: CGPoint(x: hourW, y: size.height))
        ctx.stroke(v, with: .color(Ink.print), lineWidth: 1)
        for c in 1..<6 {
            let x = hourW + CGFloat(c) * cellW
            var y: CGFloat = 2
            while y < size.height {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y, width: 1.2, height: 1.2)), with: .color(Ink.dot))
                y += 4
            }
        }
        for (i, hLabel) in Self.hours.enumerated() {
            ctx.draw(Text(hLabel).font(Fonts.print(9, .bold)).foregroundColor(Ink.print),
                     at: CGPoint(x: hourW / 2, y: (CGFloat(i) + 0.5) * rowH))
        }
        // 밥시간: 12시 🍴 → 끝 칸까지 화살표
        let my = 3.5 * rowH
        let mealX = hourW + cellW * 0.5
        var arrow = Path()
        arrow.move(to: CGPoint(x: mealX + 10, y: my))
        arrow.addLine(to: CGPoint(x: hourW + cellW * 4 - 3, y: my))
        arrow.move(to: CGPoint(x: hourW + cellW * 4 - 8, y: my - 4))
        arrow.addLine(to: CGPoint(x: hourW + cellW * 4 - 3, y: my))
        arrow.addLine(to: CGPoint(x: hourW + cellW * 4 - 8, y: my + 4))
        ctx.stroke(arrow, with: .color(Ink.red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        let d: CGFloat = 17
        let circle = CGRect(x: mealX - d / 2, y: my - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: circle), with: .color(Ink.paper))
        ctx.stroke(Path(ellipseIn: circle.insetBy(dx: 0.75, dy: 0.75)), with: .color(Ink.red), lineWidth: 1.5)
        var fork = ctx.resolve(Image(systemName: "fork.knife"))
        fork.shading = .color(Ink.red)
        ctx.draw(fork, in: circle.insetBy(dx: 4, dy: 4))
        // 글씨 도구로 적은 메모
        ctx.draw(Text("산책").font(Fonts.hand(17)).foregroundColor(Ink.text),
                 at: CGPoint(x: hourW + cellW * 0.3, y: 5.5 * rowH), anchor: .leading)
        // 칠하고 있는 형광펜 끝
        if let head {
            let tip = CGRect(x: head.x - 3, y: head.y - rowH * 0.42, width: 6, height: rowH * 0.84)
            ctx.fill(Path(roundedRect: tip, cornerRadius: 2), with: .color(Ink.print.opacity(0.75)))
        }
    }
}

/// 본 창 옆 팔레트를 줄인 모양 (형광펜 세 자루 + 글씨 · 밥)
private struct MiniPalette: View {
    let active: Int

    var body: some View {
        VStack(spacing: 13) {
            ForEach(0..<3, id: \.self) { i in
                HighlighterPen(color: OB.cats[i])
                    .scaleEffect(0.62)
                    .frame(width: 36, height: 12)
                    .offset(x: active == i ? -5 : 0)
                    .shadow(color: active == i ? OB.cats[i].opacity(0.9) : .clear, radius: 5)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
            }
            Rectangle().fill(Ink.print.opacity(0.1)).frame(width: 30, height: 1)
            ForEach(["pencil.line", "fork.knife"], id: \.self) { icon in
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.print.opacity(0.7))
                    .frame(width: 30, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.print.opacity(0.07)))
            }
        }
        .padding(.vertical, 14)
        .frame(width: 50)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "F1F0EE").opacity(0.96))
                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 0.6))
    }
}

// MARK: - 5 할 일

private struct TasksPage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Headline(text: "쓰고, 체크하고, 칠해요", tint: OnboardingModel.Step.tasks.tint)
                VStack(alignment: .leading, spacing: 17) {
                    TipRow(title: "빈 줄을 눌러 쓰기",
                           detail: "할 일을 적고 Return 을 누르면 아래 줄에 이어서 써요.") {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Ink.print)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        TipRow(title: "체크 박스", detail: "누를 때마다 표시가 바뀌어요.") {
                            MarkShape(mark: .done)
                                .stroke(Ink.red, lineWidth: 1.8)
                                .frame(width: 16, height: 16)
                        }
                        MarkSequence()
                            .padding(.leading, 51)
                    }
                    TipRow(title: "끝낸 일엔 형광펜",
                           detail: "○ 로 끝내면 그 일의 형광펜이 그어지고, 같은 형광펜끼리 모여요.") {
                        Text("완료")
                            .font(Fonts.hand(15))
                            .foregroundStyle(Ink.text)
                            .background(HighlighterBar(color: OB.cats[1]).padding(.horizontal, -3).padding(.vertical, 2))
                    }
                }
                .padding(.top, 22)
                PenNote(text: "오른쪽 클릭으로 형광펜 색을 바꾸거나 내일로 미뤄요")
                    .padding(.top, 18)
                    .padding(.leading, 4)
            }
            .frame(width: 338, alignment: .leading)
            Spacer(minLength: 0)
            TasksIllustration()
                .frame(width: 262, height: 340)
                .offset(y: -10)
        }
    }
}

/// ○ 완료 › △ 일부 › × 못함 › → 미룸
private struct MarkSequence: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array([Mark.done, .partial, .missed, .moved].enumerated()), id: \.offset) { i, m in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Ink.faint)
                }
                HStack(spacing: 3) {
                    MarkShape(mark: m)
                        .stroke(Ink.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 11)
                    Text(m.shortName)
                        .font(Fonts.print(11.5, .medium))
                        .foregroundStyle(Ink.print)
                }
            }
        }
    }
}

private extension Mark {
    var shortName: String {
        switch self {
        case .none: ""
        case .done: "완료"
        case .partial: "일부"
        case .missed: "못함"
        case .moved: "미룸"
        }
    }
}

/// 할 일 줄들: 둘째 줄의 체크 표시가 ○ → △ → × → → 로 바뀌고, ○ 일 때 형광펜이 그어진다
private struct TasksIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private struct Row {
        let tag: String?
        let text: String
        let mark: Mark
        let pen: Int
    }

    private static let rows: [Row] = [
        Row(tag: "집중 업무", text: "기획서 초안", mark: .done, pen: 0),
        Row(tag: nil, text: "자료 조사", mark: .none, pen: 0),
        Row(tag: "미팅", text: "주간 회의", mark: .done, pen: 1),
        Row(tag: nil, text: "회의록 공유", mark: .partial, pen: 1),
        Row(tag: "개인", text: "운동 30분", mark: .missed, pen: 5),
    ]
    private static let cycle: [Mark] = [.none, .done, .partial, .missed, .moved]
    private static let beat: Double = 1.25

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? Self.beat * 1.8 : tl.date.timeIntervalSince(start)
            let k = Int(t / Self.beat) % Self.cycle.count
            let since = t.truncatingRemainder(dividingBy: Self.beat)
            let live = Self.cycle[k]
            sheet(live: live, since: since)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sheet(live: Mark, since: Double) -> some View {
        let pitch: CGFloat = 36
        let tagW: CGFloat = 58
        let boxW: CGFloat = 30
        return VStack(alignment: .leading, spacing: 0) {
            FormLabel(text: "TASKS")
            ZStack(alignment: .topLeading) {
                // 줄, 카테고리 점선, 체크 박스 점선
                Canvas { ctx, size in
                    for r in 1...6 {
                        var l = Path()
                        let y = CGFloat(r) * pitch
                        l.move(to: CGPoint(x: 0, y: y))
                        l.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(l, with: .color(Ink.rule), lineWidth: 0.8)
                    }
                    var y: CGFloat = 3
                    while y < size.height {
                        ctx.fill(Path(ellipseIn: CGRect(x: tagW - 0.6, y: y, width: 1.2, height: 1.2)), with: .color(Ink.dot))
                        y += 4
                    }
                    for r in 0..<6 {
                        let box = CGRect(x: size.width - boxW + 6, y: CGFloat(r) * pitch + (pitch - 18) / 2, width: 18, height: 18)
                        ctx.stroke(Path(box), with: .color(Ink.dot), style: StrokeStyle(lineWidth: 1, dash: [1.4, 2]))
                    }
                }
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { i, row in
                    let mark = i == 1 ? live : row.mark
                    let bar = mark == .done ? (i == 1 ? min(1, since / 0.35) : 1) : 0
                    HStack(spacing: 0) {
                        Text(row.tag ?? "")
                            .font(Fonts.hand(14))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: tagW - 4)
                        Text(row.text)
                            .font(Fonts.hand(19))
                            .foregroundStyle(Ink.text)
                            .background(alignment: .leading) {
                                GeometryReader { g in
                                    HighlighterBar(color: OB.cats[row.pen])
                                        .frame(width: (g.size.width + 8) * bar, height: g.size.height * 0.8)
                                        .offset(x: -4, y: g.size.height * 0.18)
                                }
                            }
                            .padding(.leading, 10)
                        Spacer(minLength: 0)
                        MarkShape(mark: mark)
                            .stroke(mark == .none ? .clear : Ink.red,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 17, height: 17)
                            .scaleEffect(i == 1 ? 1 + 0.25 * max(0, 1 - since / 0.18) : 1)
                            .frame(width: boxW)
                    }
                    .frame(height: pitch)
                    .offset(y: CGFloat(i) * pitch)
                }
                // 비어 있는 줄: 눌러서 쓰는 중
                HStack(spacing: 1) {
                    Rectangle()
                        .fill(Ink.text)
                        .frame(width: 1.4, height: 18)
                        .opacity(since.truncatingRemainder(dividingBy: 1) < 0.55 ? 1 : 0)
                    Text("눌러서 쓰기…")
                        .font(Fonts.hand(18))
                        .foregroundStyle(Ink.faint)
                }
                .frame(height: pitch)
                .offset(x: tagW + 10, y: 5 * pitch)
                // 커서
                Image(systemName: "cursorarrow")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Ink.print)
                    .shadow(color: .white, radius: 0.5)
                    .offset(x: 214, y: pitch * 1.45)
            }
            .frame(width: 228, height: 6 * pitch, alignment: .topLeading)
            .padding(.top, 2)
        }
        .padding(14)
        .modifier(PaperCard())
        .rotationEffect(.degrees(-1.2))
    }
}

// MARK: - 6 주간 · 일간 · 홈

private struct ViewsPage: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Headline(text: "한 주, 하루, 한눈에", tint: OnboardingModel.Step.views.tint)
                VStack(spacing: 0) {
                    ShortcutRow(keys: ["W"], title: "주간", detail: "한 주를 한 장에")
                    ShortcutRow(keys: ["D"], title: "일간", detail: "하루를 10분 단위로")
                    ShortcutRow(keys: ["H"], title: "홈", detail: "쌓인 기록과 통계")
                    ShortcutRow(keys: ["T"], title: "오늘로", detail: "어디서든 오늘 장으로")
                    ShortcutRow(keys: ["⌘", ","], title: "설정", detail: "플래너 여러 권 · 형광펜 · 컬러", ruled: false)
                }
                .padding(.top, 18)
                PenNote(text: "팔레트의 버튼으로도 똑같이 할 수 있어요")
                    .padding(.top, 14)
                    .padding(.leading, 4)
            }
            .frame(width: 338, alignment: .leading)
            Spacer(minLength: 0)
            ViewsIllustration()
                .frame(width: 262, height: 340)
                .offset(y: -10)
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let title: String
    let detail: String
    var ruled = true

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap(label: $0, size: 22) }
            }
            .frame(width: 52, alignment: .leading)
            Text(title)
                .font(Fonts.print(13.5, .demiBold))
                .foregroundStyle(Ink.print)
                .frame(width: 52, alignment: .leading)
            Text(detail)
                .font(Fonts.print(12.5))
                .foregroundStyle(OB.body)
            Spacer(minLength: 0)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            if ruled { Rectangle().fill(Ink.rule).frame(height: 1) }
        }
    }
}

/// 주간 · 홈 · 일간 세 장과 책장
private struct ViewsIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniWeekly()
                .frame(width: 168, height: 107)
                .modifier(PaperCard(radius: 3))
                .overlay(alignment: .bottomLeading) { KeyCap(label: "W", size: 20).offset(x: -6, y: 8) }
                .rotationEffect(.degrees(-4))
                .offset(x: 0, y: 14)
            MiniHome()
                .frame(width: 168, height: 107)
                .modifier(PaperCard(radius: 3))
                .overlay(alignment: .topTrailing) { KeyCap(label: "H", size: 20).offset(x: 6, y: -8) }
                .rotationEffect(.degrees(3.5))
                .offset(x: 92, y: 0)
            MiniDailySchematic()
                .frame(width: 92, height: 144)
                .modifier(PaperCard(radius: 3))
                .overlay(alignment: .bottomTrailing) { KeyCap(label: "D", size: 20).offset(x: 8, y: 6) }
                .rotationEffect(.degrees(-1))
                .offset(x: 84, y: 96)
            // 책장: 여러 권
            HStack(alignment: .bottom, spacing: -8) {
                ForEach(Array([(0, "내 플래너"), (4, "2027"), (3, "운동")].enumerated()), id: \.offset) { i, b in
                    MiniCover(color: ColorConcept.of(b.0).accent)
                        .frame(width: 38, height: 50)
                        .overlay {
                            Text(b.1)
                                .font(Fonts.hand(10))
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(width: 22)
                                .offset(x: 1, y: -9)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1.5)
                        .rotationEffect(.degrees(Double(i - 1) * 6), anchor: .bottom)
                }
            }
            .offset(x: 6, y: 262)
            HStack(spacing: 4) {
                KeyCap(label: "⌘", size: 18)
                KeyCap(label: ",", size: 18)
                Text("여러 권도 한 앱에")
                    .font(Fonts.hand(17))
                    .foregroundStyle(Ink.pen)
                    .padding(.leading, 3)
            }
            .offset(x: 112, y: 290)
        }
        .frame(width: 262, height: 340, alignment: .topLeading)
    }
}

private struct MiniWeekly: View {
    var body: some View {
        Canvas { ctx, size in
            let inset: CGFloat = 8
            // 위쪽 스프링 구멍
            var x: CGFloat = 20
            while x < size.width - 6 {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 3, width: 3.5, height: 2.6), cornerRadius: 0.8),
                         with: .color(Color(hex: "4E5057").opacity(0.8)))
                x += 7
            }
            let colW = (size.width - inset * 2 - 6 * 3) / 7
            for c in 0..<7 {
                let cx = inset + CGFloat(c) * (colW + 3)
                let r = CGRect(x: cx, y: 22, width: colW, height: size.height - 30)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 1.2), with: .color(Ink.rule), lineWidth: 0.6)
                for l in 0..<3 where !(c > 4 && l > 0) {
                    let w = colW * [0.7, 0.5, 0.6][l]
                    ctx.fill(Path(roundedRect: CGRect(x: cx + 3, y: 30 + CGFloat(l) * 7, width: w, height: 2.2), cornerRadius: 1),
                             with: .color(Ink.text.opacity(0.55)))
                }
                for s in 0..<5 where c < 5 {
                    let w = colW * (0.35 + 0.13 * CGFloat((c + s) % 5))
                    let cat = OB.cats[(c + s) % 5]
                    ctx.fill(Path(roundedRect: CGRect(x: cx + 2, y: 58 + CGFloat(s) * 7, width: w, height: 4.5), cornerRadius: 1),
                             with: .color(cat.opacity(0.85)))
                }
            }
            ctx.draw(Text("MY GOAL").font(Fonts.print(4.5, .demiBold)).foregroundColor(Ink.soft),
                     at: CGPoint(x: inset + 2, y: 15), anchor: .leading)
        }
    }
}

private struct MiniHome: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 20
            while x < size.width - 6 {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 3, width: 3.5, height: 2.6), cornerRadius: 0.8),
                         with: .color(Color(hex: "4E5057").opacity(0.8)))
                x += 7
            }
            ctx.draw(Text("THIS MONTH").font(Fonts.print(4.5, .demiBold)).foregroundColor(Ink.soft),
                     at: CGPoint(x: 10, y: 16), anchor: .leading)
            let heights: [CGFloat] = [0.5, 0.8, 0.65, 0.95, 0.7, 0.35, 0.25]
            for (i, h) in heights.enumerated() {
                let bh = 52 * h
                let r = CGRect(x: 12 + CGFloat(i) * 11, y: 86 - bh, width: 7, height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(OB.cats[i % 5].opacity(0.9)))
            }
            var base = Path()
            base.move(to: CGPoint(x: 9, y: 86.5))
            base.addLine(to: CGPoint(x: 92, y: 86.5))
            ctx.stroke(base, with: .color(Ink.print), lineWidth: 0.8)
            // 달력 점
            for r in 0..<5 {
                for c in 0..<7 {
                    let on = (r * 7 + c) % 3 != 0 && r * 7 + c < 30
                    let dot = CGRect(x: 104 + CGFloat(c) * 8, y: 26 + CGFloat(r) * 12, width: 5.5, height: 5.5)
                    ctx.fill(Path(roundedRect: dot, cornerRadius: 1.2),
                             with: .color(on ? OB.cats[(r + c) % 4].opacity(0.75) : Ink.rule.opacity(0.6)))
                }
            }
            ctx.draw(Text("128H").font(Fonts.rounded(11, .black)).foregroundColor(Ink.red),
                     at: CGPoint(x: 10, y: 98), anchor: .leading)
        }
    }
}

private struct MiniDailySchematic: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 8
            while y < size.height - 6 {
                ctx.fill(Path(roundedRect: CGRect(x: 2.5, y: y, width: 2.6, height: 3.5), cornerRadius: 0.8),
                         with: .color(Color(hex: "4E5057").opacity(0.8)))
                y += 7
            }
            ctx.draw(Text("0929").font(Fonts.hand(12)).foregroundColor(Ink.text), at: CGPoint(x: 11, y: 13), anchor: .leading)
            ctx.draw(Text("6H40M").font(Fonts.rounded(8, .black)).foregroundColor(Ink.red),
                     at: CGPoint(x: size.width - 6, y: 13), anchor: .trailing)
            let split: CGFloat = 54
            for r in 0..<11 {
                let ly = 30 + CGFloat(r) * 10
                var l = Path()
                l.move(to: CGPoint(x: 10, y: ly))
                l.addLine(to: CGPoint(x: split - 3, y: ly))
                ctx.stroke(l, with: .color(Ink.rule), lineWidth: 0.5)
                if r < 5 {
                    let w: CGFloat = [26, 20, 30, 18, 24][r]
                    ctx.fill(Path(roundedRect: CGRect(x: 13, y: ly - 7, width: w, height: 2.4), cornerRadius: 1),
                             with: .color(Ink.text.opacity(0.55)))
                }
            }
            let cellW = (size.width - split - 6) / 6
            let fills: [(Int, Int, Int)] = [(0, 1, 5), (1, 0, 5), (2, 0, 2), (3, 2, 5), (5, 0, 4), (6, 0, 5), (8, 1, 3)]
            for (row, a, b) in fills {
                let r = CGRect(x: split + CGFloat(a) * cellW, y: 24 + CGFloat(row) * 9.5, width: CGFloat(b - a + 1) * cellW - 1, height: 6)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(OB.cats[(row + a) % 5].opacity(0.85)))
            }
        }
    }
}

// MARK: - 7 시작하기

private struct ReadyPage: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        let book = store.activeBook ?? model.draft.preview
        HStack(alignment: .top, spacing: 40) {
            ZStack(alignment: .bottomTrailing) {
                BookCover(book: book, width: 182)
                    .rotationEffect(.degrees(-4))
                HighlighterPen(color: OB.cats[3])
                    .scaleEffect(1.45)
                    .rotationEffect(.degrees(-58))
                    .offset(x: 26, y: -8)
            }
            .frame(width: 200)
            .padding(.top, 6)
            .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 0) {
                Headline(text: "준비 끝!", tint: OnboardingModel.Step.ready.tint, size: 44)
                BodyText(text: "이제 첫 장을 펼쳐 볼까요? 오늘 할 일부터 한 줄 적어 보세요.", size: 14)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 0) {
                    FormLabel(text: "MY PLANNER", size: 8.5, rule: 1.2)
                        .padding(.bottom, 8)
                    Text(book.name)
                        .font(Fonts.hand(26))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(book.periodText)
                            .font(Fonts.print(12, .medium))
                            .foregroundStyle(OB.body)
                        if book.end == nil {
                            Text("종료일 없이 계속")
                                .font(Fonts.print(10.5, .medium))
                                .foregroundStyle(Ink.soft)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(16)
                .frame(width: 318, alignment: .leading)
                .modifier(PaperCard())
                .padding(.top, 26)

                StickyNote(text: "이 안내는 설정(⌘,)에서\n언제든 다시 볼 수 있어요")
                    .rotationEffect(.degrees(2))
                    .padding(.top, 24)
                    .padding(.leading, 150)
            }
            .padding(.top, 8)
        }
    }
}

private struct StickyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.hand(17))
            .foregroundStyle(Ink.text)
            .lineSpacing(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                ZStack {
                    Color(hex: "FBEFA9")
                    NoiseLayer(opacity: 0.5).blendMode(.multiply)
                }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 3)
            }
            .overlay(alignment: .top) {
                // 마스킹 테이프
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 46, height: 13)
                    .rotationEffect(.degrees(-4))
                    .offset(y: -7)
            }
    }
}

// MARK: - Mini daily page (그림)

/// 작은 일간 페이지 한 장 (왼쪽 스프링 + 양식 + 손글씨 샘플)
private struct MiniDailyPage: View {
    let day: MiniDay

    /// 스프링이 종이 밖으로 나오는 폭
    static let ring: CGFloat = 8
    static let paper = CGSize(width: 206, height: 290)
    static var size: CGSize { CGSize(width: paper.width + ring, height: paper.height) }
    static var paperRect: CGRect { CGRect(x: ring, y: 0, width: paper.width, height: paper.height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Ink.paper
                NoiseLayer(opacity: 0.45).blendMode(.multiply)
                LinearGradient(colors: [.black.opacity(0.05), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.08, y: 0.5))
                Canvas { ctx, size in drawPage(&ctx, size) }
            }
            .frame(width: Self.paper.width, height: Self.paper.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 5)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .offset(x: Self.ring)
            Canvas { ctx, size in drawRings(&ctx, size) }
                .frame(width: Self.ring + 16, height: Self.paper.height)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    // 좌표는 종이 기준 (206 × 290)
    private static let holes: [CGFloat] = stride(from: 14.0, to: 282, by: 15.2).map { $0 }
    private static let left: CGFloat = 20, leftEnd: CGFloat = 130, tagX: CGFloat = 46
    private static let ttLeft: CGFloat = 138, ttRight: CGFloat = 197
    private static let gridTop: CGFloat = 70, pitch: CGFloat = 17.2, rows = 9
    private static var memoTop: CGFloat { gridTop + CGFloat(rows) * pitch + 16 }
    private static let ttRows = 14
    private static var ttPitch: CGFloat { (memoTop + 2 * pitch - gridTop) / CGFloat(ttRows) }

    private func drawRings(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let edge = Self.ring
        for y in Self.holes {
            let mid = y + 2.5
            var back = Path()
            back.move(to: CGPoint(x: edge, y: mid - 1.8))
            back.addLine(to: CGPoint(x: 1.8, y: mid - 1.8))
            back.addQuadCurve(to: CGPoint(x: 1.8, y: mid + 1.8), control: CGPoint(x: -0.6, y: mid))
            ctx.stroke(back, with: .color(Color(hex: "5E6168")), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            var front = Path()
            front.move(to: CGPoint(x: 1.8, y: mid + 1.8))
            front.addLine(to: CGPoint(x: edge + 6.5, y: mid + 0.6))
            var shadow = ctx
            shadow.addFilter(.blur(radius: 0.8))
            shadow.stroke(front.offsetBy(dx: 0.6, dy: 1), with: .color(.black.opacity(0.25)), lineWidth: 1.3)
            ctx.stroke(front, with: .color(Color(hex: "5E6168")), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            ctx.stroke(front, with: .color(Color(hex: "C4C7CD")), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
    }

    private func drawPage(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let L = Self.left, R = Self.leftEnd
        // 구멍
        for y in Self.holes {
            ctx.fill(Path(roundedRect: CGRect(x: 4, y: y, width: 5, height: 5), cornerRadius: 1.2),
                     with: .color(Color(hex: "4E5057").opacity(0.85)))
        }
        // DATE · TOTAL TIME
        label(&ctx, "DATE", x: L, y: 16, to: R)
        label(&ctx, "TOTAL TIME", x: Self.ttLeft, y: 16, to: Self.ttRight)
        let date = ctx.resolve(Text(day.date).font(Fonts.hand(19)).foregroundColor(Ink.text)
            + Text(" " + day.weekday).font(Fonts.hand(19)).foregroundColor(Ink.red))
        let ds = date.measure(in: size)
        var ink = ctx
        ink.blendMode = .multiply
        ink.fill(highlight(CGRect(x: L + 2, y: 29 + ds.height * 0.42, width: ds.width + 6, height: ds.height * 0.42)),
                 with: .color(Color(hex: "F7C3C5").opacity(0.8)))
        ctx.draw(date, at: CGPoint(x: L + 5, y: 29), anchor: .topLeading)
        let total = Text(day.hours).font(Fonts.rounded(18, .black)) + Text("H").font(Fonts.rounded(9, .black))
            + Text(day.minutes).font(Fonts.rounded(18, .black)) + Text("M").font(Fonts.rounded(9, .black))
        ctx.draw(total.foregroundColor(Ink.red), at: CGPoint(x: (Self.ttLeft + Self.ttRight) / 2, y: 40))

        // TASKS
        label(&ctx, "TASKS", x: L, y: Self.gridTop - 4, to: R, heavy: true)
        for r in 1...Self.rows {
            line(&ctx, y: Self.gridTop + CGFloat(r) * Self.pitch, from: L, to: R, width: r == 5 ? 0.9 : 0.5,
                 color: r == 5 ? Ink.print.opacity(0.6) : Ink.rule)
        }
        dotted(&ctx, x: Self.tagX, from: Self.gridTop + 2, to: Self.gridTop + CGFloat(Self.rows) * Self.pitch)
        for r in 0..<Self.rows {
            let box = CGRect(x: R - 11, y: Self.gridTop + CGFloat(r) * Self.pitch + (Self.pitch - 9) / 2, width: 9, height: 9)
            ctx.stroke(Path(box), with: .color(Ink.dot), style: StrokeStyle(lineWidth: 0.6, dash: [0.9, 1.3]))
        }
        for (i, t) in day.tasks.enumerated() {
            let cy = Self.gridTop + (CGFloat(i) + 0.55) * Self.pitch
            if let tag = t.tag {
                ctx.draw(Text(tag).font(Fonts.hand(9.5)).foregroundColor(Ink.text), at: CGPoint(x: (L + Self.tagX) / 2, y: cy))
            }
            let text = ctx.resolve(Text(t.text).font(Fonts.hand(12)).foregroundColor(Ink.text))
            let ts = text.measure(in: size)
            if t.mark == .done {
                ink.fill(highlight(CGRect(x: Self.tagX + 4, y: cy - ts.height * 0.36, width: ts.width + 6, height: ts.height * 0.74)),
                         with: .color(OB.cats[t.pen].opacity(0.8)))
            }
            ctx.draw(text, at: CGPoint(x: Self.tagX + 7, y: cy), anchor: .leading)
            if t.mark != .none {
                let box = CGRect(x: R - 11, y: Self.gridTop + CGFloat(i) * Self.pitch + (Self.pitch - 9) / 2, width: 9, height: 9)
                ctx.stroke(MarkShape(mark: t.mark).path(in: box.insetBy(dx: -0.5, dy: -0.5)), with: .color(Ink.red),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }
        }

        // MEMO
        label(&ctx, "MEMO", x: L, y: Self.memoTop - 4, to: R, heavy: true)
        for r in 1...2 {
            line(&ctx, y: Self.memoTop + CGFloat(r) * Self.pitch, from: L, to: R, width: 0.5, color: Ink.rule)
        }
        ctx.draw(Text(day.memo).font(Fonts.hand(11.5)).foregroundColor(Ink.text),
                 at: CGPoint(x: Self.tagX + 7, y: Self.memoTop + 0.55 * Self.pitch), anchor: .leading)

        // TIMETABLE
        label(&ctx, "TIMETABLE", x: Self.ttLeft, y: Self.gridTop - 4, to: Self.ttRight, heavy: true)
        let hourW: CGFloat = 9
        let cellW = (Self.ttRight - Self.ttLeft - hourW) / 6
        let bottom = Self.gridTop + CGFloat(Self.ttRows) * Self.ttPitch
        for (row, a, b, pen) in day.slots {
            let r = CGRect(x: Self.ttLeft + hourW + CGFloat(a) * cellW + 0.5, y: Self.gridTop + CGFloat(row) * Self.ttPitch + 2.2,
                           width: CGFloat(b - a + 1) * cellW - 1, height: Self.ttPitch - 4.4)
            ink.fill(Path(roundedRect: r, cornerRadius: 1.4), with: .color(OB.cats[pen].opacity(0.86)))
        }
        for r in 1...Self.ttRows {
            line(&ctx, y: Self.gridTop + CGFloat(r) * Self.ttPitch, from: Self.ttLeft, to: Self.ttRight, width: 0.5, color: Ink.rule)
        }
        line(&ctx, x: Self.ttLeft + hourW, from: Self.gridTop, to: bottom, width: 0.7, color: Ink.print.opacity(0.8))
        for c in 1..<6 {
            dotted(&ctx, x: Self.ttLeft + hourW + CGFloat(c) * cellW, from: Self.gridTop + 1, to: bottom, dot: 0.7)
        }
        for r in 0..<Self.ttRows {
            let h = (r + 6 - 1) % 12 + 1
            ctx.draw(Text("\(h)").font(Fonts.print(5.5, .bold)).foregroundColor(Ink.print),
                     at: CGPoint(x: Self.ttLeft + hourW / 2, y: Self.gridTop + (CGFloat(r) + 0.5) * Self.ttPitch))
        }

        ctx.draw(Text("paperplanner").font(Fonts.print(7.5, .bold)).foregroundColor(Ink.print),
                 at: CGPoint(x: Self.ttRight, y: size.height - 11), anchor: .trailing)
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, x: CGFloat, y: CGFloat, to end: CGFloat, heavy: Bool = false) {
        let t = ctx.resolve(Text(text).font(Fonts.print(5.6, .demiBold)).foregroundColor(Ink.print))
        let s = t.measure(in: CGSize(width: 200, height: 20))
        ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .bottomLeading)
        line(&ctx, y: y - 1, from: x + s.width + 3, to: end, width: heavy ? 1.1 : 0.9, color: Ink.print)
    }

    private func line(_ ctx: inout GraphicsContext, y: CGFloat, from a: CGFloat, to b: CGFloat, width: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: a, y: y))
        p.addLine(to: CGPoint(x: b, y: y))
        ctx.stroke(p, with: .color(color), lineWidth: width)
    }

    private func line(_ ctx: inout GraphicsContext, x: CGFloat, from a: CGFloat, to b: CGFloat, width: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: a))
        p.addLine(to: CGPoint(x: x, y: b))
        ctx.stroke(p, with: .color(color), lineWidth: width)
    }

    private func dotted(_ ctx: inout GraphicsContext, x: CGFloat, from a: CGFloat, to b: CGFloat, dot: CGFloat = 0.8) {
        var y = a
        while y < b {
            ctx.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y, width: dot, height: dot)), with: .color(Ink.dot))
            y += 2.6
        }
    }

    /// 손으로 그은 형광펜 한 줄 (HighlighterBar 와 같은 모양)
    private func highlight(_ r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX + 1, y: r.minY + h * 0.18))
        p.addLine(to: CGPoint(x: r.minX + w - 2, y: r.minY + h * 0.10))
        p.addQuadCurve(to: CGPoint(x: r.minX + w, y: r.minY + h * 0.86), control: CGPoint(x: r.minX + w + h * 0.12, y: r.minY + h * 0.5))
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.minY + h * 0.94))
        p.addQuadCurve(to: CGPoint(x: r.minX + 1, y: r.minY + h * 0.18), control: CGPoint(x: r.minX - h * 0.08, y: r.minY + h * 0.55))
        return p
    }
}

/// 그림에 쓰는 하루치 샘플
private struct MiniDay {
    struct Task {
        let tag: String?
        let text: String
        let mark: Mark
        let pen: Int
    }

    let date: String
    let weekday: String
    let hours: String
    let minutes: String
    let tasks: [Task]
    /// (줄, 첫 칸, 끝 칸, 펜)
    let slots: [(Int, Int, Int, Int)]
    let memo: String

    static let sample = MiniDay(
        date: "0929", weekday: "TUE", hours: "6", minutes: "40",
        tasks: [
            Task(tag: "업무", text: "기획서 초안", mark: .done, pen: 0),
            Task(tag: nil, text: "자료 정리", mark: .done, pen: 0),
            Task(tag: "미팅", text: "팀 미팅", mark: .partial, pen: 1),
            Task(tag: "학습", text: "영어 스터디", mark: .done, pen: 4),
            Task(tag: "개인", text: "운동 30분", mark: .missed, pen: 5),
        ],
        slots: [(1, 2, 5, 0), (2, 0, 5, 0), (3, 0, 2, 0), (3, 3, 5, 1), (4, 0, 3, 1), (6, 0, 5, 2), (7, 0, 4, 4), (9, 1, 5, 3)],
        memo: "내일 발표 준비")

    static let sampleNext = MiniDay(
        date: "0930", weekday: "WED", hours: "4", minutes: "10",
        tasks: [
            Task(tag: "업무", text: "QA 정리", mark: .done, pen: 0),
            Task(tag: "소통", text: "메일 답장", mark: .none, pen: 2),
        ],
        slots: [(1, 0, 5, 0), (2, 0, 3, 0), (4, 2, 5, 2), (5, 0, 5, 2)],
        memo: "")
}

// MARK: - Small drawing pieces

/// 인쇄된 작은 라벨 + 굵은 머리선 (양식의 TASKS ━━━ 처럼)
private struct FormLabel: View {
    let text: String
    var size: CGFloat = 8.5
    var rule: CGFloat = 1.4

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.6) {
            Text(text)
                .font(Fonts.print(size, .demiBold))
                .kerning(size * 0.08)
                .foregroundStyle(Ink.print)
                .fixedSize()
            Rectangle()
                .fill(Ink.print)
                .frame(height: rule)
        }
    }
}

/// 종이 카드 (결 + 그림자)
private struct PaperCard: ViewModifier {
    var radius: CGFloat = 4

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    Ink.paper
                    NoiseLayer(opacity: 0.45).blendMode(.multiply)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.13), radius: 9, y: 5)
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

/// 누워 있는 형광펜 (팔레트의 펜과 같은 모양): 심 · 색 뚜껑 · 흰 몸통
private struct HighlighterPen: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 4))
                p.addLine(to: CGPoint(x: 7, y: 0))
                p.addLine(to: CGPoint(x: 7, y: 12))
                p.addLine(to: CGPoint(x: 0, y: 9))
                p.closeSubpath()
            }
            .fill(color.opacity(0.95))
            .frame(width: 7, height: 12)
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 1.5,
                                   topTrailingRadius: 1.5, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.8), color, color.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 16)
                .overlay(alignment: .top) {
                    Capsule().fill(.white.opacity(0.5)).frame(width: 10, height: 2).offset(y: 3)
                }
            UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5, bottomTrailingRadius: 5,
                                   topTrailingRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(hex: "E9E7E2")], startPoint: .top, endPoint: .bottom))
                .frame(width: 28, height: 14)
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).padding(.leading, 4) }
        }
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        .fixedSize()
    }
}
