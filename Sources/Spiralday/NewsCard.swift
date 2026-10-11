import AppKit
import Combine
import SwiftUI
import SpiraldayKit

// ─────────────────────────────────────────────────────────────────────────────
// 소식 카드 (Docs/InAppNews.md §1.1) — 종이 위에 그리지 않는다: 플래너 창 옆 여백에 붙는 작은 카드 (팔레트처럼 본 창의 child window).
//   · 자리: 팔레트의 반대쪽 → 아래 → 위 → 팔레트 너머 순서로, 화면 안에 들어가고 팔레트와 겹치지 않는 첫 자리.
//     스프링이 튀어나온 쪽이면 그만큼 더 띄운다. 어디에도 자리가 없으면(창이 화면을 꽉 채울 때) 종이 아래 가운데에 겹친다
//   · 닫기: [확인] · Return · Esc · 카드 밖 누르기 · [자세히 보기](시스템 브라우저로 열고 닫는다). 띄우는 순간 본 것이라 다시 뜨지 않는다
//   · 소리 · 진동 없음, 움직임은 살짝 나타나기뿐 (동작 줄이기면 그것도 없음). 글은 Text(verbatim:) — HTML · 마크다운을 해석하지 않는다
//   · VoiceOver: 카드가 열쇠 창이 되고 ‘소식: 제목’을 알린다
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - 자리 (화면 좌표, 아래가 0)

@MainActor
enum NewsCardPlacement {
    /// 카드 너비 (패널은 양쪽에 margin 을 더한다)
    static let width: CGFloat = 320
    /// 패널 가장자리의 그림자 여유 (그림자는 창이 아니라 카드가 그린다 — 열쇠 창의 창 그림자는 패널 네모 전체를 옅게 덮는다)
    static let margin: CGFloat = 20
    /// 종이 · 팔레트와 카드 사이
    /// 종이 · 팔레트와 카드 패널 사이 (카드 유리까지는 팔레트 유리와 같은 거리)
    static let gap: CGFloat = MainWindowController.paletteGap + PaletteMetrics.margin - margin
    /// 화면 가장자리에서
    static let screenInset: CGFloat = 8
    /// 옆에 둘 때 종이 위끝에서 내려오는 만큼
    static let topInset: CGFloat = 36

    enum Spot: Equatable { case side(PaletteEdge), overPaper }

    /// 카드 자리와 그 자리의 종류
    static func place(_ size: CGSize, page: NSRect, palette: NSRect?, paletteSide: PaletteEdge?, kind: PageKind,
                      visible vis: NSRect) -> (frame: NSRect, spot: Spot) {
        let room = vis.insetBy(dx: screenInset, dy: screenInset)
        for side in order(paletteSide) {
            let r = candidate(size, on: side, page: page, palette: palette, paletteSide: paletteSide, kind: kind)
            if room.contains(r), !(palette.map { r.intersects($0) } ?? false) { return (rounded(r), .side(side)) }
        }
        // 어디에도 자리가 없다: 종이 아래 가운데 (일간 · 주간 모두 가장 덜 쓰는 곳), 화면 안으로
        var r = NSRect(x: page.midX - size.width / 2, y: page.minY + 24, width: size.width, height: size.height)
        r.origin.x = min(max(r.minX, room.minX), room.maxX - r.width)
        r.origin.y = min(max(r.minY, room.minY), room.maxY - r.height)
        return (rounded(r), .overPaper)
    }

    /// 볼 차례: 팔레트의 반대쪽, 아래, 위, 팔레트 쪽 (팔레트 너머). 팔레트가 없으면 오른쪽 · 왼쪽 · 아래 · 위
    static func order(_ paletteSide: PaletteEdge?) -> [PaletteEdge] {
        guard let p = paletteSide else { return [.right, .left, .bottom, .top] }
        var out: [PaletteEdge] = [p.opposite]
        for s in [PaletteEdge.bottom, .top, .right, .left] where !out.contains(s) && s != p { out.append(s) }
        out.append(p)
        return out
    }

    static func candidate(_ size: CGSize, on side: PaletteEdge, page: NSRect, palette: NSRect?, paletteSide: PaletteEdge?,
                          kind: PageKind) -> NSRect {
        let ring = PalettePlacement.ringClearance(side, kind: kind, pageWidth: page.width)
        let w = size.width, h = size.height
        // 팔레트 쪽이면 팔레트 너머에
        let beyond = side == paletteSide ? palette : nil
        let top = page.maxY - topInset - h
        switch side {
        case .right:
            return NSRect(x: max(page.maxX + ring, beyond?.maxX ?? -.infinity) + gap, y: top, width: w, height: h)
        case .left:
            return NSRect(x: min(page.minX - ring, beyond?.minX ?? .infinity) - gap - w, y: top, width: w, height: h)
        case .bottom:
            return NSRect(x: page.maxX - w, y: min(page.minY - ring, beyond?.minY ?? .infinity) - gap - h, width: w, height: h)
        case .top:
            return NSRect(x: page.maxX - w, y: max(page.maxY + ring, beyond?.maxY ?? -.infinity) + gap, width: w, height: h)
        }
    }

    private static func rounded(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width, height: r.height)
    }
}

// MARK: - 창

/// 카드 패널: 열쇠 창이 될 수 있고 (Return · Esc · VoiceOver), 앱을 활성화하지 않는다
final class NewsCardPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 플래너 창 옆에 카드를 띄우고 닫는다 (하나뿐)
@MainActor
final class NewsCardController: NewsCardHost {
    static let shared = NewsCardController()

    private weak var planner: NSWindow?
    private weak var state: AppState?
    private weak var sync: SyncController?
    private var panel: NewsCardPanel?
    private var host: NSHostingView<AnyView>?
    private var content: NewsCardContent?
    private var mouseMonitor: Any?
    private var bag = Set<AnyCancellable>()

    var isShowing: Bool { panel != nil }
    /// 지금 띄운 카드 · 그 창 (시험용)
    var shown: NewsCardContent? { content }
    var panelForTests: NewsCardPanel? { panel }

    /// 본 창이 열리면 (AppDelegate.openPlanner)
    func attach(planner: NSWindow, state: AppState, sync: SyncController?) {
        self.planner = planner
        self.state = state
        self.sync = sync
        bag.removeAll()
        let nc = NotificationCenter.default
        // 창 크기 · 화면이 바뀌면 다시 자리 잡고, 창을 닫으면 카드도 닫는다
        nc.publisher(for: NSWindow.didResizeNotification, object: planner)
            .merge(with: nc.publisher(for: NSWindow.didChangeScreenNotification, object: planner))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
            .store(in: &bag)
        nc.publisher(for: NSWindow.willCloseNotification, object: planner)
            .merge(with: nc.publisher(for: NSWindow.willMiniaturizeNotification, object: planner))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
            .store(in: &bag)
        // 팔레트가 다른 쪽으로 옮기면 (설정 › 팔레트 · 화면에 자리가 없어 반대쪽으로) 카드도 다시 자리 잡는다
        PaletteModel.shared.$side.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)
        // 둘러보기가 시작되면 비켜 준다
        TourController.shared.$kind.map { $0 != nil }.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.dismiss() }
            .store(in: &bag)
    }

    // MARK: NewsCardHost

    var onboardingVisible: Bool {
        NSApp.windows.contains { $0.identifier == OnboardingController.windowIdentifier && $0.isVisible }
    }

    func canPresentCard() -> Bool {
        let why = blocker()
        // 바꿔 끼운 실행(QA)에서는 왜 건너뛰었는지 적는다
        if let why, !NewsCenter.shared.launch.persists, NewsCenter.shared.launch.opens {
            print("소식: 이번 카드 차례는 건너뛰어요 — \(why)")
            fflush(stdout)
        }
        return why == nil
    }

    /// QA 스크린샷: 바꿔 끼운 실행(출시 서명이 없는 빌드 · 메모리에만)에 `--news-card-anyway` 를 주면 앱이 앞에 있지 않아도 카드를 띄운다
    /// (시스템 대화상자가 앞을 차지해 QA 앱이 활성이 되지 못할 때). 출시 앱 · 보통 실행에서는 이 길이 없다
    static let qaFlag = "--news-card-anyway"
    private var qaIgnoresFocus: Bool {
        let l = NewsCenter.shared.launch
        return !l.persists && l.opens && l.source != .none && CommandLine.arguments.contains(Self.qaFlag)
    }

    private func blocker() -> String? {
        guard panel == nil else { return "카드가 이미 떠 있음" }
        guard NSApp.isActive || qaIgnoresFocus else { return "앱이 앞에 있지 않음" }
        guard NSApp.modalWindow == nil else { return "모달 창" }
        guard let w = planner, let state else { return "플래너 창 없음" }
        return Self.blocker(planner: w, windows: NSApp.windows, keyWindow: qaIgnoresFocus ? w : NSApp.keyWindow, state: state,
                            tourRunning: TourController.shared.isRunning, syncFlow: sync?.flow != nil,
                            tracking: RunLoop.current.currentMode == .eventTracking || NSEvent.pressedMouseButtons != 0)
    }

    /// §5.1 의 조건 (창 목록을 받아 시험할 수 있게)
    static func mayPresent(planner w: NSWindow, windows: [NSWindow], keyWindow: NSWindow?, state: AppState,
                           tourRunning: Bool, syncFlow: Bool, tracking: Bool) -> Bool {
        blocker(planner: w, windows: windows, keyWindow: keyWindow, state: state, tourRunning: tourRunning, syncFlow: syncFlow,
                tracking: tracking) == nil
    }

    /// 지금 카드를 띄우지 못하는 까닭 (띄워도 되면 nil)
    static func blocker(planner w: NSWindow, windows: [NSWindow], keyWindow: NSWindow?, state: AppState,
                        tourRunning: Bool, syncFlow: Bool, tracking: Bool) -> String? {
        guard w.isVisible, !w.isMiniaturized else { return "플래너 창이 보이지 않음" }
        guard w.attachedSheet == nil else { return "플래너 창에 시트" }
        // 플래너가 앞에: 열쇠 창이 플래너이거나 그 팔레트
        guard let key = keyWindow, key === w || key.parent === w else { return "다른 창이 앞에 있음" }
        // 다른 창(설정 · PDF · 업데이트 · 처음 안내) · 팝오버가 떠 있지 않다
        if let o = windows.first(where: { o in
            guard o !== w, o.parent !== w, o.isVisible else { return false }
            return o.styleMask.contains(.titled) || o.className.contains("Popover") || o.attachedSheet != nil
        }) { return "다른 창이 떠 있음 (\(o.className) \(o.title))" }
        // 둘러보기 · 동기화 연결 · 메뉴 · 칠하는 중 · 넘기는 중 · 글을 쓰는 중이 아니다
        if tourRunning { return "둘러보는 중" }
        if syncFlow { return "동기화 연결 중" }
        if tracking { return "메뉴 · 누르는 중" }
        guard !state.morphing, state.curl.isIdle, !state.frameBusy else { return "넘기거나 창 모양을 바꾸는 중" }
        guard state.editingKey == nil else { return "글을 쓰는 중" }
        if let tv = w.firstResponder as? NSTextView, tv.isEditable { return "글 칸에 입력 중 (\(tv.className))" }
        return nil
    }

    func presentCard(_ content: NewsCardContent) {
        guard let w = planner else { return }
        dismiss(animated: false)
        self.content = content
        let p = NewsCardPanel(contentRect: NSRect(x: 0, y: 0, width: NewsCardPlacement.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.animationBehavior = .none
        p.becomesKeyOnlyIfNeeded = false
        p.title = NewsCopy.paneTitle("ko")
        p.setAccessibilityLabel(content.kind == .notice ? "소식" : NewsCopy.whatsNewCaption("ko"))
        p.onCancel = { [weak self] in self?.dismiss() }
        // 패널 가장자리에 카드 그림자 자리를 둔다 (그림자는 카드가 그린다 — 창 그림자는 열쇠 창이면 패널 네모 전체를 옅게 덮는다)
        let view = NewsCardView(content: content,
                                onLink: { [weak self] in
                                    if let url = content.link { NewsCenter.openLink(url) }
                                    self?.dismiss()
                                },
                                onOK: { [weak self] in self?.dismiss() })
            .padding(NewsCardPlacement.margin)
        // 크기는 따로 잰다 (sizingOptions 를 비운 호스트는 fittingSize 가 0 이다 — 팔레트의 measure 와 같은 방법)
        let size = NSHostingView(rootView: view).fittingSize
        let h = NSHostingView(rootView: AnyView(view))
        h.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        h.frame = container.bounds
        h.autoresizingMask = [.width, .height]
        container.addSubview(h)
        p.contentView = container
        p.setContentSize(size)
        panel = p
        host = h
        reposition()
        w.addChildWindow(p, ordered: .above)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.alphaValue = reduce ? 1 : 0
        p.makeKeyAndOrderFront(nil)
        if !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
        // 카드 밖을 누르면 닫는다 (누른 것은 그대로 그 창으로 간다)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, let p = self.panel, e.window !== p { self.dismiss() }
            }
            return e
        }
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: "\(content.caption): \(content.title)",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func dismiss(animated: Bool = true) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard let p = panel else { return }
        panel = nil
        host = nil
        content = nil
        let wasKey = p.isKeyWindow
        let close = { [weak planner] in
            planner?.removeChildWindow(p)
            p.orderOut(nil)
            if wasKey, let planner, planner.isVisible { planner.makeKey() }
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { close(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async { close() }
        }
        // 닫는 동안에도 열쇠는 바로 플래너로
        if wasKey, let planner, planner.isVisible { planner.makeKey() }
    }

    /// 창 옆 제자리로
    func reposition() {
        guard let p = panel, let w = planner, let state else { return }
        let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        let pal = w.childWindows?.first { $0 is PalettePanel } as? PalettePanel
        let placed = NewsCardPlacement.place(p.frame.size, page: w.frame, palette: pal?.isVisible == true ? pal?.frame : nil,
                                             paletteSide: pal?.isVisible == true ? pal?.side : nil, kind: state.kind, visible: vis)
        if p.frame != placed.frame { p.setFrame(placed.frame, display: true) }
    }
}

// MARK: - 카드

struct NewsCardView: View {
    let content: NewsCardContent
    /// 스냅샷(QA): 머티리얼 대신 비슷한 색으로
    var snapshot = false
    var onLink: () -> Void = {}
    var onOK: () -> Void = {}

    static let bodyMaxHeight: CGFloat = 220
    static let padding: CGFloat = 18
    static let bodyFont: CGFloat = 13
    static let lineSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: content.caption)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(verbatim: content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            bodyText
                .padding(.bottom, 14)
            HStack(alignment: .center, spacing: 8) {
                if let note = content.footnote {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if content.link != nil {
                    Button(NewsCopy.learnMore("ko"), action: onLink)
                        .help("spiralday.com 에서 자세히 봐요 (브라우저로 열려요)")
                }
                Button(NewsCopy.ok("ko"), action: onOK)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(Self.padding)
        .frame(width: NewsCardPlacement.width, alignment: .leading)
        .modifier(NewsCardBackground(snapshot: snapshot))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.kind == .notice ? "소식" : NewsCopy.whatsNewCaption("ko"))
    }

    @ViewBuilder private var bodyText: some View {
        let text = Text(verbatim: content.body)
            .font(.system(size: Self.bodyFont))
            .lineSpacing(Self.lineSpacing)
            .foregroundStyle(.primary.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if Self.bodyHeight(content.body) > Self.bodyMaxHeight {
            ScrollView { text.padding(.trailing, 6) }
                .frame(height: Self.bodyMaxHeight)
        } else {
            text
        }
    }

    /// 본문 높이 (카드 안에서 스크롤할지 정한다)
    static func bodyHeight(_ s: String) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: bodyFont), .paragraphStyle: style])
        let r = a.boundingRect(with: NSSize(width: NewsCardPlacement.width - 2 * padding, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height)
    }
}

/// 카드 바탕: 종이 옆에 놓인 메모 카드처럼 불투명한 바탕 + 부드러운 그림자 (라이트 · 다크). 유리 · 머티리얼은 쓰지 않는다 —
/// 투명한 패널에서 열쇠 창이 되면 패널 네모 전체가 옅게 비쳤다 (2026-10-11 QA). 스냅샷도 같은 모양
private struct NewsCardBackground: ViewModifier {
    let snapshot: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let dark = scheme == .dark
        content
            .background(
                shape.fill(dark ? Color(white: 0.17) : Color(hex: "F8F7F4"))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.15), radius: 6, y: 2)
            )
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07), lineWidth: 0.6))
    }
}
