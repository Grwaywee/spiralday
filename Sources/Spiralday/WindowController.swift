import AppKit
import SwiftUI
import Combine
import SpiraldayKit

/// 창 = 종이 한 장.
/// - 제목 막대는 투명, 빨강/노랑/초록 버튼이 종이 왼쪽 위에 그대로 올라간다.
/// - 창 비율은 페이지 비율로 고정 (일간 1277:2000, 주간 2000:1277).
/// - 주간 ↔ 일간 전환 시 창이 새 비율로 부드럽게 변한다.
/// - 도구 팔레트는 창 옆(설정에서 고른 쪽)에 떠 있는 별도 패널 (창과 함께 움직인다).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let store: PlannerStore
    private let state: AppState
    private let snapshotter: PageSnapshotter
    private var palette: PaletteController?
    private var rings: RingWindowController?
    /// 넘김 스냅숏에 종이 위 고리 앞 가닥을 굽는다 (넘어가는 종이가 고리를 덮게)
    private let ringBaker = RingSnapshotBaker()
    private var bag = Set<AnyCancellable>()

    static let paletteGap: CGFloat = 14
    static let paletteWidth: CGFloat = PaletteMetrics.thickness
    /// 창 크기를 바꾸는 도중에 팔레트 · 스프링을 맞추도록 걸어 둔 것이 있는지
    private var childLayoutScheduled = false

    init(store: PlannerStore, state: AppState) {
        self.store = store
        self.state = state
        snapshotter = PageSnapshotter(store: store, state: state)

        let kind = state.kind
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize(kind, screen: NSScreen.main)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        window.titlebarAppearsTransparent = true
        // 날짜는 종이 위에 직접 쓰므로 창 제목은 숨긴다 (창 목록/미션 컨트롤용으로만 쓴다)
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .aqua)   // 종이는 늘 밝다
        window.backgroundColor = NSColor(Ink.paper)
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        applyConstraints(kind)

        let host = NSHostingView(rootView: RootView().environmentObject(store).environmentObject(state))
        host.sizingOptions = []
        window.contentView = host

        if let saved = Self.savedContentSize(kind) { window.setContentSize(saved) }
        window.center()
        // 팔레트가 고른 쪽에도 반대쪽에도 들어가지 않으면 (위 · 아래에 두었는데 창이 높을 때 등) 창을 옮기고 줄인다
        if let vis = (window.screen ?? NSScreen.main)?.visibleFrame, !Self.paletteHasRoom(window.frame, kind: kind, visible: vis) {
            window.setFrame(Self.fit(window.frame, kind: kind, edge: PaletteModel.shared.edge, visible: vis), display: false)
        }

        // 이 창(과 팔레트)의 키 · 스크롤만 플래너가 받는다 — PDF 내보내기 · 설정 · 업데이트 창 · 팝오버의 것은 그 창으로
        state.plannerWindow = window
        state.isPlannerPanel = { $0 is PalettePanel }
        wire()
        updateTitle()
        palette = PaletteController(parent: window, store: store, state: state, model: .shared)
        // 종이 밖 고리만 자식 창에 (종이 위 앞 가닥은 RootView 의 넘김 오버레이 아래와 넘김 스냅숏에)
        rings = RingWindowController(parent: window, part: .outsidePaper)
    }

    /// 자식 창에 그리는 고리 부분 (시험용)
    var ringPart: RingPart? { rings?.part }

    func show() {
        window.makeKeyAndOrderFront(nil)
        palette?.attach()
        rings?.attach(state.kind)
        state.curl.backingScale = window.backingScaleFactor
        snapshotter.schedulePrewarm(delay: 0.8)
    }

    // MARK: wiring

    private func wire() {
        state.kindTransition = { [weak self] k, apply in self?.morph(to: k, apply: apply) }
        state.onPageChange = { [weak self] in
            self?.updateTitle()
            self?.snapshotter.schedulePrewarm()
        }
        state.curl.snapshot = { [weak self] delta in
            // 책의 첫 장 / 마지막 장 너머로는 넘길 수 없다 (마우스 드래그·스와이프·모서리 들기도 막힌다)
            guard let self, self.state.canStep(delta) else { return nil }
            let size = self.state.curl.pageSize
            let scale = self.window.backingScaleFactor
            let kind = self.state.kind
            guard let cur = self.snapshotter.image(kind: kind, index: self.state.index, size: size, scale: scale),
                  let nb = self.snapshotter.image(kind: kind, index: self.state.index + delta, size: size, scale: scale)
            else { return nil }
            // 종이 위 고리 앞 가닥을 두 장 모두에 굽는다: 평평한 곳에서는 고리가 그대로 보이고, 들린 종이(뒷면)는 그 위에 그려진다
            return PageBitmaps(current: self.ringBaker.bake(cur, kind: kind, size: size, scale: scale),
                               neighbor: self.ringBaker.bake(nb, kind: kind, size: size, scale: scale))
        }
        // 둘러보기의 어두운 막이 보이는 동안 종이 밖 고리도 덮는다 (TourLiveStage 의 visible 과 같은 조건)
        Publishers.CombineLatest4(TourController.shared.$kind.map { $0 != nil }, TourController.shared.$arrived,
                                  state.curl.$isActive, state.$morphing)
            .map { running, arrived, turning, morphing in running && arrived && !turning && !morphing }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dim in self?.rings?.setDimmed(dim) }
            .store(in: &bag)
        store.objectWillChange
            .sink { [weak self] _ in self?.snapshotter.schedulePrewarm(delay: 0.6) }
            .store(in: &bag)
        // 도구 단축키(1–7 · E): 팔레트가 접혀 있으면 잠깐 펼쳐 보여 준다
        state.onToolShortcut = { PaletteModel.shared.flash() }
        // 설정에서 팔레트 자리를 바꾸면 바로 옮긴다 (그 쪽에 자리가 없으면 창을 옮겨 자리를 만든다)
        PaletteModel.shared.$edge
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.palette?.changeEdge { [weak self] size, done in
                    guard let self else { done(); return }
                    self.makeRoomForPalette(size, done: done)
                }
            }
            .store(in: &bag)
        // 디스플레이 배치 · 해상도가 바뀌면 팔레트 · 스프링을 다시 맞춘다
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleChildLayout() }
            .store(in: &bag)
    }

    private func updateTitle() {
        let book = store.activeBook.map { "\($0.name) — " } ?? ""
        defer { window.title = book + window.title }
        // 책 맨 앞의 표지 · 첫 장
        if let front = state.front {
            window.title = front.title
            return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch state.kind {
        case .daily:
            f.dateFormat = "yyyy년 M월 d일 EEEE"
            window.title = f.string(from: state.dayDate(state.dayIndex))
        case .home:
            window.title = "Spiralday — 홈"
        case .weekly:
            let s = state.weekStart(state.weekIndex)
            let e = Dates.add(days: 6, to: s)
            let a = Dates.comp(s), b = Dates.comp(e)
            let range = a.month == b.month ? "\(a.month!)월 \(a.day!)일 – \(b.day!)일" : "\(a.month!)월 \(a.day!)일 – \(b.month!)월 \(b.day!)일"
            window.title = "\(String(a.year!))년 \(range) · \(a.weekOfYear!)주차"
        }
    }

    // MARK: sizing

    private func applyConstraints(_ kind: PageKind) {
        window.contentAspectRatio = kind.design
        window.contentMinSize = kind == .daily ? NSSize(width: 358, height: 560) : NSSize(width: 860, height: 549)
    }

    static func defaultContentSize(_ kind: PageKind, screen: NSScreen?) -> NSSize {
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let edge = PaletteModel.shared.edge
        // 팔레트 자리: 옆이면 가로에서, 위 · 아래면 세로에서 뺀다 (스프링 쪽이면 스프링만큼 더)
        let ring = edge == .ringSide(kind) ? ringAllowance(kind) : 0
        let hRoom = edge.isVertical ? paletteGap + paletteWidth + 40 + ring : 0
        let vRoom = edge.isVertical ? 0 : paletteGap + paletteWidth + 20 + ring
        switch kind {
        case .daily:
            var h = min(vis.height * 0.9, 1180, vis.height - vRoom)
            var w = h * kind.aspect
            if w > vis.width - hRoom { w = vis.width - hRoom; h = w / kind.aspect }
            return NSSize(width: w.rounded(), height: h.rounded())
        case .weekly, .home:
            var w = min((vis.width - hRoom) * 0.92, 1760)
            var h = w / kind.aspect
            let maxH = min(vis.height * 0.9, vis.height - vRoom)
            if h > maxH { h = maxH; w = h * kind.aspect }
            return NSSize(width: w.rounded(), height: h.rounded())
        }
    }

    /// 스프링이 종이 밖으로 나오는 폭의 넉넉한 어림 (가장 큰 창 기준: 일간 ≈ 23, 주간 · 홈 ≈ 34)
    private static func ringAllowance(_ kind: PageKind) -> CGFloat {
        let maxWidth: CGFloat = kind == .daily ? 1180 * kind.aspect : 1760
        return (RingWindowController.outside * maxWidth / kind.design.width).rounded(.up)
    }

    // MARK: palette room

    /// 창 밖에 팔레트를 붙이는 데 드는 폭: 틈 + 팔레트 + 여유 (+ 그 쪽에 스프링이 있으면 스프링)
    static func paletteRoom(_ edge: PaletteEdge, kind: PageKind, pageWidth: CGFloat) -> CGFloat {
        paletteGap + paletteWidth + 20 + PalettePlacement.ringClearance(edge, kind: kind, pageWidth: pageWidth)
    }

    /// 창을 둘 수 있는 곳 = 화면 − 팔레트 쪽 자리 (팔레트가 없는 가로 가장자리는 8 띄운다)
    static func windowArea(_ vis: NSRect, edge: PaletteEdge, kind: PageKind, pageWidth: CGFloat) -> NSRect {
        let room = paletteRoom(edge, kind: kind, pageWidth: pageWidth)
        var minX = vis.minX + 8, maxX = vis.maxX, minY = vis.minY, maxY = vis.maxY
        switch edge {
        case .right: maxX = vis.maxX - room
        case .left: minX = vis.minX + room; maxX = vis.maxX - 8
        case .top: maxY = vis.maxY - room; maxX = vis.maxX - 8
        case .bottom: minY = vis.minY + room; maxX = vis.maxX - 8
        }
        return NSRect(x: minX, y: minY, width: max(maxX - minX, 100), height: max(maxY - minY, 100))
    }

    /// 창을 팔레트 자리까지 화면에 들어가게: 팔레트 쪽 자리를 뺀 곳 안으로 옮기고, 그래도 크면 비율을 지키며 줄인다
    static func fit(_ frame: NSRect, kind: PageKind, edge: PaletteEdge, visible vis: NSRect) -> NSRect {
        var f = frame
        var area = windowArea(vis, edge: edge, kind: kind, pageWidth: f.width)
        if f.width > area.width + 0.5 || f.height > area.height + 0.5 {
            let aspect = f.width / max(f.height, 1)
            let s = min(area.width / f.width, area.height / f.height)
            let w = max((f.width * s).rounded(.down), kind == .daily ? 358 : 860)
            let h = (w / aspect).rounded()
            f = NSRect(x: (f.midX - w / 2).rounded(), y: f.maxY - h, width: w, height: h)
            area = windowArea(vis, edge: edge, kind: kind, pageWidth: w)
        }
        if f.maxX > area.maxX { f.origin.x = area.maxX - f.width }
        if f.minX < area.minX { f.origin.x = area.minX }
        if f.maxY > area.maxY { f.origin.y = area.maxY - f.height }
        if f.minY < area.minY { f.origin.y = area.minY }
        return f
    }

    /// 팔레트가 고른 쪽이나 그 반대쪽에 화면 밖으로 나가지 않고 붙을 수 있는지
    private static func paletteHasRoom(_ frame: NSRect, kind: PageKind, visible vis: NSRect) -> Bool {
        let edge = PaletteModel.shared.edge
        let t = paletteWidth + 2 * PaletteMetrics.margin
        let size = CGSize(width: t, height: t)
        return [edge, edge.opposite].contains { PalettePlacement.fits(PalettePlacement.frame(size, on: $0, of: frame, kind: kind), on: $0, in: vis) }
    }

    private static func savedContentSize(_ kind: PageKind) -> NSSize? {
        guard let s = UserDefaults.standard.string(forKey: "contentSize.\(kind.rawValue)") else { return nil }
        let v = NSSizeFromString(s)
        return v.width > 100 ? NSSize(width: v.width, height: (v.width / kind.aspect).rounded()) : nil
    }

    private func saveContentSize() {
        guard !state.morphing else { return }
        let s = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(s), forKey: "contentSize.\(state.kind.rawValue)")
    }

    /// 창 비율 전환: 내용을 살짝 감추고 → 창 모양을 바꾸고 → 새 페이지를 보여준다.
    private func morph(to kind: PageKind, apply: @escaping () -> Void) {
        let screen = window.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? window.frame
        let content = Self.savedContentSize(kind) ?? Self.defaultContentSize(kind, screen: screen)
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        let old = window.frame
        target.origin.x = old.midX - target.width / 2
        target.origin.y = old.maxY - target.height        // 윗변 고정
        // 화면 안에 (팔레트 자리까지) 들어오게. 모자라면 비율을 지키며 줄인다
        target = Self.fit(target, kind: kind, edge: PaletteModel.shared.edge, visible: vis)

        withAnimation(.easeIn(duration: 0.14)) { state.morphing = true }
        rings?.setVisible(false, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [self] in
            apply()
            store.editPrefs { $0.lastKind = kind }
            window.contentAspectRatio = NSSize(width: 0, height: 0)
            window.contentMinSize = NSSize(width: 300, height: 300)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.46
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.15, 1.0)
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(target, display: true)
            } completionHandler: { [self] in
                MainActor.assumeIsolated {
                    applyConstraints(kind)
                    palette?.reposition()
                    rings?.update(kind)
                    rings?.setVisible(true, animated: true)
                    withAnimation(.easeOut(duration: 0.24)) { state.morphing = false }
                    // 도중에는 팔레트가 붙은 쪽을 고정해 두었으니 끝난 뒤 (다음 차례에) 제자리를 다시 고른다
                    scheduleChildLayout()
                    snapshotter.schedulePrewarm(delay: 0.5)
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    /// 초록 버튼(확대): 페이지 비율을 지키면서 화면에 들어가는 가장 큰 크기 (팔레트 자리 제외)
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let edge = PaletteModel.shared.edge
        let kind = state.kind
        let aspect = kind.aspect
        func frame(ring pageWidth: CGFloat) -> NSRect {
            var avail = defaultFrame
            let room = Self.paletteRoom(edge, kind: kind, pageWidth: pageWidth)
            switch edge {
            case .right: avail.size.width -= room
            case .left: avail.origin.x += room; avail.size.width -= room
            case .top: avail.size.height -= room
            case .bottom: avail.origin.y += room; avail.size.height -= room
            }
            var size = NSSize(width: avail.width, height: avail.width / aspect)
            if size.height > avail.height { size = NSSize(width: avail.height * aspect, height: avail.height) }
            return NSRect(x: avail.minX + (avail.width - size.width) / 2, y: avail.maxY - size.height,
                          width: size.width.rounded(), height: size.height.rounded())
        }
        // 스프링 쪽이면 스프링 폭이 창 크기를 따라가므로 한 번 더 맞춘다
        let first = frame(ring: 0)
        return edge == .ringSide(kind) ? frame(ring: first.width) : first
    }

    /// 설정에서 팔레트 자리를 바꿨을 때: 그 쪽에 자리가 없으면 창을 옮겨 (모자라면 줄여) 자리를 만든다
    private func makeRoomForPalette(_ paletteSize: CGSize, done: @escaping @MainActor () -> Void, tries: Int = 0) {
        // 쪽을 바꾸는 중이면 끝난 뒤에
        guard !state.morphing else {
            guard tries < 40 else { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { done(); return }
                self.makeRoomForPalette(paletteSize, done: done, tries: tries + 1)
            }
            return
        }
        let edge = PaletteModel.shared.edge
        let kind = state.kind
        let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let old = window.frame
        let want = PalettePlacement.frame(paletteSize, on: edge, of: old, kind: kind)
        guard !PalettePlacement.fits(want, on: edge, in: vis) else { done(); return }
        let target = Self.fit(old, kind: kind, edge: edge, visible: vis)
        guard target != old else { done(); return }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { done(); return }
            self.state.frameBusy = false
            self.rings?.update(self.state.kind)
            // 바꾼 크기를 기억한다 (점검 실행에서는 적지 않는다)
            if target.size != old.size, PaletteModel.shared.persists { self.saveContentSize() }
            self.snapshotter.schedulePrewarm(delay: 0.3)
            done()
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(target, display: true)
            finish()
            return
        }
        // 쪽 전환(morph)과 창 애니메이션이 겹치면 AppKit 이 제약 갱신을 끝없이 되풀이하다 멈춘다: 끝날 때까지 쪽을 바꾸지 않는다
        state.frameBusy = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.15, 1.0)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        } completionHandler: {
            // 애니메이션 완료 알림 안에서 창을 더 건드리지 않고 다음 차례에
            DispatchQueue.main.async { finish() }
        }
    }

    func windowDidResize(_ notification: Notification) {
        // setFrame 안에서는 다른 창을 옮기거나 SwiftUI 모델을 바꾸지 않고 다음 차례에 한 번에 맞춘다
        scheduleChildLayout()
    }

    /// 팔레트 · 스프링을 본 창에 맞춘다 (여러 번 불려도 다음 차례에 한 번만)
    private func scheduleChildLayout() {
        guard !childLayoutScheduled else { return }
        childLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.childLayoutScheduled = false
            self.palette?.reposition()
            if !self.state.morphing { self.rings?.update(self.state.kind) }
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        saveContentSize()
        snapshotter.schedulePrewarm(delay: 0.3)
    }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        state.curl.backingScale = window.backingScaleFactor
    }
    func windowDidChangeScreen(_ notification: Notification) { scheduleChildLayout() }
    func windowWillClose(_ notification: Notification) {
        store.saveNow()
        NSApp.terminate(nil)
    }
}
