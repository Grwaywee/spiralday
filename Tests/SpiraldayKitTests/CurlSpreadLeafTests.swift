import XCTest
import CoreGraphics
@testable import SpiraldayKit

/// 펼친 스프링 책(iPad)에서 넘어가는 잎이 덮는 자리(CurlSpreadLeaf) — 틈 위에 그리는 코일 고리를 잎과 앞뒤로 가린다.
/// 잎은 한 장처럼 말리고 끝 무렵 구멍 띠가 코일을 돈다: 위 고리는 잎의 구멍 안쪽(제본 여백) 위로 지나고 구멍 바깥 잎 밑으로
/// 들어간다, 아래 고리는 잎 전체 밑.
/// 셰이더가 실제로 그린 그림과 화소로 견준다 (잎이 보이는 곳은 모두 안, 드러난 쪽 · 빈 곳은 모두 밖).
@MainActor
final class CurlSpreadLeafTests: XCTestCase {
    /// 반 크기 책 (CurlSpreadTests 와 같은 놓기): 쪽 153×240 · 틈 6 · 구멍 = 틈 반 + 5 · bleed 24
    private func spread(horizontal: Bool) -> CurlSpread {
        let p = horizontal ? CGSize(width: 240, height: 153) : CGSize(width: 153, height: 240)
        let gutter: CGFloat = 6, bleed: CGFloat = 24
        if horizontal {
            return CurlSpread(axis: .horizontal, overlaySize: CGSize(width: p.width + 2 * bleed, height: 2 * p.height + gutter),
                              hinge: p.height + gutter / 2, halfGutter: gutter / 2,
                              versoRect: CGRect(x: bleed, y: 0, width: p.width, height: p.height),
                              rectoRect: CGRect(x: bleed, y: p.height + gutter, width: p.width, height: p.height),
                              coil: gutter / 2 + 5)
        }
        return CurlSpread(axis: .vertical, overlaySize: CGSize(width: 2 * p.width + gutter, height: p.height + 2 * bleed),
                          hinge: p.width + gutter / 2, halfGutter: gutter / 2,
                          versoRect: CGRect(x: 0, y: bleed, width: p.width, height: p.height),
                          rectoRect: CGRect(x: p.width + gutter, y: bleed, width: p.width, height: p.height),
                          coil: gutter / 2 + 5)
    }

    /// 위 고리를 가리는 모양: 구멍(코일 반지름) + 철사 끝 2pt 부터
    private func upperMask(_ l: CurlSpreadLeaf, _ g: CurlSpread) -> CurlSheetShape {
        l.lifted(bindingMargin: g.coil - g.halfGutter + 2)
    }

    /// 위에서 본 위 고리 한 가닥의 점들 (각 t: 0 = 드는 쪽 구멍, π = 반대쪽 구멍), 제본을 따라 여러 자리
    private func arc(_ g: CurlSpread, sigma: CGFloat, from t0: Double, to t1: Double) -> [CGPoint] {
        var pts: [CGPoint] = []
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let length = g.axis == .vertical ? lift.height : lift.width
        for along in stride(from: 6.0, through: Double(length) - 6, by: 9) {
            for t in stride(from: t0, through: t1, by: 0.02) {
                let across = sigma * g.coil * CGFloat(cos(t))
                pts.append(g.axis == .vertical ? CGPoint(x: g.hinge + across, y: lift.minY + CGFloat(along))
                                               : CGPoint(x: lift.minX + CGFloat(along), y: g.hinge + across))
            }
        }
        return pts
    }

    func testTheCoilIsNeverHiddenAtRestOrOnceLanded() {
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            for dir in [FlipDirection.forward, .backward] {
                let sigma: CGFloat = dir == .forward ? 1 : -1
                for p in [0.0, 1.0] {
                    let l = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: p)
                    XCTAssertTrue(l.isFlat)
                    let hit = arc(g, sigma: sigma, from: 0, to: .pi).filter { upperMask(l, g).contains($0) }
                    XCTAssertTrue(hit.isEmpty, "\(horizontal) \(dir) \(p): 평평한 잎은 위 고리를 가리지 않는다 (\(hit.prefix(3)))")
                    // 아래 고리(틈 안)도 — 잎 전체가 틈 밖
                    let gap = arc(g, sigma: sigma, from: 0, to: .pi).filter { pt in
                        abs((g.axis == .vertical ? pt.x : pt.y) - g.hinge) < g.halfGutter - 0.5
                    }
                    XCTAssertTrue(gap.filter { l.lifted(bindingMargin: 0).contains($0) }.isEmpty, "\(horizontal) \(dir) \(p): 틈은 비어 있다")
                }
                // 내려앉은 잎은 반대쪽에 누운 자리 전체를 계속 덮는다 (새 펼침이 그려질 때까지 그 밑의 고리를 감춘다)
                let landed = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: 1).lifted(bindingMargin: 0)
                let opp = sigma > 0 ? g.versoRect : g.rectoRect
                XCTAssertTrue(landed.contains(CGPoint(x: opp.midX, y: opp.midY)))
            }
        }
    }

    /// 잎은 한 장처럼 말려 넘어간다: 말림이 제본에 닿기 전에는 고리를 하나도 가리지 않고, 뒤집힌 부분이 틈 위에 누우면
    /// 그 밑의 위 고리를 가린다. 구멍 띠가 코일을 돌 때는 잎의 구멍 너머(반대쪽으로 이어지는 고리)가 잎 밑이다.
    func testTheLeafCurlsOverTheCoilLikePaper() {
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            for dir in [FlipDirection.forward, .backward] {
                let sigma: CGFloat = dir == .forward ? 1 : -1
                let name = "\(horizontal ? "weekly" : "daily") \(dir)"
                for p in [0.1, 0.2] {
                    let l = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: p)
                    XCTAssertEqual(l.holeAngle, 0)
                    let hit = arc(g, sigma: sigma, from: 0, to: .pi).filter { upperMask(l, g).contains($0) }
                    XCTAssertTrue(hit.isEmpty, "\(name) \(p): 모서리만 들린 잎은 코일에 닿지 않는다 (\(hit.prefix(3)))")
                }
                for p in [0.7, 0.8] {
                    let l = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: p)
                    XCTAssertEqual(l.holeAngle, 0, "\(name) \(p): 구멍 띠는 아직 제 쪽에")
                    let pts = arc(g, sigma: sigma, from: 0.1, to: .pi - 0.1)
                    let hidden = pts.filter { upperMask(l, g).contains($0) }.count
                    XCTAssertGreaterThan(Double(hidden) / Double(pts.count), 0.9, "\(name) \(p): 틈 위에 누운 잎 밑으로 고리가 들어간다")
                }
                var pivoted = 0
                for p in stride(from: 0.86, through: 0.999, by: 0.004) {
                    let l = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: p)
                    let theta = l.holeAngle
                    guard theta > 0.2, theta < 1.2 else { continue }
                    pivoted += 1
                    let beyond = arc(g, sigma: sigma, from: theta + 0.3, to: .pi - 0.3)
                    XCTAssertFalse(beyond.isEmpty)
                    let hidden = beyond.filter { upperMask(l, g).contains($0) }.count
                    XCTAssertEqual(hidden, beyond.count, "\(name) \(p) θ \(theta): 잎의 구멍 너머 고리는 잎 밑")
                }
                XCTAssertGreaterThan(pivoted, 0, "\(name): 구멍 띠가 코일을 도는 프레임을 보았다")
            }
        }
    }

    // MARK: 셰이더와 견주기

    /// 드는 면 = 빨강, 뒷면 = 초록, 드러나는 쪽 = 파랑: 빨강 · 초록이 보이는 화소는 모두 모양 안,
    /// 파랑 · 빈 곳(투명)은 모두 모양 밖 (윤곽 근처 1.5pt 는 뺀다).
    func testShapeMatchesTheRenderedLeaf() throws {
        try XCTSkipIf(CurlGPU.shared?.spreadPipeline == nil, "Metal 없음")
        var leafSeen = 0
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            let page = horizontal ? CGSize(width: 240, height: 153) : CGSize(width: 153, height: 240)
            let scale: CGFloat = 2
            let red = try solid(page, scale, 255, 0, 0), green = try solid(page, scale, 0, 255, 0), blue = try solid(page, scale, 0, 0, 255)
            for dir in [FlipDirection.forward, .backward] {
                for hold in [false, true] {
                    let progress = [0.2, 0.4, 0.55, 0.7, 0.85, 0.93, 0.96, 0.98, 0.995]
                    let frames = CurlController.renderSpreadStills(SpreadBitmaps(front: red, back: green, revealed: blue),
                                                                   spread: g, direction: dir, holdTop: hold, scale: scale,
                                                                   progress: progress)
                    XCTAssertEqual(frames.count, progress.count)
                    for (img, p) in zip(frames, progress) {
                        let name = "\(horizontal ? "weekly" : "daily") \(dir) hold \(hold) \(p)"
                        let shape = CurlSpreadLeaf.turn(spread: g, direction: dir, holdTop: hold, progress: p).lifted(bindingMargin: 0)
                        let px = try pixels(img)
                        var wrongLeaf = 0, wrongUnder = 0
                        for y in stride(from: 1, to: px.height, by: 3) {
                            for x in stride(from: 1, to: px.width, by: 3) {
                                let q = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                                let (r, gg, b, a) = px[x, y]
                                let isLeaf = a > 250 && ((r > 120 && gg < 90 && b < 90) || (gg > 120 && r < 90 && b < 90))
                                let isUnder = (a > 250 && b > 120 && r < 90 && gg < 90) || a < 6
                                guard isLeaf || isUnder else { continue }
                                let inside = shape.contains(q)
                                if isLeaf { leafSeen += 1 }
                                if isLeaf, !inside, distance(q, shape.outline) > 1.5 { wrongLeaf += 1 }
                                if isUnder, inside, distance(q, shape.outline) > 1.5 { wrongUnder += 1 }
                            }
                        }
                        XCTAssertEqual(wrongLeaf, 0, "\(name): 잎이 보이는데 모양 밖 — 고리가 잎 위로 비친다")
                        XCTAssertEqual(wrongUnder, 0, "\(name): 드러난 쪽 · 빈 곳인데 모양 안 — 고리를 괜히 감춘다")
                    }
                }
            }
        }
        XCTAssertGreaterThan(leafSeen, 4000, "잎이 실제로 보이는 장면을 견주었다")
    }

    // MARK: 도우미

    private func solid(_ size: CGSize, _ scale: CGFloat, _ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    private struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]
        subscript(x: Int, y: Int) -> (Int, Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
    }

    /// RGBA (premultiplied), 위에서부터 (화면 방향)
    private func pixels(_ img: CGImage) throws -> Pixels {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        try data.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setBlendMode(.copy)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, data: data)
    }

    private func distance(_ p: CGPoint, _ poly: [CGPoint]) -> CGFloat {
        guard poly.count >= 2 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2)) : 0
            let dx = a.x + ab.x * t - p.x, dy = a.y + ab.y * t - p.y
            best = min(best, (dx * dx + dy * dy).squareRoot())
        }
        return best
    }
}
