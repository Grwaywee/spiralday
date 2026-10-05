#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MetalKit
import QuartzCore

/// The page-curl overlay: a Metal view exactly covering the page. It draws the
/// revealed under page and the curling page in one pass, so nothing below it shows.
/// Hidden and paused while no turn is in progress; never takes part in hit-testing.
///
/// iOS: the overlay layer is never opaque — the single page as well as the open book. A single page still
/// covers every pixel (its shader writes alpha 1), so the picture is the same; the layer only no longer tells
/// Core Animation that it is opaque. With an opaque layer under the desk theme's paper light (a multiply layer
/// above the paper and the turn, iOS app 5224134) the owner's iPhone 12 Pro Max (iOS 26) and iPad Pro 12.9
/// (iPadOS 26) showed no curl: the paper went white until the turn ended and the next page appeared — while
/// screenshots of the same turns (also on those devices) showed the curl. The open book's see-through overlay
/// under the same light turned fine on that iPad: this is the one layer setting in which the two differed.
final class CurlMetalView: MTKView {
    /// Called once per display refresh while running (and for synchronous draws).
    var onFrame: ((CurlMetalView) -> Void)?

    private let driver = Driver()

    init(gpu: CurlGPU) {
        super.init(frame: .zero, device: gpu.device)
        colorPixelFormat = gpu.pixelFormat
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = true
        presentsWithTransaction = false
        clearColor = MTLClearColor(red: 252 / 255, green: 251 / 255, blue: 247 / 255, alpha: 1)
        isHidden = true
        if let metal = layer as? CAMetalLayer {
            // 일반 뷰처럼 sRGB 로 색 맞춤 → 오버레이가 나타나고 사라질 때 색이 튀지 않는다
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.isOpaque = Self.opaqueLayer(spread: false)
            metal.maximumDrawableCount = 3
        }
        #if !os(macOS)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        #endif
        driver.owner = self
        delegate = driver
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    #else
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    #endif

    /// Spread mode (an open book): the overlay is see-through (premultiplied alpha) — the live pages below
    /// show wherever the turning sheet does not cover. A single page covers the whole page (alpha 1); its layer
    /// is opaque only on the Mac (iOS: see the type's note).
    func setTransparent(_ transparent: Bool) {
        if let metal = layer as? CAMetalLayer { metal.isOpaque = Self.opaqueLayer(spread: transparent) }
        #if !os(macOS)
        isOpaque = false
        backgroundColor = .clear
        #endif
        clearColor = transparent ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                                 : MTLClearColor(red: 252 / 255, green: 251 / 255, blue: 247 / 255, alpha: 1)
    }

    /// Whether the overlay's Metal layer says it is opaque: only a single page on the Mac.
    static func opaqueLayer(spread: Bool) -> Bool {
        #if os(macOS)
        !spread
        #else
        false
        #endif
    }

    /// Runs the display-synchronised loop at the screen's highest refresh rate.
    func run() {
        #if os(macOS)
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        #else
        // ProMotion 아이폰에서 60 을 넘기려면 앱 Info.plist 에 CADisableMinimumFrameDurationOnPhone = YES
        preferredFramesPerSecond = window?.screen.maximumFramesPerSecond ?? 60
        #endif
        isPaused = false
    }

    private final class Driver: NSObject, MTKViewDelegate {
        weak var owner: CurlMetalView?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let owner else { return }
            owner.onFrame?(owner)
        }
    }
}
