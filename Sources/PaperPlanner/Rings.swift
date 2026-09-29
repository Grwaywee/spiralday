import AppKit
import SwiftUI

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

@MainActor
final class RingModel: ObservableObject {
    @Published var kind: PageKind = .daily
    @Published var u: CGFloat = 1
    /// 띠 안에서 종이 가장자리까지의 거리 (pt)
    @Published var outside: CGFloat = 0
}

/// 쌍으로 된 금속 고리(twin-loop). 구멍에서 나와 종이 가장자리를 넘어 뒤로 감긴다.
/// 앞쪽 가닥은 종이 위로 보이고, 뒤쪽 가닥은 종이 바깥에서만 보인다.
struct RingStrip: View {
    @ObservedObject var model: RingModel

    var body: some View {
        let kind = model.kind
        let u = model.u
        let outside = model.outside
        Canvas { ctx, _ in
            // 디자인 좌표계로: 종이 가장자리 = 0, 바깥 = 음수
            if kind.edge == .leading {
                ctx.translateBy(x: outside, y: 0)
            } else {
                ctx.translateBy(x: 0, y: outside)
            }
            ctx.scaleBy(x: u, y: u)
            for hole in SpiralBinding.holes(kind) {
                for side: CGFloat in [-1, 1] {
                    drawLoop(&ctx, kind: kind, hole: hole, side: side)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 한 가닥의 고리. 좌표는 "스프링 방향" 기준 (along = 가장자리를 따라, across = 가장자리에서 안쪽으로)
    private func drawLoop(_ ctx: inout GraphicsContext, kind: PageKind, hole: CGRect, side: CGFloat) {
        let leading = kind.edge == .leading
        let holeAcross = leading ? hole.midX : hole.midY
        let along = (leading ? hole.midY : hole.midX) + side * 4.8
        let tip: CGFloat = -29        // 종이 밖으로 나온 끝
        let rr: CGFloat = 4.4         // 고리 반지름 (앞/뒤 가닥 사이 절반)
        let wire: CGFloat = 2.9       // 철사 굵기

        func pt(_ across: CGFloat, _ a: CGFloat) -> CGPoint {
            leading ? CGPoint(x: across, y: a) : CGPoint(x: a, y: across)
        }

        // 뒤쪽 가닥 + 끝의 둥근 부분 (종이 뒤로 들어가므로 가장자리 0 에서 끝난다)
        var back = Path()
        back.move(to: pt(0, along - rr))
        back.addLine(to: pt(tip + rr, along - rr))
        // 반원: 방향과 상관없이 같은 모양이 되도록 곡선으로
        back.addCurve(to: pt(tip + rr, along + rr),
                      control1: pt(tip - rr * 0.36, along - rr),
                      control2: pt(tip - rr * 0.36, along + rr))
        // 앞쪽 가닥: 끝에서 나와 종이 위를 지나 구멍으로
        var front = Path()
        front.move(to: pt(tip + rr, along + rr))
        front.addLine(to: pt(holeAcross - 1, along + rr * 0.35))

        let dark = Color(hex: "5E6168")
        let mid = Color(hex: "A9ACB3")
        let light = Color(hex: "F4F5F7")

        // 종이 위에 떨어지는 앞 가닥 그림자
        var shadow = ctx
        shadow.addFilter(.blur(radius: 1.6))
        shadow.translateBy(x: leading ? 1.2 : 1.8, y: leading ? 2.2 : 1.4)
        shadow.stroke(front, with: .color(.black.opacity(0.28)), style: StrokeStyle(lineWidth: wire, lineCap: .round))

        // 뒤 가닥은 살짝 어둡게
        ctx.stroke(back, with: .color(dark), style: StrokeStyle(lineWidth: wire, lineCap: .round))
        ctx.stroke(back, with: .color(mid.opacity(0.9)), style: StrokeStyle(lineWidth: wire * 0.45, lineCap: .round))

        // 앞 가닥: 가장자리는 어둡고 가운데 하이라이트
        ctx.stroke(front, with: .color(dark), style: StrokeStyle(lineWidth: wire, lineCap: .round))
        ctx.stroke(front, with: .color(mid), style: StrokeStyle(lineWidth: wire * 0.7, lineCap: .round))
        var hl = Path()
        hl.move(to: pt(tip + rr + 1, along + rr - wire * 0.18))
        hl.addLine(to: pt(holeAcross - 3, along + rr * 0.35 - wire * 0.18))
        ctx.stroke(hl, with: .color(light.opacity(0.9)), style: StrokeStyle(lineWidth: wire * 0.28, lineCap: .round))
    }
}
