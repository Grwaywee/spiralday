import XCTest
import CoreGraphics
@testable import SpiraldayKit

/// 펼친 책(iPad)에서 넘어가는 잎의 들린 부분(CurlSpreadLeaf) — 골 위에 그리는 철사 고리를 그 아래로 가릴 자리.
/// 셰이더가 실제로 그린 그림과 화소로 견준다 (뒷면이 보이는 곳은 모두 안, 드러난 쪽 · 빈 곳은 모두 밖),
/// 잎의 제본 여백(철사가 꿰인 곳)은 빼고, 넘김 앞 · 착지한 마지막 프레임에는 철사를 하나도 가리지 않는다.
@MainActor
final class CurlSpreadLeafTests: XCTestCase {
    /// 반 크기 책 (CurlSpreadTests 와 같은 놓기): 쪽 153×240 · 골 6 · bleed 20
    private func spread(horizontal: Bool) -> CurlSpread {
        let p = horizontal ? CGSize(width: 240, height: 153) : CGSize(width: 153, height: 240)
        let gutter: CGFloat = 6, bleed: CGFloat = 20
        if horizontal {
            return CurlSpread(axis: .horizontal, overlaySize: CGSize(width: p.width + 2 * bleed, height: 2 * p.height + gutter + 2 * bleed),
                              hinge: bleed + p.height + gutter / 2, halfGutter: gutter / 2,
                              versoRect: CGRect(x: bleed, y: bleed, width: p.width, height: p.height),
                              rectoRect: CGRect(x: bleed, y: bleed + p.height + gutter, width: p.width, height: p.height))
        }
        return CurlSpread(axis: .vertical, overlaySize: CGSize(width: 2 * p.width + gutter, height: p.height + 2 * bleed),
                          hinge: p.width + gutter / 2, halfGutter: gutter / 2,
                          versoRect: CGRect(x: 0, y: bleed, width: p.width, height: p.height),
                          rectoRect: CGRect(x: p.width + gutter, y: bleed, width: p.width, height: p.height))
    }

    /// 철사가 지나는 띠: 골을 건너 양쪽 구멍(제본 가장자리에서 hole 만큼)까지, 쪽 길이 전체
    private func wire(_ g: CurlSpread, hole: CGFloat) -> [CGPoint] {
        let reach = g.halfGutter + hole
        var pts: [CGPoint] = []
        let lift = g.rectoRect
        for along in stride(from: 4.0, through: Double(g.axis == .vertical ? lift.height : lift.width) - 4, by: 6) {
            for across in stride(from: -reach, through: reach, by: 1) {
                pts.append(g.axis == .vertical ? CGPoint(x: g.hinge + across, y: lift.minY + CGFloat(along))
                                               : CGPoint(x: lift.minX + CGFloat(along), y: g.hinge + across))
            }
        }
        return pts
    }

    func testNothingIsHiddenAtRestAndOnceLanded() {
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            for dir in [FlipDirection.forward, .backward] {
                for hold in [false, true] {
                    XCTAssertTrue(CurlSpreadLeaf.turn(spread: g, direction: dir, holdTop: hold, progress: 0)
                        .lifted(bindingMargin: 12).isEmpty, "\(horizontal) \(dir): 넘김 앞에는 아무것도 들리지 않았다")
                    // 착지: 잎이 반대쪽에 거울로 누웠다 — 제본 여백 밖만 남아 철사(구멍 9 까지)와 겹치지 않는다
                    let landed = CurlSpreadLeaf.turn(spread: g, direction: dir, holdTop: hold, progress: 1).lifted(bindingMargin: 12)
                    let hit = wire(g, hole: 9).filter { landed.contains($0) }
                    XCTAssertTrue(hit.isEmpty, "\(horizontal) \(dir) hold \(hold): 착지한 마지막 프레임에 철사를 가리지 않는다 (\(hit.prefix(3)))")
                }
            }
        }
    }

    /// 넘김 가운데 · 후반에는 들린 잎이 골의 철사를 덮는다 (고치기 전에는 철사가 잎 위로 비쳤다)
    func testTheLiftedLeafCoversTheWireMidTurn() {
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            for dir in [FlipDirection.forward, .backward] {
                var covered = 0
                for p in [0.45, 0.6, 0.75, 0.85] {
                    let s = CurlSpreadLeaf.turn(spread: g, direction: dir, progress: p).lifted(bindingMargin: 12)
                    covered += wire(g, hole: 9).filter { s.contains($0) }.count
                }
                XCTAssertGreaterThan(covered, 200, "\(horizontal) \(dir)")
            }
        }
    }

    /// 잎의 제본 여백(철사가 꿰인 띠)은 넘김 끝 무렵에야 들린다 — 여백을 빼면 그때 그만큼 작아지고, 다른 데는 같다
    func testTheBindingMarginIsLeftOut() {
        let g = spread(horizontal: false)
        var onlyAll = 0
        for p in [0.5, 0.7, 0.9, 0.97, 0.985, 0.995] {
            let all = CurlSpreadLeaf.turn(spread: g, direction: .forward, progress: p).lifted(bindingMargin: 0)
            let some = CurlSpreadLeaf.turn(spread: g, direction: .forward, progress: p).lifted(bindingMargin: 12)
            for y in stride(from: 25.0, to: 255, by: 5) {
                for x in stride(from: 0.0, to: Double(g.overlaySize.width), by: 1) {
                    let q = CGPoint(x: x, y: y)
                    let a = all.contains(q), s = some.contains(q)
                    if s && !a && distance(q, all.outline) > 1 { XCTFail("\(p): 여백을 뺀 모양이 더 크다 \(q)") }
                    if a && !s { onlyAll += 1 }
                }
            }
        }
        XCTAssertGreaterThan(onlyAll, 0, "넘김 끝 무렵에는 여백만큼 빠진다")
    }

    // MARK: 셰이더와 견주기

    /// 드는 면 = 빨강, 뒷면 = 초록, 드러나는 쪽 = 파랑: 초록이 보이는 화소는 모두 모양 안,
    /// 파랑 · 빈 곳(투명)은 모두 모양 밖 (윤곽 근처 1.5pt 는 뺀다).
    func testShapeMatchesTheRenderedLeaf() throws {
        try XCTSkipIf(CurlGPU.shared?.spreadPipeline == nil, "Metal 없음")
        var backSeen = 0
        for horizontal in [false, true] {
            let g = spread(horizontal: horizontal)
            let page = horizontal ? CGSize(width: 240, height: 153) : CGSize(width: 153, height: 240)
            let scale: CGFloat = 2
            let red = try solid(page, scale, 255, 0, 0), green = try solid(page, scale, 0, 255, 0), blue = try solid(page, scale, 0, 0, 255)
            for dir in [FlipDirection.forward, .backward] {
                for hold in [false, true] {
                    let progress = [0.2, 0.4, 0.55, 0.7, 0.85, 0.95]
                    let frames = CurlController.renderSpreadStills(SpreadBitmaps(front: red, back: green, revealed: blue),
                                                                   spread: g, direction: dir, holdTop: hold, scale: scale,
                                                                   progress: progress)
                    XCTAssertEqual(frames.count, progress.count)
                    for (img, p) in zip(frames, progress) {
                        let name = "\(horizontal ? "weekly" : "daily") \(dir) hold \(hold) \(p)"
                        let shape = CurlSpreadLeaf.turn(spread: g, direction: dir, holdTop: hold, progress: p).lifted(bindingMargin: 0)
                        let px = try pixels(img)
                        var wrongBack = 0, wrongUnder = 0
                        for y in stride(from: 1, to: px.height, by: 4) {
                            for x in stride(from: 1, to: px.width, by: 4) {
                                let q = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                                let (r, gg, b, a) = px[x, y]
                                let isBack = a > 250 && gg > 120 && r < 90 && b < 90
                                let isUnder = (a > 250 && b > 120 && r < 90 && gg < 90) || a < 6
                                guard isBack || isUnder else { continue }
                                let inside = shape.contains(q)
                                if isBack { backSeen += 1 }
                                if isBack, !inside, distance(q, shape.outline) > 1.5 { wrongBack += 1 }
                                if isUnder, inside, distance(q, shape.outline) > 1.5 { wrongUnder += 1 }
                            }
                        }
                        XCTAssertEqual(wrongBack, 0, "\(name): 뒷면이 보이는데 모양 밖 — 철사가 잎 위로 비친다")
                        XCTAssertEqual(wrongUnder, 0, "\(name): 드러난 쪽 · 빈 곳인데 모양 안 — 철사를 괜히 감춘다")
                    }
                }
            }
        }
        XCTAssertGreaterThan(backSeen, 2000, "뒷면이 실제로 보이는 장면을 견주었다")
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
