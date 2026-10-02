import SwiftUI

@MainActor
public final class RingModel: ObservableObject {
    @Published public var kind: PageKind = .daily
    @Published public var u: CGFloat = 1
    /// 띠 안에서 종이 가장자리까지의 거리 (pt)
    @Published public var outside: CGFloat = 0

    public init() {}
}

/// 쌍으로 된 금속 고리(twin-loop). 구멍에서 나와 종이 가장자리를 넘어 뒤로 감긴다.
/// 앞쪽 가닥은 종이 위로 보이고, 뒤쪽 가닥은 종이 바깥에서만 보인다.
public struct RingStrip: View {
    @ObservedObject public var model: RingModel

    public init(model: RingModel) {
        self.model = model
    }

    public var body: some View {
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
