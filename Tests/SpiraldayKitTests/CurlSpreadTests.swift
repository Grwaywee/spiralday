import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import SpiraldayKit

/// 펼친 책(iPad) 넘김 — 말림 엔진의 펼침 모드: 물리(거울 착지) · 셰이더(첫 · 마지막 프레임이 쪽 그대로) ·
/// 컨트롤러 상태 기계(넘김 · 되돌림 · 반대 방향 · 연타 · 잡기) · AppState 의 넘김 가로채기.
/// 한 장 경로(맥)가 그대로인지는 SpiraldayKitTests 의 기존 시험과 Mac 앞뒤 스냅샷 비교가 본다.
@MainActor
final class CurlSpreadTests: XCTestCase {
    // MARK: 물리 — 코일을 도는 잎 (CurlHingeLeaf)

    private func frame(stiffness: Double = 1) -> CurlFrame {
        // 11" 가로 일간: 틈 반 5 · 구멍 = 틈 반 + 15u(5.6) · 쪽 478 × 749
        CurlFrame.spread(W: 5 + 478, H: 749, halfGutter: 5, stiffness: stiffness, coil: 5 + 5.6)
    }

    private func leaf(_ f: CurlFrame, progress p: Double) -> CurlHingeLeaf {
        CurlHingeLeaf(frame: f, finger: p >= 1 ? f.E : p <= 0 ? f.K : CurlVec(f.fingerX(progress: p, forward: true), f.H))
    }

    func testSinglePageFrameKeepsItsNumbers() {
        // 한 장(맥 · 폰)의 넘김 궤적은 펼침 모드를 더해도 같은 수
        let f = CurlFrame(edge: .leading, view: CGSize(width: 400, height: 626))
        XCTAssertEqual(f.landing, .behindBinding)
        XCTAssertEqual(f.E.x, -1.08 * 400, accuracy: 1e-9)
        XCTAssertEqual(f.c1, CurlVec(0.55 * 400, 0.75 * 626))
        XCTAssertEqual(f.c2, CurlVec(-0.35 * 400, 0.92 * 626))
        XCTAssertEqual(f.rMax, 40, accuracy: 1e-9)
        let fold = f.fold(CurlVec(120, 500))
        // 예전 식 그대로 계산한 값
        let D = f.K - CurlVec(120, 500)
        let angle = min(max(atan2(D.y, D.x), -CurlFrame.maxTilt), CurlFrame.maxTilt)
        let N = CurlVec(cos(angle), sin(angle))
        let dist = simd_dot(D, N)
        let t = (f.K.x - 120) / (2.08 * 400)
        let r0 = f.rMin + (f.rMax - f.rMin) * sin(.pi * t)
        let r = r0 * (1 - exp(-dist / (.pi * r0)))
        XCTAssertEqual(fold.radius, r, accuracy: 1e-12)
        XCTAssertEqual(fold.axisPoint.x, (f.K - N * ((dist + .pi * r) / 2)).x, accuracy: 1e-12)
        let g = CurlGlide.make(in: f, from: f.K, velocity: .zero, toTurned: true)!
        XCTAssertEqual(g.duration, CurlGlide.fullDuration * (0.34 + 0.66 * min(simd_length(f.E - f.K) / f.span, 1.15)), accuracy: 1e-12)
        XCTAssertEqual(g.timing.slope(1), CurlTiming.exitSlope, accuracy: 1e-9, "한 장은 고리 뒤로 미끄러져 나간다 (그대로)")
        let back = CurlGlide.make(in: f, from: CurlVec(100, 600), velocity: .zero, toTurned: false)!
        XCTAssertEqual(back.timing.slope(1), CurlTiming.landingSlope, accuracy: 1e-9)
    }

    func testLeafRestsAndLandsExactlyFlat() {
        let f = frame()
        XCTAssertEqual(f.landing, .mirrored)
        XCTAssertEqual(f.E, CurlVec(-f.W, f.H), "착지 = 반대쪽에 거울로 (−W′, H)")
        let rest = leaf(f, progress: 0), landed = leaf(f, progress: 1)
        XCTAssertEqual(rest.theta, 0)
        XCTAssertEqual(rest.bow, 0)
        XCTAssertEqual(rest.effect, 0, "쉬는 잎은 그림자 · 빛 없이 쪽 그대로")
        XCTAssertEqual(landed.theta, .pi)
        XCTAssertEqual(landed.effect, 0)
        for p in rest.profile {
            XCTAssertEqual(p.x, p.z, "쉬는 잎: 제자리에 평평 (X = s)")
            XCTAssertEqual(p.y, 0)
        }
        for p in landed.profile {
            XCTAssertEqual(p.x, -p.z, "내려앉은 잎: 반대쪽에 정확한 거울 (X = −s)")
            XCTAssertEqual(p.y, 0)
        }
        XCTAssertEqual(rest.profile.first?.z, 5, "종이는 틈 가장자리부터")
        XCTAssertEqual(rest.profile.last?.z, f.W, "자유 끝까지")
    }

    func testLeafTurnsAboutTheCoilWithoutSliding() {
        let f = frame()
        for p in stride(from: 0.05, through: 0.95, by: 0.05) {
            let l = leaf(f, progress: p)
            // 제본 가장자리 · 구멍은 늘 코일 축에서 같은 거리 (경첩이 미끄러지거나 골로 접히지 않는다)
            let edge = l.profile[0], hole = l.profile[1]
            XCTAssertEqual((edge.x * edge.x + edge.y * edge.y).squareRoot(), 5, accuracy: 1e-9, "\(p)")
            XCTAssertEqual((hole.x * hole.x + hole.y * hole.y).squareRoot(), 10.6, accuracy: 1e-9, "\(p)")
            XCTAssertEqual(hole.w, l.theta, accuracy: 1e-12, "구멍까지는 뻣뻣하게")
            // 자유 끝은 손가락 아래 (F.x)
            XCTAssertEqual(l.profile.last!.x, f.fingerX(progress: p, forward: true), accuracy: 1e-5 * f.W, "\(p)")
            XCTAssertGreaterThan(l.profile.last!.y, 0, "넘기는 동안 잎은 공중에")
            XCTAssertGreaterThan(l.effect, 0)
        }
    }

    func testBowLeadsWhileRisingAndTrailsWhileFalling() {
        let f = frame()
        let rising = leaf(f, progress: 0.25), falling = leaf(f, progress: 0.75), up = leaf(f, progress: 0.5)
        XCTAssertGreaterThan(rising.bow, 0.1, "제 쪽에서 들릴 때는 자유 끝이 앞선다")
        XCTAssertGreaterThan(rising.profile.last!.w, rising.theta)
        XCTAssertLessThan(falling.bow, -0.1, "반대쪽으로 떨어질 때는 자유 끝이 뒤따른다")
        XCTAssertLessThan(falling.profile.last!.w, falling.theta)
        XCTAssertLessThan(up.bow, 0, "서 있을 때는 자유 끝이 조금 뒤따른다 (옆에서 보아도 선이 아니라 종이)")
        XCTAssertGreaterThan(up.bow, -0.2)
        XCTAssertLessThanOrEqual(abs(rising.bow), CurlHingeLeaf.paperBow + 1e-9, "살짝 휠 뿐")
        let board = leaf(frame(stiffness: 2.4), progress: 0.25)
        XCTAssertLessThan(abs(board.bow), abs(rising.bow) / 4, "판(표지)은 거의 휘지 않는다")
    }

    func testSpreadGlideLandsWithoutAPop() throws {
        let f = frame()
        let g = try XCTUnwrap(CurlGlide.make(in: f, from: f.K, velocity: .zero, toTurned: true, full: CurlGlide.spreadDuration))
        XCTAssertEqual(g.point(1), f.E)
        XCTAssertEqual(g.timing.slope(1), 0, accuracy: 1e-9, "잎은 멈추듯 내려앉는다")
        // 잎의 각속도가 처음 · 끝에서 0 으로 (툭 들리거나 탁 떨어지지 않는다)
        func angle(_ tau: Double) -> Double { CurlHingeLeaf(frame: f, finger: g.point(tau)).theta }
        let dt = 0.002
        let start = (angle(dt) - angle(0)) / dt, end = (angle(1) - angle(1 - dt)) / dt
        var peak = 0.0
        for i in 1..<100 { let t = Double(i) / 100; peak = max(peak, (angle(t + dt) - angle(t)) / dt) }
        XCTAssertLessThan(start, peak * 0.25, "들리기 시작할 때 천천히")
        XCTAssertLessThan(end, peak * 0.35, "내려앉을 때 천천히")
        XCTAssertLessThan(g.point(0.7).x, 0, "궤적은 경첩을 넘어간다")
    }

    func testOutlineSeesTheLeafThroughThePerspective() {
        let f = frame()
        let flat = leaf(f, progress: 0).outline(from: 5)
        XCTAssertEqual(flat.map(\.x).min()!, 5, accuracy: 1e-9)
        XCTAssertEqual(flat.map(\.x).max()!, f.W, accuracy: 1e-9)
        XCTAssertEqual(flat.map(\.y).min()!, 0, accuracy: 1e-9)
        XCTAssertEqual(flat.map(\.y).max()!, f.H, accuracy: 1e-9)
        // 서 있는 잎은 카메라에 가까워 제본을 따라 조금 더 길어 보인다
        let up = leaf(f, progress: 0.45).outline(from: 5)
        XCTAssertLessThan(up.map(\.y).min()!, -1)
        XCTAssertGreaterThan(up.map(\.y).max()!, f.H + 1)
        XCTAssertGreaterThan(up.map(\.y).min()!, -0.12 * f.H, "넘침은 오버레이 bleed 안")
    }

    // MARK: 셰이더 — 첫 프레임 · 마지막 프레임이 살아 있는 쪽과 같은지

    private struct Book {
        let spread: CurlSpread
        let verso: CGImage, recto: CGImage, nextVerso: CGImage, nextRecto: CGImage
    }

    /// 단색에 가까운 쪽 그림 (가장자리 띠 · 글자 대신 줄무늬)
    private func page(_ size: CGSize, scale: CGFloat, hue: Double, stripes: Int) -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: hue, green: 0.4, blue: 1 - hue, alpha: 1))
        for i in 0..<stripes {
            ctx.fill(CGRect(x: w / 8, y: h * (i * 2 + 1) / (stripes * 2 + 1), width: w * 3 / 4 - i * 3, height: max(2, h / 60)))
        }
        ctx.fill(CGRect(x: 4, y: 4, width: w / 5, height: h / 9))
        return ctx.makeImage()!
    }

    private func book(horizontal: Bool) -> Book {
        // 11" 가로 일간 비슷한 크기의 작은 책 (테스트가 빨리 끝나게 반 크기)
        let p = horizontal ? CGSize(width: 240, height: 153) : CGSize(width: 153, height: 240)
        let gutter: CGFloat = 6, bleed: CGFloat = 20
        let verso: CGRect, recto: CGRect, overlay: CGSize, hinge: CGFloat
        if horizontal {
            verso = CGRect(x: 0, y: bleed, width: p.width, height: p.height)
            recto = CGRect(x: 0, y: bleed + p.height + gutter, width: p.width, height: p.height)
            overlay = CGSize(width: p.width + 2 * bleed, height: 2 * p.height + gutter + 2 * bleed)
            hinge = bleed + p.height + gutter / 2
        } else {
            verso = CGRect(x: 0, y: bleed, width: p.width, height: p.height)
            recto = CGRect(x: p.width + gutter, y: bleed, width: p.width, height: p.height)
            overlay = CGSize(width: 2 * p.width + gutter, height: p.height + 2 * bleed)
            hinge = p.width + gutter / 2
        }
        // 위 · 아래(가로 제본) 책은 along 축이 x: 두 쪽이 같은 minX 여야 한다
        let v2 = horizontal ? verso.offsetBy(dx: bleed, dy: 0) : verso
        let r2 = horizontal ? recto.offsetBy(dx: bleed, dy: 0) : recto
        let g = CurlSpread(axis: horizontal ? .horizontal : .vertical, overlaySize: overlay, hinge: hinge,
                           halfGutter: gutter / 2, versoRect: v2, rectoRect: r2)
        return Book(spread: g, verso: page(p, scale: 2, hue: 0.1, stripes: 5), recto: page(p, scale: 2, hue: 0.3, stripes: 7),
                    nextVerso: page(p, scale: 2, hue: 0.6, stripes: 9), nextRecto: page(p, scale: 2, hue: 0.9, stripes: 4))
    }

    /// overlay 이미지에서 rect 자리(pt)를 잘라 page 와 비교: 채널 최대 차이
    private func maxDiff(_ overlay: CGImage, _ rect: CGRect, scale: CGFloat, _ page: CGImage) -> Int {
        let crop = overlay.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                               width: rect.width * scale, height: rect.height * scale))!
        let a = rgba(crop), b = rgba(page)
        XCTAssertEqual(a.count, b.count)
        var m = 0
        for i in 0..<min(a.count, b.count) { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
        return m
    }

    private func rgba(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    private func maxAlpha(_ overlay: CGImage, _ rect: CGRect, scale: CGFloat) -> Int {
        let crop = overlay.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                               width: rect.width * scale, height: rect.height * scale))!
        let px = rgba(crop)
        var m = 0
        for i in stride(from: 3, to: px.count, by: 4) { m = max(m, Int(px[i])) }
        return m
    }

    private func checkTurn(horizontal: Bool, direction: FlipDirection, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let b = book(horizontal: horizontal)
        let fwd = direction == .forward
        // 앞으로: 드는 면 = recto, 뒷면 = 새 verso, 드러나는 쪽 = 새 recto / 뒤로: 드는 면 = verso, 뒷면 = 새 recto, 드러나는 = 새 verso
        let bitmaps = fwd ? SpreadBitmaps(front: b.recto, back: b.nextVerso, revealed: b.nextRecto)
                          : SpreadBitmaps(front: b.verso, back: b.nextRecto, revealed: b.nextVerso)
        let frames = CurlController.renderSpreadStills(bitmaps, spread: b.spread, direction: direction, scale: 2,
                                                       progress: [0, 0.35, 0.6, 1])
        XCTAssertEqual(frames.count, 4, file: file, line: line)
        let lift = fwd ? b.spread.rectoRect : b.spread.versoRect
        let opp = fwd ? b.spread.versoRect : b.spread.rectoRect
        // 첫 프레임: 드는 쪽 = 드는 면 그대로, 반대쪽은 투명 (살아 있는 쪽이 비친다)
        XCTAssertLessThanOrEqual(maxDiff(frames[0], lift, scale: 2, bitmaps.front), 1, "첫 프레임 = 드는 쪽", file: file, line: line)
        XCTAssertEqual(maxAlpha(frames[0], opp, scale: 2), 0, "첫 프레임의 반대쪽은 투명", file: file, line: line)
        // 마지막 프레임: 반대쪽 = 새 쪽(뒷면), 드는 쪽 자리 = 드러난 쪽 — 살아 있는 새 펼침과 같다
        XCTAssertLessThanOrEqual(maxDiff(frames[3], opp, scale: 2, bitmaps.back), 1, "마지막 프레임의 반대쪽 = 뒷면 쪽", file: file, line: line)
        XCTAssertLessThanOrEqual(maxDiff(frames[3], lift, scale: 2, bitmaps.revealed!), 1, "마지막 프레임의 드는 쪽 자리 = 드러난 쪽", file: file, line: line)
        // 가운데: 반대쪽에 무언가(뒷면 · 그림자)가 와 있다
        XCTAssertGreaterThan(maxAlpha(frames[2], opp, scale: 2), 0, "넘기는 중에는 반대쪽에도 장 · 그림자", file: file, line: line)
        write(frames, "spread_\(horizontal ? "weekly" : "daily")_\(fwd ? "fwd" : "back")")
    }

    func testSpreadTurnFirstAndLastFramesMatchTheLivePagesDaily() throws {
        try checkTurn(horizontal: false, direction: .forward)
        try checkTurn(horizontal: false, direction: .backward)
    }

    func testSpreadTurnFirstAndLastFramesMatchTheLivePagesWeekly() throws {
        try checkTurn(horizontal: true, direction: .forward)
        try checkTurn(horizontal: true, direction: .backward)
    }

    func testNothingRevealedLeavesTheDeskTransparent() throws {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let b = book(horizontal: false)
        // 마지막 장(뒤 속표지)을 넘겨 뒤표지를 덮는다: 드러나는 쪽 없음 → 오른쪽 자리는 책상
        let frames = CurlController.renderSpreadStills(SpreadBitmaps(front: b.recto, back: b.nextVerso, revealed: nil, stiffness: 2.4,
                                                                     rim: SIMD3(0.8, 0.3, 0.3)),
                                                       spread: b.spread, direction: .forward, scale: 2, progress: [1])
        XCTAssertEqual(maxAlpha(frames[0], b.spread.rectoRect, scale: 2), 0, "드러날 쪽이 없으면 투명 (책상)")
        XCTAssertLessThanOrEqual(maxDiff(frames[0], b.spread.versoRect, scale: 2, b.nextVerso), 1)
    }

    func testTimedSpreadFramesRender() throws {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let b = book(horizontal: false)
        let frames = CurlController.renderSpreadTurnFrames(SpreadBitmaps(front: b.recto, back: b.nextVerso, revealed: b.nextRecto),
                                                           spread: b.spread, direction: .forward, scale: 2, frameCount: 8)
        XCTAssertEqual(frames.count, 8)
        XCTAssertLessThanOrEqual(maxDiff(frames[7], b.spread.versoRect, scale: 2, b.nextVerso), 1)
    }

    // MARK: 컨트롤러 상태 기계

    private final class Host {
        var commits: [Int] = []
        var snapshots: [(FlipDirection, Int)] = []
    }

    private func controller(_ host: Host) throws -> CurlController {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let b = book(horizontal: false)
        let c = CurlController()
        _ = c.makeOverlayView()
        c.layout = .spread(b.spread)
        c.spreadSnapshot = { dir, n in
            host.snapshots.append((dir, n))
            return SpreadBitmaps(front: b.recto, back: b.nextVerso, revealed: b.nextRecto)
        }
        c.spreadCommit = { host.commits.append($0) }
        c.commit = { _ in XCTFail("펼침 모드는 commit 대신 spreadCommit") }
        return c
    }

    private func run(_ c: CurlController, seconds: Double) {
        var t = 0.0
        while t < seconds { c._testAdvance(1.0 / 120); t += 1.0 / 120 }
    }

    func testFlipCommitsOneSpread() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 1)
        XCTAssertEqual(c._testPhase, "gliding")
        XCTAssertEqual(c.spreadLift, .forward, "드는 쪽(recto)의 살아 있는 쪽을 숨기라고 알린다")
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [1])
        XCTAssertEqual(c._testPhase, "finishing")
        XCTAssertNil(c.spreadLift, "넘김이 끝나면 살아 있는 쪽을 다시 보인다")
    }

    func testBackwardFlipCommitsMinusOne() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.backward, spreads: 1)
        XCTAssertEqual(c.spreadLift, .backward)
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [-1])
    }

    func testOppositeDirectionBeforeHalfwayPutsTheSheetBack() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 1)
        run(c, seconds: 0.15)
        XCTAssertLessThan(c._testProgress ?? 1, 0.5)
        c.flip(.backward, spreads: 1)
        XCTAssertEqual(c._testCommitsGlide, false, "반 전이면 되돌림")
        XCTAssertNil(c._testPending)
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [], "되돌린 장은 넘기지 않는다")
    }

    func testOppositeDirectionAfterHalfwayTurnsBackAfterLanding() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 1)
        run(c, seconds: 0.5)
        XCTAssertGreaterThan(c._testProgress ?? 0, 0.5)
        c.flip(.backward, spreads: 1)
        XCTAssertEqual(c._testPending, -1, "반 넘었으면 내려앉은 뒤 반대로")
        run(c, seconds: 2.5)
        XCTAssertEqual(host.commits, [1, -1])
    }

    func testRepeatedTapsQueueOneAndHurry() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 1)
        run(c, seconds: 0.1)
        c.flip(.forward, spreads: 1)
        c.flip(.forward, spreads: 1)
        XCTAssertEqual(c._testPending, 1, "기다리는 넘김은 하나만")
        run(c, seconds: 3)
        XCTAssertEqual(host.commits, [1, 1])
    }

    func testJumpCommitsManySpreadsInOneSheet() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 138)
        XCTAssertEqual(host.snapshots.last?.1, 138)
        run(c, seconds: 1.5)
        XCTAssertEqual(host.commits, [138])
    }

    func testCatchingTheFallingSheetTracksTheFinger() throws {
        let host = Host()
        let c = try controller(host)
        let g = book(horizontal: false).spread
        c.flip(.forward, spreads: 1)
        run(c, seconds: 0.08)
        // 아직 거의 들리지 않은 장의 오른쪽 아래 모서리 근처
        let p = CGPoint(x: g.rectoRect.maxX - 30, y: g.rectoRect.maxY - 30)
        XCTAssertTrue(c.hitsTurningSheet(p))
        XCTAssertFalse(c.hitsTurningSheet(CGPoint(x: g.versoRect.minX + 5, y: g.versoRect.minY + 5)), "반대쪽 끝은 장이 아니다")
        XCTAssertTrue(c.grab(at: p))
        XCTAssertEqual(c._testPhase, "tracking")
        // 손가락을 오른쪽으로 되돌려 놓으면 제자리
        c.dragChanged(to: CGPoint(x: g.rectoRect.maxX - 2, y: g.rectoRect.maxY - 2))
        run(c, seconds: 0.2)
        c.dragEnded(at: CGPoint(x: g.rectoRect.maxX - 2, y: g.rectoRect.maxY - 2),
                    predictedEnd: CGPoint(x: g.rectoRect.maxX + 20, y: g.rectoRect.maxY))
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [], "잡아서 되돌린 장은 넘어가지 않는다")
    }

    func testDragPastHalfCommitsAndShortDragSettlesBack() throws {
        let host = Host()
        let c = try controller(host)
        let g = book(horizontal: false).spread
        let corner = CGPoint(x: g.rectoRect.maxX - 4, y: g.rectoRect.maxY - 4)
        // 손가락 속도는 실제 시각으로 잰다: 끌어 놓고 잠깐 멈춘 뒤 놓는다 (튕김 없이)
        c.dragBegan(.forward, at: corner, holdTop: false)
        Thread.sleep(forTimeInterval: 0.03)
        c.dragChanged(to: CGPoint(x: corner.x - 40, y: corner.y - 10))
        run(c, seconds: 0.3)
        Thread.sleep(forTimeInterval: 0.15)
        c.dragChanged(to: CGPoint(x: corner.x - 40, y: corner.y - 10))
        Thread.sleep(forTimeInterval: 0.03)
        c.dragEnded(at: CGPoint(x: corner.x - 40, y: corner.y - 10), predictedEnd: CGPoint(x: corner.x - 40, y: corner.y - 10))
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [], "조금 끌다 놓으면 제자리")
        // 다시: 경첩 너머까지 끌어 놓기
        run(c, seconds: 0.2)
        c.dragBegan(.forward, at: corner, holdTop: false)
        Thread.sleep(forTimeInterval: 0.03)
        c.dragChanged(to: CGPoint(x: g.versoRect.midX, y: corner.y - 30))
        run(c, seconds: 0.4)
        Thread.sleep(forTimeInterval: 0.15)
        c.dragChanged(to: CGPoint(x: g.versoRect.midX, y: corner.y - 30))
        Thread.sleep(forTimeInterval: 0.03)
        c.dragEnded(at: CGPoint(x: g.versoRect.midX, y: corner.y - 30), predictedEnd: CGPoint(x: g.versoRect.midX, y: corner.y - 30))
        run(c, seconds: 1.2)
        XCTAssertEqual(host.commits, [1])
    }

    func testTopCornerDragFlipsY() throws {
        let host = Host()
        let c = try controller(host)
        let g = book(horizontal: false).spread
        // 위 모서리를 잡고 아래로 조금 끌면 (holdTop) 위 모서리가 손을 따른다 → 장이 들린다
        c.dragBegan(.forward, at: CGPoint(x: g.rectoRect.maxX - 3, y: g.rectoRect.minY + 3), holdTop: true)
        c.dragChanged(to: CGPoint(x: g.rectoRect.maxX - 60, y: g.rectoRect.minY + 20))
        run(c, seconds: 0.3)
        XCTAssertGreaterThan(c._testProgress ?? 0, 0.05)
    }

    func testLayoutChangeEndsATurnAndCommitsIfItWasGoing() throws {
        let host = Host()
        let c = try controller(host)
        c.flip(.forward, spreads: 1)
        run(c, seconds: 0.2)
        c.layout = .page
        XCTAssertEqual(host.commits, [1], "회전 · 크기 바뀜: 넘기던 장은 바로 넘긴다")
        XCTAssertNil(c.spreadLift)
    }

    // MARK: AppState 의 넘김 가로채기

    private final class Router: PageTurnRouter {
        var handles = true
        var turns: [FlipDirection] = []
        var todays = 0
        var shows: [Int] = []
        func routes(_ kind: PageKind) -> Bool { handles }
        func canTurn(_ dir: FlipDirection) -> Bool { dir == .forward }
        func turn(_ dir: FlipDirection) { turns.append(dir) }
        func goToday() { todays += 1 }
        func show(index: Int) { shows.append(index) }
    }

    func testRouterTakesFlipsTodayAndFrontPages() {
        let store = PlannerStore(inMemory: true)
        store.useDemoBook(start: Dates.add(days: -42, to: Dates.weekStart(Date())))
        let state = AppState(kind: .daily)
        state.store = store
        let r = Router()
        state.turnRouter = r
        state.dayIndex = state.dayRange.lowerBound   // 책 첫날 (끝 진동 검사보다 라우터가 먼저)
        state.flip(.backward)
        state.flip(.forward)
        XCTAssertEqual(r.turns, [.backward, .forward])
        state.goToday()
        XCTAssertEqual(r.todays, 1)
        state.showFront(.cover)
        XCTAssertEqual(r.shows, [state.frontIndex(.cover, .daily)])
        XCTAssertTrue(state.canFlip(.forward))
        XCTAssertFalse(state.canFlip(.backward))
        // 라우터가 이 쪽을 넘기지 않으면 지금처럼
        r.handles = false
        XCTAssertEqual(state.canFlip(.backward), state.canStep(-1))
        state.focus(index: state.dayRange.lowerBound + 3)
        XCTAssertEqual(state.dayIndex, state.dayRange.lowerBound + 3)
    }

    func testNoRouterKeepsSinglePageBehaviour() {
        let state = AppState(kind: .daily)
        XCTAssertNil(state.turnRouter)
        XCTAssertEqual(state.canFlip(.forward), state.canStep(1))
        XCTAssertEqual(state.curl.layout, .page)
    }

    // MARK: verso 종이

    func testVersoHolesMirrorToTheOtherEdge() {
        let d = SpiralBinding.holes(.daily), dv = SpiralBinding.holes(.daily, side: .verso)
        XCTAssertEqual(SpiralBinding.holes(.daily, side: .recto), d)
        XCTAssertEqual(dv.count, d.count)
        XCTAssertEqual(dv[0].minX, PageKind.daily.design.width - d[0].maxX, accuracy: 1e-9)
        XCTAssertEqual(dv[0].minY, d[0].minY)
        let w = SpiralBinding.holes(.weekly), wv = SpiralBinding.holes(.weekly, side: .verso)
        XCTAssertEqual(wv[3].minY, PageKind.weekly.design.height - w[3].maxY, accuracy: 1e-9)
        XCTAssertEqual(wv[3].minX, w[3].minX)
    }

    // MARK: 그림 남기기

    private func write(_ frames: [CGImage], _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SPIRALDAY_RENDER_DIR"].map({ URL(fileURLWithPath: $0) }) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, img) in frames.enumerated() {
            let url = dir.appendingPathComponent(String(format: "%@_%02d.png", name, i))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
