import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Page curl engine — PUBLIC CONTRACT
//
// The host (AppState / RootView) talks to the curl engine ONLY through the API in
// this file. Coordinates passed in are SwiftUI points in the page view's own
// coordinate space (origin top-left, y down, size == `pageSize`), i.e. screen
// orientation. The engine handles binding orientation internally via `edge`:
//   .leading (daily)  — spiral on the left edge, pages turn right → left
//   .top     (weekly) — spiral on the top edge,  pages turn bottom → top
//
// Life cycle of one turn:
//   1. something starts an interaction (flip / hover peek / drag / swipe)
//   2. engine calls willBegin(), then snapshot(delta) to obtain page bitmaps
//      delta = +1 next page, -1 previous page, or ±n for a multi-page jump
//   3. engine shows its overlay (isActive = true) and animates
//   4. when the turn completes it calls commit(delta) so the host swaps the live
//      page, then hides the overlay on a following run-loop turn (no flash)
//      A cancelled turn never calls commit.
// ─────────────────────────────────────────────────────────────────────────────

enum FlipDirection {
    case forward, backward
    var delta: Int { self == .forward ? 1 : -1 }
}

enum SwipePhase { case began, changed, ended, cancelled }

struct PageBitmaps {
    /// The page currently visible (before the turn).
    let current: CGImage
    /// The destination page (next page for forward, previous for backward).
    let neighbor: CGImage
}

@MainActor
final class CurlController: ObservableObject {
    /// True while the overlay is visible (a turn / peek is in progress).
    @Published private(set) var isActive = false

    /// Binding side of the current page kind. Set by the host before interactions.
    var edge: BindingEdge = .leading
    /// Page view size in points (screen orientation). Kept up to date by the host.
    var pageSize: CGSize = .zero
    /// Backing scale factor of the window (for texture resolution).
    var backingScale: CGFloat = 2

    /// Host-provided page renderer. Return nil if bitmaps are unavailable (turn is skipped).
    var snapshot: ((_ delta: Int) -> PageBitmaps?)?
    /// Called once when a turn completes; host must advance the page index by `delta`.
    var commit: ((_ delta: Int) -> Void)?
    /// Called at the start of any interaction (host ends text editing, etc.)
    var willBegin: (() -> Void)?

    var isIdle: Bool { !isActive }

    // MARK: Interactions

    /// Animated full page turn (keyboard / button / corner click).
    /// If a turn is already running, the request is queued (at most one) and the running
    /// turn is accelerated. `landingOffset` (e.g. ±5 for "go to today") shows a single
    /// turn whose destination page is `landingOffset` pages away.
    func flip(_ direction: FlipDirection, landingOffset: Int? = nil) {
        guard isIdle else { return }
        let delta = landingOffset ?? direction.delta
        willBegin?()
        commit?(delta)   // STUB: no animation yet
    }

    /// Pointer entered / left a page corner hot-zone: show / hide a small dog-ear peek.
    func hover(_ direction: FlipDirection, inside: Bool) {}

    /// Pointer pressed on a corner hot-zone and started dragging. `point` in page view coords.
    func dragBegan(_ direction: FlipDirection, at point: CGPoint) {}
    func dragChanged(to point: CGPoint) {}
    /// Released. `predictedEnd` is SwiftUI's predictedEndLocation (for fling velocity).
    func dragEnded(at point: CGPoint, predictedEnd: CGPoint) {}

    /// Trackpad horizontal two-finger swipe. deltaX is already normalised so that
    /// negative = fingers moving left = go forward. Units: points per event.
    func swipe(_ phase: SwipePhase, deltaX: CGFloat) {
        if phase == .began { flip(deltaX < 0 ? .forward : .backward) }
    }

    /// The persistent overlay view (created once, reused). Must ignore hit-testing and be
    /// hidden while inactive. The host embeds it above the live page.
    func makeOverlayView() -> NSView {
        if let overlayView { return overlayView }
        let v = PassthroughView()
        v.isHidden = true
        overlayView = v
        return v
    }

    private var overlayView: NSView?

    // MARK: Offscreen rendering (README screenshots / GIF, snapshot tests)

    /// Renders `frameCount` frames of an automatic forward (or backward) turn from
    /// `bitmaps.current` to `bitmaps.neighbor`, at `pageSize` points × `scale`.
    static func renderTurnFrames(_ bitmaps: PageBitmaps, direction: FlipDirection, edge: BindingEdge,
                                 pageSize: CGSize, scale: CGFloat, frameCount: Int) -> [CGImage] {
        []
    }
}

/// NSView that never participates in hit-testing.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI wrapper for the controller's persistent overlay.
struct CurlOverlay: NSViewRepresentable {
    let controller: CurlController
    func makeNSView(context: Context) -> NSView { controller.makeOverlayView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
