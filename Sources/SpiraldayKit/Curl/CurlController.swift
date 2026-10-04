import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal
import QuartzCore
import simd

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
//
// Implementation: a Metal cylinder curl (CurlShader) driven by a single finger point
// F in page space (CurlPhysics). Every interaction only moves F: springs for peeks and
// pointer tracking, arc-length glides with a minimum-jerk ease for automatic turns.
// ─────────────────────────────────────────────────────────────────────────────

public enum FlipDirection: Sendable {
    case forward, backward
    public var delta: Int { self == .forward ? 1 : -1 }
}

public enum SwipePhase: Sendable { case began, changed, ended, cancelled }

public struct PageBitmaps {
    /// The page currently visible (before the turn).
    public let current: CGImage
    /// The destination page (next page for forward, previous for backward).
    public let neighbor: CGImage

    public init(current: CGImage, neighbor: CGImage) {
        self.current = current
        self.neighbor = neighbor
    }
}

// MARK: - Spread mode (an open book on the iPad)
//
// The host lays out ONE book: two pages side by side (vertical binding, daily) or stacked
// (horizontal binding, weekly) with a gutter between them. The overlay covers the whole
// book (+ a bleed along the binding). A turn lifts the recto (forward) or the verso
// (backward), carries it over the gutter and lays it MIRRORED on the other page; its back
// shows the page that lands there. Coordinates are SwiftUI points in the overlay's own
// space. `delta` of a spread turn = number of spreads (signed); it commits through
// `spreadCommit`. While a turn shows, `spreadLift` names the side whose live page the
// overlay is drawing (the host hides it so the overlay — which is see-through — can
// reveal the desk under the last sheet).

/// Which way the binding runs across an open book.
public enum SpreadAxis: Sendable, Equatable {
    /// Vertical binding: verso on the left, recto on the right (daily, landscape)
    case vertical
    /// Horizontal binding: verso on top, recto below (weekly, portrait)
    case horizontal
}

/// Geometry of an open book in the overlay's coordinate space (points).
public struct CurlSpread: Equatable, Sendable {
    public var axis: SpreadAxis
    /// Overlay view size (book + bleed).
    public var overlaySize: CGSize
    /// The hinge line (centre of the gutter): x for a vertical binding, y for a horizontal one.
    public var hinge: CGFloat
    /// Half the gutter width (the rings live there).
    public var halfGutter: CGFloat
    public var versoRect: CGRect
    public var rectoRect: CGRect

    public init(axis: SpreadAxis, overlaySize: CGSize, hinge: CGFloat, halfGutter: CGFloat, versoRect: CGRect, rectoRect: CGRect) {
        self.axis = axis
        self.overlaySize = overlaySize
        self.hinge = hinge
        self.halfGutter = halfGutter
        self.versoRect = versoRect
        self.rectoRect = rectoRect
    }
}

/// Single page (default — Mac, phone, single-page desks) or an open book.
public enum CurlLayout: Equatable, Sendable {
    case page
    case spread(CurlSpread)
}

/// Bitmaps of one spread turn (each at the size of its page × backing scale).
public struct SpreadBitmaps {
    /// The page being lifted (recto forward, verso backward).
    public let front: CGImage
    /// The back of that sheet = the page that lands on the other side.
    public let back: CGImage
    /// The page under the lifted one (nil: nothing — the desk shows).
    public let revealed: CGImage?
    /// 1 = paper, 2.4 = board (cover / inside back cover).
    public var stiffness: Double
    /// Board edge colour (sRGB 0…1), drawn as a thin rim while a board turns.
    public var rim: SIMD3<Float>?

    public init(front: CGImage, back: CGImage, revealed: CGImage?, stiffness: Double = 1, rim: SIMD3<Float>? = nil) {
        self.front = front
        self.back = back
        self.revealed = revealed
        self.stiffness = stiffness
        self.rim = rim
    }
}

@MainActor
public final class CurlController: ObservableObject {
    /// True while the overlay is visible (a turn / peek is in progress).
    @Published public private(set) var isActive = false

    /// Binding side of the current page kind. Set by the host before interactions.
    public var edge: BindingEdge = .leading
    /// Page view size in points (screen orientation). Kept up to date by the host.
    public var pageSize: CGSize = .zero {
        didSet {
            if abs(pageSize.width - oldValue.width) > 0.5 || abs(pageSize.height - oldValue.height) > 0.5 {
                geometryChanged()
            }
        }
    }
    /// Backing scale factor of the window (for texture resolution).
    public var backingScale: CGFloat = 2 {
        didSet { if abs(backingScale - oldValue) > 0.001 { geometryChanged() } }
    }

    /// Host-provided page renderer. Return nil if bitmaps are unavailable (turn is skipped).
    public var snapshot: ((_ delta: Int) -> PageBitmaps?)?
    /// Called once when a turn completes; host must advance the page index by `delta`.
    public var commit: ((_ delta: Int) -> Void)?
    /// Called at the start of any interaction (host ends text editing, etc.)
    public var willBegin: (() -> Void)?

    /// Single page (default) or an open book. Changing it ends a running turn (like a resize).
    public var layout: CurlLayout = .page {
        didSet {
            guard layout != oldValue else { return }
            geometryChanged()
            configureOverlay()
        }
    }
    /// Spread mode: bitmaps for a turn of `spreads` spreads in `dir` (nil = turn skipped / no animation).
    public var spreadSnapshot: ((_ dir: FlipDirection, _ spreads: Int) -> SpreadBitmaps?)?
    /// Spread mode: a turn completed — the host moves its book by `spreads` (signed) spreads.
    public var spreadCommit: ((_ spreads: Int) -> Void)?
    /// Spread mode: the side whose live page the overlay is drawing right now (.forward = recto, .backward = verso).
    /// The host hides that live page until the turn commits or settles back.
    @Published public private(set) var spreadLift: FlipDirection?

    public var isIdle: Bool { !isActive }

    private var isSpread: Bool { if case .spread = layout { return true } else { return false } }

    public init() {}

    // MARK: Interactions

    /// Animated full page turn (keyboard / button / corner click).
    /// If a turn is already running, the request is queued (at most one) and the running
    /// turn is accelerated. `landingOffset` (e.g. ±5 for "go to today") shows a single
    /// turn whose destination page is `landingOffset` pages away.
    public func flip(_ direction: FlipDirection, landingOffset: Int? = nil) {
        if isSpread {
            flip(direction, spreads: landingOffset.map { abs($0) } ?? 1)
            return
        }
        let delta = landingOffset ?? direction.delta
        switch phase {
        case .tracking, .gliding:
            // 연타: 하나만 기다리게 하고, 지금 넘어가는 장은 빨리 끝낸다
            pending = PendingFlip(direction: direction, landingOffset: landingOffset)
            if glide != nil { glide?.rateTarget = Tune.hurryRate }
        case .idle, .peek, .finishing:
            let chained = phase == .finishing
            if isLiveResizing {
                willBegin?()
                commitWithoutAnimation(delta)
                return
            }
            // 비트맵이 없으면 애니메이션 없이 넘긴다 (willBegin 은 begin 에서 이미 불렸다)
            guard acquire(direction, delta: delta) else {
                if phase == .idle || phase == .finishing { commitWithoutAnimation(delta) }
                return
            }
            glideFromCurrent(commits: true, rate: chained ? Tune.chainRate : 1)
        }
    }

    /// Pointer entered / left a page corner hot-zone: show / hide a small dog-ear peek.
    public func hover(_ direction: FlipDirection, inside: Bool) {
        if inside {
            guard !isLiveResizing else { return }
            switch phase {
            case .idle, .peek, .finishing:
                guard acquire(direction, delta: direction.delta), let turn else { return }
                phase = .peek
                peekTarget = peekPoint(turn)
                needsDraw = true
            case .tracking, .gliding:
                break
            }
        } else if phase == .peek, turn?.direction == direction {
            peekTarget = nil
            needsDraw = true
        }
    }

    /// Pointer pressed on a corner hot-zone and started dragging. `point` in page view coords.
    public func dragBegan(_ direction: FlipDirection, at point: CGPoint) {
        guard !isLiveResizing, phase != .tracking, phase != .gliding,
              acquire(direction, delta: direction.delta), let turn else { return }
        var t = Tracking(input: .pointer, target: F)
        t.start = point
        t.startProgress = CurlMath.clamp01(turn.progress(F))
        if turn.forward {
            // 모서리가 손가락 쪽으로 부드럽게 따라온다 (grab 오프셋이 곧 사라짐)
            t.target = turn.frame.toPage(point)
            t.grab = F - t.target
        }
        t.history.add(turn.progress(t.target), at: CACurrentMediaTime())
        tracking = t
        phase = .tracking
        needsDraw = true
    }

    public func dragChanged(to point: CGPoint) {
        guard phase == .tracking, var t = tracking, t.input == .pointer, let turn else { return }
        t.target = pointerTarget(point, t, turn)
        t.history.add(turn.progress(t.target), at: CACurrentMediaTime())
        tracking = t
        needsDraw = true
    }

    /// Released. `predictedEnd` is SwiftUI's predictedEndLocation (for fling velocity).
    public func dragEnded(at point: CGPoint, predictedEnd: CGPoint) {
        guard phase == .tracking, var t = tracking, t.input == .pointer, let turn else { return }
        let now = CACurrentMediaTime()
        t.target = pointerTarget(point, t, turn)
        t.history.add(turn.progress(t.target), at: now)
        tracking = t
        let p = turn.progress(t.target)
        let flingPredicted = turn.progress(pointerTarget(predictedEnd, t, turn)) - p
        let flingMeasured = t.history.velocity(now: now) * Tune.flingHorizon
        let fling = abs(flingPredicted) > abs(flingMeasured) && flingPredicted * flingMeasured >= 0
            ? flingPredicted : flingMeasured
        release(progress: p, fling: fling)
    }

    /// The drag was cancelled by the system (iOS: gesture interrupted). Settles like a release without fling.
    public func dragCancelled() {
        guard phase == .tracking, let t = tracking, t.input == .pointer, let turn else { return }
        release(progress: turn.progress(t.target), fling: 0)
    }

    // MARK: Spread interactions (open book)

    /// Animated turn of `spreads` spreads (1 = one sheet; more = a jump that shows one sheet carrying
    /// the destination). While a sheet is moving: the same direction queues one turn and hurries the
    /// running one; the opposite direction puts a sheet that has not reached half way back down
    /// (no commit) or turns back after it lands.
    public func flip(_ direction: FlipDirection, spreads: Int) {
        guard isSpread else { flip(direction, landingOffset: spreads > 1 ? direction.delta * spreads : nil); return }
        let delta = direction.delta * max(1, abs(spreads))
        switch phase {
        case .tracking:
            pending = PendingFlip(direction: direction, landingOffset: delta)
        case .gliding:
            if let turn, let g = glide {
                let p = turn.progress(F)
                if turn.direction != direction && g.commits && p < 0.5 {
                    // 반을 넘지 않은 장: 지금 속도를 이어 제자리로 (넘기지 않는다)
                    pending = nil
                    glideFromCurrent(commits: false)
                    return
                }
                if turn.direction == direction && !g.commits && turn.delta == delta {
                    // 되돌아가던 장을 다시 넘긴다
                    pending = nil
                    glideFromCurrent(commits: true)
                    return
                }
            }
            pending = PendingFlip(direction: direction, landingOffset: delta)
            if glide?.commits == true { glide?.rateTarget = Tune.hurryRate }
        case .idle, .peek, .finishing:
            let chained = phase == .finishing
            guard acquire(direction, delta: delta) else {
                if phase == .idle || phase == .finishing { commitWithoutAnimation(delta) }
                return
            }
            glideFromCurrent(commits: true, rate: chained ? Tune.chainRate : 1)
        }
    }

    /// Spread mode: a finger / pencil started dragging a page corner or edge band. `point` in overlay coordinates;
    /// `holdTop`: the far end along the binding is held (top corner daily, left end weekly).
    public func dragBegan(_ direction: FlipDirection, at point: CGPoint, holdTop: Bool) {
        guard isSpread else { dragBegan(direction, at: point); return }
        guard phase != .tracking, phase != .gliding else { return }
        if phase == .peek, let turn, turn.spread?.holdTop != holdTop { hideNow() }
        guard acquire(direction, delta: direction.delta, holdTop: holdTop), let turn else { return }
        var t = Tracking(input: .pointer, target: F)
        t.start = point
        t.startProgress = CurlMath.clamp01(turn.progress(F))
        t.target = spreadPoint(point, turn)
        t.grab = F - t.target
        t.history.add(turn.progress(t.target), at: CACurrentMediaTime())
        tracking = t
        phase = .tracking
        needsDraw = true
    }

    /// Spread mode: is this overlay point on the sheet that is moving right now (to catch it)?
    public func hitsTurningSheet(_ point: CGPoint) -> Bool {
        guard phase == .gliding || phase == .finishing, let turn, turn.spread != nil else { return false }
        return sheetCovers(spreadPoint(point, turn), turn)
    }

    /// Spread mode: catch the moving sheet under the finger. It follows the finger from where it was
    /// caught (no jump) and is released like a drag. Returns false when the point misses the sheet.
    @discardableResult
    public func grab(at point: CGPoint) -> Bool {
        guard phase == .gliding, let turn, turn.spread != nil, sheetCovers(spreadPoint(point, turn), turn) else { return false }
        pending = nil
        glide = nil
        var t = Tracking(input: .pointer, target: F)
        t.start = point
        t.startProgress = CurlMath.clamp01(turn.progress(F))
        t.target = spreadPoint(point, turn)
        t.grab = F - t.target
        t.holdsGrab = true
        t.history.add(turn.progress(F), at: CACurrentMediaTime())
        tracking = t
        phase = .tracking
        needsDraw = true
        metalView?.run()
        return true
    }

    /// Trackpad horizontal two-finger swipe. deltaX is already normalised so that
    /// negative = fingers moving left = go forward. Units: points per event.
    public func swipe(_ phase: SwipePhase, deltaX: CGFloat) {
        switch phase {
        case .began:
            let direction: FlipDirection = deltaX < 0 ? .forward : .backward
            if self.phase == .tracking || self.phase == .gliding {
                flip(direction)
                return
            }
            guard !isLiveResizing, acquire(direction, delta: direction.delta), let turn else { return }
            var t = Tracking(input: .swipe, target: F)
            t.startProgress = CurlMath.clamp01(turn.progress(F))
            t.history.add(t.startProgress, at: CACurrentMediaTime())
            tracking = t
            self.phase = .tracking
            applySwipe(deltaX)
        case .changed:
            applySwipe(deltaX)
        case .ended, .cancelled:
            guard self.phase == .tracking, let t = tracking, t.input == .swipe, let turn else { return }
            let velocity = t.history.velocity(now: CACurrentMediaTime(), window: 0.1)
            release(progress: turn.progress(t.target), fling: velocity * Tune.flingHorizon)
        }
    }

    /// The persistent overlay view (created once, reused). Must ignore hit-testing and be
    /// hidden while inactive. The host embeds it above the live page.
    public func makeOverlayView() -> PlatformView {
        if let overlayView { return overlayView }
        let v: PlatformView
        if let gpu = CurlGPU.shared {
            gpu.warmUp()   // 셰이더를 미리 백그라운드에서 컴파일 → 첫 넘김에 끊김이 없다
            let mv = CurlMetalView(gpu: gpu)
            mv.onFrame = { [weak self] view in self?.renderFrame(view) }
            metalView = mv
            // 펼침 모드가 오버레이보다 먼저 정해졌으면 (iPad 의 책이 처음 그려질 때) 여기서 투명하게
            if isSpread { configureOverlay() }
            v = mv
        } else {
            v = PassthroughView()
            v.isHidden = true
        }
        overlayView = v
        return v
    }

    private var overlayView: PlatformView?

    // MARK: Offscreen rendering (README screenshots / GIF, snapshot tests)

    /// Renders `frameCount` frames of an automatic forward (or backward) turn from
    /// `bitmaps.current` to `bitmaps.neighbor`, at `pageSize` points × `scale`.
    public static func renderTurnFrames(_ bitmaps: PageBitmaps, direction: FlipDirection, edge: BindingEdge,
                                 pageSize: CGSize, scale: CGFloat, frameCount: Int) -> [CGImage] {
        let frame = CurlFrame(edge: edge, view: pageSize)
        let forward = direction == .forward
        guard frameCount > 0, frame.isValid, let gpu = CurlGPU.shared,
              let glide = CurlGlide.canonical(in: frame, forward: forward) else { return [] }
        // 같은 시간 간격으로 (실제 넘김과 같은 곡선)
        let folds = (0..<frameCount).map { i -> CurlFold in
            let tau = frameCount == 1 ? 1 : Double(i) / Double(frameCount - 1)
            return frame.fold(glide.point(tau))
        }
        let (top, under) = forward ? (bitmaps.current, bitmaps.neighbor) : (bitmaps.neighbor, bitmaps.current)
        return gpu.renderOffscreen(frame: frame, folds: folds, top: top, under: under, scale: scale)
    }

    /// Renders stills with the finger at given points in normalised page space
    /// ((0,0) binding/top … (1,1) held corner K; x < 0 is past the binding).
    public static func renderStills(_ bitmaps: PageBitmaps, direction: FlipDirection, edge: BindingEdge,
                             pageSize: CGSize, scale: CGFloat, fingers: [CGPoint]) -> [CGImage] {
        let frame = CurlFrame(edge: edge, view: pageSize)
        guard frame.isValid, let gpu = CurlGPU.shared else { return [] }
        let folds = fingers.map { frame.fold(CurlVec(Double($0.x) * frame.W, Double($0.y) * frame.H)) }
        let (top, under) = direction == .forward ? (bitmaps.current, bitmaps.neighbor) : (bitmaps.neighbor, bitmaps.current)
        return gpu.renderOffscreen(frame: frame, folds: folds, top: top, under: under, scale: scale)
    }

    // MARK: - Engine

    private enum Tune {
        /// Pointer / swipe smoothing: critically damped follow, ~30 ms time constant.
        static let followOmega = 1 / 0.03
        /// The initial corner-to-finger offset of a drag fades with this time constant.
        static let grabFade = 0.09
        static let peekOmega = 19.0
        static let peekDamping = 0.78
        static let swipeGain = 1.4
        static let commitProgress = 0.45
        /// A fling decides the turn when it would carry the page this far.
        static let flingDecisive = 0.14
        /// Seconds of current velocity counted as "fling" distance.
        static let flingHorizon = 0.2
        /// Playback rate of a running turn once another one is queued.
        static let hurryRate = 1.6
        /// Playback rate of a queued turn that starts right after the previous one.
        static let chainRate = 1.3
        /// Delay between commit and hiding the overlay (the host swaps the live page first).
        static let hideDelay = 0.035
        /// Textures are released after this long without any interaction.
        static let purgeDelay = 20.0
    }

    private enum Phase { case idle, peek, tracking, gliding, finishing }
    private enum Input { case pointer, swipe }

    private struct Turn {
        let direction: FlipDirection
        let delta: Int
        let frame: CurlFrame
        let arc: CurlArc
        let top: MTLTexture       // the page that moves
        let under: MTLTexture     // the page revealed below it
        /// Spread mode (an open book): nil for a single page
        var spread: SpreadTurn? = nil

        var forward: Bool { direction == .forward }
        /// A spread turn always moves K → E in its own (mirrored) page space.
        var advancing: Bool { forward || spread != nil }
        /// Finger position where nothing has turned (the host's current page shows).
        var rest: CurlVec { advancing ? frame.K : frame.E }
        /// Finger position where the turn is complete.
        var goal: CurlVec { advancing ? frame.E : frame.K }
        func progress(_ F: CurlVec) -> Double { frame.progress(F, forward: advancing) }
        /// Point of the canonical arc at a progress value.
        func arcPoint(_ p: Double) -> CurlVec {
            let x = frame.fingerX(progress: p, forward: advancing)
            return CurlVec(x, arc.y(atX: x))
        }
    }

    private struct SpreadTurn {
        let geometry: CurlSpread
        /// +1 lifting the recto, −1 the verso
        let sigma: Double
        let holdTop: Bool
        let back: MTLTexture
        let revealed: MTLTexture?
        let stiffness: Double
        let rim: SIMD3<Float>?
        var liftRect: CGRect { sigma > 0 ? geometry.rectoRect : geometry.versoRect }
        var oppRect: CGRect { sigma > 0 ? geometry.versoRect : geometry.rectoRect }
    }

    private struct Tracking {
        var input: Input
        /// Where the finger is (page space); the rendered F follows it with a spring.
        var target: CurlVec
        var grab = CurlVec.zero
        var start = CGPoint.zero
        var startProgress = 0.0
        var travel = 0.0
        /// A caught sheet keeps its offset to the finger (it does not snap its corner to the finger).
        var holdsGrab = false
        var history = CurlVelocityTracker()

        init(input: Input, target: CurlVec) {
            self.input = input
            self.target = target
        }
    }

    private struct Glide {
        let motion: CurlGlide
        var tau = 0.0
        var rate: Double
        var rateTarget: Double
        let commits: Bool
    }

    private struct PendingFlip {
        let direction: FlipDirection
        let landingOffset: Int?
    }

    private var phase: Phase = .idle
    private var turn: Turn?
    /// The finger (page space) and its velocity (points / s).
    private var F = CurlVec.zero
    private var V = CurlVec.zero
    private var peekTarget: CurlVec?
    private var tracking: Tracking?
    private var glide: Glide?
    private var pending: PendingFlip?
    private var needsDraw = false
    private var lastFrameTime: CFTimeInterval?

    private var metalView: CurlMetalView?
    private let textures = CurlTextureCache()
    private var hideWork: DispatchWorkItem?
    private var purgeWork: DispatchWorkItem?

    private var isLiveResizing: Bool {
        #if os(macOS)
        metalView?.inLiveResize ?? false
        #else
        false
        #endif
    }

    /// 마우스 왼쪽 단추를 뗐는지 (macOS). iOS 는 손가락이 멈춰 있을 수 있어서 늘 false — 끝은 dragEnded / dragCancelled 로 온다.
    private var pointerButtonReleased: Bool {
        #if os(macOS)
        NSEvent.pressedMouseButtons & 1 == 0
        #else
        false
        #endif
    }

    // MARK: turn set-up

    /// Makes a turn in `direction` current and visible: continues a matching peek,
    /// replaces a peek in the other direction, or starts a new one.
    private func acquire(_ direction: FlipDirection, delta: Int, holdTop: Bool = false) -> Bool {
        if phase == .peek, let turn, turn.direction == direction, turn.delta == delta,
           turn.spread == nil || turn.spread?.holdTop == holdTop {
            willBegin?()
            return true
        }
        guard begin(direction, delta: delta, holdTop: holdTop) else {
            if phase == .peek { hideNow() }
            return false
        }
        present()
        return true
    }

    /// Loads bitmaps and textures for a new turn with the finger at rest.
    private func begin(_ direction: FlipDirection, delta: Int, holdTop: Bool = false) -> Bool {
        if case .spread(let geometry) = layout {
            return beginSpread(direction, delta: delta, geometry: geometry, holdTop: holdTop)
        }
        willBegin?()
        let frame = CurlFrame(edge: edge, view: pageSize)
        guard frame.isValid, metalView != nil, let gpu = CurlGPU.shared, gpu.pipeline != nil,
              let bitmaps = snapshot?(delta) else { return false }
        let forward = direction == .forward
        let (topImage, underImage) = forward ? (bitmaps.current, bitmaps.neighbor) : (bitmaps.neighbor, bitmaps.current)
        guard let top = textures.texture(for: topImage, gpu: gpu),
              let under = textures.texture(for: underImage, gpu: gpu) else { return false }
        turn = Turn(direction: direction, delta: delta, frame: frame, arc: CurlArc(frame), top: top, under: under)
        F = forward ? frame.K : frame.E
        V = .zero
        peekTarget = nil
        tracking = nil
        glide = nil
        phase = .gliding      // callers set the real phase right after
        needsDraw = true
        return true
    }

    /// Spread mode: loads the three page bitmaps of a turn and puts the finger at rest (K).
    private func beginSpread(_ direction: FlipDirection, delta: Int, geometry g: CurlSpread, holdTop: Bool) -> Bool {
        willBegin?()
        let sigma = direction == .forward ? 1.0 : -1.0
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let across = Double(g.axis == .vertical ? lift.width : lift.height)
        let along = Double(g.axis == .vertical ? lift.height : lift.width)
        guard metalView != nil, let gpu = CurlGPU.shared, gpu.spreadPipeline != nil,
              let bitmaps = spreadSnapshot?(direction, abs(delta)) else { return false }
        let frame = CurlFrame.spread(W: Double(g.halfGutter) + across, H: along, halfGutter: Double(g.halfGutter),
                                     stiffness: bitmaps.stiffness)
        guard frame.isValid,
              let front = textures.texture(for: bitmaps.front, gpu: gpu),
              let back = textures.texture(for: bitmaps.back, gpu: gpu) else { return false }
        var revealed: MTLTexture?
        if let r = bitmaps.revealed {
            guard let t = textures.texture(for: r, gpu: gpu) else { return false }
            revealed = t
        }
        let sp = SpreadTurn(geometry: g, sigma: sigma, holdTop: holdTop, back: back, revealed: revealed,
                            stiffness: bitmaps.stiffness, rim: bitmaps.rim)
        turn = Turn(direction: direction, delta: delta, frame: frame, arc: CurlArc(frame), top: front, under: back, spread: sp)
        F = frame.K
        V = .zero
        peekTarget = nil
        tracking = nil
        glide = nil
        phase = .gliding      // callers set the real phase right after
        needsDraw = true
        return true
    }

    /// Single page → host commit (as always); open book → spreadCommit.
    /// `spread` = the kind of turn that completed (the layout may already have changed — rotation).
    private func emitCommit(_ delta: Int, spread: Bool) {
        if spread { spreadCommit?(delta) } else { commit?(delta) }
    }

    private func commitWithoutAnimation(_ delta: Int) {
        if phase == .finishing { hideNow() }
        emitCommit(delta, spread: isSpread)
    }

    /// Overlay point → page space of the sheet being turned (spread mode).
    private func spreadPoint(_ p: CGPoint, _ turn: Turn) -> CurlVec {
        guard let sp = turn.spread else { return turn.frame.toPage(p) }
        let g = sp.geometry
        let lift = sp.liftRect
        let across = Double(g.axis == .vertical ? p.x - g.hinge : p.y - g.hinge)
        let along = Double(g.axis == .vertical ? p.y - lift.minY : p.x - lift.minX)
        return CurlVec(sp.sigma * across, sp.holdTop ? turn.frame.H - along : along)
    }

    /// Whether the moving sheet (front or back) covers this page-space point (the shader's coverage, no AA).
    private func sheetCovers(_ q: CurlVec, _ turn: Turn) -> Bool {
        guard let sp = turn.spread else { return false }
        let fold = turn.frame.fold(F)
        let N = fold.normal, r = fold.radius
        let d = simd_dot(q - fold.axisPoint, N)
        guard d <= r else { return false }
        let a = r > 1e-9 ? asin(min(max(min(max(d, 0), r) / r, 0), 1)) : 0
        let sF = q + N * (min(d, 0) + r * a - d)
        let sB = q + N * (r * (.pi - a) + max(-d, 0) - d)
        let lo = Double(sp.geometry.halfGutter), hi = turn.frame.W, H = turn.frame.H
        func inside(_ s: CurlVec) -> Bool { s.x >= lo && s.x <= hi && s.y >= 0 && s.y <= H }
        return inside(sF) || (simd_length(F - turn.frame.K) > 1e-3 && inside(sB))
    }

    private func configureOverlay() {
        textures.capacity = isSpread ? 6 : 4
        metalView?.setTransparent(isSpread)
        if isSpread { CurlGPU.shared?.warmUpSpread() }
    }

    // MARK: motion

    private func peekPoint(_ t: Turn) -> CurlVec {
        let f = t.frame
        // 펼친 책: 바깥 모서리가 살짝 들린다 (앞 · 뒤 모두 같은 모양 — 거울 공간)
        if t.spread != nil { return f.K + CurlVec(-0.06 * f.W, -0.03 * f.H) }
        if t.forward { return f.K + CurlVec(-0.085 * f.W, -0.036 * f.H) }
        // 이전 장은 스프링 쪽에서 살짝 비친다 (포인터가 있는 모서리 쪽이 조금 더 넓게)
        let toward = edge == .top ? -1.0 : 1.0
        return f.E + CurlVec(0.2 * f.W, toward * 0.05 * f.H)
    }

    private func pointerTarget(_ p: CGPoint, _ t: Tracking, _ turn: Turn) -> CurlVec {
        let f = turn.frame
        if turn.spread != nil { return spreadPoint(p, turn) }
        if turn.forward { return f.toPage(p) }
        // 이전 장: 스프링 쪽에서 오른쪽으로 끄는 만큼 선형으로 되돌아온다
        let room = max(pageSize.width - t.start.x, 0.25 * pageSize.width) * 0.9
        let p01 = t.startProgress + Double((p.x - t.start.x) / room) * (1 - t.startProgress)
        var q = turn.arcPoint(min(max(p01, -0.05), 1.04))
        if edge == .leading {
            q.y += min(max(Double(p.y - t.start.y), -0.25 * f.H), 0.1 * f.H)
        }
        return q
    }

    private func applySwipe(_ dx: CGFloat) {
        guard phase == .tracking, var t = tracking, t.input == .swipe, let turn else { return }
        let sign = turn.forward ? -1.0 : 1.0
        let span = turn.frame.span
        t.travel += sign * Double(dx) * Tune.swipeGain
        // 끝을 넘어 계속 밀어도 되돌릴 때 바로 반응하도록 이동량 자체를 제한
        t.travel = min(max(t.travel, (-0.03 - t.startProgress) * span), (1.03 - t.startProgress) * span)
        let p = t.startProgress + t.travel / span
        t.target = turn.arcPoint(p)
        t.history.add(p, at: CACurrentMediaTime())
        tracking = t
        needsDraw = true
    }

    private func clampFinger(_ q: CurlVec, _ f: CurlFrame) -> CurlVec {
        CurlVec(min(max(q.x, f.E.x - 0.2 * f.W), f.K.x), min(max(q.y, -0.25 * f.H), 1.5 * f.H))
    }

    /// Decide commit / cancel on release and glide there, continuing the current velocity.
    private func release(progress p: Double, fling: Double) {
        let commits = abs(fling) > Tune.flingDecisive ? fling > 0 : p + 0.5 * fling >= Tune.commitProgress
        glideFromCurrent(commits: commits)
    }

    private func glideFromCurrent(commits: Bool, rate: Double = 1) {
        guard let turn else { return }
        tracking = nil
        peekTarget = nil
        needsDraw = true
        let rateNow = pending != nil ? max(rate, Tune.hurryRate) : rate
        let full: Double
        if let sp = turn.spread {
            full = abs(turn.delta) > 1 ? CurlGlide.jumpDuration : sp.stiffness > 1.01 ? CurlGlide.boardDuration : CurlGlide.spreadDuration
        } else {
            full = CurlGlide.fullDuration
        }
        guard let motion = CurlGlide.make(in: turn.frame, from: F, velocity: V, toTurned: commits == turn.advancing,
                                          full: full) else {
            F = commits ? turn.goal : turn.rest
            V = .zero
            finish(committed: commits)
            return
        }
        glide = Glide(motion: motion, rate: rateNow, rateTarget: rateNow, commits: commits)
        phase = .gliding
        metalView?.run()
    }

    private func advance(_ dt: Double) {
        guard let turn, dt > 0 else { return }
        switch phase {
        case .peek:
            let target = peekTarget ?? turn.rest
            let before = F
            CurlSpring.step(&F, &V, target: target, omega: Tune.peekOmega,
                            damping: peekTarget == nil ? 1 : Tune.peekDamping, dt: dt)
            if peekTarget == nil, simd_length(F - turn.rest) < 0.2, simd_length(V) < 3 {
                F = turn.rest
                V = .zero
                finish(committed: false)
            }
            if simd_length(F - before) > 1e-4 { needsDraw = true }
        case .tracking:
            guard var t = tracking else { return }
            if !t.holdsGrab { t.grab *= exp(-dt / Tune.grabFade) }
            tracking = t
            let before = F
            CurlSpring.step(&F, &V, target: clampFinger(t.target + t.grab, turn.frame),
                            omega: Tune.followOmega, damping: 1, dt: dt)
            if simd_length(F - before) > 1e-4 { needsDraw = true }
            // 끝 신호 없이 사라진 제스처 (창 비활성화 등으로 취소): 놓은 것으로 처리한다
            let silent = CACurrentMediaTime() - t.history.lastTime
            if (t.input == .pointer && silent > 0.25 && pointerButtonReleased)
                || (t.input == .swipe && silent > 2) {
                release(progress: turn.progress(t.target), fling: 0)
            }
        case .gliding:
            guard var g = glide else { return }
            g.rate += (g.rateTarget - g.rate) * (1 - exp(-dt / 0.07))
            g.tau = min(1, g.tau + dt * g.rate / g.motion.duration)
            glide = g
            F = g.motion.point(g.tau)
            V = g.motion.velocity(g.tau) * g.rate
            needsDraw = true
            if g.tau >= 1 {
                F = g.commits ? turn.goal : turn.rest
                V = .zero
                finish(committed: g.commits)
            }
        case .idle, .finishing:
            break
        }
    }

    /// End of a turn (or peek). Commits, then chains a queued turn or hides the overlay.
    private func finish(committed: Bool) {
        guard let done = turn else { return }
        glide = nil
        tracking = nil
        peekTarget = nil
        // 펼친 책: 숨겨 둔 살아 있는 쪽을 다시 보인다 (새 펼침과 함께 그려진 뒤에 오버레이를 숨긴다)
        if done.spread != nil, spreadLift != nil { spreadLift = nil }
        if committed { emitCommit(done.delta, spread: done.spread != nil) }

        if let next = pending {
            pending = nil
            let delta = next.landingOffset ?? next.direction.delta
            if begin(next.direction, delta: delta) {
                // 다음 장을 오버레이 위에서 바로 이어 넘긴다 (숨겼다 보이기 없음)
                if let t = turn, t.spread != nil { spreadLift = t.direction }
                glideFromCurrent(commits: true, rate: Tune.chainRate)
                return
            }
            emitCommit(delta, spread: isSpread)   // 비트맵이 없으면 애니메이션 없이
        }
        turn = done
        F = committed ? done.goal : done.rest
        V = .zero
        phase = .finishing
        needsDraw = true
        // 펼친 책은 되돌아간 장도 살아 있는 쪽이 다시 보인 뒤에 숨긴다 (오버레이가 투명하다)
        scheduleHide(after: committed || done.spread != nil ? Tune.hideDelay : 0)
    }

    /// Window resized / moved to another display during a turn: finish instantly.
    private func geometryChanged() {
        guard phase != .idle, phase != .finishing else { return }
        pending = nil
        let commits = phase == .gliding && glide?.commits == true
        finish(committed: commits)
        hideNow()
    }

    // MARK: overlay

    private func present() {
        hideWork?.cancel()
        hideWork = nil
        purgeWork?.cancel()
        purgeWork = nil
        guard let view = metalView else { return }
        lastFrameTime = nil
        needsDraw = true
        if view.isHidden {
            // 첫 프레임을 CA 트랜잭션과 함께 올린다 → 나타나는 순간 깜빡임 없음
            view.presentsWithTransaction = true
            view.draw()
            view.presentsWithTransaction = false
            view.isHidden = false
        }
        view.run()
        if !isActive { isActive = true }
        if let t = turn, t.spread != nil, spreadLift != t.direction { spreadLift = t.direction }
    }

    private func scheduleHide(after delay: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hideNow() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        metalView?.isPaused = true
        metalView?.isHidden = true
        phase = .idle
        turn = nil
        glide = nil
        tracking = nil
        peekTarget = nil
        lastFrameTime = nil
        if isActive { isActive = false }
        if spreadLift != nil { spreadLift = nil }
        schedulePurge()
    }

    private func schedulePurge() {
        purgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle else { return }
                self.textures.purge()
            }
        }
        purgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tune.purgeDelay, execute: work)
    }

    /// One display frame: advance the motion by the real elapsed time, then draw.
    private func renderFrame(_ view: CurlMetalView) {
        let now = CACurrentMediaTime()
        if let last = lastFrameTime { advance(min(max(now - last, 0), 1.0 / 20)) }
        lastFrameTime = now
        if phase == .finishing || phase == .idle { view.isPaused = true }
        guard let turn else { return }
        guard needsDraw || view.presentsWithTransaction else { return }
        if let sp = turn.spread {
            renderSpreadFrame(view, turn, sp)
            return
        }
        guard let gpu = CurlGPU.shared, let pipeline = gpu.pipeline,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = gpu.queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = CurlUniforms(frame: turn.frame, fold: turn.frame.fold(F), pixelSize: view.drawableSize)
        gpu.encode(enc, pipeline: pipeline, uniforms: &u, top: turn.top, under: turn.under)
        enc.endEncoding()
        if view.presentsWithTransaction {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        needsDraw = false
    }

    // MARK: spread rendering

    private func renderSpreadFrame(_ view: CurlMetalView, _ turn: Turn, _ sp: SpreadTurn) {
        guard let gpu = CurlGPU.shared, let pipeline = gpu.spreadPipeline,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = gpu.queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = Self.spreadUniforms(frame: turn.frame, fold: turn.frame.fold(F), spread: sp,
                                    lifted: simd_length(F - turn.frame.K) > 1e-3, pixelSize: view.drawableSize)
        gpu.encodeSpread(enc, pipeline: pipeline, uniforms: &u, front: turn.top, back: sp.back, revealed: sp.revealed)
        enc.endEncoding()
        if view.presentsWithTransaction {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        needsDraw = false
    }

    private static func spreadUniforms(frame: CurlFrame, fold: CurlFold, spread sp: SpreadTurn, lifted: Bool,
                                       pixelSize: CGSize) -> CurlSpreadUniforms {
        let g = sp.geometry
        let ov = g.overlaySize
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
        let rim = sp.rim.map { SIMD4($0.x, $0.y, $0.z, 1) } ?? .zero
        return CurlSpreadUniforms(
            liftRect: rect(sp.liftRect), oppRect: rect(sp.oppRect), rim: sp.stiffness > 1.01 ? rim : .zero,
            viewSize: SIMD2(Float(ov.width), Float(ov.height)),
            pixelScale: SIMD2(Float(Double(pixelSize.width) / max(Double(ov.width), 1)),
                              Float(Double(pixelSize.height) / max(Double(ov.height), 1))),
            pageSize: SIMD2(Float(frame.W), Float(frame.H)),
            axisPoint: SIMD2(Float(fold.axisPoint.x), Float(fold.axisPoint.y)),
            normal: SIMD2(Float(fold.normal.x), Float(fold.normal.y)),
            radius: Float(fold.radius), effect: Float(fold.effect),
            hinge: Float(g.hinge), sigma: Float(sp.sigma), halfGutter: Float(g.halfGutter),
            holdTop: sp.holdTop ? 1 : 0, horizontal: g.axis == .horizontal ? 1 : 0,
            hasRevealed: sp.revealed != nil ? 1 : 0, lifted: lifted ? 1 : 0)
    }

    // MARK: spread offscreen (tests · frame captures)

    /// Renders `frameCount` frames of an automatic spread turn (the same timed curve as on screen) as
    /// premultiplied bitmaps of the whole overlay (`spread.overlaySize` × scale). Transparent where the
    /// live pages would show — composite over the book to see the whole picture.
    public static func renderSpreadTurnFrames(_ bitmaps: SpreadBitmaps, spread g: CurlSpread, direction: FlipDirection,
                                              spreads: Int = 1, holdTop: Bool = false, scale: CGFloat,
                                              frameCount: Int) -> [CGImage] {
        guard frameCount > 0, let gpu = CurlGPU.shared else { return [] }
        let (frame, sp) = offscreenTurn(bitmaps, g, direction, holdTop)
        guard frame.isValid else { return [] }
        let full = spreads > 1 ? CurlGlide.jumpDuration : bitmaps.stiffness > 1.01 ? CurlGlide.boardDuration : CurlGlide.spreadDuration
        guard let glide = CurlGlide.make(in: frame, from: frame.K, velocity: .zero, toTurned: true, full: full) else { return [] }
        let fingers = (0..<frameCount).map { i -> CurlVec in
            let tau = frameCount == 1 ? 1 : Double(i) / Double(frameCount - 1)
            return glide.point(tau)
        }
        return renderSpread(gpu, bitmaps, g, frame, sp, fingers, scale)
    }

    /// Spread stills with the finger at given progress values on the canonical arc (0 = flat, 1 = landed).
    public static func renderSpreadStills(_ bitmaps: SpreadBitmaps, spread g: CurlSpread, direction: FlipDirection,
                                          holdTop: Bool = false, scale: CGFloat, progress: [Double]) -> [CGImage] {
        guard let gpu = CurlGPU.shared else { return [] }
        let (frame, sp) = offscreenTurn(bitmaps, g, direction, holdTop)
        guard frame.isValid else { return [] }
        let arc = CurlArc(frame)
        let fingers = progress.map { p -> CurlVec in
            let x = frame.fingerX(progress: p, forward: true)
            return p >= 1 ? frame.E : p <= 0 ? frame.K : CurlVec(x, arc.y(atX: x))
        }
        return renderSpread(gpu, bitmaps, g, frame, sp, fingers, scale)
    }

    private static func offscreenTurn(_ b: SpreadBitmaps, _ g: CurlSpread, _ direction: FlipDirection,
                                      _ holdTop: Bool) -> (CurlFrame, (sigma: Double, holdTop: Bool)) {
        let sigma = direction == .forward ? 1.0 : -1.0
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let across = Double(g.axis == .vertical ? lift.width : lift.height)
        let along = Double(g.axis == .vertical ? lift.height : lift.width)
        let frame = CurlFrame.spread(W: Double(g.halfGutter) + across, H: along, halfGutter: Double(g.halfGutter),
                                     stiffness: b.stiffness)
        return (frame, (sigma, holdTop))
    }

    private static func renderSpread(_ gpu: CurlGPU, _ b: SpreadBitmaps, _ g: CurlSpread, _ frame: CurlFrame,
                                     _ m: (sigma: Double, holdTop: Bool), _ fingers: [CurlVec], _ scale: CGFloat) -> [CGImage] {
        // 텍스처 대신 크기만 쓰는 자리: 셰이더 값만 만든다 (텍스처는 renderSpreadOffscreen 이 올린다)
        let lift = m.sigma > 0 ? g.rectoRect : g.versoRect
        let opp = m.sigma > 0 ? g.versoRect : g.rectoRect
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
        let rim = b.stiffness > 1.01 ? (b.rim.map { SIMD4($0.x, $0.y, $0.z, 1) } ?? .zero) : .zero
        let uniforms = fingers.map { F -> CurlSpreadUniforms in
            let fold = frame.fold(F)
            return CurlSpreadUniforms(
                liftRect: rect(lift), oppRect: rect(opp), rim: rim,
                viewSize: SIMD2(Float(g.overlaySize.width), Float(g.overlaySize.height)),
                pixelScale: SIMD2(Float(scale), Float(scale)),
                pageSize: SIMD2(Float(frame.W), Float(frame.H)),
                axisPoint: SIMD2(Float(fold.axisPoint.x), Float(fold.axisPoint.y)),
                normal: SIMD2(Float(fold.normal.x), Float(fold.normal.y)),
                radius: Float(fold.radius), effect: Float(fold.effect),
                hinge: Float(g.hinge), sigma: Float(m.sigma), halfGutter: Float(g.halfGutter),
                holdTop: m.holdTop ? 1 : 0, horizontal: g.axis == .horizontal ? 1 : 0,
                hasRevealed: b.revealed != nil ? 1 : 0, lifted: simd_length(F - frame.K) > 1e-3 ? 1 : 0)
        }
        return gpu.renderSpreadOffscreen(overlay: g.overlaySize, uniforms: uniforms, front: b.front, back: b.back,
                                         revealed: b.revealed, scale: scale)
    }

    // MARK: test hooks (internal — @testable only)

    /// Advances the motion by dt seconds as a display frame would (no drawing).
    func _testAdvance(_ dt: Double) { advance(dt) }
    var _testPhase: String { "\(phase)" }
    var _testProgress: Double? { turn.map { $0.progress(F) } }
    var _testPending: Int? { pending.map { $0.landingOffset ?? $0.direction.delta } }
    var _testCommitsGlide: Bool? { glide?.commits }
    var _testTurnDelta: Int? { turn?.delta }
    var _testRadius: Double? { turn.map { $0.frame.fold(F).radius } }
}

#if os(macOS)
/// NSView that never participates in hit-testing.
public final class PassthroughView: NSView {
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
/// UIView that never participates in hit-testing.
public final class PassthroughView: UIView {
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif

/// SwiftUI wrapper for the controller's persistent overlay.
#if os(macOS)
public struct CurlOverlay: NSViewRepresentable {
    public let controller: CurlController
    public init(controller: CurlController) { self.controller = controller }
    public func makeNSView(context: Context) -> NSView { controller.makeOverlayView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
public struct CurlOverlay: UIViewRepresentable {
    public let controller: CurlController
    public init(controller: CurlController) { self.controller = controller }
    public func makeUIView(context: Context) -> UIView { controller.makeOverlayView() }
    public func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
