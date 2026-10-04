import SwiftUI

@MainActor
public final class RingModel: ObservableObject {
    @Published public var kind: PageKind = .daily
    @Published public var u: CGFloat = 1
    /// 띠 안에서 종이 가장자리까지의 거리 (pt)
    @Published public var outside: CGFloat = 0

    public init() {}
}

/// 고리의 어느 부분을 그릴지. 종이 가장자리(across = 0)에서 나눈다.
/// Mac 은 종이 밖 부분만 종이 창 밖의 자식 창에 그리고, 종이 위 부분은 종이 창 안의 넘김 오버레이 아래와
/// 넘김 스냅숏에 그린다 — 넘어가는 종이가 고리를 저절로 덮게 (2026-10 사장님 피드백 B: 넘어가는 종이 위로 고리가 비침).
public enum RingPart: Sendable, Equatable {
    /// 전부 (기본 — iOS · 위젯 · 공유 그림, 처음 안내 창은 예전 그대로)
    case all
    /// 종이 가장자리 바깥(across < 0)만: 뒤 가닥 · 고리 끝 · 종이 밖으로 나온 앞 가닥
    case outsidePaper
    /// 종이 위(across ≥ 0)만: 종이 위를 지나 구멍으로 들어가는 앞 가닥과 그 그림자
    case overPaper
}

/// 쌍으로 된 금속 고리(twin-loop). 구멍에서 나와 종이 가장자리를 넘어 뒤로 감긴다.
/// 앞쪽 가닥은 종이 위로 보이고, 뒤쪽 가닥은 종이 바깥에서만 보인다.
public struct RingStrip: View {
    @ObservedObject public var model: RingModel
    /// 그릴 부분 (기본: 전부)
    public let part: RingPart

    public init(model: RingModel, part: RingPart = .all) {
        self.model = model
        self.part = part
    }

    public var body: some View {
        let kind = model.kind
        let u = model.u
        let outside = model.outside
        let part = part
        Canvas { ctx, _ in
            Self.draw(&ctx, kind: kind, u: u, outside: outside, part: part)
        }
        .allowsHitTesting(false)
    }

    /// 고리를 그린다. outside = 그리는 곳 안에서 종이 가장자리까지의 거리 (pt — 종이 위에 바로 그리면 0), u = 디자인 단위 → pt
    public static func draw(_ ctx: inout GraphicsContext, kind: PageKind, u: CGFloat, outside: CGFloat, part: RingPart = .all) {
        // 디자인 좌표계로: 종이 가장자리 = 0, 바깥 = 음수
        if kind.edge == .leading {
            ctx.translateBy(x: outside, y: 0)
        } else {
            ctx.translateBy(x: 0, y: outside)
        }
        ctx.scaleBy(x: u, y: u)
        if let keep = clip(part, kind: kind) { ctx.clip(to: Path(keep)) }
        for hole in SpiralBinding.holes(kind) {
            for side: CGFloat in [-1, 1] {
                drawLoop(&ctx, kind: kind, hole: hole, side: side)
            }
        }
    }

    /// 그 부분만 남기는 자리 (디자인 좌표, 종이 가장자리 = 0). 전부면 nil
    public static func clip(_ part: RingPart, kind: PageKind) -> CGRect? {
        let far: CGFloat = 100_000
        let leading = kind.edge == .leading
        switch part {
        case .all:
            return nil
        case .outsidePaper:
            return leading ? CGRect(x: -far, y: -far, width: far, height: 2 * far)
                           : CGRect(x: -far, y: -far, width: 2 * far, height: far)
        case .overPaper:
            return leading ? CGRect(x: 0, y: -far, width: far, height: 2 * far)
                           : CGRect(x: -far, y: 0, width: 2 * far, height: far)
        }
    }

    /// 한 가닥의 고리. 좌표는 "스프링 방향" 기준 (along = 가장자리를 따라, across = 가장자리에서 안쪽으로)
    private static func drawLoop(_ ctx: inout GraphicsContext, kind: PageKind, hole: CGRect, side: CGFloat) {
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
