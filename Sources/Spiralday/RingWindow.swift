import AppKit
import SwiftUI
import SpiraldayKit

/// 스프링 링. 종이(본 창) 가장자리에 걸친 투명한 child window 에 그려서
/// 링이 창 밖으로 잘리지 않고 진짜 노트처럼 튀어나와 보이게 한다.
/// 마우스 이벤트는 모두 아래 창으로 통과시킨다.
@MainActor
final class RingWindowController {
    /// 종이 바깥으로 나오는 폭 / 종이 안쪽으로 들어오는 폭 (디자인 단위)
    static let outside: CGFloat = 38
    static let inside: CGFloat = 36

    private let window: NSWindow
    private let model = RingModel()
    private weak var parent: NSWindow?

    init(parent: NSWindow) {
        self.parent = parent
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenNone, .ignoresCycle]
        window.contentView = NSHostingView(rootView: RingStrip(model: model))
    }

    func attach(_ kind: PageKind) {
        guard let parent else { return }
        if window.parent == nil { parent.addChildWindow(window, ordered: .above) }
        update(kind)
    }

    /// 본 창 크기/모드가 바뀔 때마다 띠의 위치와 링 배치를 맞춘다.
    func update(_ kind: PageKind) {
        guard let parent else { return }
        let page = parent.frame
        let u = page.width / kind.design.width
        let out = (Self.outside * u).rounded(.up)
        let ins = (Self.inside * u).rounded(.up)
        let frame: NSRect
        switch kind.edge {
        case .leading:
            frame = NSRect(x: page.minX - out, y: page.minY, width: out + ins, height: page.height)
        case .top:
            frame = NSRect(x: page.minX, y: page.maxY - ins, width: page.width, height: out + ins)
        }
        if model.kind != kind { model.kind = kind }
        if model.u != u { model.u = u }
        if model.outside != out { model.outside = out }
        window.setFrame(frame, display: true)
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.22 : 0.12
                window.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            window.alphaValue = visible ? 1 : 0
        }
    }
}
