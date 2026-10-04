import AppKit
import SwiftUI
import SpiraldayKit

/// 스프링 링. 종이(본 창) 가장자리 밖에 붙인 투명한 child window 에 그려서
/// 링이 창 밖으로 잘리지 않고 진짜 노트처럼 튀어나와 보이게 한다.
/// 마우스 이벤트는 모두 아래 창으로 통과시킨다.
///
/// 플래너 창(part: .outsidePaper)은 종이 밖 부분만 이 창에 그린다. 종이 위 앞 가닥은 본 창 안 넘김 오버레이 아래
/// (RootView 의 RingStrandsOverPaper)와 넘김 스냅숏(RingSnapshotBaker)에 그려서, 넘어가는 종이가 고리를 저절로 덮는다
/// (사장님 피드백 B: 넘어가는 종이 위로 고리가 비침). 이 창은 종이와 겹치지 않는다 — 넘김 오버레이는 종이 밖에 그리지 않으니
/// 고리 창이 위에 있어도 들린 종이를 가리지 않는다. 처음 안내 창(넘김 없음)은 예전처럼 전부(.all).
@MainActor
final class RingWindowController {
    /// 종이 바깥으로 나오는 폭 / 종이 안쪽으로 들어오는 폭 (디자인 단위)
    static let outside: CGFloat = 38
    static let inside: CGFloat = 36

    let part: RingPart
    private let window: NSWindow
    private let model = RingModel()
    private let shade = RingShade()
    private weak var parent: NSWindow?

    init(parent: NSWindow, part: RingPart = .all) {
        self.parent = parent
        self.part = part
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenNone, .ignoresCycle]
        window.contentView = NSHostingView(rootView: RingWindowContent(model: model, shade: shade, part: part))
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
        if model.kind != kind { model.kind = kind }
        if model.u != u { model.u = u }
        if model.outside != out { model.outside = out }
        window.setFrame(Self.frame(page: page, kind: kind, part: part), display: true)
    }

    /// 고리 창의 자리 (화면 좌표, 아래가 0). .outsidePaper 는 종이 밖 띠뿐이라 종이 사각형과 겹치지 않는다
    static func frame(page: NSRect, kind: PageKind, part: RingPart) -> NSRect {
        let u = page.width / kind.design.width
        let out = (outside * u).rounded(.up)
        let ins = part == .outsidePaper ? 0 : (inside * u).rounded(.up)
        switch kind.edge {
        case .leading:
            return NSRect(x: page.minX - out, y: page.minY, width: out + ins, height: page.height)
        case .top:
            return NSRect(x: page.minX, y: page.maxY - ins, width: page.width, height: out + ins)
        }
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

    /// 둘러보기의 어두운 막이 종이를 덮는 동안 종이 밖 고리도 같은 막으로 (막은 본 창 안에만 있어서 이 창을 덮지 못한다)
    func setDimmed(_ dimmed: Bool) {
        if shade.dimmed != dimmed { shade.dimmed = dimmed }
    }

    var isDimmed: Bool { shade.dimmed }
}

/// 고리 창의 어두운 막 (둘러보기)
@MainActor
final class RingShade: ObservableObject {
    @Published var dimmed = false
}

/// 고리 창의 내용: 고리 + (둘러보는 동안) 고리 위에만 얹는 둘러보기 막 — 투명한 곳(책상 · 바탕화면)은 그대로 둔다
struct RingWindowContent: View {
    @ObservedObject var model: RingModel
    @ObservedObject var shade: RingShade
    let part: RingPart

    var body: some View {
        RingStrip(model: model, part: part)
            .overlay {
                // sourceAtop: 그려진 고리 화소에만 막 색을 덮는다 (종이 위 막과 같은 색 · 같은 비율)
                Rectangle()
                    .fill(TourLayout.curtain)
                    .opacity(shade.dimmed ? 1 : 0)
                    .blendMode(.sourceAtop)
            }
            .compositingGroup()
            .animation(.easeOut(duration: 0.22), value: shade.dimmed)
            .allowsHitTesting(false)
    }
}

/// 종이 위 앞 가닥 (본 창 안, 넘김 오버레이 아래 — 넘어가는 종이가 덮는다). 종이 밖 부분은 RingWindowController 의 창
struct RingStrandsOverPaper: View {
    let kind: PageKind
    let size: CGSize

    var body: some View {
        let u = size.width / kind.design.width
        Canvas { ctx, _ in
            RingStrip.draw(&ctx, kind: kind, u: u, outside: 0, part: .overPaper)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 넘김 스냅숏(지금 장 · 다음 장)에 종이 위 앞 가닥을 굽는다. 넘김 오버레이는 불투명하게 종이를 덮으므로,
/// 고리가 넘김 중에도 보이려면 스냅숏 안에 있어야 한다 — 그러면 들린 종이(뒷면)는 고리 위에 그려진다.
/// 같은 원본 그림에는 같은 결과 그림을 돌려준다 (말림 텍스처 캐시가 그림의 정체로 찾는다).
@MainActor
final class RingSnapshotBaker {
    private var strands: (kind: PageKind, size: CGSize, scale: CGFloat, image: CGImage)?
    private var baked: [(source: CGImage, image: CGImage)] = []
    private let capacity = 6

    func bake(_ page: CGImage, kind: PageKind, size: CGSize, scale: CGFloat) -> CGImage {
        if let i = baked.firstIndex(where: { $0.source === page }) {
            let e = baked.remove(at: i)
            baked.append(e)
            return e.image
        }
        guard let overlay = strandsImage(kind: kind, size: size, scale: scale),
              let out = Self.compose(page, overlay) else { return page }
        baked.append((page, out))
        while baked.count > capacity { baked.removeFirst() }
        return out
    }

    private func strandsImage(kind: PageKind, size: CGSize, scale: CGFloat) -> CGImage? {
        if let s = strands, s.kind == kind, s.size == size, s.scale == scale { return s.image }
        guard let img = Self.strands(kind: kind, size: size, scale: scale) else { return nil }
        strands = (kind, size, scale, img)
        return img
    }

    /// 종이 위 앞 가닥만 투명 바탕에 (종이 크기 × scale)
    static func strands(kind: PageKind, size: CGSize, scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: RingStrandsOverPaper(kind: kind, size: size))
        r.scale = scale
        r.isOpaque = false
        return r.cgImage
    }

    /// 종이 그림 위에 가닥 그림을 얹는다 (말림 텍스처와 같은 sRGB · BGRA premultiplied)
    static func compose(_ page: CGImage, _ overlay: CGImage) -> CGImage? {
        let w = page.width, h = page.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(page, in: rect)
        ctx.setBlendMode(.normal)
        ctx.draw(overlay, in: rect)
        return ctx.makeImage()
    }
}
