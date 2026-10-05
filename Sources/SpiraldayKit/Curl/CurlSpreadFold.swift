import Foundation
import CoreGraphics
import simd

// ─────────────────────────────────────────────────────────────────────────────
// Open spiral notebook (spread mode, iPad): the turning leaf CURLS exactly like a single page — the same cylinder
// (one finger point F, axis tilt ≤ 35°, radius rMin … rMax·sin πt, the flap lying over at height 2r, the same
// shading in CurlSpreadShader) — but it hangs on the coil by its holes, so it never slides off the binding:
//
//   1. While the roll is beyond the holes, the leaf IS the single page's curl: its flat part (binding strip and
//      holes included) lies on its own page. Close to the holes the axis tilts less, so that it reaches the hole
//      line along the whole binding at once.
//   2. Once the roll reaches the holes it stays there, and the strip up to them (the binding edge g/2 … the holes at
//      `coil`) turns about the coil axis by θ: its holes ride around the coil, never along the paper. The roll
//      turns the rest of the way (π − θ), so the flap stays parallel to the desk while it comes down. θ follows the
//      finger: the free corner stays under it (screen x), like the corner of a single page.
//   3. θ = π: the leaf lies flat, mirrored about the coil axis (x → −x) — exactly the page on the other side.
//
// σ-space (the lifted side's space): x = distance from the coil axis toward the lifted page, y = along the binding,
// z = height above the pages. A paper point s ∈ [g/2, W′] × [0, H], d = (s − A)·N its distance past the axis:
//   d ≤ 0                       flat     (s, 0)
//   0 < d ≤ ψr   (ψ = π − θ)    roll     s − N d + N r sin(d/r),            height r (1 − cos(d/r))
//   d > ψr,  e = d − ψr         flap     s − N d + N (r sin ψ + e cos ψ),   height r (1 − cos ψ) + e sin ψ
// then the turn about the coil axis: (x, z) → (x cos θ − z sin θ, x sin θ + z cos θ). Seen from straight above like
// the single page (orthographic): screen = (x, y). With θ = 0 this is exactly the single page's cylinder.
// ─────────────────────────────────────────────────────────────────────────────

/// One frame of an open book's turning leaf (see above). Built by `CurlFrame.spreadFold(_:)`.
struct CurlSpreadFold {
    /// The cylinder in the leaf's own plane (axis · normal · radius); its effect is the frame's shading strength.
    var fold: CurlFold
    /// The binding strip's turn about the coil axis: 0 = lying on its own side (the whole single-page curl), π = landed.
    var theta: Double
    var cosTheta: Double
    var sinTheta: Double
    /// The finger has left the rest position (the back of the leaf can show).
    var lifted: Bool
    /// Leaf length W′ (from the coil axis), length along the binding, the open half gap, the coil's radius (holes).
    let W: Double
    let H: Double
    let halfGutter: Double
    let coil: Double

    /// Lying flat: at rest, or landed on the other side (no shading — exactly the pages).
    var isFlat: Bool { fold.effect == 0 }

    // MARK: 3D

    /// Where a paper point (σ-space page coordinates) is in this frame: (screen x, screen y, height) in σ-space.
    func position(_ s: CurlVec) -> SIMD3<Double> {
        let N = fold.normal, A = fold.axisPoint, r = fold.radius
        let psi = Double.pi - theta
        let d = simd_dot(s - A, N)
        var p = s, w = 0.0
        if d > 0 {
            if r > 1e-12 && d <= psi * r {
                let phi = d / r
                p = s - N * d + N * (r * sin(phi))
                w = r * (1 - cos(phi))
            } else {
                let e = d - psi * r
                p = s - N * d + N * (r * sin(psi) + e * cos(psi))
                w = r * (1 - cos(psi)) + e * sin(psi)
            }
        }
        return SIMD3(p.x * cosTheta - w * sinTheta, p.y, p.x * sinTheta + w * cosTheta)
    }

    // MARK: outline (seen from above)

    /// The region the leaf's paper from `s0` (distance from the coil axis, ≥ g/2) on covers on screen, σ-space.
    func outline(from s0: Double) -> [CurlVec] {
        let lo = max(s0, halfGutter)
        guard lo < W - 1e-6, H > 1e-6 else { return [] }
        return theta > 0 ? pivotOutline(lo) : curlOutline(lo)
    }

    /// Whether a σ-space point is on the leaf as seen from above.
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

    /// θ = 0 (the single page's cylinder): along the axis (t) the cylinder keeps every line; across it (u, past the
    /// axis) the flat part stays where it is and the rest goes to r·sin(u/r) (roll) / πr − u (flap). For each t the
    /// paper covers one interval — the upper and lower ends trace the outline.
    private func curlOutline(_ lo: Double) -> [CurlVec] {
        let N = CurlMath.normalize(fold.normal, CurlVec(1, 0))
        let T = CurlVec(-N.y, N.x)
        let A = fold.axisPoint
        let r = max(fold.radius, 0)
        let halfTurn = Double.pi * r
        let corners = [CurlVec(lo, 0), CurlVec(W, 0), CurlVec(W, H), CurlVec(lo, H)].map {
            CurlVec(simd_dot($0 - A, T), simd_dot($0 - A, N))
        }
        func depth(_ u: Double) -> Double {
            guard r > 1e-6 else { return -u }
            return u <= halfTurn ? r * sin(u / r) : halfTurn - u
        }
        let ts = corners.map(\.x)
        guard let t0 = ts.min(), let t1 = ts.max(), t1 - t0 > 1e-6 else { return [] }
        var samples = (0...128).map { t0 + (t1 - t0) * Double($0) / 128 }
        samples += ts
        // densely where an edge of the paper crosses the roll
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            guard abs(b.y - a.y) > 1e-9 else { continue }
            for k in 0...16 {
                let s = (halfTurn * Double(k) / 16 - a.y) / (b.y - a.y)
                if s > 0, s < 1 { samples.append(a.x + (b.x - a.x) * s) }
            }
        }
        samples = samples.map { min(max($0, t0), t1) }.sorted()
        var upper: [CurlVec] = [], lower: [CurlVec] = []
        var last = -Double.infinity
        for t in samples where t - last > 1e-7 {
            last = t
            guard let (uLo, uHi) = Self.span(corners, at: t) else { continue }
            var dLo: Double, dHi: Double
            if uHi <= 0 {
                (dLo, dHi) = (uLo, uHi)
            } else {
                let a = max(uLo, 0)
                let da = depth(a), db = depth(uHi)
                dHi = (a <= halfTurn / 2 && halfTurn / 2 <= uHi) ? r : max(da, db)
                dLo = min(da, db)
                if uLo < 0 { dLo = min(dLo, uLo); dHi = max(dHi, 0) }
            }
            upper.append(A + T * t + N * dHi)
            lower.append(A + T * t + N * dLo)
        }
        guard upper.count >= 2 else { return [] }
        return upper + lower.reversed()
    }

    /// θ > 0 (the axis is parallel to the binding): every row is the same cross-section — strip, roll, flap.
    private func pivotOutline(_ lo: Double) -> [CurlVec] {
        let a = fold.axisPoint.x, r = max(fold.radius, 0)
        let rollEnd = a + r * (Double.pi - theta)
        var ss = [lo, W, min(max(a, lo), W), min(max(rollEnd, lo), W)]
        // the top of the roll (its normal straight up: β = θ + (s − a)/r = π/2), and the roll in between
        if theta < .pi / 2 { ss.append(min(max(a + r * (.pi / 2 - theta), lo), W)) }
        for k in 1..<32 { ss.append(min(max(a + (rollEnd - a) * Double(k) / 32, lo), W)) }
        let xs = ss.map { position(CurlVec($0, 0)).x }
        guard let x0 = xs.min(), let x1 = xs.max(), x1 - x0 > 1e-9 else { return [] }
        return [CurlVec(x0, 0), CurlVec(x1, 0), CurlVec(x1, H), CurlVec(x0, H)]
    }

    /// The u interval of a convex polygon (t, u) on the line t = const.
    private static func span(_ poly: [CurlVec], at t: Double) -> (Double, Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if abs(a.x - t) < 1e-9 { lo = min(lo, a.y); hi = max(hi, a.y) }
            if (a.x - t) * (b.x - t) < 0 {
                let u = a.y + (b.y - a.y) * (t - a.x) / (b.x - a.x)
                lo = min(lo, u); hi = max(hi, u)
            }
        }
        return lo <= hi ? (lo, hi) : nil
    }
}

extension CurlFrame {
    /// The open book's leaf for a finger position (see the top of this file). Single-page frames answer their
    /// cylinder with θ = 0.
    func spreadFold(_ F: CurlVec) -> CurlSpreadFold {
        let sp = spread ?? Spread(W: W, H: H, halfGutter: 0, stiffness: 1, coil: 0)
        let W = sp.W, H = sp.H, coil = sp.coil
        let lifted = simd_length(F - K) > 1e-3
        func make(_ fold: CurlFold, theta: Double = 0) -> CurlSpreadFold {
            let landed = theta >= .pi
            return CurlSpreadFold(fold: fold, theta: landed ? .pi : theta,
                                  cosTheta: theta == 0 ? 1 : landed ? -1 : cos(theta),
                                  sinTheta: theta == 0 || landed ? 0 : sin(theta),
                                  lifted: lifted, W: W, H: H, halfGutter: sp.halfGutter, coil: coil)
        }
        guard spread != nil else { return make(fold(F)) }
        let D = K - F
        guard simd_length(D) > 1e-6 else { return make(.flat(at: K)) }
        // the single page's radius: flat at both ends, roundest half way (a board: rounder); 0 while nearly flat
        let tilt = sp.stiffness > 1.01 ? Self.boardTilt : Self.maxTilt
        let t = CurlMath.clamp01((K.x - F.x) / span)
        let r0 = min(sp.stiffness * (rMin + (rMax - rMin) * sin(.pi * t)), 0.25 * W)
        func radius(_ dist: Double) -> Double { r0 > 1e-9 ? r0 * (1 - exp(-dist / (.pi * r0))) : 0 }
        // landed: the leaf lies on the other side, mirrored about the coil axis (the roll has turned 0, no shading)
        if F.x <= E.x + 1e-9 {
            return make(CurlFold(axisPoint: CurlVec(coil, H), normal: CurlVec(1, 0), radius: radius(D.x), effect: 0), theta: .pi)
        }
        // the single page's cylinder for an axis angle, and where its axis comes closest to the binding on the page
        func cylinder(_ angle: Double) -> (fold: CurlFold, nearest: Double)? {
            let N = CurlVec(cos(angle), sin(angle))
            let dist = simd_dot(D, N)
            guard dist > 1e-6 else { return nil }
            let r = radius(dist)
            let d0 = (dist + .pi * r) / 2
            let nearest = W - d0 / cos(angle) + min(0, H * tan(angle))
            return (CurlFold(axisPoint: K - N * d0, normal: N, radius: r, effect: CurlMath.smooth(0, 0.05 * W, r)), nearest)
        }
        let angle = min(max(atan2(D.y, D.x), -tilt), tilt)
        guard let free = cylinder(angle) else { return make(.flat(at: K)) }
        if free.nearest >= coil { return make(free.fold) }
        let straight = cylinder(0)
        if (straight?.nearest ?? .infinity) >= coil {
            // the tilted axis would roll the holes at one end of the binding: tilt only as far as it stays beyond them
            // (no cylinder at all = the leaf still lies flat)
            var lo = 0.0, hi = 1.0
            for _ in 0..<40 {
                let m = (lo + hi) / 2
                if (cylinder(angle * m)?.nearest ?? .infinity) >= coil { lo = m } else { hi = m }
            }
            return make(cylinder(angle * lo)?.fold ?? .flat(at: K))
        }
        // the roll has reached the holes: it stays there and the strip turns about the coil, θ such that the free
        // corner lies under the finger (the corner's x falls monotonically from 2·coil + πr − W′ at θ = 0 to −W′ at π)
        let r = radius(D.x)
        func cornerX(_ th: Double) -> Double { coil * cos(th) - r * sin(th) - (W - coil - r * (.pi - th)) }
        var lo = 0.0, hi = Double.pi
        for _ in 0..<60 {
            let m = (lo + hi) / 2
            if cornerX(m) > F.x { lo = m } else { hi = m }
        }
        let th = (lo + hi) / 2
        // shading follows the flap's height (2r on a single page)
        let height = coil * sin(th) + r * (1 + cos(th))
        return make(CurlFold(axisPoint: CurlVec(coil, H), normal: CurlVec(1, 0), radius: r,
                             effect: CurlMath.smooth(0, 0.05 * W, height / 2)), theta: th)
    }
}
