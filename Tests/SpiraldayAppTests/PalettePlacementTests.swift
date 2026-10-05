import XCTest
import AppKit
@testable import SpiraldayKit
@testable import Spiralday

/// 팔레트 · 떠 있는 알림이 화면 밖으로 나가지 않는다 (사장님 피드백 J: 팝오버 · 메뉴가 화면 밖으로 나감 — Mac 지킴이).
/// PalettePlacement.place 는 펼친 팔레트 패널의 자리를 정하고(고른 쪽 → 자리가 없으면 반대쪽 → 둘 다 없으면 덜 모자란 쪽에 화면 안으로),
/// SyncLiveHintPlacement 는 "다른 기기에서 쓰는 중" 알림을 칸 위(모자라면 아래)에 화면 안으로 놓는다.
/// 좌표는 AppKit 화면 좌표 (아래가 0).
@MainActor
final class PalettePlacementTests: XCTestCase {
    /// 보통 Mac 화면의 보이는 곳 (메뉴 막대 · Dock 을 뺀 곳)
    private let big = NSRect(x: 0, y: 70, width: 1728, height: 1012)
    /// 작은 화면 (11" · 확대한 화면 · 낮은 해상도 외장 모니터)
    private let small = NSRect(x: 0, y: 0, width: 1024, height: 615)
    private let tall = CGSize(width: 104, height: 560)      // 세로 팔레트 (왼쪽 · 오른쪽)
    private let wide = CGSize(width: 560, height: 104)      // 가로 팔레트 (위 · 아래)

    private func size(_ side: PaletteEdge) -> CGSize { side.isVertical ? tall : wide }

    /// 종이에서 팔레트까지 (틈 + 스프링이 그 쪽에 있으면 스프링만큼)
    private func gap(_ side: PaletteEdge, _ kind: PageKind, _ page: NSRect) -> CGFloat {
        MainWindowController.paletteGap + PalettePlacement.ringClearance(side, kind: kind, pageWidth: page.width)
    }

    private func assertInside(_ r: NSRect, _ vis: NSRect, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minX, vis.minX - 0.5, "\(label): 왼쪽이 화면 밖 \(r) / \(vis)", file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, vis.maxX + 0.5, "\(label): 오른쪽이 화면 밖 \(r) / \(vis)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, vis.minY - 0.5, "\(label): 아래가 화면 밖 \(r) / \(vis)", file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, vis.maxY + 0.5, "\(label): 위가 화면 밖 \(r) / \(vis)", file: file, line: line)
    }

    // MARK: 고른 쪽

    /// 자리가 넉넉하면 고른 쪽, 그 가장자리의 가운데에 종이에서 틈(+ 스프링)만큼 떨어져 붙는다
    func testPrefersTheChosenSideWhenThereIsRoom() {
        for kind in [PageKind.daily, .weekly] {
            let page = NSRect(x: 520, y: 220, width: kind == .daily ? 460 : 820, height: kind == .daily ? 720 : 524)
            for side in PaletteEdge.allCases {
                let (r, got) = PalettePlacement.place(size(side), page: page, visible: big, preferred: side, kind: kind)
                XCTAssertEqual(got, side, "\(kind) \(side)")
                let d = gap(side, kind, page)
                switch side {
                case .right: XCTAssertEqual(r.minX, (page.maxX + d).rounded(), accuracy: 0.5)
                case .left: XCTAssertEqual(r.maxX, (page.minX - d).rounded(), accuracy: 0.5)
                case .top: XCTAssertEqual(r.minY, (page.maxY + d).rounded(), accuracy: 0.5)
                case .bottom: XCTAssertEqual(r.maxY, (page.minY - d).rounded(), accuracy: 0.5)
                }
                if side.isVertical { XCTAssertEqual(r.midY, page.midY, accuracy: 1) } else { XCTAssertEqual(r.midX, page.midX, accuracy: 1) }
                XCTAssertTrue(r.intersection(page).isEmpty, "\(kind) \(side): 종이를 가리지 않는다")
                assertInside(r, big, "\(kind) \(side)")
            }
        }
    }

    /// 왼쪽 자리 · 일간: 스프링이 왼쪽으로 튀어나와 있어서 스프링만큼 더 띄운다 (팔레트가 고리를 덮지 않게)
    func testTheLeftSideKeepsClearOfTheRings() {
        let page = NSRect(x: 600, y: 200, width: 460, height: 720)
        let (r, side) = PalettePlacement.place(tall, page: page, visible: big, preferred: .left, kind: .daily)
        XCTAssertEqual(side, .left)
        let ring = RingWindowController.frame(page: page, kind: .daily, part: .outsidePaper)
        XCTAssertGreaterThan(PalettePlacement.ringClearance(.left, kind: .daily, pageWidth: page.width), 0)
        XCTAssertLessThanOrEqual(r.maxX, ring.minX - MainWindowController.paletteGap + 0.5, "팔레트와 고리 사이에도 틈")
        XCTAssertEqual(PalettePlacement.ringClearance(.right, kind: .daily, pageWidth: page.width), 0, "스프링이 없는 쪽은 그대로")
        // 주간은 위가 스프링 쪽
        let wpage = NSRect(x: 300, y: 120, width: 820, height: 524)
        let (t, tside) = PalettePlacement.place(wide, page: wpage, visible: big, preferred: .top, kind: .weekly)
        XCTAssertEqual(tside, .top)
        let wring = RingWindowController.frame(page: wpage, kind: .weekly, part: .outsidePaper)
        XCTAssertGreaterThanOrEqual(t.minY, wring.maxY + MainWindowController.paletteGap - 0.5)
    }

    // MARK: 화면 가장자리

    /// 종이가 화면 가장자리에 붙어 있으면 반대쪽으로 넘어간다 (그 쪽에 자리가 있으면)
    func testFlipsToTheOtherSideAtTheScreenEdge() {
        let cases: [(PaletteEdge, NSRect, PageKind)] = [
            (.right, NSRect(x: big.maxX - 470, y: 200, width: 460, height: 720), .daily),
            (.left, NSRect(x: big.minX + 4, y: 200, width: 460, height: 720), .daily),
            (.top, NSRect(x: 300, y: big.maxY - 530, width: 820, height: 524), .weekly),
            (.bottom, NSRect(x: 300, y: big.minY + 2, width: 820, height: 524), .weekly),
        ]
        for (side, page, kind) in cases {
            let (r, got) = PalettePlacement.place(size(side), page: page, visible: big, preferred: side, kind: kind)
            XCTAssertEqual(got, side.opposite, "\(side): 자리가 없으면 반대쪽")
            XCTAssertTrue(r.intersection(page).isEmpty, "\(side): 반대쪽에서도 종이를 가리지 않는다")
            assertInside(r, big, "\(side)")
        }
    }

    /// 쪽을 바꾸는 움직임(morph) 도중에는 반대쪽으로 튀지 않고 그 쪽에서 화면 안으로만
    func testDoesNotFlipWhileMorphing() {
        let page = NSRect(x: big.maxX - 470, y: 200, width: 460, height: 720)
        let (r, side) = PalettePlacement.place(tall, page: page, visible: big, preferred: .right, kind: .daily, flips: false)
        XCTAssertEqual(side, .right)
        XCTAssertEqual(r.maxX, big.maxX, accuracy: 0.5, "화면 안으로 민다")
        assertInside(r, big, "morph")
    }

    // MARK: 작은 화면

    /// 작은 화면: 양쪽 다 자리가 없으면 덜 모자란 쪽에 화면 안으로 (종이에 조금 겹친다 — 그래도 팔레트는 다 보인다)
    func testSmallScreenKeepsThePaletteOnScreen() {
        let page = NSRect(x: 60, y: 20, width: 380, height: 595)    // 일간 종이가 화면 높이를 다 쓴다
        for side in [PaletteEdge.right, .left] {
            let (r, got) = PalettePlacement.place(tall, page: page.offsetBy(dx: side == .right ? 520 : 0, dy: 0), visible: small,
                                                  preferred: side, kind: .daily)
            assertInside(r, small, "작은 화면 \(side) → \(got)")
        }
        let wpage = NSRect(x: 40, y: 30, width: 944, height: 560)   // 주간 종이가 화면을 거의 다 쓴다
        for side in [PaletteEdge.top, .bottom] {
            let (r, got) = PalettePlacement.place(wide, page: wpage, visible: small, preferred: side, kind: .weekly)
            assertInside(r, small, "작은 화면 \(side) → \(got)")
        }
    }

    /// 팔레트가 화면보다 길면 위(세로) · 왼쪽(가로)을 맞춘다 — 형광펜 이름 · 첫 도구가 늘 보이게
    func testAPaletteLongerThanTheScreenAlignsItsStart() {
        let longer = CGSize(width: 104, height: small.height + 120)
        let page = NSRect(x: 300, y: 10, width: 380, height: 595)
        let (r, side) = PalettePlacement.place(longer, page: page, visible: small, preferred: .right, kind: .daily)
        XCTAssertEqual(side, .right)
        XCTAssertEqual(r.maxY, small.maxY - 8, accuracy: 0.5, "위를 맞춘다")
        let longerH = CGSize(width: small.width + 100, height: 104)
        let (h, _) = PalettePlacement.place(longerH, page: NSRect(x: 10, y: 300, width: 900, height: 200), visible: small,
                                            preferred: .bottom, kind: .weekly)
        XCTAssertEqual(h.minX, small.minX + 8, accuracy: 0.5, "왼쪽을 맞춘다")
    }

    /// 실제로 잰 팔레트 (형광펜 12개 — 가장 긴 팔레트)도 흔한 작은 화면(1280 × 800 의 보이는 곳)에서 화면 안:
    /// 세로 팔레트가 화면보다 길면 형광펜 목록만 줄여 그 안에서 스크롤한다 — 아래 도구(지우개 · 글씨 · 밥 · 설정)가 화면 밖으로
    /// 밀려 누를 수 없던 것 (이 시험이 찾음: 12개 = 1086pt). 화면이 넉넉하면 예전 그대로 다 펼친다
    func testTheLongestRealPaletteFitsACommonSmallScreen() {
        let store = PlannerStore(inMemory: true)
        store.editPrefs { p in
            p.categories = (0..<Prefs.maxCategories).map { Category(id: $0, name: "형광펜 \($0 + 1)", hex: "8EDCD2", counts: true) }
        }
        let state = AppState(kind: .daily)
        state.store = store
        for vis in [NSRect(x: 0, y: 0, width: 1280, height: 775), NSRect(x: 0, y: 0, width: 1440, height: 875), small] {
            for side in PaletteEdge.allCases {
                let (s, limit) = PaletteController.fit(side, store: store, state: state, maxLength: PaletteController.maxLength(in: vis))
                XCTAssertGreaterThan(s.width * s.height, 0)
                if side.isVertical {
                    let natural = PaletteController.measure(side, store: store, state: state)
                    XCTAssertGreaterThan(natural.height, vis.height, "형광펜 12개 세로 팔레트는 이 화면보다 길다 (시험의 전제)")
                    switch limit {
                    case .pens(let h)?: XCTAssertGreaterThanOrEqual(h, PaletteController.minPenViewport, "\(side) \(vis)")
                    case .column?: XCTAssertEqual(vis, small, "팔레트 전체 스크롤은 아주 짧은 화면에서만")
                    case nil: XCTFail("\(side) \(vis): 줄여야 한다")
                    }
                }
                let kind: PageKind = side.isVertical ? .daily : .weekly
                let page = kind == .daily ? NSRect(x: vis.midX - 230, y: 20, width: 460, height: min(720, vis.height - 40))
                    : NSRect(x: 80, y: 140, width: vis.width - 160, height: (vis.width - 160) / PageKind.weekly.aspect)
                let (r, got) = PalettePlacement.place(s, page: page, visible: vis, preferred: side, kind: kind)
                assertInside(r, vis, "\(side) → \(got) \(s) on \(vis.size)")
            }
        }
        // 화면이 넉넉하면 줄이지 않는다 (지금 모양 그대로)
        let roomy = PaletteController.fit(.right, store: store, state: state, maxLength: PaletteController.maxLength(in: NSRect(x: 0, y: 0, width: 2560, height: 1400)))
        XCTAssertNil(roomy.limit)
        XCTAssertEqual(roomy.size, PaletteController.measure(.right, store: store, state: state))
        // 기본 형광펜 7개 (866pt): 큰 화면에서는 그대로, 13" MacBook Air (1440 × 900, 아래 Dock — 보이는 높이 ≈ 805) 에서는
        // 형광펜 목록만 조금 줄인다 — 예전에는 설정 단추가 화면 밖이었다
        let seven = PlannerStore(inMemory: true)
        let st7 = AppState(kind: .daily)
        st7.store = seven
        XCTAssertNil(PaletteController.fit(.right, store: seven, state: st7, maxLength: PaletteController.maxLength(in: big)).limit)
        let air = NSRect(x: 0, y: 70, width: 1440, height: 805)
        let (s7, l7) = PaletteController.fit(.right, store: seven, state: st7, maxLength: PaletteController.maxLength(in: air))
        guard case .pens(let h)? = l7 else { return XCTFail("형광펜 목록만 줄인다: \(String(describing: l7))") }
        XCTAssertGreaterThan(h, 200, "7개 가운데 다섯 줄 남짓은 그대로 보인다")
        XCTAssertLessThanOrEqual(s7.height, PaletteController.maxLength(in: air))
    }

    /// 아무 자리 · 아무 화면에서나: 팔레트가 화면보다 작으면 늘 화면 안 (고정 씨앗의 무작위 자리 2000개)
    func testAlwaysOnScreenWhenItFits() {
        var rng = SplitMix(seed: 0x5EED_2026)
        var checked = 0
        for _ in 0..<2000 {
            let vis = NSRect(x: rng.next(-200, 200), y: rng.next(0, 80), width: rng.next(800, 2600), height: rng.next(560, 1500))
            let kind: PageKind = rng.next(0, 1) < 0.5 ? .daily : .weekly
            let w = kind == .daily ? rng.next(300, 700) : rng.next(500, 1400)
            let h = w / kind.aspect
            let page = NSRect(x: rng.next(vis.minX - 100, vis.maxX - w + 100), y: rng.next(vis.minY - 50, vis.maxY - h + 50), width: w, height: h)
            let side = PaletteEdge.allCases[Int(rng.next(0, 3.999))]
            let s = size(side)
            guard s.width <= vis.width - 16, s.height <= vis.height - 16 else { continue }
            let (r, got) = PalettePlacement.place(s, page: page, visible: vis, preferred: side, kind: kind)
            assertInside(r, vis, "\(side) → \(got) page \(page) vis \(vis)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1500)
    }

    /// 접힌 손잡이는 펼친 자리 안, 종이 쪽 가장자리의 가운데 (손잡이가 펼친 팔레트와 같은 자리에서 열린다)
    func testTheCollapsedHandleSitsInsideTheOpenPanel() {
        for side in PaletteEdge.allCases {
            let full = NSRect(x: 400, y: 300, width: size(side).width, height: size(side).height)
            let h = PalettePlacement.handleFrame(in: full, side: side)
            XCTAssertTrue(full.insetBy(dx: -0.5, dy: -0.5).contains(h), "\(side)")
            switch side {
            case .right: XCTAssertEqual(h.minX, full.minX)
            case .left: XCTAssertEqual(h.maxX, full.maxX)
            case .top: XCTAssertEqual(h.minY, full.minY)
            case .bottom: XCTAssertEqual(h.maxY, full.maxY)
            }
        }
    }

    // MARK: 동기화 "다른 기기에서 쓰는 중" 알림

    func testSyncLiveHintStaysOnScreen() {
        let size = CGSize(width: 150, height: 18)
        // 보통: 칸 오른쪽 위
        let field = NSRect(x: 400, y: 500, width: 300, height: 22)
        let f = SyncLiveHintPlacement.frame(size: size, field: field, visible: big)
        XCTAssertEqual(f.minY, field.maxY + 2)
        XCTAssertEqual(f.maxX, field.maxX)
        // 칸이 화면 위 끝: 칸 바로 아래로
        let top = NSRect(x: 400, y: big.maxY - 22, width: 300, height: 22)
        let t = SyncLiveHintPlacement.frame(size: size, field: top, visible: big)
        XCTAssertEqual(t.maxY, top.minY - 2)
        assertInside(t, big, "위 끝")
        // 칸이 화면 오른쪽 밖으로 걸침: 화면 안으로
        let right = NSRect(x: big.maxX - 60, y: 500, width: 300, height: 22)
        assertInside(SyncLiveHintPlacement.frame(size: size, field: right, visible: big), big, "오른쪽 끝")
        // 칸이 좁아 알림이 왼쪽 화면 밖으로: 화면 안으로
        let left = NSRect(x: big.minX - 40, y: 500, width: 60, height: 22)
        assertInside(SyncLiveHintPlacement.frame(size: size, field: left, visible: big), big, "왼쪽 끝")
        // 화면을 모르면 예전 그대로
        XCTAssertEqual(SyncLiveHintPlacement.frame(size: size, field: field, visible: nil), f)
    }
}

/// 고정 씨앗 의사 난수 (시험이 늘 같은 자리를 본다)
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + (hi - lo) * CGFloat(Double(nextUInt() >> 11) / Double(1 << 53))
    }
}
