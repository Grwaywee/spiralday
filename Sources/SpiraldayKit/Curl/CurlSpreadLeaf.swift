import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Open (spiral-bound) book: the leaf turning in this frame — for hosts that draw the coil above the see-through
// overlay (the twin-loop wire arching over the open gap; CurlHingeLeaf turns the leaf about the coil's axis).
//
// The leaf is threaded on the coil through its holes, so the wire and the leaf hide each other like on paper:
//   · the wire's upper arcs pass ABOVE the leaf between its binding edge and its holes (inside the coil) and BELOW
//     everything of the leaf beyond its holes — mask the arcs with `lifted(bindingMargin:)` from the holes (+ the
//     wire's own reach) on;
//   · the coil's lower arcs (seen in the gap, or around the edge of a closed book) are under the whole leaf — mask
//     them with `lifted(bindingMargin: 0)`.
// The shape is the leaf's paper as seen on screen (its perspective included) and stays put on the landing frame:
// a leaf lying on the other side keeps hiding what lies under it until the host has drawn the new spread.
// ─────────────────────────────────────────────────────────────────────────────

/// The leaf of an open book that is turning in the frame the overlay shows now (see `CurlController.spreadLeaf`).
public struct CurlSpreadLeaf: Sendable {
    let geometry: CurlSpread
    /// +1 lifting the recto (forward), −1 the verso (backward)
    let sigma: Double
    let holdTop: Bool
    let leaf: CurlHingeLeaf

    /// The side being lifted (.forward = recto, .backward = verso).
    public var direction: FlipDirection { sigma > 0 ? .forward : .backward }

    /// The leaf's angle about the coil (0 = lying on its own side, π = landed on the other side).
    public var angle: Double { leaf.theta }

    /// Whether the leaf lies flat (at rest or landed).
    public var isFlat: Bool { leaf.isFlat }

    /// Region of the overlay (its own points) the leaf's paper covers on screen from `bindingMargin` points past
    /// its binding edge on (0 = the whole leaf; the holes' distance + the wire's reach = what lies above the wire).
    public func lifted(bindingMargin: CGFloat) -> CurlSheetShape {
        let g = geometry
        let s0 = Double(g.halfGutter) + Double(max(bindingMargin, 0))
        let outline = leaf.outline(from: s0)
        guard outline.count >= 3 else { return .none }
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let hinge = Double(g.hinge), x0 = Double(lift.minX), y0 = Double(lift.minY)
        let horizontal = g.axis == .horizontal
        let w = g.overlaySize.width, h = g.overlaySize.height
        let pts = outline.map { q -> CGPoint in
            let across = sigma * q.x
            let p = horizontal ? CGPoint(x: x0 + q.y, y: hinge + across) : CGPoint(x: hinge + across, y: y0 + q.y)
            // keep inside the overlay
            return CGPoint(x: min(max(p.x, 0), w), y: min(max(p.y, 0), h))
        }
        return CurlSheetShape(outline: pts)
    }

    /// The leaf of an automatic spread turn at `progress` (0 = flat, 1 = landed: the free edge at that fraction of its
    /// way across) — the same frame `CurlController.renderSpreadStills` draws (tests · QA).
    public static func turn(spread g: CurlSpread, direction: FlipDirection, holdTop: Bool = false,
                            stiffness: Double = 1, progress: Double) -> CurlSpreadLeaf {
        let sigma = direction == .forward ? 1.0 : -1.0
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let across = Double(g.axis == .vertical ? lift.width : lift.height)
        let along = Double(g.axis == .vertical ? lift.height : lift.width)
        let frame = CurlFrame.spread(W: Double(g.halfGutter) + across, H: along, halfGutter: Double(g.halfGutter),
                                     stiffness: stiffness, coil: Double(g.coil))
        let finger: CurlVec = progress >= 1 ? frame.E : progress <= 0 ? frame.K
            : CurlVec(frame.fingerX(progress: progress, forward: true), frame.H)
        return CurlSpreadLeaf(geometry: g, sigma: sigma, holdTop: holdTop, leaf: CurlHingeLeaf(frame: frame, finger: finger))
    }
}
