import Foundation
import CoreGraphics
import simd

// ─────────────────────────────────────────────────────────────────────────────
// Page-curl geometry and motion.
//
// PAGE SPACE: the binding is x = 0, the free edge x = W, y runs along the binding
// (0…H). For a leading binding (daily) this is the screen orientation; for a top
// binding (weekly) it is the screen transposed (page.x = screen.y, page.y = screen.x).
//
// The whole curl state is ONE point: the finger F that holds the page corner
// K = (W, H). F = K is a flat page, F = E = (-1.08 W, H) is a page that has left
// the view completely. Everything else (fold axis, cylinder radius) derives from F.
// ─────────────────────────────────────────────────────────────────────────────

typealias CurlVec = SIMD2<Double>

enum CurlMath {
    @inline(__always) static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    @inline(__always) static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func normalize(_ v: CurlVec, _ fallback: CurlVec) -> CurlVec {
        let l = simd_length(v)
        return l > 1e-9 ? v / l : fallback
    }
}

// MARK: - Frame (page space ↔ screen)

struct CurlFrame {
    let edge: BindingEdge
    /// Page view size in points, screen orientation.
    let view: CGSize

    /// Extent perpendicular to the binding.
    var W: Double { Double(edge == .top ? view.height : view.width) }
    /// Extent along the binding.
    var H: Double { Double(edge == .top ? view.width : view.height) }
    var isValid: Bool { view.width >= 8 && view.height >= 8 }

    /// Held corner: the bottom end of the free edge (screen bottom-right for both bindings).
    var K: CurlVec { CurlVec(W, H) }
    /// Finger position at which the turned page is completely out of the view.
    var E: CurlVec { CurlVec(-1.08 * W, H) }
    /// Canonical turn arc (cubic Bézier K → c1 → c2 → E): the corner lifts first,
    /// sweeps over in a gentle arc and lands flat behind the binding.
    var c1: CurlVec { CurlVec(0.55 * W, 0.75 * H) }
    var c2: CurlVec { CurlVec(-0.35 * W, 0.92 * H) }
    /// Horizontal travel of a full turn.
    var span: Double { K.x - E.x }

    func toPage(_ p: CGPoint) -> CurlVec {
        edge == .top ? CurlVec(Double(p.y), Double(p.x)) : CurlVec(Double(p.x), Double(p.y))
    }

    // MARK: fold

    static let maxTilt = 35.0 * .pi / 180
    var rMax: Double { 0.10 * W }
    var rMin: Double { 0.012 * W }

    /// Cylinder fold for a finger position.
    func fold(_ F: CurlVec) -> CurlFold {
        let D = K - F
        guard simd_length(D) > 1e-6 else { return .flat(at: K) }
        // 스프링에서 찢어지지 않게 축 기울기를 제한한다
        let angle = min(max(atan2(D.y, D.x), -Self.maxTilt), Self.maxTilt)
        let N = CurlVec(cos(angle), sin(angle))
        let dist = simd_dot(D, N)
        guard dist > 1e-6 else { return .flat(at: K) }
        // 시작과 끝은 납작하게, 가운데서 가장 둥글게
        let t = CurlMath.clamp01((K.x - F.x) / (2.08 * W))
        let r0 = rMin + (rMax - rMin) * sin(.pi * t)
        // 거의 평평할 때는 반지름도 0 으로 (dist/π 로 부드럽게 수렴)
        let r = r0 * (1 - exp(-dist / (.pi * r0)))
        let d0 = (dist + .pi * r) / 2
        return CurlFold(axisPoint: K - N * d0, normal: N, radius: r,
                        effect: CurlMath.smooth(0, 0.05 * W, r))
    }

    /// Normalised turn progress of a finger point (0 = rest, 1 = turned) for a direction.
    func progress(_ F: CurlVec, forward: Bool) -> Double {
        forward ? (K.x - F.x) / span : (F.x - E.x) / span
    }

    /// The finger x for a progress value.
    func fingerX(progress p: Double, forward: Bool) -> Double {
        forward ? K.x - p * span : E.x + p * span
    }
}

struct CurlFold {
    var axisPoint: CurlVec
    var normal: CurlVec
    var radius: Double
    /// 0…1 strength of lift-dependent shading (shadows, occlusion).
    var effect: Double

    static func flat(at K: CurlVec) -> CurlFold {
        CurlFold(axisPoint: K, normal: CurlVec(1, 0), radius: 0, effect: 0)
    }
}

// MARK: - Motion path

/// Cubic Bézier finger path. Driven by its own parameter (not arc length) so a glide can
/// start with any velocity, including one pointing away from the goal: the parameter
/// simply dips below 0 (the curve is extended backwards) and comes back.
struct CurlPath {
    let p0: CurlVec, p1: CurlVec, p2: CurlVec, p3: CurlVec

    init(_ p0: CurlVec, _ p1: CurlVec, _ p2: CurlVec, _ p3: CurlVec) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    static func bezier(_ a: CurlVec, _ b: CurlVec, _ c: CurlVec, _ d: CurlVec, _ s: Double) -> CurlVec {
        let m = 1 - s
        return a * (m * m * m) + b * (3 * m * m * s) + c * (3 * m * s * s) + d * (s * s * s)
    }

    static func derivative(_ a: CurlVec, _ b: CurlVec, _ c: CurlVec, _ d: CurlVec, _ s: Double) -> CurlVec {
        let m = 1 - s
        return (b - a) * (3 * m * m) + (c - b) * (6 * m * s) + (d - c) * (3 * s * s)
    }

    func point(_ s: Double) -> CurlVec { Self.bezier(p0, p1, p2, p3, s) }
    func derivative(_ s: Double) -> CurlVec { Self.derivative(p0, p1, p2, p3, s) }
}

// MARK: - Timing

/// Minimum-jerk ease (quintic): zero acceleration at both ends, a given initial slope
/// (to continue a release / peek, may be negative) and final slope. From rest it is
/// lightly time-warped so the page answers a key press quickly and lands softer.
/// A page that leaves the view keeps a little speed as it slides behind the rings
/// (no invisible crawl at the end); a page that lands flat settles gently.
struct CurlTiming {
    static let warp = 0.38
    static let maxSlope = 2.2
    static let minSlope = -1.5
    /// Slope of a page sliding out from behind / in under the binding rings (hidden there),
    /// and final slope of a page landing flat.
    static let exitSlope = 0.6
    static let landingSlope = 0.3

    private let k: Double
    private let a1: Double, a3: Double, a4: Double, a5: Double

    /// Slopes are d(parameter)/d(τ), τ = normalised time.
    init(initialSlope: Double, finalSlope: Double) {
        k = Self.warp * max(0, 1 - abs(initialSlope))
        let v0 = min(max(initialSlope / (1 + k), Self.minSlope), Self.maxSlope)
        let A = 1 - v0, B = finalSlope - v0
        a1 = v0
        a3 = 10 * A - 4 * B
        a4 = 7 * B - 15 * A
        a5 = 6 * A - 3 * B
    }

    private func w(_ t: Double) -> Double { t + k * t * (1 - t) * (1 - t) }
    private func dw(_ t: Double) -> Double { 1 + k * (1 - t) * (1 - 3 * t) }

    func value(_ tau: Double) -> Double {
        let x = w(CurlMath.clamp01(tau))
        let x3 = x * x * x
        return a1 * x + a3 * x3 + a4 * x3 * x + a5 * x3 * x * x
    }

    func slope(_ tau: Double) -> Double {
        let t = CurlMath.clamp01(tau)
        let x = w(t)
        let x2 = x * x
        return (a1 + 3 * a3 * x2 + 4 * a4 * x2 * x + 5 * a5 * x2 * x2) * dw(t)
    }
}

/// A timed finger motion along a path.
struct CurlGlide {
    let path: CurlPath
    let duration: Double
    let timing: CurlTiming

    func point(_ tau: Double) -> CurlVec {
        if tau <= 0 { return path.p0 }
        if tau >= 1 { return path.p3 }
        return path.point(timing.value(tau))
    }

    /// Finger velocity in points per second (at playback rate 1).
    func velocity(_ tau: Double) -> CurlVec {
        path.derivative(timing.value(tau)) * (timing.slope(tau) / duration)
    }

    /// Nominal duration of a full, automatic page turn.
    static let fullDuration = 0.66

    /// Glide from any finger state to the turned (E) or flat (K) position, continuing
    /// the current velocity and arriving along the canonical arc.
    static func make(in f: CurlFrame, from F0: CurlVec, velocity V0: CurlVec, toTurned: Bool,
                     entrySlope: Double = 0) -> CurlGlide? {
        let goal = toTurned ? f.E : f.K
        let chord = goal - F0
        let dist = simd_length(chord)
        guard dist > 0.25 else { return nil }
        let chordDir = chord / dist

        // canonical directions of the arc
        let home = toTurned ? f.K : f.E
        let canonicalStart = toTurned ? CurlMath.normalize(f.c1 - f.K, CurlVec(-1, 0)) : CurlMath.normalize(f.c2 - f.E, CurlVec(1, 0))
        let arrive = toTurned ? CurlMath.normalize(f.E - f.c2, CurlVec(-1, 0)) : CurlMath.normalize(f.K - f.c1, CurlVec(1, 0))

        // leave along the canonical arc near its start, along the chord elsewhere, and
        // follow a fast finger that already heads the right way
        let near = 1 - CurlMath.smooth(0, 0.35 * f.W, simd_length(F0 - home))
        var dir = CurlMath.normalize(simd_mix(chordDir, canonicalStart, CurlVec(repeating: near)), chordDir)
        let speed = simd_length(V0)
        if speed > 1e-6 {
            let a = CurlMath.smooth(0.03 * f.W, 0.5 * f.W, speed) * CurlMath.smooth(-0.2, 0.5, simd_dot(V0 / speed, chordDir))
            dir = CurlMath.normalize(simd_mix(dir, V0 / speed, CurlVec(repeating: a)), dir)
        }

        var duration = fullDuration * (0.34 + 0.66 * min(dist / f.span, 1.15))
        // initial slope s'(0) = (V0·dir) T / |B'(0)|, |B'(0)| = 3 lead (negative = moving away first)
        let along = simd_dot(V0, dir)
        var lead = 0.288 * dist
        if along > 0 {
            lead = max(lead, min(along * duration / (3 * CurlTiming.maxSlope), 0.6 * dist))
            let fastest = CurlTiming.maxSlope * 3 * lead / along
            if duration > fastest { duration = max(0.16, fastest) }
        }
        let slope = along * duration / (3 * lead) + entrySlope
        let path = CurlPath(F0, F0 + dir * lead, goal - arrive * (0.356 * dist), goal)
        let final = toTurned ? CurlTiming.exitSlope : CurlTiming.landingSlope
        return CurlGlide(path: path, duration: duration, timing: CurlTiming(initialSlope: slope, finalSlope: final))
    }

    /// The automatic turn used by flip() and the offscreen renderer. A backward turn starts
    /// with the previous page hidden behind the binding, so it enters already moving.
    static func canonical(in f: CurlFrame, forward: Bool) -> CurlGlide? {
        make(in: f, from: forward ? f.K : f.E, velocity: .zero, toTurned: forward,
             entrySlope: forward ? 0 : CurlTiming.exitSlope)
    }
}

/// y of the canonical arc as a function of the finger x (used by swipes / backward drags).
struct CurlArc {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private let H: Double

    init(_ f: CurlFrame) {
        H = f.H
        let n = 64
        xs.reserveCapacity(n + 1); ys.reserveCapacity(n + 1)
        // x decreases monotonically along K → E; store ascending.
        for i in stride(from: n, through: 0, by: -1) {
            let p = CurlPath.bezier(f.K, f.c1, f.c2, f.E, Double(i) / Double(n))
            xs.append(p.x); ys.append(p.y)
        }
    }

    func y(atX x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return H }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] < x { lo = mid } else { hi = mid }
        }
        let t = (x - xs[lo]) / max(xs[hi] - xs[lo], 1e-12)
        return ys[lo] + (ys[hi] - ys[lo]) * t
    }
}

// MARK: - Springs

enum CurlSpring {
    /// Exact damped-spring step toward a fixed target (stable for any dt).
    static func step(_ x: inout CurlVec, _ v: inout CurlVec, target: CurlVec, omega w: Double, damping z: Double, dt: Double) {
        guard dt > 0 else { return }
        let e0 = x - target
        if z >= 0.999 {
            let c = v + e0 * w
            let k = exp(-w * dt)
            x = target + (e0 + c * dt) * k
            v = (v - c * (w * dt)) * k
        } else {
            let wd = w * (1 - z * z).squareRoot()
            let k = exp(-z * w * dt)
            let cs = cos(wd * dt), sn = sin(wd * dt)
            let b = (v + e0 * (z * w)) / wd
            x = target + (e0 * cs + b * sn) * k
            v = (v * cs - (v * (z * w) + e0 * (w * w)) * (sn / wd)) * k
        }
    }
}

/// Recent-sample velocity estimate (inline storage: copying / mutating never allocates).
struct CurlVelocityTracker {
    private var t = SIMD16<Double>(repeating: 0)
    private var x = SIMD16<Double>(repeating: 0)
    private var count = 0
    private var head = 0
    /// Time of the most recent sample.
    private(set) var lastTime = 0.0

    mutating func add(_ value: Double, at time: Double) {
        lastTime = time
        t[head] = time; x[head] = value
        head = (head + 1) % t.scalarCount
        count = min(count + 1, t.scalarCount)
    }

    /// Least-squares slope over the last `window` seconds (units per second).
    func velocity(now: Double, window: Double = 0.09) -> Double {
        guard count >= 2 else { return 0 }
        var n = 0.0, st = 0.0, sx = 0.0, stt = 0.0, stx = 0.0
        for i in 0..<count {
            let j = (head - 1 - i + t.scalarCount) % t.scalarCount
            let dt = t[j] - now
            if dt < -window && n >= 2 { break }
            n += 1; st += dt; sx += x[j]; stt += dt * dt; stx += dt * x[j]
        }
        let den = n * stt - st * st
        guard n >= 2, abs(den) > 1e-12 else { return 0 }
        return (n * stx - st * sx) / den
    }
}
