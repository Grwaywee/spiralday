import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Open (spiral-bound) book: the leaf turning in this frame — for hosts that draw the coil above the see-through
// overlay (the twin-loop wire arching over the open gap; the leaf curls like a single page and, at the end, its
// binding strip rides around the coil — CurlSpreadFold).
//
// The leaf is threaded on the coil through its holes, so the wire and the leaf hide each other like on paper:
//   · the wire's upper arcs pass ABOVE the leaf between its binding edge and its holes (inside the coil) and BELOW
//     everything of the leaf beyond its holes (the roll, the flap lying over the gap) — mask the arcs with
//     `lifted(bindingMargin:)` from the holes (+ the wire's own reach) on;
//   · the coil's lower arcs (seen in the gap, or around the edge of a closed book) are under the whole leaf — mask
//     them with `lifted(bindingMargin: 0)`.
// The shape is the leaf's paper as seen from above (the same model the shader draws) and stays put on the landing
// frame: a leaf lying on the other side keeps hiding what lies under it until the host has drawn the new spread.
// ─────────────────────────────────────────────────────────────────────────────

/// The leaf of an open book that is turning in the frame the overlay shows now (see `CurlController.spreadLeaf`).
public struct CurlSpreadLeaf: Sendable {
    let geometry: CurlSpread
    /// +1 lifting the recto (forward), −1 the verso (backward)
    let sigma: Double
    let holdTop: Bool
    let fold: CurlSpreadFold

    /// The side being lifted (.forward = recto, .backward = verso).
    public var direction: FlipDirection { sigma > 0 ? .forward : .backward }

    /// How far the leaf's holes have gone around the coil (0 = the strip still lies on its own side — most of a turn,
    /// while the leaf curls; π = landed on the other side).
    public var holeAngle: Double { fold.theta }

    /// Whether the leaf lies flat (at rest or landed).
    public var isFlat: Bool { fold.isFlat }

    /// Region of the overlay (its own points) the leaf's paper covers on screen from `bindingMargin` points past
    /// its binding edge on (0 = the whole leaf; the holes' distance + the wire's reach = what lies above the wire).
    public func lifted(bindingMargin: CGFloat) -> CurlSheetShape {
        let g = geometry
        let outline = fold.outline(from: Double(g.halfGutter) + Double(max(bindingMargin, 0)))
        guard outline.count >= 3 else { return .none }
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let hinge = Double(g.hinge), x0 = Double(lift.minX), y0 = Double(lift.minY), H = fold.H
        let horizontal = g.axis == .horizontal
        let view = outline.map { q -> CurlVec in
            let across = sigma * q.x
            let along = holdTop ? H - q.y : q.y
            return horizontal ? CurlVec(x0 + along, hinge + across) : CurlVec(hinge + across, y0 + along)
        }
        // keep what the overlay shows
        let w = Double(g.overlaySize.width), h = Double(g.overlaySize.height)
        var poly = Self.clip(view) { $0.x }
        poly = Self.clip(poly) { w - $0.x }
        poly = Self.clip(poly) { $0.y }
        poly = Self.clip(poly) { h - $0.y }
        guard poly.count >= 3 else { return .none }
        return CurlSheetShape(outline: poly.map { CGPoint(x: $0.x, y: $0.y) })
    }

    /// The leaf of an automatic spread turn (the canonical arc) at `progress` (0 = flat, 1 = landed) — the same frame
    /// `CurlController.renderSpreadStills` draws (tests · QA).
    public static func turn(spread g: CurlSpread, direction: FlipDirection, holdTop: Bool = false,
                            stiffness: Double = 1, progress: Double) -> CurlSpreadLeaf {
        let sigma = direction == .forward ? 1.0 : -1.0
        let frame = CurlFrame.spread(g, direction: direction, stiffness: stiffness)
        return CurlSpreadLeaf(geometry: g, sigma: sigma, holdTop: holdTop, fold: frame.spreadFold(frame.arcFinger(progress)))
    }

    /// Sutherland–Hodgman against one half-plane { inside(p) ≥ 0 }.
    private static func clip(_ poly: [CurlVec], _ inside: (CurlVec) -> Double) -> [CurlVec] {
        guard !poly.isEmpty else { return [] }
        var out: [CurlVec] = []
        out.reserveCapacity(poly.count + 4)
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let da = inside(a), db = inside(b)
            if da >= 0 { out.append(a) }
            if (da >= 0) != (db >= 0) { out.append(a + (b - a) * (da / (da - db))) }
        }
        return out
    }
}

extension CurlFrame {
    /// The frame of a spread turn that lifts the recto (forward) or the verso (backward) of `g`.
    static func spread(_ g: CurlSpread, direction: FlipDirection, stiffness: Double) -> CurlFrame {
        let lift = direction == .forward ? g.rectoRect : g.versoRect
        let across = Double(g.axis == .vertical ? lift.width : lift.height)
        let along = Double(g.axis == .vertical ? lift.height : lift.width)
        return .spread(W: Double(g.halfGutter) + across, H: along, halfGutter: Double(g.halfGutter),
                       stiffness: stiffness, coil: Double(g.coil))
    }

    /// The finger of an automatic turn at `progress` (0 = rest, 1 = turned): on the canonical arc.
    func arcFinger(_ progress: Double) -> CurlVec {
        if progress >= 1 { return E }
        if progress <= 0 { return K }
        let x = fingerX(progress: progress, forward: true)
        return CurlVec(x, CurlArc(self).y(atX: x))
    }
}

extension CurlSpread {
    /// The overlay point of the finger of an automatic turn at `progress` (0 = rest, 1 = landed on the other side):
    /// on the canonical arc, the path `CurlController.flip` takes. A host that drives a turn by progress (a swipe
    /// anywhere on the page, a QA hold) hands these points to `dragBegan` / `dragChanged` — the leaf then curls like
    /// an automatic turn, the way a single page follows `swipe`. Progress may overshoot a little (−0.1 … 1.1).
    public func arcPoint(_ direction: FlipDirection, progress: Double) -> CGPoint {
        let frame = CurlFrame.spread(self, direction: direction, stiffness: 1)
        let p = min(max(progress, -0.1), 1.1)
        let x = frame.fingerX(progress: p, forward: true)
        let F = CurlVec(x, CurlArc(frame).y(atX: x))
        let sigma = direction == .forward ? 1.0 : -1.0
        let lift = direction == .forward ? rectoRect : versoRect
        let across = CGFloat(sigma * F.x), along = CGFloat(F.y)
        return axis == .vertical ? CGPoint(x: hinge + across, y: lift.minY + along)
                                 : CGPoint(x: lift.minX + along, y: hinge + across)
    }
}
