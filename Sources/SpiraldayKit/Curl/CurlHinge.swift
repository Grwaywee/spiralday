import Foundation
import CoreGraphics
import simd

// ─────────────────────────────────────────────────────────────────────────────
// Open book (spread mode, iPad): a SPIRAL-BOUND leaf turning about the coil.
//
// A spiral notebook's leaf is threaded on the coil through its holes. It turns about the coil's axis — the hinge
// line in the middle of the open gap between the two pages — so its binding edge never slides or folds into a
// gutter. The leaf stays almost rigid; past its holes it bows gently toward the free edge: the edge leads while the
// leaf rises on its own side (lifted by the hand, sagging between the coil and the hand), it trails as the leaf
// falls onto the other side, and the leaf lies exactly flat on either side.
//
// CROSS-SECTION (the plane across the binding), the lifted side's space ("σ-space"): x = distance from the hinge
// toward the lifted page, z = height above the pages. s = arc length along the leaf from the hinge axis. Its paper
// is s ∈ [g/2, W′] (the gap [0, g/2) holds no paper), its holes are at s = coil (the coil's radius).
//
//   φ(s) = θ                                    s ≤ coil   (rigid between the axis and the holes)
//   φ(s) = θ + β·((s − coil) / (W′ − coil))²    s > coil   (the bow, strongest at the free edge)
//   X(s) = ∫ cos φ ds,  Z(s) = ∫ sin φ ds
//
// The pose follows ONE number — the finger's x (F.x of CurlFrame, page space): the free edge lies under it,
// X(W′) = F.x, and the bow is β = B·(sin 2θₑ − 0.4 sin² θₑ) with θₑ = acos(F.x / W′) (0 = flat, π = landed): the
// edge leads while the leaf rises, it is a little behind when the leaf stands up (so a leaf seen edge-on still
// shows a sliver of paper, never a line) and trails as it falls. At F = K (rest) and F = E (landed) β = 0 and
// θ = 0 / π exactly: the leaf is the page lying flat on its own / the other side.
//
// SCREEN: a gentle perspective from a camera above the middle of the book, `camera` = 8 W′ away (the Android
// tablet's CSS leaf uses the same): across = X·k, along = c + (y − c)·k, k = camera / (camera − Z), c = H / 2.
// ─────────────────────────────────────────────────────────────────────────────

struct CurlHingeLeaf {
    /// Profile samples: index 0 = the paper's binding edge (s = g/2), 1 = the holes (s = coil), then evenly to W′.
    static let bowSamples = 38
    /// Bow of a paper leaf (rad at the free edge, at 45° / 135°); a board divides it by stiffness².
    static let paperBow = 0.30
    /// Camera distance in leaf lengths (W′): a leaf standing up looks 14% longer along the binding.
    static let cameraLeaves = 8.0

    let W: Double
    let H: Double
    let halfGutter: Double
    let coil: Double
    let camera: Double
    /// Angle of the rigid part (0 = flat on its own side, π = on the other side).
    let theta: Double
    /// Bow at the free edge (rad, + = leading).
    let bow: Double
    /// 0 at rest / landed … 1 once the leaf is clearly in the air (shading, shadows).
    let effect: Double
    /// (X, Z, s, φ) per sample.
    let profile: [SIMD4<Double>]

    var isFlat: Bool { effect == 0 }

    init(frame f: CurlFrame, finger F: CurlVec) {
        let sp = f.spread ?? CurlFrame.Spread(W: f.W, H: f.H, halfGutter: 0, stiffness: 1, coil: 0)
        W = sp.W
        H = sp.H
        halfGutter = sp.halfGutter
        coil = sp.coil
        camera = Self.cameraLeaves * sp.W
        let x = min(max(F.x, -W), W)
        let rest = F.x >= W - 1e-9
        let landed = F.x <= -W + 1e-9
        let edgeAngle = acos(min(max(x / W, -1), 1))
        let B = Self.paperBow / (sp.stiffness * sp.stiffness)
        let beta = rest || landed ? 0 : B * (sin(2 * edgeAngle) - 0.4 * sin(edgeAngle) * sin(edgeAngle))
        bow = beta
        let theta: Double
        if rest {
            theta = 0
        } else if landed {
            theta = .pi
        } else {
            theta = Self.solve(x: x, beta: beta, W: W, coil: sp.coil, guess: edgeAngle)
        }
        self.theta = theta
        profile = Self.profile(theta: theta, beta: beta, W: W, halfGutter: sp.halfGutter, coil: sp.coil)
        if rest || landed {
            effect = 0
        } else {
            let zMax = profile.map(\.y).max() ?? 0
            let e = CurlMath.smooth(0, 0.07 * W, zMax)
            effect = e < 1e-4 ? 0 : e
        }
    }

    // MARK: pose

    /// Local angle at arc length s.
    static func phi(_ s: Double, theta: Double, beta: Double, W: Double, coil: Double) -> Double {
        guard s > coil, W > coil else { return theta }
        let q = (s - coil) / (W - coil)
        return theta + beta * q * q
    }

    /// The free edge's x for a rigid angle θ (midpoint rule over the bowed part).
    private static func edgeX(theta: Double, beta: Double, W: Double, coil: Double) -> (x: Double, z: Double) {
        var x = coil * cos(theta), z = coil * sin(theta)
        let n = bowSamples
        let h = (W - coil) / Double(n)
        for i in 0..<n {
            let s = coil + (Double(i) + 0.5) * h
            let p = phi(s, theta: theta, beta: beta, W: W, coil: coil)
            x += h * cos(p)
            z += h * sin(p)
        }
        return (x, z)
    }

    /// θ such that the free edge lies at x (Newton on dX/dθ = −Z, bisection when it stalls).
    private static func solve(x: Double, beta: Double, W: Double, coil: Double, guess: Double) -> Double {
        var lo = -0.8, hi = Double.pi + 0.8
        var t = guess - beta * 0.4
        for _ in 0..<24 {
            let e = edgeX(theta: t, beta: beta, W: W, coil: coil)
            let err = e.x - x
            if abs(err) < 1e-7 * W { break }
            if err > 0 { lo = max(lo, t) } else { hi = min(hi, t) }   // X falls as θ grows
            var next = e.z > 1e-6 * W ? t + err / e.z : (lo + hi) / 2
            if !(next > lo && next < hi) { next = (lo + hi) / 2 }
            t = next
        }
        return t
    }

    /// (X, Z, s, φ): the paper's binding edge, the holes, then the bowed part.
    private static func profile(theta: Double, beta: Double, W: Double, halfGutter: Double, coil: Double) -> [SIMD4<Double>] {
        var out: [SIMD4<Double>] = []
        out.reserveCapacity(bowSamples + 2)
        let c = cos(theta), sn = sin(theta)
        out.append(SIMD4(halfGutter * c, halfGutter * sn, halfGutter, theta))
        var x = coil * c, z = coil * sn
        if coil > halfGutter + 1e-9 { out.append(SIMD4(x, z, coil, theta)) }
        let h = (W - coil) / Double(bowSamples)
        for i in 0..<bowSamples {
            let s0 = coil + Double(i) * h
            let p = phi(s0 + 0.5 * h, theta: theta, beta: beta, W: W, coil: coil)
            x += h * cos(p)
            z += h * sin(p)
            let s1 = i == bowSamples - 1 ? W : s0 + h
            out.append(SIMD4(x, z, s1, phi(s1, theta: theta, beta: beta, W: W, coil: coil)))
        }
        // flat at rest / landed: exactly the page (no drift from the sum)
        if beta == 0 && (theta == 0 || theta == .pi) {
            let sign = theta == 0 ? 1.0 : -1.0
            out = out.map { SIMD4(sign * $0.z, 0, $0.z, theta) }
        }
        return out
    }

    // MARK: screen

    /// Perspective factor at height z.
    func k(_ z: Double) -> Double { camera / max(camera - z, 1e-6) }

    /// Projected across (σ-space) of profile sample i.
    func across(_ i: Int) -> Double { profile[i].x * k(profile[i].y) }

    /// The region the leaf's paper from arc length `s0` on covers on screen, in σ-space:
    /// (across from the hinge toward the lifted side, along from the lifted page's start — page y, not flipped).
    /// x-monotone: for each across, the leaf's highest point there sets how far beyond the page ends it reaches.
    func outline(from s0: Double) -> [CurlVec] {
        let start = max(s0, halfGutter)
        guard start < W - 1e-6 else { return [] }
        // samples from s0 (interpolated) to the edge
        var pts: [(a: Double, k: Double)] = []
        for i in 0..<(profile.count - 1) {
            let p = profile[i], q = profile[i + 1]
            if q.z <= start { continue }
            if p.z < start {
                let t = (start - p.z) / max(q.z - p.z, 1e-12)
                let X = p.x + (q.x - p.x) * t, Z = p.y + (q.y - p.y) * t
                pts.append((X * k(Z), k(Z)))
            } else if pts.isEmpty {
                pts.append((across(i), k(p.y)))
            }
            pts.append((across(i + 1), k(q.y)))
        }
        guard pts.count >= 2 else { return [] }
        // columns: every sample's across plus an even grid
        let lo = pts.map(\.a).min()!, hi = pts.map(\.a).max()!
        guard hi - lo > 1e-6 else { return [] }
        var cols = pts.map(\.a)
        for i in 0...48 { cols.append(lo + (hi - lo) * Double(i) / 48) }
        cols.sort()
        let c = H / 2
        var top: [CurlVec] = [], bottom: [CurlVec] = []
        var last = -Double.infinity
        for a in cols where a - last > 1e-6 * W {
            last = a
            var kMax = 0.0
            for j in 0..<(pts.count - 1) {
                let p = pts[j], q = pts[j + 1]
                let a0 = min(p.a, q.a), a1 = max(p.a, q.a)
                guard a >= a0 - 1e-9, a <= a1 + 1e-9 else { continue }
                let t = a1 - a0 > 1e-12 ? (a - p.a) / (q.a - p.a) : 0
                kMax = max(kMax, p.k + (q.k - p.k) * min(max(t, 0), 1))
            }
            guard kMax > 0 else { continue }
            top.append(CurlVec(a, c - c * kMax))
            bottom.append(CurlVec(a, c + (H - c) * kMax))
        }
        guard top.count >= 2 else { return [] }
        return top + bottom.reversed()
    }

    /// Whether a σ-space point (across, page y) is on the leaf as seen on screen.
    func covers(_ q: CurlVec) -> Bool {
        let poly = outline(from: halfGutter)
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y) {
                let x = a.x + (q.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if q.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: shadow

    /// Bins of the shadow profile (σ-space across from −1.15 W′ to 1.15 W′).
    static let shadowBins = 192
    static let shadowReach = 1.15

    /// The leaf's soft shadow on the pages below, per across bin (0…1 darkness, × effect). The light comes from
    /// above, a little from the binding's start (screen top-left): a leaf in the air casts a band that widens and
    /// fades with its height, darkest where it is close to the paper (the hinge, a leaf about to land).
    /// `lightSlope` = how far the shadow moves away from the hinge per unit height (σ-space; the host's light).
    func shadow(lightSlope: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Self.shadowBins)
        guard effect > 0 else { return out }
        let span = 2 * Self.shadowReach * W
        let bin = span / Double(Self.shadowBins)
        struct Seg { var a0, a1, i0, i1, w0, w1: Double }
        var segs: [Seg] = []
        func foot(_ p: SIMD4<Double>) -> (a: Double, i: Double, w: Double) {
            let z = max(p.y, 0)
            return (p.x + lightSlope * z, 0.30 * exp(-z / (0.8 * W)), 1.5 + 0.22 * z)
        }
        for j in 0..<(profile.count - 1) {
            let p = foot(profile[j]), q = foot(profile[j + 1])
            segs.append(Seg(a0: p.a, a1: q.a, i0: p.i, i1: q.i, w0: p.w, w1: q.w))
        }
        for b in 0..<Self.shadowBins {
            let a = -Self.shadowReach * W + (Double(b) + 0.5) * bin
            var v = 0.0
            for s in segs {
                let lo = min(s.a0, s.a1), hi = max(s.a0, s.a1)
                let t = hi - lo > 1e-9 ? min(max((a - s.a0) / (s.a1 - s.a0), 0), 1) : 0
                let d = a < lo ? lo - a : a > hi ? a - hi : 0
                let w = s.w0 + (s.w1 - s.w0) * t
                let i = s.i0 + (s.i1 - s.i0) * t
                v = max(v, i * (1 - CurlMath.smooth(0, w, d)))
            }
            out[b] = Float(v * effect)
        }
        return out
    }
}
