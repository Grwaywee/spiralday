import XCTest
import QuartzCore
import MetalKit
@testable import SpiraldayKit

/// 넘김 오버레이의 층 설정: iOS 에서는 한 장도 펼친 책처럼 불투명하지 않은 층이다 (CurlMetalView 의 설명).
/// 불투명한 층 위에 책상 테마의 종이 빛(곱하기 층)이 얹힌 빌드에서 소유자 iPhone 12 Pro Max · iPad Pro 12.9 (iOS 26) 는
/// 한 장 넘김에서 말림이 보이지 않고 종이가 하얘졌다가 다음 장이 보였다 (2026-10-05). 같은 빛 아래 비치는 층인 펼친 책은 잘 넘어갔다.
/// 그림은 같다 — 한 장 셰이더는 모든 화소를 알파 1 로 덮는다 (CurlSheetShapeTests 의 화소 견주기 그대로).
@MainActor
final class CurlOverlayLayerTests: XCTestCase {
    #if os(macOS)
    private let singlePageOpaque = true
    #else
    private let singlePageOpaque = false
    #endif

    func testTheSinglePageOverlayIsNotAnOpaqueLayerOnIOS() throws {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let c = CurlController()
        let view = try XCTUnwrap(c.makeOverlayView() as? CurlMetalView)
        let metal = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(metal.isOpaque, singlePageOpaque, "한 장: iOS 는 비치는 층 (Mac 은 그대로 불투명)")
        #if !os(macOS)
        XCTAssertFalse(view.isOpaque)
        #endif

        // 펼친 책 → 다시 한 장 (iPad 를 돌릴 때)
        c.layout = .spread(spread())
        XCTAssertFalse(metal.isOpaque, "펼친 책: 비치는 층")
        c.layout = .page
        XCTAssertEqual(metal.isOpaque, singlePageOpaque, "펼침에서 돌아온 한 장도")
        #if !os(macOS)
        XCTAssertFalse(view.isOpaque)
        #endif
    }

    /// 펼침이 오버레이보다 먼저 정해졌다가 (iPad 가 가로로 켜졌다) 한 장으로
    func testSpreadBeforeTheOverlayThenSinglePage() throws {
        try XCTSkipIf(CurlGPU.shared == nil, "Metal 없음")
        let c = CurlController()
        c.layout = .spread(spread())
        let view = try XCTUnwrap(c.makeOverlayView() as? CurlMetalView)
        let metal = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertFalse(metal.isOpaque)
        c.layout = .page
        XCTAssertEqual(metal.isOpaque, singlePageOpaque)
    }

    private func spread() -> CurlSpread {
        let p = CGSize(width: 500, height: 700), gutter: CGFloat = 28, bleed: CGFloat = 20
        return CurlSpread(axis: .vertical, overlaySize: CGSize(width: 2 * p.width + gutter, height: p.height + 2 * bleed),
                          hinge: p.width + gutter / 2, halfGutter: gutter / 2,
                          versoRect: CGRect(x: 0, y: bleed, width: p.width, height: p.height),
                          rectoRect: CGRect(x: p.width + gutter, y: bleed, width: p.width, height: p.height))
    }
}
