import SwiftUI
import AppKit
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
    var pageSize: CGSize = .zero {
        didSet {
            if abs(pageSize.width - oldValue.width) > 0.5 || abs(pageSize.height - oldValue.height) > 0.5 {
                geometryChanged()
            }
        }
    }
    /// Backing scale factor of the window (for texture resolution).
    var backingScale: CGFloat = 2 {
        didSet { if abs(backingScale - oldValue) > 0.001 { geometryChanged() } }
    }

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
    func hover(_ direction: FlipDirection, inside: Bool) {
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
    func dragBegan(_ direction: FlipDirection, at point: CGPoint) {
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

    func dragChanged(to point: CGPoint) {
        guard phase == .tracking, var t = tracking, t.input == .pointer, let turn else { return }
        t.target = pointerTarget(point, t, turn)
        t.history.add(turn.progress(t.target), at: CACurrentMediaTime())
        tracking = t
        needsDraw = true
    }

    /// Released. `predictedEnd` is SwiftUI's predictedEndLocation (for fling velocity).
    func dragEnded(at point: CGPoint, predictedEnd: CGPoint) {
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

    /// Trackpad horizontal two-finger swipe. deltaX is already normalised so that
    /// negative = fingers moving left = go forward. Units: points per event.
    func swipe(_ phase: SwipePhase, deltaX: CGFloat) {
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
    func makeOverlayView() -> NSView {
        if let overlayView { return overlayView }
        let v: NSView
        if let gpu = CurlGPU.shared {
            gpu.warmUp()   // 셰이더를 미리 백그라운드에서 컴파일 → 첫 넘김에 끊김이 없다
            let mv = CurlMetalView(gpu: gpu)
            mv.onFrame = { [weak self] view in self?.renderFrame(view) }
            metalView = mv
            v = mv
        } else {
            v = PassthroughView()
            v.isHidden = true
        }
        overlayView = v
        return v
    }

    private var overlayView: NSView?

    // MARK: Offscreen rendering (README screenshots / GIF, snapshot tests)

    /// Renders `frameCount` frames of an automatic forward (or backward) turn from
    /// `bitmaps.current` to `bitmaps.neighbor`, at `pageSize` points × `scale`.
    static func renderTurnFrames(_ bitmaps: PageBitmaps, direction: FlipDirection, edge: BindingEdge,
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
    static func renderStills(_ bitmaps: PageBitmaps, direction: FlipDirection, edge: BindingEdge,
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

        var forward: Bool { direction == .forward }
        /// Finger position where nothing has turned (the host's current page shows).
        var rest: CurlVec { forward ? frame.K : frame.E }
        /// Finger position where the turn is complete.
        var goal: CurlVec { forward ? frame.E : frame.K }
        func progress(_ F: CurlVec) -> Double { frame.progress(F, forward: forward) }
        /// Point of the canonical arc at a progress value.
        func arcPoint(_ p: Double) -> CurlVec {
            let x = frame.fingerX(progress: p, forward: forward)
            return CurlVec(x, arc.y(atX: x))
        }
    }

    private struct Tracking {
        var input: Input
        /// Where the finger is (page space); the rendered F follows it with a spring.
        var target: CurlVec
        var grab = CurlVec.zero
        var start = CGPoint.zero
        var startProgress = 0.0
        var travel = 0.0
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

    private var isLiveResizing: Bool { metalView?.inLiveResize ?? false }

    // MARK: turn set-up

    /// Makes a turn in `direction` current and visible: continues a matching peek,
    /// replaces a peek in the other direction, or starts a new one.
    private func acquire(_ direction: FlipDirection, delta: Int) -> Bool {
        if phase == .peek, let turn, turn.direction == direction, turn.delta == delta {
            willBegin?()
            return true
        }
        guard begin(direction, delta: delta) else {
            if phase == .peek { hideNow() }
            return false
        }
        present()
        return true
    }

    /// Loads bitmaps and textures for a new turn with the finger at rest.
    private func begin(_ direction: FlipDirection, delta: Int) -> Bool {
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

    private func commitWithoutAnimation(_ delta: Int) {
        if phase == .finishing { hideNow() }
        commit?(delta)
    }

    // MARK: motion

    private func peekPoint(_ t: Turn) -> CurlVec {
        let f = t.frame
        if t.forward { return f.K + CurlVec(-0.085 * f.W, -0.036 * f.H) }
        // 이전 장은 스프링 쪽에서 살짝 비친다 (포인터가 있는 모서리 쪽이 조금 더 넓게)
        let toward = edge == .top ? -1.0 : 1.0
        return f.E + CurlVec(0.2 * f.W, toward * 0.05 * f.H)
    }

    private func pointerTarget(_ p: CGPoint, _ t: Tracking, _ turn: Turn) -> CurlVec {
        let f = turn.frame
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
        guard let motion = CurlGlide.make(in: turn.frame, from: F, velocity: V, toTurned: commits == turn.forward) else {
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
            t.grab *= exp(-dt / Tune.grabFade)
            tracking = t
            let before = F
            CurlSpring.step(&F, &V, target: clampFinger(t.target + t.grab, turn.frame),
                            omega: Tune.followOmega, damping: 1, dt: dt)
            if simd_length(F - before) > 1e-4 { needsDraw = true }
            // 끝 신호 없이 사라진 제스처 (창 비활성화 등으로 취소): 놓은 것으로 처리한다
            let silent = CACurrentMediaTime() - t.history.lastTime
            if (t.input == .pointer && silent > 0.25 && NSEvent.pressedMouseButtons & 1 == 0)
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
        if committed { commit?(done.delta) }

        if let next = pending {
            pending = nil
            let delta = next.landingOffset ?? next.direction.delta
            if begin(next.direction, delta: delta) {
                // 다음 장을 오버레이 위에서 바로 이어 넘긴다 (숨겼다 보이기 없음)
                glideFromCurrent(commits: true, rate: Tune.chainRate)
                return
            }
            commit?(delta)   // 비트맵이 없으면 애니메이션 없이
        }
        turn = done
        F = committed ? done.goal : done.rest
        V = .zero
        phase = .finishing
        needsDraw = true
        scheduleHide(after: committed ? Tune.hideDelay : 0)
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
