import XCTest
import CoreGraphics
@testable import SpiraldayKit

/// 넘어가는 종이의 들린 부분(CurlSheetShape) — 제본 위에 그리는 것(스프링 고리)을 가릴 자리.
/// 셰이더가 실제로 그린 그림과 맞는지 (뒷면이 보이는 곳은 모두 안, 아래 장이 보이는 곳은 모두 밖) 화소로 견준다.
@MainActor
final class CurlSheetShapeTests: XCTestCase {
    private let daily = CGSize(width: 390, height: 611)
    private let weekly = CGSize(width: 611, height: 390)

    // MARK: 기하

    func testNothingIsLiftedAtRestOrOnceTurned() {
        for (edge, size) in [(BindingEdge.leading, daily), (.top, weekly)] {
            for dir in [FlipDirection.forward, .backward] {
                for p in [0.0, 1.0] {
                    XCTAssertTrue(CurlSheetShape.turn(edge: edge, pageSize: size, direction: dir, progress: p).isEmpty,
                                  "\(edge) \(dir) \(p): 넘김 앞 · 뒤에는 고리를 가리지 않는다 (끝에 고리가 튀지 않게)")
                }
            }
        }
    }

    /// 넘김 후반에는 들린 종이(뒷면)가 제본 쪽 띠 — 고리가 종이 위로 지나가는 자리 — 를 덮는다
    func testTheLiftedSheetCrossesTheBindingStrip() {
        let shape = CurlSheetShape.turn(edge: .leading, pageSize: daily, direction: .forward, progress: 0.7)
        XCTAssertFalse(shape.isEmpty)
        let ring = 18 * daily.width / PageKind.daily.design.width     // 구멍 가운데 · 앞 가닥 끝 (디자인 15)
        let covered = stride(from: 40.0, through: 600.0, by: 20.0).filter { shape.contains(CGPoint(x: ring, y: $0)) }
        XCTAssertGreaterThan(covered.count, 10, "0.7 에서 제본 쪽 띠 대부분이 넘어가는 종이 아래")
        // 주간: 제본이 위 — 같은 자리를 옮긴 것
        let top = CurlSheetShape.turn(edge: .top, pageSize: weekly, direction: .forward, progress: 0.7)
        let ringY = 18 * weekly.height / PageKind.weekly.design.height
        let coveredTop = stride(from: 40.0, through: 600.0, by: 20.0).filter { top.contains(CGPoint(x: $0, y: ringY)) }
        XCTAssertGreaterThan(coveredTop.count, 10)
    }

    func testOutlineStaysInsideThePageView() {
        for p in stride(from: 0.05, through: 0.95, by: 0.05) {
            let s = CurlSheetShape.turn(edge: .leading, pageSize: daily, direction: .forward, progress: p)
            for q in s.outline {
                XCTAssertTrue(q.x >= -0.01 && q.x <= daily.width + 0.01 && q.y >= -0.01 && q.y <= daily.height + 0.01,
                              "\(p): \(q) — 오버레이 밖(제본 너머)으로 미끄러진 종이는 그리지 않으니 가리지도 않는다")
            }
        }
    }

    // MARK: 셰이더와 견주기

    /// 움직이는 종이 = 빨강, 아래 장 = 파랑으로 그린 넘김에서:
    /// 뒷면(종이 뒤 색)이 보이는 화소는 모두 모양 안, 아래 장(파랑)이 보이는 화소는 모두 모양 밖 (윤곽 근처 1.5pt 는 뺀다).
    func testShapeMatchesTheRenderedSheet() throws {
        guard CurlGPU.shared?.pipeline != nil else { throw XCTSkip("Metal 없음") }
        var cases: [(String, BindingEdge, CGSize, FlipDirection, CGPoint)] = []
        for (edge, size, name) in [(BindingEdge.leading, daily, "daily"), (.top, weekly, "weekly")] {
            let f = CurlFrame(edge: edge, view: size)
            let arc = CurlArc(f)
            for p in [0.15, 0.35, 0.5, 0.62, 0.75, 0.88, 0.96] {
                for dir in [FlipDirection.forward, .backward] {
                    let x = f.fingerX(progress: p, forward: dir == .forward)
                    cases.append(("\(name) \(dir) \(p)", edge, size, dir,
                                  CGPoint(x: x / f.W, y: arc.y(atX: x) / f.H)))
                }
            }
            // 모서리를 잡고 끈 손가락 (호를 벗어난 자리)
            for finger in [CGPoint(x: 0.6, y: 0.95), CGPoint(x: 0.12, y: 0.7), CGPoint(x: -0.3, y: 0.9),
                           CGPoint(x: 0.9, y: 0.25), CGPoint(x: 0.4, y: 1.2)] {
                cases.append(("\(name) held \(finger)", edge, size, .forward, finger))
            }
        }
        var backSeen = 0
        for (name, edge, size, dir, finger) in cases {
            let scale: CGFloat = 2
            let red = try solid(size, scale, r: 255, g: 0, b: 0)
            let blue = try solid(size, scale, r: 0, g: 0, b: 255)
            let bitmaps = dir == .forward ? PageBitmaps(current: red, neighbor: blue) : PageBitmaps(current: blue, neighbor: red)
            let img = try XCTUnwrap(CurlController.renderStills(bitmaps, direction: dir, edge: edge, pageSize: size,
                                                                scale: scale, fingers: [finger]).first, name)
            let px = try pixels(img)
            let shape = CurlSheetShape.held(edge: edge, pageSize: size, finger: finger)
            var wrongBack = 0, wrongUnder = 0
            for y in stride(from: 1, to: px.height, by: 5) {
                for x in stride(from: 1, to: px.width, by: 5) {
                    let q = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                    let (r, g, b) = px[x, y]
                    let isBack = r > 140 && g > 140 && b > 120
                    let isUnder = b > 140 && r < 70 && g < 70
                    guard isBack || isUnder else { continue }
                    let inside = shape.contains(q)
                    if isBack { backSeen += 1 }
                    // 윤곽에서 1.5pt 안쪽은 안티에일리어싱 · 표본 차이라 뺀다 (어긋날 때만 잰다)
                    if isBack, !inside, distance(q, shape.outline) > 1.5 { wrongBack += 1 }
                    if isUnder, inside, distance(q, shape.outline) > 1.5 { wrongUnder += 1 }
                }
            }
            XCTAssertEqual(wrongBack, 0, "\(name): 뒷면이 보이는데 모양 밖 — 고리가 넘어가는 종이 위로 비친다")
            XCTAssertEqual(wrongUnder, 0, "\(name): 아래 장이 보이는데 모양 안 — 고리를 괜히 감춘다")
        }
        XCTAssertGreaterThan(backSeen, 1000, "뒷면이 실제로 보이는 장면을 견주었다")
    }

    // MARK: 도우미

    private func solid(_ size: CGSize, _ scale: CGFloat, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
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
        subscript(x: Int, y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    /// RGBA, 위에서부터 (화면 방향)
    private func pixels(_ img: CGImage) throws -> Pixels {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        try data.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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
