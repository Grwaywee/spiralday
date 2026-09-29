import AppKit
import MetalKit
import QuartzCore

/// The page-curl overlay: an opaque Metal view exactly covering the page. It draws the
/// revealed under page and the curling page in one pass, so nothing below it shows.
/// Hidden and paused while no turn is in progress; never takes part in hit-testing.
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
            metal.isOpaque = true
            metal.maximumDrawableCount = 3
        }
        driver.owner = self
        delegate = driver
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Runs the display-synchronised loop at the screen's highest refresh rate.
    func run() {
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
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
