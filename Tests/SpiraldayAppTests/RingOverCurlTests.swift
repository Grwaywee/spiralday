import XCTest
import SwiftUI
import AppKit
@testable import SpiraldayKit
@testable import Spiralday

/// 회귀 (사장님 피드백 B, Mac): 넘어가는 종이 위로 스프링 고리가 비쳤다 — 고리 전체가 본 창 위의 자식 창(.above)에 있어서
/// 불투명한 넘김 오버레이보다 늘 위에 그려졌다. 고친 것: 자식 창은 종이 밖 고리만 그리고(종이와 겹치지 않음),
/// 종이 위 앞 가닥은 본 창 안 넘김 오버레이 아래와 넘김 스냅숏(지금 장 · 다음 장)에 굽는다 (watchLiftedSheet 는 쓰지 않음).
///
/// 여기서는 Mac 창 쌓기를 그대로 합성한다: 넘김 프레임 = Kit 셰이더(renderStills)가 앱이 실제로 넘기는 스냅숏(RingSnapshotBaker)으로
/// 그린 것, 그 위에 고리 창(RingWindowController.frame) — 그리고 들린 종이(CurlSheetShape) 안에 고리 화소가 하나도 없는지 본다.
@MainActor
final class RingOverCurlTests: XCTestCase {
    private let daily = CGSize(width: 560, height: 877)
    private let weekly = CGSize(width: 1270, height: 811)
    private let scale: CGFloat = 2

    // MARK: 창 자리

    /// 고리 창은 종이 사각형과 겹치지 않는다 (넘김 오버레이는 종이 밖에 그리지 않으니, 겹치지만 않으면 들린 종이를 가릴 수 없다)
    func testTheRingWindowNeverOverlapsThePaper() {
        let pages = [NSRect(x: 100, y: 80, width: 560, height: 877), NSRect(x: 0.5, y: 33.5, width: 358, height: 560.7),
                     NSRect(x: 300, y: 200, width: 1270, height: 811), NSRect(x: -20, y: 10, width: 860, height: 549),
                     NSRect(x: 7, y: 7, width: 1760, height: 1124)]
        for page in pages {
            for kind in [PageKind.daily, .weekly, .home] {
                let ring = RingWindowController.frame(page: page, kind: kind, part: .outsidePaper)
                let overlap = ring.intersection(page)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 1e-6,
                              "\(kind) \(page): 고리 창 \(ring) 이 종이와 겹친다 — 넘어가는 종이 위로 고리가 비친다")
                XCTAssertGreaterThan(ring.width * ring.height, 0)
                // 종이 가장자리에 딱 붙어 있다 (틈이 생기면 고리가 끊겨 보인다)
                switch kind.edge {
                case .leading: XCTAssertEqual(ring.maxX, page.minX, accuracy: 1e-9)
                case .top: XCTAssertEqual(ring.minY, page.maxY, accuracy: 1e-9)
                }
                // 처음 안내 창(전부)은 예전 그대로 종이 안쪽까지
                let all = RingWindowController.frame(page: page, kind: kind, part: .all)
                XCTAssertTrue(all.contains(ring))
            }
        }
    }

    /// 나눠 그린 고리(종이 밖 창 + 종이 위 가닥)가 예전 한 장짜리 고리 띠와 화소까지 같다 (모양은 바뀌지 않는다)
    func testSplitRingsLookExactlyLikeTheWholeStrip() throws {
        for (kind, page) in [(PageKind.daily, daily), (.weekly, weekly)] {
            let u = page.width / kind.design.width
            let out = (RingWindowController.outside * u).rounded(.up)
            let ins = (RingWindowController.inside * u).rounded(.up)
            let leading = kind.edge == .leading
            let stripSize = leading ? CGSize(width: out + ins, height: page.height) : CGSize(width: page.width, height: out + ins)
            let model = RingModel()
            model.kind = kind
            model.u = u
            model.outside = out
            let whole = try render(RingStrip(model: model, part: .all).frame(width: stripSize.width, height: stripSize.height),
                                   stripSize)
            // 새로: 종이 밖 창(폭 out) + 본 창 안 가닥(종이 크기 캔버스, 가장자리 ins 만큼만 본다)
            let outSize = leading ? CGSize(width: out, height: page.height) : CGSize(width: page.width, height: out)
            let outside = try render(RingWindowContent(model: model, shade: RingShade(), part: .outsidePaper)
                .frame(width: outSize.width, height: outSize.height), outSize)
            let over = try render(RingStrandsOverPaper(kind: kind, size: page), page)
            var worst = 0, ink = 0, off = 0
            for y in 0..<whole.height {
                for x in 0..<whole.width {
                    let w = whole[x, y]
                    let n: (Int, Int, Int, Int)
                    if leading {
                        n = x < outside.width ? outside[x, y] : over[x - outside.width, y]
                    } else {
                        n = y < outside.height ? outside[x, y] : over[x, y - outside.height]
                    }
                    if w.3 > 0 { ink += 1 }
                    let d = max(abs(w.0 - n.0), abs(w.1 - n.1), abs(w.2 - n.2), abs(w.3 - n.3))
                    if d > 4 { off += 1 }
                    worst = max(worst, d)
                }
            }
            XCTAssertGreaterThan(ink, 2000, "\(kind): 고리가 그려졌다")
            // 그리는 자리(평행 이동)만 달라 안티에일리어싱 가장자리 몇 화소가 몇 단계 다를 수 있다 — 모양 · 이음매 · 그림자는 같다
            XCTAssertLessThanOrEqual(worst, 24, "\(kind): 나눈 고리가 예전 띠와 다르다 (이음매 · 그림자)")
            XCTAssertLessThan(Double(off), Double(ink) * 0.01, "\(kind): 다른 화소가 너무 많다")
        }
    }

    /// 플래너 창이 실제로 그렇게 붙인다: 자식 창은 종이 밖 고리만, 넘김 스냅숏에는 종이 위 가닥이 구워져 있다
    func testThePlannerWindowSplitsTheRingsAndBakesThemIntoTheTurn() throws {
        let store = PlannerStore(inMemory: true)
        store.fillSample(around: Date())
        let state = AppState(kind: .daily)
        state.store = store
        let wc = MainWindowController(store: store, state: state)
        XCTAssertEqual(wc.ringPart, .outsidePaper, "플래너 창의 고리 창이 종이 위까지 그리면 넘어가는 종이 위로 고리가 비친다")
        state.curl.pageSize = daily
        let bitmaps = try XCTUnwrap(state.curl.snapshot?(1))
        // 넘김을 다시 시작해도 굽지 않는다: 쪽 그림을 그릴 때 구워 둔 캐시의 그림 그대로 (미리 그리기 때 굽는다 — 넘김 첫 프레임이 끊기지 않게)
        let again = try XCTUnwrap(state.curl.snapshot?(1))
        XCTAssertTrue(again.current === bitmaps.current && again.neighbor === bitmaps.neighbor, "넘김을 시작할 때마다 다시 굽는다")
        let s = wc.window.backingScaleFactor
        let snap = PageSnapshotter(store: store, state: state)
        let plain = try XCTUnwrap(snap.image(kind: .daily, index: state.index, size: daily, scale: s))
        let plainNext = try XCTUnwrap(snap.image(kind: .daily, index: state.index + 1, size: daily, scale: s))
        let a = try pixels(plain), b = try pixels(bitmaps.current), m = try pixels(plainNext), n = try pixels(bitmaps.neighbor)
        XCTAssertEqual(a.width, b.width)
        let band = Int(36 * daily.width / PageKind.daily.design.width * s)
        var strands = 0, neighborStrands = 0, elsewhere = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = a[x, y], q = b[x, y]
                let d = max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2))
                if d > 60 { if x < band { strands += 1 } else { elsewhere += 1 } }
                let o = m[x, y], r = n[x, y]
                if max(abs(o.0 - r.0), abs(o.1 - r.1), abs(o.2 - r.2)) > 60 { if x < band { neighborStrands += 1 } else { elsewhere += 1 } }
            }
        }
        let least = Int(150 * s * s)
        XCTAssertGreaterThan(strands, least, "지금 장 스냅숏에 종이 위 고리 앞 가닥이 구워져 있다")
        XCTAssertGreaterThan(neighborStrands, least, "다음 장 스냅숏에도")
        XCTAssertEqual(elsewhere, 0, "가닥은 제본 쪽 띠에만")
    }

    // MARK: 넘김 위 고리

    /// 일간 · 주간, 앞 · 뒤로, 넘김 0.1–0.9: 들린 종이 안에는 고리 화소가 없고, 평평한 종이 위에는 고리가 그대로 보인다
    func testTheTurningSheetCoversTheRings() throws {
        guard CurlGPU.shared?.pipeline != nil else { throw XCTSkip("Metal 없음") }
        let outDir = ProcessInfo.processInfo.environment["SPIRALDAY_RING_FRAMES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outDir { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
        var covered = 0, visibleOnFlat = 0
        for (kind, page) in [(PageKind.daily, daily), (.weekly, weekly)] {
            let store = PlannerStore(inMemory: true)
            store.fillSample(around: Date())
            let state = AppState(kind: kind)
            state.store = store
            let snap = PageSnapshotter(store: store, state: state)
            let baker = RingSnapshotBaker()
            // 앱이 실제로 넘기는 그림 (WindowController: 쪽 그림을 그릴 때 가닥을 구워 캐시에 — state.curl.snapshot 은 그 캐시에서)
            let bakedSnap = PageSnapshotter(store: store, state: state)
            bakedSnap.decorate = { img, k, size, sc in baker.bake(img, kind: k, size: size, scale: sc) }
            // 고리 앞 가닥이 있는 자리 (가닥만 그린 그림의 불투명한 화소)
            let mask = try pixels(XCTUnwrap(RingSnapshotBaker.strands(kind: kind, size: page, scale: scale)))
            let frame = CurlFrame(edge: kind.edge, view: page)
            let arc = CurlArc(frame)
            for dir in [FlipDirection.forward, .backward] {
                let cur = try XCTUnwrap(snap.image(kind: kind, index: state.index, size: page, scale: scale))
                let nb = try XCTUnwrap(snap.image(kind: kind, index: state.index + dir.delta, size: page, scale: scale))
                let bakedCur = try XCTUnwrap(bakedSnap.image(kind: kind, index: state.index, size: page, scale: scale))
                let bakedNb = try XCTUnwrap(bakedSnap.image(kind: kind, index: state.index + dir.delta, size: page, scale: scale))
                XCTAssertTrue(bakedSnap.image(kind: kind, index: state.index, size: page, scale: scale) === bakedCur,
                              "같은 장은 같은 그림 (말림 텍스처 캐시가 다시 올리지 않게)")
                // 띠만 잘라 얹어도 가닥 그림 전체를 얹은 것과 화소 하나까지 같다 (같은 쪽 그림에 — 쪽 그림을 두 번 그리면 1/255 쯤 다를 수 있다)
                let whole = try XCTUnwrap(RingSnapshotBaker.compose(cur, XCTUnwrap(RingSnapshotBaker.strands(kind: kind, size: page, scale: scale))))
                let (p1, p2) = (try pixels(whole), try pixels(baker.bake(cur, kind: kind, size: page, scale: scale)))
                var differ = 0
                for y in 0..<p1.height { for x in 0..<p1.width where p1[x, y] != p2[x, y] { differ += 1 } }
                XCTAssertEqual(differ, 0, "\(kind) \(dir): 잘라 얹은 가닥이 전체를 얹은 것과 다르다")
                let progresses = stride(from: 0.1, through: 0.9001, by: 0.1).map { $0 }
                let fingers = progresses.map { p -> CGPoint in
                    let x = frame.fingerX(progress: p, forward: dir == .forward)
                    return CGPoint(x: x / frame.W, y: arc.y(atX: x) / frame.H)
                }
                let plainFrames = CurlController.renderStills(PageBitmaps(current: cur, neighbor: nb), direction: dir,
                                                              edge: kind.edge, pageSize: page, scale: scale, fingers: fingers)
                let bakedFrames = CurlController.renderStills(PageBitmaps(current: bakedCur, neighbor: bakedNb), direction: dir,
                                                              edge: kind.edge, pageSize: page, scale: scale, fingers: fingers)
                XCTAssertEqual(plainFrames.count, progresses.count)
                XCTAssertEqual(bakedFrames.count, progresses.count)
                for (i, p) in progresses.enumerated() {
                    let name = "\(kind) \(dir) \(String(format: "%.1f", p))"
                    let shape = CurlSheetShape.turn(edge: kind.edge, pageSize: page, direction: dir, progress: p)
                    // 들린 종이 안쪽 (윤곽에서 1.5pt 안 — 안티에일리어싱 · 표본 차이는 뺀다)을 화소 마스크로
                    let lifted = try insideMask(shape, page: page)
                    let plain = try pixels(plainFrames[i]), baked = try pixels(bakedFrames[i])
                    var ringsUnderSheet = 0
                    let band = 50 * page.width / kind.design.width      // 고리가 지나가는 제본 쪽 띠 (디자인 50)
                    for y in stride(from: 0, to: plain.height, by: 1) {
                        for x in stride(from: 0, to: plain.width, by: 1) {
                            let q = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                            let across = kind.edge == .leading ? q.x : q.y
                            // 띠 밖은 성기게 (가닥의 비침은 들린 종이 어디에나 생길 수 있어 띠 밖도 본다)
                            if across > band, x % 3 != 0 || y % 3 != 0 { continue }
                            let a = plain[x, y], b = baked[x, y]
                            let diff = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                            let ringHere = mask[x, y].3 > 128
                            if lifted[y * plain.width + x] > 128 {
                                // 들린 종이 안: 고리는 없다. 뒷면에 비치는 잉크(셰이더가 6.5% 로 거울처럼 비춤)만 허락한다
                                if diff > 24 { ringsUnderSheet += 1 }
                                if ringHere { covered += 1 }
                            } else if diff > 60, !shape.contains(q) {
                                visibleOnFlat += 1
                            }
                        }
                    }
                    XCTAssertEqual(ringsUnderSheet, 0, "\(name): 들린 종이 위로 고리가 비친다")
                    if let outDir {
                        try write(stack(baked: bakedFrames[i], kind: kind, page: page),
                                  outDir.appendingPathComponent("\(kind.rawValue)_\(dir)_\(String(format: "%.1f", p)).png"))
                    }
                }
            }
        }
        XCTAssertGreaterThan(covered, 2000, "들린 종이가 고리 자리를 실제로 덮는 장면을 견주었다")
        XCTAssertGreaterThan(visibleOnFlat, 5000, "평평한 종이 위의 고리는 넘기는 동안에도 보인다 (스냅숏에 구웠다)")
    }

    // MARK: 둘러보기 막

    /// 둘러보기의 어두운 막은 본 창 안에만 있다 — 종이 밖 고리 창도 같은 막 색으로 덮이고, 투명한 곳(바탕화면)은 그대로
    func testTheTourCurtainDimsTheRingsOutsideThePaper() throws {
        let kind = PageKind.daily
        let u = daily.width / kind.design.width
        let out = (RingWindowController.outside * u).rounded(.up)
        let size = CGSize(width: out, height: daily.height)
        let model = RingModel()
        model.kind = kind
        model.u = u
        model.outside = out
        let lit = RingShade(), dim = RingShade()
        dim.dimmed = true
        let a = try render(RingWindowContent(model: model, shade: lit, part: .outsidePaper).frame(width: size.width, height: size.height), size)
        let b = try render(RingWindowContent(model: model, shade: dim, part: .outsidePaper).frame(width: size.width, height: size.height), size)
        // 막 색 (1D1A26, 50%) 을 불투명한 고리 화소 위에 얹은 값
        let curtain = (0x1D, 0x1A, 0x26)
        var opaque = 0, checked = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = a[x, y], q = b[x, y]
                if p.3 == 0 {
                    XCTAssertEqual(q.0 + q.1 + q.2 + q.3, 0, "막이 투명한 곳(바탕화면)을 칠하면 안 된다 (\(x), \(y))")
                    continue
                }
                XCTAssertLessThanOrEqual(abs(p.3 - q.3), 2, "막은 고리의 모양(불투명도)을 바꾸지 않는다 (\(x), \(y))")
                guard p.3 == 255 else { continue }
                opaque += 1
                let want = ((p.0 + curtain.0) / 2, (p.1 + curtain.1) / 2, (p.2 + curtain.2) / 2)
                if abs(q.0 - want.0) <= 3, abs(q.1 - want.1) <= 3, abs(q.2 - want.2) <= 3 { checked += 1 }
            }
        }
        XCTAssertGreaterThan(opaque, 500)
        XCTAssertEqual(checked, opaque, "종이 밖 고리도 종이 위 막과 같은 색 · 같은 비율로 어두워진다")
    }

    // MARK: 도우미

    /// 넘김 프레임(본 창) 위에 고리 창(종이 밖)을 Mac 처럼 쌓은 그림 — SPIRALDAY_RING_FRAMES_DIR 로 눈으로 볼 때만
    private func stack(baked: CGImage, kind: PageKind, page: CGSize) throws -> CGImage {
        let pageRect = NSRect(origin: .zero, size: page)
        let ringRect = RingWindowController.frame(page: pageRect, kind: kind, part: .outsidePaper)
        let model = RingModel()
        model.kind = kind
        model.u = page.width / kind.design.width
        model.outside = (RingWindowController.outside * model.u).rounded(.up)
        let ring = try XCTUnwrap(ImageRenderer(content: RingWindowContent(model: model, shade: RingShade(), part: .outsidePaper)
            .frame(width: ringRect.width, height: ringRect.height)).with(scale: scale).cgImage)
        let all = pageRect.union(ringRect)
        let w = Int(all.width * scale), h = Int(all.height * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func place(_ r: NSRect) -> CGRect {
            CGRect(x: (r.minX - all.minX) * scale, y: (r.minY - all.minY) * scale, width: r.width * scale, height: r.height * scale)
        }
        ctx.draw(baked, in: place(pageRect))
        ctx.draw(ring, in: place(ringRect))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func render<V: View>(_ view: V, _ size: CGSize) throws -> Pixels {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = scale
        r.isOpaque = false
        return try pixels(XCTUnwrap(r.cgImage))
    }

    private func write(_ img: CGImage, _ url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]
        /// RGBA (premultiplied), 위에서부터
        subscript(x: Int, y: Int) -> (Int, Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
    }

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

    /// 들린 모양 안쪽에서 윤곽까지 1.5pt 넘게 떨어진 화소 = 255 (위에서부터, 페이지 화소 크기)
    private func insideMask(_ shape: CurlSheetShape, page: CGSize) throws -> [UInt8] {
        let w = Int(page.width * scale), h = Int(page.height * scale)
        var data = [UInt8](repeating: 0, count: w * h)
        guard !shape.isEmpty else { return data }
        try data.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            // 화면 방향(위가 0)으로
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.addPath(shape.path)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath()
            ctx.addPath(shape.path)
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(3)
            ctx.strokePath()
        }
        return data
    }
}

private extension ImageRenderer {
    @MainActor
    func with(scale: CGFloat) -> ImageRenderer {
        self.scale = scale
        isOpaque = false
        return self
    }
}
