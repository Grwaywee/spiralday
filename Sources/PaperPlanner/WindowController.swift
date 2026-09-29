import AppKit
import SwiftUI
import Combine

/// 창 = 종이 한 장.
/// - 제목 막대는 투명, 빨강/노랑/초록 버튼이 종이 왼쪽 위에 그대로 올라간다.
/// - 창 비율은 페이지 비율로 고정 (일간 1277:2000, 주간 2000:1277).
/// - 주간 ↔ 일간 전환 시 창이 새 비율로 부드럽게 변한다.
/// - 도구 팔레트는 창 오른쪽 옆에 떠 있는 별도 패널 (창과 함께 움직인다).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let store: PlannerStore
    private let state: AppState
    private let snapshotter: PageSnapshotter
    private var palette: PaletteController?
    private var rings: RingWindowController?
    private var bag = Set<AnyCancellable>()

    static let paletteGap: CGFloat = 14
    static let paletteWidth: CGFloat = 78

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

        wire()
        updateTitle()
        palette = PaletteController(parent: window, store: store, state: state)
        rings = RingWindowController(parent: window)
    }

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
            guard let self else { return nil }
            let size = self.state.curl.pageSize
            let scale = self.window.backingScaleFactor
            guard let cur = self.snapshotter.image(kind: self.state.kind, index: self.state.index, size: size, scale: scale),
                  let nb = self.snapshotter.image(kind: self.state.kind, index: self.state.index + delta, size: size, scale: scale)
            else { return nil }
            return PageBitmaps(current: cur, neighbor: nb)
        }
        store.objectWillChange
            .sink { [weak self] _ in self?.snapshotter.schedulePrewarm(delay: 0.6) }
            .store(in: &bag)
    }

    private func updateTitle() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch state.kind {
        case .daily:
            f.dateFormat = "yyyy년 M월 d일 EEEE"
            window.title = f.string(from: state.dayDate(state.dayIndex))
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
        switch kind {
        case .daily:
            let h = min(vis.height * 0.9, 1180)
            return NSSize(width: (h * kind.aspect).rounded(), height: h.rounded())
        case .weekly:
            var w = min((vis.width - paletteGap - paletteWidth - 40) * 0.92, 1760)
            var h = w / kind.aspect
            if h > vis.height * 0.9 { h = vis.height * 0.9; w = h * kind.aspect }
            return NSSize(width: w.rounded(), height: h.rounded())
        }
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
        // 화면 안에 (오른쪽 팔레트 자리까지) 들어오게
        let rightLimit = vis.maxX - Self.paletteGap - Self.paletteWidth - 20
        if target.maxX > rightLimit { target.origin.x = rightLimit - target.width }
        if target.minX < vis.minX + 8 { target.origin.x = vis.minX + 8 }
        if target.minY < vis.minY { target.origin.y = vis.minY }
        if target.maxY > vis.maxY { target.origin.y = vis.maxY - target.height }

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
                    snapshotter.schedulePrewarm(delay: 0.5)
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    /// 초록 버튼(확대): 페이지 비율을 지키면서 화면에 들어가는 가장 큰 크기 (팔레트 자리 제외)
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        var avail = defaultFrame
        avail.size.width -= Self.paletteGap + Self.paletteWidth + 20
        let aspect = state.kind.aspect
        var size = NSSize(width: avail.width, height: avail.width / aspect)
        if size.height > avail.height { size = NSSize(width: avail.height * aspect, height: avail.height) }
        return NSRect(x: avail.minX + (avail.width - size.width) / 2, y: avail.maxY - size.height,
                      width: size.width.rounded(), height: size.height.rounded())
    }

    func windowDidResize(_ notification: Notification) {
        palette?.reposition()
        if !state.morphing { rings?.update(state.kind) }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        saveContentSize()
        snapshotter.schedulePrewarm(delay: 0.3)
    }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        state.curl.backingScale = window.backingScaleFactor
    }
    func windowDidChangeScreen(_ notification: Notification) { palette?.reposition() }
    func windowWillClose(_ notification: Notification) {
        store.saveNow()
        NSApp.terminate(nil)
    }
}
