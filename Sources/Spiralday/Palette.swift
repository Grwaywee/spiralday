import AppKit
import Combine
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 도구 팔레트 (1.0.6: 접기 · 자리 고르기)
//   · 본 창의 child window(PalettePanel). 창을 옮기면 같이 움직이고, 앱을 활성화시키지 않는다.
//   · 자리: 오른쪽(기본) · 왼쪽 · 위 · 아래 (설정 → 팔레트). 옆이면 세로 한 줄, 위 · 아래면 가로 한 줄.
//     스프링이 달린 쪽(일간 왼쪽, 주간 · 홈 위)이면 스프링만큼 더 띄운다. 화면에 자리가 없으면 반대쪽으로.
//   · 접기: 접으면 종이 옆에 가느다란 손잡이만 남는다 (지금 고른 도구가 보인다).
//     손잡이에 마우스를 올리면 펼쳐지고 팔레트에서 벗어나면 다시 접힌다. 손잡이를 누르면 펼친 채로 고정.
//     1–7 · E 로 도구를 바꾸면 잠깐 펼쳐 보여 준다. 마우스를 누른 채(칠하는 중)로는 펼치지 않는다.
//   · 패널은 펼친 팔레트 크기 그대로 두고 접고 펼치는 움직임은 SwiftUI 안에서만 한다
//     (접힌 채로 가만히 있을 때만 패널을 손잡이 크기로 줄인다). 창 크기가 바뀌는 도중에는
//     팔레트 모델을 바꾸지 않고 다음 차례로 미룬다 (1.0.5 크래시와 같은 모양을 만들지 않게).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - 자리

enum PaletteEdge: String, CaseIterable, Identifiable {
    case right, left, top, bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .right: "오른쪽"
        case .left: "왼쪽"
        case .top: "위"
        case .bottom: "아래"
        }
    }

    /// 옆에 붙는 세로 팔레트인지 (위 · 아래는 가로 한 줄)
    var isVertical: Bool { self == .right || self == .left }

    var opposite: PaletteEdge {
        switch self {
        case .right: .left
        case .left: .right
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// 팔레트 안에서 종이를 향한 쪽 (손잡이가 붙는 곳)
    var dock: Alignment {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// 종이 쪽 방향 (SwiftUI 좌표, 아래가 +y). 고른 펜이 이쪽으로 살짝 나온다.
    var towardPage: CGVector {
        switch self {
        case .right: CGVector(dx: -1, dy: 0)
        case .left: CGVector(dx: 1, dy: 0)
        case .top: CGVector(dx: 0, dy: 1)
        case .bottom: CGVector(dx: 0, dy: -1)
        }
    }

    /// 접기 화살표 (종이 쪽으로) · 펼치기 화살표 (바깥으로)
    var collapseSymbol: String {
        switch self {
        case .right: "chevron.left"
        case .left: "chevron.right"
        case .top: "chevron.down"
        case .bottom: "chevron.up"
        }
    }

    var expandSymbol: String { opposite.collapseSymbol }

    /// 팔레트에서 여는 팝오버(펜 · D-day)는 종이 쪽으로 뜬다
    var popoverArrowEdge: Edge {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// 스프링이 달린 쪽 (일간: 왼쪽, 주간 · 홈: 위)
    static func ringSide(_ kind: PageKind) -> PaletteEdge { kind.edge == .leading ? .left : .top }
}

enum PaletteMetrics {
    /// 세로 팔레트의 너비 = 가로 팔레트의 높이 (그림자 여유 빼고)
    static let thickness: CGFloat = 78
    /// 패널 가장자리의 그림자 여유
    static let margin: CGFloat = 6
    static let radius: CGFloat = 20
    /// 접었을 때의 손잡이
    static let handleThickness: CGFloat = 26
    static let handleLength: CGFloat = 116
    /// 손잡이에 올린 뒤 펼치기까지 · 팔레트에서 벗어난 뒤 접기까지 · 단축키로 잠깐 펼쳐 두는 시간
    static let hoverDelay: TimeInterval = 0.12
    static let leaveDelay: TimeInterval = 0.6
    static let flashDuration: TimeInterval = 1.2

    static func handleSize(_ side: PaletteEdge) -> CGSize {
        side.isVertical ? CGSize(width: handleThickness, height: handleLength)
            : CGSize(width: handleLength, height: handleThickness)
    }

    /// 그림자 여유까지 넣은 손잡이 패널
    static func handlePanelSize(_ side: PaletteEdge) -> CGSize {
        let s = handleSize(side)
        return CGSize(width: s.width + 2 * margin, height: s.height + 2 * margin)
    }
}

// MARK: - 자리 계산 (화면 좌표, 아래가 0)

@MainActor
enum PalettePlacement {
    /// 그 쪽에 스프링이 튀어나와 있으면 그만큼 더 띄운다 (종이 너비를 따라 커진다)
    static func ringClearance(_ side: PaletteEdge, kind: PageKind, pageWidth: CGFloat) -> CGFloat {
        guard side == .ringSide(kind) else { return 0 }
        return (RingWindowController.outside * pageWidth / kind.design.width).rounded(.up)
    }

    /// 한 쪽에 붙였을 때의 패널 자리 (그 가장자리의 가운데. 화면은 보지 않는다)
    static func frame(_ size: CGSize, on side: PaletteEdge, of page: NSRect, kind: PageKind) -> NSRect {
        let d = MainWindowController.paletteGap + ringClearance(side, kind: kind, pageWidth: page.width)
        let w = size.width, h = size.height
        switch side {
        case .right: return NSRect(x: page.maxX + d, y: page.midY - h / 2, width: w, height: h)
        case .left: return NSRect(x: page.minX - d - w, y: page.midY - h / 2, width: w, height: h)
        case .top: return NSRect(x: page.midX - w / 2, y: page.maxY + d, width: w, height: h)
        case .bottom: return NSRect(x: page.midX - w / 2, y: page.minY - d - h, width: w, height: h)
        }
    }

    /// 종이에서 먼 가장자리가 화면 안인지
    static func fits(_ r: NSRect, on side: PaletteEdge, in vis: NSRect) -> Bool {
        overflow(r, side, vis) <= 0
    }

    private static func overflow(_ r: NSRect, _ side: PaletteEdge, _ vis: NSRect) -> CGFloat {
        switch side {
        case .right: r.maxX - vis.maxX
        case .left: vis.minX - r.minX
        case .top: r.maxY - vis.maxY
        case .bottom: vis.minY - r.minY
        }
    }

    /// 펼친 팔레트 패널의 자리와 실제로 붙은 쪽.
    /// 고른 쪽에 자리가 없으면 반대쪽, 양쪽 다 없으면 덜 모자란 쪽에 화면 안으로 (종이에 조금 겹친다).
    /// flips: false 면 반대쪽으로 넘기지 않고 그 쪽에서 화면 안으로만 (쪽 전환 애니메이션 도중)
    static func place(_ size: CGSize, page: NSRect, visible vis: NSRect, preferred: PaletteEdge,
                      kind: PageKind, flips: Bool = true) -> (frame: NSRect, side: PaletteEdge) {
        var side = preferred
        var r = frame(size, on: side, of: page, kind: kind)
        if !fits(r, on: side, in: vis) {
            let o = frame(size, on: side.opposite, of: page, kind: kind)
            if flips, fits(o, on: side.opposite, in: vis) || overflow(o, side.opposite, vis) < overflow(r, side, vis) {
                side = side.opposite
                r = o
            }
            if !fits(r, on: side, in: vis) {
                switch side {
                case .right: r.origin.x = vis.maxX - r.width
                case .left: r.origin.x = vis.minX
                case .top: r.origin.y = vis.maxY - r.height
                case .bottom: r.origin.y = vis.minY
                }
            }
        }
        // 가장자리를 따라서는 화면 안으로 (화면보다 길면 위 · 왼쪽을 맞춘다)
        if side.isVertical {
            r.origin.y = min(max(r.minY, vis.minY + 8), vis.maxY - r.height - 8)
        } else {
            r.origin.x = max(min(r.minX, vis.maxX - r.width - 8), vis.minX + 8)
        }
        r.origin.x = r.origin.x.rounded()
        r.origin.y = r.origin.y.rounded()
        return (r, side)
    }

    /// 접혀 있을 때의 패널: 펼친 자리 안, 종이 쪽 가장자리의 가운데 (SwiftUI 가 손잡이를 놓는 자리와 같다)
    static func handleFrame(in full: NSRect, side: PaletteEdge) -> NSRect {
        let s = PaletteMetrics.handlePanelSize(side)
        let x: CGFloat, y: CGFloat
        switch side {
        case .right: x = full.minX; y = full.midY - s.height / 2
        case .left: x = full.maxX - s.width; y = full.midY - s.height / 2
        case .top: x = full.midX - s.width / 2; y = full.minY
        case .bottom: x = full.midX - s.width / 2; y = full.maxY - s.height
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)
    }
}

// MARK: - 상태 (자리 · 접기)

/// 팔레트의 자리와 접힘. 팔레트 창과 설정 창만 본다 (본 창은 보지 않는다).
@MainActor
final class PaletteModel: ObservableObject {
    static let shared = PaletteModel()

    private enum Key {
        static let edge = "palette.edge"
        static let autoCollapse = "palette.autoCollapse"
        static let collapsed = "palette.collapsed"
    }

    /// 개발 · 점검 실행에서는 설정을 읽기만 하고 적지 않는다
    private static let volatileFlags = ["--demo", "--snapshot", "--tour-test", "--palette-test", "--sample-book-test",
                                        "--pdf-test", "--icon", "--palette-edge", "--load-safety-test"]

    /// `--palette-edge right|left|top|bottom`: 설정을 건드리지 않고 이번 실행만 그 자리에 (점검용)
    static var argumentEdge: PaletteEdge? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--palette-edge"), i + 1 < a.count else { return nil }
        return PaletteEdge(rawValue: a[i + 1])
    }

    /// 설정에 적는지 (점검 실행 · 점검용 모델은 적지 않는다)
    let persists: Bool

    /// 고른 자리 (설정)
    @Published var edge: PaletteEdge {
        didSet { if edge != oldValue { save(edge.rawValue, Key.edge) } }
    }

    /// 팔레트 자동으로 접기: 켜 두면 늘 접힌 채로 시작하고, 켜는 순간 접힌다. 끄면 펼쳐 둔다.
    @Published var autoCollapse: Bool {
        didSet {
            guard autoCollapse != oldValue else { return }
            save(autoCollapse, Key.autoCollapse)
            if autoCollapse { collapse() } else { pin() }
        }
    }

    /// 펼친 채로 고정 (손잡이를 누르거나 ⌘\ 로 펼쳤을 때)
    @Published private(set) var pinned: Bool
    /// 잠깐 펼침 (손잡이에 마우스를 올렸을 때 · 도구 단축키)
    @Published private(set) var peeking = false
    /// 실제로 붙은 쪽 (화면에 자리가 없으면 고른 쪽의 반대). 팔레트 창이 정한다.
    @Published var side: PaletteEdge

    var isOpen: Bool { pinned || peeking }

    /// 팔레트 창: 펼치기 직전 (패널을 먼저 펼친 크기로) · 접은 뒤 · 마우스가 팔레트 위에 있는지
    var willOpen: (() -> Void)?
    var didClose: (() -> Void)?
    var containsMouse: (() -> Bool)?

    private var overHandle = false
    private var hoverWork: DispatchWorkItem?
    private var openUntil = Date.distantPast
    private var watch: Timer?
    /// 팝오버 · 메뉴가 떠 있는 동안에는 접지 않는다
    private var holds: Set<String> = []

    private init() {
        let d = UserDefaults.standard
        persists = !Self.volatileFlags.contains(where: CommandLine.arguments.contains)
        let e = Self.argumentEdge ?? PaletteEdge(rawValue: d.string(forKey: Key.edge) ?? "") ?? .right
        edge = e
        side = e
        let auto = d.bool(forKey: Key.autoCollapse)
        autoCollapse = auto
        pinned = auto ? false : !d.bool(forKey: Key.collapsed)
        // 팔레트의 메뉴(플래너 고르기 · 컬러 오른쪽 클릭)가 열려 있는 동안
        for (name, on) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hold("menu", on) }
            }
        }
    }

    /// 점검용 (--palette-test · --tour-test): 설정을 읽지도 적지도 않는다
    init(testEdge: PaletteEdge, open: Bool) {
        persists = false
        edge = testEdge
        side = testEdge
        autoCollapse = false
        pinned = open
    }

    private func save(_ value: Any, _ key: String) {
        guard persists else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: 펼치기 · 접기

    /// 펼친 채로 고정 (손잡이 누르기 · ⌘\)
    func pin() {
        cancelHoverOpen()
        stopWatch()
        if !isOpen { willOpen?() }
        if !pinned { pinned = true }
        if peeking { peeking = false }
        save(false, Key.collapsed)
    }

    /// 접기 (팔레트의 접기 화살표 · ⌘\)
    func collapse() {
        cancelHoverOpen()
        stopWatch()
        let was = isOpen
        if pinned { pinned = false }
        if peeking { peeking = false }
        save(true, Key.collapsed)
        if was { didClose?() }
    }

    /// ⌘\ · 화살표: 고정돼 있으면 접고, 접혀 있으면 펼쳐 고정한다.
    /// 마우스를 올려 잠깐 펼친 상태에서 누르면 그대로 펼친 채 고정한다 (접지 않는다).
    func togglePinned() {
        if pinned { collapse() } else { pin() }
    }

    /// 손잡이에 마우스를 올리면 잠깐 뒤 펼친다. 마우스를 누른 채(종이를 칠하다가) 지나가면 펼치지 않는다.
    func hoverHandle(_ inside: Bool) {
        overHandle = inside
        cancelHoverOpen()
        guard inside, !isOpen, NSEvent.pressedMouseButtons == 0 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.overHandle, !self.isOpen, NSEvent.pressedMouseButtons == 0 else { return }
            self.peek(for: PaletteMetrics.leaveDelay)
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + PaletteMetrics.hoverDelay, execute: w)
    }

    /// 도구 단축키로 도구를 바꿨을 때: 접혀 있으면 잠깐 펼쳐 무엇을 골랐는지 보여 준다
    func flash() {
        guard !pinned, NSEvent.pressedMouseButtons == 0 else { return }
        peek(for: PaletteMetrics.flashDuration)
    }

    /// 팝오버 · 메뉴가 떠 있는 동안에는 잠깐 펼친 팔레트를 접지 않는다
    func hold(_ reason: String, _ on: Bool) {
        if on { holds.insert(reason) } else { holds.remove(reason) }
    }

    private func cancelHoverOpen() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    private func peek(for seconds: TimeInterval) {
        openUntil = max(openUntil, Date().addingTimeInterval(seconds))
        if !peeking {
            if !isOpen { willOpen?() }
            peeking = true
        }
        startWatch()
    }

    /// 잠깐 펼친 동안: 마우스가 팔레트 위에 있거나 팝오버가 떠 있으면 연장, 벗어난 지 leaveDelay 지나면 접는다
    private func startWatch() {
        guard watch == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
    }

    private func tick() {
        guard peeking else { stopWatch(); return }
        let now = Date()
        if !holds.isEmpty || containsMouse?() == true {
            openUntil = max(openUntil, now.addingTimeInterval(PaletteMetrics.leaveDelay))
        }
        guard now >= openUntil else { return }
        stopWatch()
        peeking = false
        if !pinned { didClose?() }
    }
}

// MARK: - 창

/// 팔레트 패널을 본 창 옆(고른 쪽)에 붙이고, 접힘에 맞춰 크기를 바꾼다.
@MainActor
final class PaletteController {
    private let panel: PalettePanel
    private let host: NSHostingView<AnyView>
    private let model: PaletteModel
    private let store: PlannerStore
    private let state: AppState
    private weak var parent: NSWindow?
    private var bag = Set<AnyCancellable>()
    /// 펼친 팔레트 패널 크기 (그림자 여유 포함). 방향 · 내용이 바뀌면 다시 잰다.
    private var fullSize: CGSize = .zero
    private var measuredVertical: Bool?
    /// 펼친 팔레트의 자리 (접혀 있어도 계산해 둔다)
    private var fullFrame: NSRect = .zero
    /// 패널이 손잡이 크기로 줄어 있는지 (접힌 채로 가만히 있을 때)
    private var shrunk: Bool
    private var shrinkWork: DispatchWorkItem?
    private var shadowTimer: Timer?
    private var shadowUntil = Date.distantPast
    private var edgeGeneration = 0

    init(parent: NSWindow, store: PlannerStore, state: AppState, model: PaletteModel) {
        self.parent = parent
        self.store = store
        self.state = state
        self.model = model
        host = NSHostingView(rootView: AnyView(PaletteView(model: model).environmentObject(store).environmentObject(state)))
        // 패널 크기는 여기서 정한다 (내용이 바뀌어도 창이 저절로 커지거나 줄지 않게)
        host.sizingOptions = []
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: PaletteMetrics.thickness, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // SwiftUI 뷰를 패널의 contentView 로 바로 두면, 내용 크기가 애니메이션으로 바뀔 때 SwiftUI 가 패널 크기를
        // 스스로 바꾸려 해서(updateAnimatedWindowSize) 여기서 정한 크기와 싸우다 제약 갱신이 끝없이 되풀이된다.
        // 빈 그릇 뷰 안에 꽉 채워 넣어 패널 크기는 이 컨트롤러만 정하게 한다.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: PaletteMetrics.thickness, height: 520))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        shrunk = !(model.isOpen || TourController.shared.isRunning)

        model.willOpen = { [weak self] in self?.willOpen() }
        model.didClose = { [weak self] in self?.didClose() }
        model.containsMouse = { [weak self] in self?.containsMouse() ?? false }
        // 둘러보는 동안에는 접힌 팔레트도 펼쳐 둔다 (끝나면 접힘 · 고정을 그대로 되돌린다)
        TourController.shared.$kind.map { $0 != nil }.removeDuplicates().dropFirst()
            .sink { [weak self] running in
                if running { self?.willOpen() } else { self?.didClose() }
            }
            .store(in: &bag)
        // 형광펜 개수 · 플래너 이름이 바뀌면 크기를 다시 잰다 (칠할 때마다 재지 않게 모아서)
        store.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.remeasure() }
            .store(in: &bag)
    }

    private var effectiveOpen: Bool { model.isOpen || TourController.shared.isRunning }

    func attach() {
        guard let parent, panel.parent == nil else { reposition(); return }
        parent.addChildWindow(panel, ordered: .above)
        reposition()
        if model.side != panel.side { model.side = panel.side }
        panel.orderFront(nil)
    }

    /// 펼친 팔레트의 크기를 잰다 (그림자 여유 포함, 짝수로 올려 손잡이가 반 점 어긋나지 않게)
    static func measure(_ side: PaletteEdge, store: PlannerStore, state: AppState, snapshot: Bool = false) -> CGSize {
        let v = NSHostingView(rootView: PaletteBody(side: side)
            .environment(\.isSnapshot, snapshot)
            .environmentObject(store)
            .environmentObject(state))
        let s = v.fittingSize
        func even(_ x: CGFloat) -> CGFloat { (x / 2).rounded(.up) * 2 }
        return CGSize(width: even(s.width + 2 * PaletteMetrics.margin), height: even(s.height + 2 * PaletteMetrics.margin))
    }

    /// 본 창 옆 제자리로. 창 크기를 바꾸는 도중이면 본 창 컨트롤러가 다음 차례로 미뤄서 부른다.
    func reposition() {
        guard let parent else { return }
        let edge = model.edge
        if measuredVertical != edge.isVertical || fullSize == .zero {
            fullSize = Self.measure(edge, store: store, state: state)
            measuredVertical = edge.isVertical
        }
        let vis = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        // 쪽 전환(morph) 도중에는 붙은 쪽을 그대로 둔다: state.kind 는 이미 새 쪽이라 스프링 여유가 먼저 커져서,
        // 창이 아직 움직이는 몇 프레임 동안 잠깐 모자라 반대쪽으로 튀었다 돌아오지 않게 (끝나면 다시 맞춘다)
        let locked = state.morphing && panel.parent != nil && (panel.side == edge || panel.side == edge.opposite)
        let (full, side) = PalettePlacement.place(fullSize, page: parent.frame, visible: vis,
                                                  preferred: locked ? panel.side : edge, kind: state.kind, flips: !locked)
        fullFrame = full
        panel.side = side
        let target = shrunk ? PalettePlacement.handleFrame(in: full, side: side) : full
        if panel.frame != target { panel.setFrame(target, display: true) }
        if model.side != side {
            // 팔레트 모양(손잡이 방향 · 펜 끝)은 다음 차례에 바꾼다 (창 크기를 바꾸는 도중일 수 있다)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.side == side, self.model.side != side else { return }
                self.model.side = side
            }
        }
    }

    private func remeasure() {
        guard panel.parent != nil else { return }
        let s = Self.measure(model.edge, store: store, state: state)
        guard s != fullSize else { return }
        fullSize = s
        measuredVertical = model.edge.isVertical
        reposition()
    }

    /// 설정에서 자리를 바꿨을 때: 팔레트가 살짝 사라졌다가, (본 창이 자리를 만든 뒤) 새 자리에 나타난다
    func changeEdge(makeRoom: @escaping @MainActor (_ paletteSize: CGSize, _ done: @escaping @MainActor () -> Void) -> Void) {
        edgeGeneration += 1
        let gen = edgeGeneration
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && panel.isVisible
        fade(to: 0, animated: animate) { [weak self] in
            guard let self, gen == self.edgeGeneration else { return }
            let edge = self.model.edge
            self.fullSize = Self.measure(edge, store: self.store, state: self.state)
            self.measuredVertical = edge.isVertical
            makeRoom(self.fullSize) { [weak self] in
                guard let self, gen == self.edgeGeneration else { return }
                self.reposition()
                self.model.side = self.panel.side
                self.refreshShadow()
                self.fade(to: 1, animated: animate, completion: nil)
            }
        }
    }

    private func fade(to alpha: CGFloat, animated: Bool, completion: (@MainActor () -> Void)?) {
        guard animated else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = alpha == 0 ? 0.12 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: alpha == 0 ? .easeIn : .easeOut)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            // 애니메이션 완료 알림 안에서 창을 옮기거나 모델을 바꾸지 않고 다음 차례에
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: 접기 · 펼치기

    /// 펼치기 직전: 줄여 둔 패널을 먼저 펼친 크기로 (손잡이는 같은 자리에 그대로 있다)
    private func willOpen() {
        shrinkWork?.cancel()
        shrinkWork = nil
        if shrunk {
            shrunk = false
            if fullFrame == .zero || panel.parent == nil { reposition() } else { panel.setFrame(fullFrame, display: true) }
        }
        refreshShadow()
    }

    /// 접은 뒤: 움직임이 끝나면 패널을 손잡이 크기로 줄인다 (그 사이 다시 펼치면 그대로)
    private func didClose() {
        refreshShadow()
        shrinkWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shrinkWork = nil
            guard !self.effectiveOpen, !self.shrunk else { return }
            self.shrunk = true
            self.reposition()
            self.panel.invalidateShadow()
        }
        shrinkWork = w
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.05 : 0.5), execute: w)
    }

    private func containsMouse() -> Bool {
        guard !shrunk, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    /// 창 그림자는 내용의 모양을 따라 그려지므로 접고 펼치는 동안 매 프레임 다시 그린다
    private func refreshShadow() {
        shadowUntil = Date().addingTimeInterval(0.6)
        guard shadowTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.panel.invalidateShadow()
                if Date() >= self.shadowUntil {
                    timer.invalidate()
                    self.shadowTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        shadowTimer = t
    }
}

/// 텍스트 입력(펜 이름 바꾸기)을 위해 key 가 될 수 있는 비활성화 패널
final class PalettePanel: NSPanel {
    /// 실제로 붙은 쪽 (둘러보기가 말풍선 방향을 정할 때 읽는다)
    var side: PaletteEdge = .right

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Palette UI

/// 팔레트 창의 내용: 펼친 팔레트 ↔ 손잡이. 종이 쪽 가장자리에 붙어서 바깥으로 펼쳐진다.
struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject private var tour = TourController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = model.side
        // 둘러보는 동안에는 접혀 있어도 펼쳐 둔다
        let open = model.isOpen || tour.isRunning
        let handle = PaletteMetrics.handleSize(side)
        let motion = !reduceMotion
        let radius = open ? PaletteMetrics.radius : PaletteMetrics.handleThickness / 2
        ZStack(alignment: side.dock) {
            if open {
                PaletteBody(side: side, model: model)
                    .fixedSize()
                    .transition(motion ? .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.07)),
                                                     removal: .opacity.animation(.easeIn(duration: 0.09)))
                                : .identity)
            } else {
                PaletteHandle(side: side) { model.pin() }
                    .onHover { model.hoverHandle($0) }
                    .transition(motion ? .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                                                     removal: .opacity.animation(.easeIn(duration: 0.08)))
                                : .identity)
            }
        }
        .frame(width: open ? nil : handle.width, height: open ? nil : handle.height, alignment: side.dock)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .modifier(PaletteBackground(radius: radius))
        .padding(PaletteMetrics.margin) // 그림자 여유
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.dock)
        .animation(motion ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: open)
        // 플래너 둘러보기: 도구 자리를 알려 주고, 둘러보는 동안에는 누를 수 없다
        .tourPaletteRoot()
    }
}

/// 펼친 팔레트. 옆에 두면 세로 한 줄, 위 · 아래에 두면 같은 도구를 가로 한 줄로.
/// 패널 크기를 잴 때도 쓴다 (model 없이).
struct PaletteBody: View {
    let side: PaletteEdge
    var model: PaletteModel? = nil
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var editing: Int? = nil
    @State private var editingDDay = false

    var body: some View {
        Group {
            if side.isVertical { column } else { row }
        }
        // 펜 편집 · D-day 팝오버가 떠 있는 동안에는 잠깐 펼친 팔레트를 접지 않는다
        .onChange(of: editing != nil || editingDDay) { _, on in model?.hold("popover", on) }
    }

    // MARK: 옆 (세로)

    private var column: some View {
        VStack(spacing: 12) {
            BookMenu(compact: false)
                .tourTarget(.book)

            VStack(spacing: 4) {
                kindButton(.home, "홈", "chart.bar.xaxis", "H")
                kindButton(.weekly, "주간", "rectangle.split.3x1", "W")
                kindButton(.daily, "일간", "doc.plaintext", "D")
            }

            VStack(spacing: 4) {
                arrows(height: 26)
                todayButton(height: 24)
                ddayButton(height: 24)
            }

            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 6)

            concept(columns: 3, dot: 16)

            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 6)

            VStack(spacing: 6) {
                // 둘러보기가 가리킬 수 있게 펜 묶음을 한 덩어리로 (같은 간격이라 모양은 그대로)
                VStack(spacing: 6) {
                    ForEach(store.categories) { c in pen(c) }
                }
                .tourTarget(.pens)
                eraser
                HStack(spacing: 4) {
                    textChip(compact: false)
                    mealChip(compact: false)
                }
            }

            settingsButton
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: PaletteMetrics.thickness)
        // 접기: 바깥쪽 위 모서리
        .overlay(alignment: side == .left ? .topLeading : .topTrailing) {
            if model != nil { CollapseButton(side: side) { model?.collapse() }.padding(3) }
        }
    }

    // MARK: 위 · 아래 (가로)

    private var row: some View {
        HStack(spacing: 7) {
            BookMenu(compact: true)
                .frame(width: 50)
                .tourTarget(.book)

            rowDivider

            HStack(spacing: 4) {
                kindButton(.home, "홈", "chart.bar.xaxis", "H", width: 38)
                kindButton(.weekly, "주간", "rectangle.split.3x1", "W", width: 38)
                kindButton(.daily, "일간", "doc.plaintext", "D", width: 38)
            }

            VStack(spacing: 4) {
                arrows(height: 29)
                HStack(spacing: 4) {
                    todayButton(height: 29).frame(width: 38)
                    ddayButton(height: 29)
                }
            }
            .frame(width: 98)

            rowDivider

            concept(columns: 5, dot: 15)

            rowDivider

            HStack(spacing: 1) {
                ForEach(store.categories) { c in pen(c) }
            }
            .tourTarget(.pens)
            eraser

            VStack(spacing: 4) {
                textChip(compact: true)
                mealChip(compact: true)
            }
            .frame(width: 48)

            settingsButton
                .frame(width: 30, height: 62)

            if model != nil {
                CollapseButton(side: side) { model?.collapse() }
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(height: PaletteMetrics.thickness)
    }

    private var rowDivider: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(width: 1).padding(.vertical, 10)
    }

    // MARK: 도구

    private func select(_ id: Int) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { state.tool = id }
    }

    private func kindButton(_ k: PageKind, _ title: String, _ icon: String, _ key: String, width: CGFloat? = nil) -> some View {
        let on = state.kind == k
        return Button { state.switchKind(k) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: width ?? .infinity, minHeight: width == nil ? 40 : 62)
            .frame(width: width)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color(hex: "3C3357") : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) 보기 (\(key))")
        .animation(.snappy(duration: 0.25), value: on)
        .tourTarget(k == .home ? .home : k == .weekly ? .weekly : .daily)
    }

    private func arrows(height: CGFloat) -> some View {
        HStack(spacing: 4) {
            IconButton(icon: "chevron.left", help: "이전 장 (←)", height: height) { state.flip(.backward) }
            IconButton(icon: "chevron.right", help: "다음 장 (→)", height: height) { state.flip(.forward) }
        }
        .tourTarget(.arrows)
    }

    private func todayButton(height: CGFloat) -> some View {
        Button { state.goToday() } label: {
            Text("오늘")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("오늘로 (T)")
        .tourTarget(.today)
    }

    private func ddayButton(height: CGFloat) -> some View {
        // 표지·첫 장에서는 붙일 날이 없다 (첫날이 바뀌지 않게)
        let off = state.kind == .daily && state.front != nil
        return Button { editingDDay = true } label: {
            Label("D-day", systemImage: "flag.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 일간: 보고 있는 날 · 주간/홈: 오늘
        .popover(isPresented: $editingDDay, arrowEdge: side.popoverArrowEdge) {
            DDayEditor(date: state.kind == .daily ? state.dayDate(state.dayIndex) : Dates.day(Date()))
                .environmentObject(store)
        }
        .help(state.kind == .daily ? "D-day — 보고 있는 날에 붙이기" : "D-day — 오늘에 붙이기")
        .disabled(off)
        .opacity(off ? 0.4 : 1)
        .tourTarget(.dday)
    }

    private func concept(columns: Int, dot: CGFloat) -> some View {
        // 표지·첫 장에서는 고를 날이 없다 (첫날의 컬러가 바뀌지 않게)
        let off = state.kind == .daily && state.front != nil
        return ConceptPicker(columns: columns, dot: dot)
            .disabled(off)
            .opacity(off ? 0.4 : 1)
            .tourTarget(.concept)
    }

    private func pen(_ c: Category) -> some View {
        PenRow(color: c.color, name: c.name, selected: state.tool == c.id, side: side)
            .onTapGesture(count: 2) { editing = c.id }
            .onTapGesture { select(c.id) }
            .popover(isPresented: Binding(get: { editing == c.id }, set: { if !$0 { editing = nil } }),
                     arrowEdge: side.popoverArrowEdge) {
                PenEditor(id: c.id).environmentObject(store)
            }
            // 할 일의 형광펜(분류)은 할 일 왼쪽 칸에서 고른다. 여기 펜은 타임테이블 칠하기용.
            .help("\(c.name) 형광펜 — 타임테이블 칠하기 · 클릭: 선택 · 더블클릭: 이름·색 바꾸기")
    }

    private var eraser: some View {
        EraserRow(selected: state.tool == AppState.eraser, side: side)
            .onTapGesture { select(AppState.eraser) }
            .help("지우개 (E) — 칠한 칸, 글씨, 밥시간을 지운다")
            .tourTarget(.eraser)
    }

    private func textChip(compact: Bool) -> some View {
        ToolChip(icon: "pencil.line", title: "글씨", selected: state.tool == AppState.textTool, compact: compact)
            .onTapGesture { select(AppState.textTool) }
            .help("타임테이블에 글씨 쓰기 — 칸을 누르거나 끌어서 쓰기 시작")
            .tourTarget(.text)
    }

    private func mealChip(compact: Bool) -> some View {
        ToolChip(icon: "fork.knife", title: "밥", selected: state.tool == AppState.mealTool, compact: compact)
            .onTapGesture { select(AppState.mealTool) }
            .help("밥시간 — 시작 칸부터 끝 칸까지 끌기 (누르기만 하면 1시간)")
            .tourTarget(.meal)
    }

    private var settingsButton: some View {
        Button {
            // 동기화에 손볼 것이 있으면 (오류 · 빠짐 · 복구 코드 확인) 설정 → 동기화로 바로
            if SyncIndicator.shared.gear?.attention == true {
                SettingsWindowController.shared.showSync(store: store, state: state)
            } else {
                SettingsWindowController.shared.show(store: store, state: state)
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .syncGearBadge()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .syncSettingsHelp("설정 (⌘,) — 형광펜 이름·색, 기본 컬러, D-day, 팔레트 자리")
        .tourTarget(.settings)
    }
}

/// 펼친 팔레트의 접기 화살표 (종이 쪽을 가리킨다)
private struct CollapseButton: View {
    let side: PaletteEdge
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: side.collapseSymbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.primary.opacity(hover ? 0.8 : 0.42))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("팔레트 접기 (⌘\\)")
        .accessibilityLabel("팔레트 접기")
    }
}

/// 접힌 팔레트: 종이 옆의 가느다란 손잡이. 지금 고른 도구가 보이고, 누르면 펼친 채로 고정된다.
private struct PaletteHandle: View {
    let side: PaletteEdge
    let action: () -> Void
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @State private var hover = false

    var body: some View {
        let size = PaletteMetrics.handleSize(side)
        let tool = PaletteTool(state.tool, store: store)
        let shape = RoundedRectangle(cornerRadius: PaletteMetrics.handleThickness / 2, style: .continuous)
        let stack = side.isVertical ? AnyLayout(VStackLayout(spacing: 9)) : AnyLayout(HStackLayout(spacing: 9))
        Button(action: action) {
            stack {
                ToolBadge(tool: tool)
                // 잡는 곳 (점 세 개)
                let dots = side.isVertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
                dots {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.primary.opacity(0.28)).frame(width: 3, height: 3)
                    }
                }
                Image(systemName: side.expandSymbol)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.primary.opacity(hover ? 0.8 : 0.5))
            }
            .frame(width: size.width, height: size.height)
            .background(shape.fill(.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("팔레트 펼치기 (⌘\\) — 지금 도구: \(tool.name)")
        .accessibilityLabel("팔레트 펼치기")
        .accessibilityValue("지금 도구: \(tool.name)")
    }
}

/// 손잡이에 보여 줄 지금 도구
private struct PaletteTool {
    enum Look { case pen(Color), eraser, text, meal }
    let name: String
    let look: Look

    @MainActor
    init(_ id: Int, store: PlannerStore) {
        switch id {
        case AppState.eraser: name = "지우개"; look = .eraser
        case AppState.textTool: name = "글씨"; look = .text
        case AppState.mealTool: name = "밥"; look = .meal
        default:
            let c = store.category(id)
            name = c.map { "\($0.name) 형광펜" } ?? "형광펜"
            look = .pen(c?.color ?? Color.gray)
        }
    }
}

private struct ToolBadge: View {
    let tool: PaletteTool

    var body: some View {
        switch tool.look {
        case .pen(let c):
            Circle()
                .fill(c)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 2))
                .shadow(color: c.opacity(0.7), radius: 3, y: 1)
                .frame(width: 18, height: 18)
        case .eraser: symbol("eraser.fill", Color(hex: "7FA7E0"))
        case .text: symbol("pencil.line", Color(hex: "3C3357"))
        case .meal: symbol("fork.knife", Color(hex: "3C3357"))
        }
    }

    private func symbol(_ name: String, _ fill: Color) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 18, height: 18)
            .overlay(Image(systemName: name).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white))
            .shadow(color: fill.opacity(0.5), radius: 2, y: 1)
    }
}

/// 지금 펼친 플래너(책). 눌러서 다른 권으로 바꾸거나 관리 화면을 연다.
private struct BookMenu: View {
    let compact: Bool
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let book = store.activeBook
        Group {
            // 점검용 그림(ImageRenderer)은 메뉴 단추를 그리지 못해 모양만 그린다
            if isSnapshot {
                label(book)
            } else {
                Menu {
                    ForEach(store.books) { b in
                        Button { store.activate(b.id) } label: {
                            // 예시 플래너는 이름에 "예시" 가 없을 때(이름을 바꿨을 때)만 표시를 붙인다
                            Text((b.id == book?.id ? "✓ " : "   ") + b.name
                                 + (b.isSample && !b.name.contains("예시") ? "  · 예시" : ""))
                        }
                    }
                    Divider()
                    Button("플래너 관리…") { SettingsWindowController.shared.show(store: store, state: state) }
                } label: {
                    label(book)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .help(book.map { "\($0.name) · \($0.periodText)" } ?? "플래너를 만들어 주세요")
    }

    private func label(_ book: BookInfo?) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ColorConcept.of(book?.cover ?? 0).accent)
                .frame(width: compact ? 17 : 22, height: compact ? 22 : 28)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.18)).frame(width: compact ? 2.5 : 3)
                }
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            Text(book?.name ?? "플래너 없음")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(compact ? 0.8 : 1)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 그날의 컬러 컨셉 (일간: 이 날만, 주간: 기본값). 오른쪽 클릭으로 기본값 지정.
private struct ConceptPicker: View {
    let columns: Int
    let dot: CGFloat
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        let daily = state.kind == .daily
        let date = state.dayDate(state.dayIndex)
        let dayTheme = store.day(date).theme
        let def = store.data.prefs.defaultTheme
        let current = daily ? (dayTheme ?? def) : def
        let spacing: CGFloat = 5
        VStack(spacing: 6) {
            Text(daily ? "오늘의 컬러" : "기본 컬러")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(dot), spacing: spacing), count: columns), spacing: spacing) {
                ForEach(ColorConcept.all) { c in
                    Circle()
                        .fill(c.accent)
                        .frame(width: dot, height: dot)
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
            .frame(width: CGFloat(columns) * dot + CGFloat(columns - 1) * spacing)
        }
    }
}

private struct PaletteBackground: ViewModifier {
    var radius: CGFloat = PaletteMetrics.radius
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if isSnapshot {
            // ImageRenderer 는 유리 · 머티리얼을 그리지 못한다: 비슷한 색과 그림자로
            content
                .background {
                    shape.fill(Color(hex: "F3F2EF").opacity(0.97))
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                }
                .overlay(shape.strokeBorder(.white.opacity(0.75), lineWidth: 0.6))
        } else if #available(macOS 26.0, *) {
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
    var height: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hover ? 0.12 : 0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 펜 · 지우개 그림을 종이 쪽으로 돌린다.
/// 그림은 끝이 왼쪽(종이 쪽)을 보고 누워 있다: 오른쪽 팔레트는 그대로, 왼쪽은 뒤집고, 위 · 아래는 세운다.
private struct TowardPage: ViewModifier {
    let side: PaletteEdge
    /// 누운 그림의 크기
    let size: CGSize
    /// 세웠을 때 줄이는 비율 (가로 팔레트)
    var upright: CGFloat = 0.74

    func body(content: Content) -> some View {
        switch side {
        case .right:
            content.frame(width: size.width, height: size.height)
        case .left:
            content.frame(width: size.width, height: size.height).scaleEffect(x: -1, y: 1)
        case .top, .bottom:
            content
                .frame(width: size.width, height: size.height)
                // 위 팔레트: 끝이 아래(종이)로, 아래 팔레트: 끝이 위로
                .rotationEffect(.degrees(side == .top ? -90 : 90))
                .frame(width: size.height, height: size.width)
                .scaleEffect(upright)
                .frame(width: (size.height * upright).rounded(), height: (size.width * upright).rounded())
        }
    }
}

/// 형광펜: 종이 쪽으로 납작한 심, 색 뚜껑, 흰 몸통. 고르면 종이 쪽으로 살짝 나온다.
private struct PenRow: View {
    let color: Color
    let name: String
    let selected: Bool
    let side: PaletteEdge
    @State private var hover = false

    var body: some View {
        let lift: CGFloat = selected ? 4 : hover ? 2 : 0
        let v = side.towardPage
        let pen = PenArt(color: color)
            .modifier(TowardPage(side: side, size: CGSize(width: 53, height: 16)))
            .shadow(color: selected ? color.opacity(0.9) : .black.opacity(0.18), radius: selected ? 6 : 1.5, y: 1)
            .offset(x: v.dx * lift, y: v.dy * lift)
        let label = Text(name)
            .font(.system(size: 9, weight: selected ? .bold : .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.6))
            .lineLimit(1)
            .minimumScaleFactor(side.isVertical ? 0.8 : 0.7)
        Group {
            if side.isVertical {
                VStack(spacing: 3) { pen; label }
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                // 이름은 종이에서 먼 쪽에
                VStack(spacing: 3) {
                    if side == .top { label; Spacer(minLength: 0); pen } else { pen; Spacer(minLength: 0); label }
                }
                .padding(.vertical, 1)
                .frame(width: 31, height: 62)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// 누워 있는 형광펜 그림 (53 × 16, 심이 왼쪽)
private struct PenArt: View {
    let color: Color

    var body: some View {
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
    }
}

/// 타임테이블 도구 (글씨 · 밥). compact: 가로 팔레트에서 아이콘과 이름을 한 줄로.
private struct ToolChip: View {
    let icon: String
    let title: String
    let selected: Bool
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 2))
        layout {
            Image(systemName: icon).font(.system(size: compact ? 11 : 12, weight: .semibold))
            Text(title).font(.system(size: compact ? 10 : 9, weight: selected ? .bold : .medium, design: .rounded))
        }
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
        .frame(maxWidth: .infinity, minHeight: compact ? 29 : 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color(hex: "3C3357") : Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }
}

private struct EraserRow: View {
    let selected: Bool
    let side: PaletteEdge
    @State private var hover = false

    var body: some View {
        let lift: CGFloat = selected ? 4 : hover ? 2 : 0
        let v = side.towardPage
        let art = HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: "7FA7E0"))
                .frame(width: 26, height: 18)
                .overlay(Text("ERASE").font(.system(size: 5.5, weight: .black, design: .rounded)).foregroundStyle(.white)
                    // 왼쪽 팔레트에서 그림을 뒤집어도 글자는 바로 읽히게
                    .scaleEffect(x: side == .left ? -1 : 1, y: 1))
        }
        .modifier(TowardPage(side: side, size: CGSize(width: 42, height: 18), upright: 0.8))
        .shadow(color: selected ? Color(hex: "7FA7E0").opacity(0.9) : .black.opacity(0.18), radius: selected ? 6 : 1.5, y: 1)
        .offset(x: v.dx * lift, y: v.dy * lift)
        let label = Text("지우개")
            .font(.system(size: 9, weight: selected ? .bold : .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.6))
            .lineLimit(1)
            .fixedSize()
        Group {
            if side.isVertical {
                VStack(spacing: 3) { art; label }
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                VStack(spacing: 3) {
                    if side == .top { label; Spacer(minLength: 0); art } else { art; Spacer(minLength: 0); label }
                }
                .padding(.vertical, 1)
                .frame(width: 34, height: 62)
            }
        }
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

// MARK: - 설정: 자리 고르기

/// 설정 → 팔레트: 네 자리를 그림으로 보고 고른다
struct PalettePositionPicker: View {
    @Binding var edge: PaletteEdge

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PaletteEdge.allCases) { e in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { edge = e }
                } label: {
                    PalettePositionCard(edge: e, selected: e == edge)
                }
                .buttonStyle(.plain)
                .help("팔레트를 종이 \(e.title)에 두기")
                .accessibilityLabel("팔레트를 \(e.title)에")
                .accessibilityAddTraits(e == edge ? .isSelected : [])
            }
        }
    }
}

/// 책상 위 종이 한 장과 그 옆 팔레트
private struct PalettePositionCard: View {
    let edge: PaletteEdge
    let selected: Bool
    @State private var hover = false

    private static let pens = ["F2A93B", "E7728F", "5E86D6", "3FAE8C"]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                Color(hex: "E3E1DC")
                scene
            }
            .frame(height: 96)

            HStack(spacing: 6) {
                Text(edge == .right ? "오른쪽 · 기본" : edge.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.25 : 0.12),
                                    lineWidth: selected ? 2 : 1))
        .contentShape(shape)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    private var scene: some View {
        let page = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Ink.paper)
            .frame(width: 46, height: 62)
            .overlay(alignment: .top) {
                VStack(spacing: 5) {
                    ForEach(0..<6, id: \.self) { i in
                        Rectangle().fill(Ink.rule.opacity(i == 0 ? 1 : 0.7)).frame(height: i == 0 ? 1.2 : 0.6)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.top, 10)
            }
            .overlay(alignment: .leading) {
                // 스프링
                VStack(spacing: 5) {
                    ForEach(0..<8, id: \.self) { _ in
                        Capsule().fill(Color(hex: "8E9198")).frame(width: 6, height: 1.6)
                    }
                }
                .offset(x: -3)
            }
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
        let vertical = edge.isVertical
        let bar = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(.white.opacity(0.96))
            .frame(width: vertical ? 11 : 50, height: vertical ? 50 : 11)
            .overlay {
                let dots = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
                dots {
                    ForEach(Self.pens, id: \.self) { h in
                        Circle().fill(Color(hex: h)).frame(width: 5, height: 5)
                    }
                }
            }
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            .scaleEffect(selected ? 1 : 0.94)
        return Group {
            switch edge {
            case .right: HStack(spacing: 7) { page; bar }
            case .left: HStack(spacing: 10) { bar; page }
            case .top: VStack(spacing: 7) { bar; page }
            case .bottom: VStack(spacing: 7) { page; bar }
            }
        }
    }
}

// MARK: - QA (--palette-test)

/// `Spiralday --palette-test <dir>`: 팔레트를 종이 옆에 붙인 모습을 PNG 로 (메모리의 예시 데이터로만).
///   <자리>_<쪽>_open.png            네 자리 × 일간 · 주간, 펼친 팔레트 (스프링 · 틈 · 가운데 맞춤 확인)
///   <자리>_<쪽>_closed-<도구>.png    접힌 손잡이: 펜 · 지우개 · 글씨 · 밥
///   picker.png                      설정 → 팔레트의 자리 고르기
@MainActor
enum PaletteTest {
    static func run(to dir: URL, store: PlannerStore) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pen = store.categories.first?.id ?? 0
        var count = 0
        func save(_ img: CGImage?, _ name: String) {
            guard let img else { print("✗ \(name) 을 그리지 못했어요"); return }
            Snapshotter.write(img, dir.appendingPathComponent(name))
            print("  \(name)  \(img.width / 2) × \(img.height / 2)")
            count += 1
        }
        for edge in PaletteEdge.allCases {
            // 스프링 쪽과 겹치는 조합을 기본으로 (왼쪽 · 일간, 위 · 주간)
            let main: PageKind = edge.isVertical ? .daily : .weekly
            let other: PageKind = main == .daily ? .weekly : .daily
            for kind in [main, other] {
                save(scene(edge: edge, kind: kind, open: true, tool: pen, store: store), "\(edge.rawValue)_\(kind.rawValue)_open.png")
            }
            for (name, tool) in [("pen", pen), ("eraser", AppState.eraser), ("text", AppState.textTool), ("meal", AppState.mealTool)] {
                save(scene(edge: edge, kind: main, open: false, tool: tool, store: store),
                     "\(edge.rawValue)_\(main.rawValue)_closed-\(name).png")
            }
        }
        for sel in [PaletteEdge.right, .top] {
            let picker = PalettePositionPicker(edge: .constant(sel))
                .frame(width: 540)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            let r = ImageRenderer(content: picker)
            r.scale = 2
            save(r.cgImage, "picker_\(sel.rawValue).png")
        }
        print("✓ \(count)장 → \(dir.path)")
        return 0
    }

    /// 종이(보통 크기) + 스프링 + 팔레트 패널을 실제 창과 같은 자리 계산으로 한 장에
    static func scene(edge: PaletteEdge, kind: PageKind, open: Bool, tool: Int, store: PlannerStore) -> CGImage? {
        let state = AppState(kind: kind)
        state.store = store
        state.tool = tool
        let pageSize = kind == .daily ? CGSize(width: 560, height: 877) : CGSize(width: 1270, height: 811)
        guard let page = PageSnapshotter(store: store, state: state).image(kind: kind, index: state.index, size: pageSize, scale: 2)
        else { return nil }
        let model = PaletteModel(testEdge: edge, open: open)
        let full = PaletteController.measure(edge, store: store, state: state, snapshot: true)
        // 화면 좌표(아래가 0)에서 자리를 잡는다. 화면은 넉넉하게 (뒤집히지 않게)
        let pageRect = NSRect(origin: .zero, size: pageSize)
        let placed = PalettePlacement.place(full, page: pageRect, visible: pageRect.insetBy(dx: -4000, dy: -4000),
                                            preferred: edge, kind: kind)
        model.side = placed.side
        let pal = open ? placed.frame : PalettePlacement.handleFrame(in: placed.frame, side: placed.side)
        // 스프링 (RingWindowController.update 와 같게)
        let u = pageSize.width / kind.design.width
        let out = (RingWindowController.outside * u).rounded(.up)
        let ins = (RingWindowController.inside * u).rounded(.up)
        let ring = kind.edge == .leading
            ? NSRect(x: -out, y: 0, width: out + ins, height: pageSize.height)
            : NSRect(x: 0, y: pageSize.height - ins, width: pageSize.width, height: out + ins)
        let rings = RingModel()
        rings.kind = kind
        rings.u = u
        rings.outside = out
        let bounds = pageRect.union(placed.frame).union(ring).insetBy(dx: -28, dy: -28)
        func origin(_ r: NSRect) -> CGSize { CGSize(width: r.minX - bounds.minX, height: bounds.maxY - r.maxY) }
        let content = ZStack(alignment: .topLeading) {
            Color(white: 0.85)
            Image(decorative: page, scale: 2)
                .resizable()
                .frame(width: pageSize.width, height: pageSize.height)
                .offset(origin(pageRect))
            RingStrip(model: rings)
                .frame(width: ring.width, height: ring.height)
                .offset(origin(ring))
            PaletteView(model: model)
                .frame(width: pal.width, height: pal.height)
                .offset(origin(pal))
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .environment(\.isSnapshot, true)
        .environment(\.colorScheme, .light)
        .environmentObject(store)
        .environmentObject(state)
        let r = ImageRenderer(content: content)
        r.scale = 2
        return r.cgImage
    }
}
