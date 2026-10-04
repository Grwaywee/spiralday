import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Open book (spread mode): the leaf turning in this frame — for hosts that draw the binding
// (the twin-loop wire across the gutter) above the see-through overlay.
//
// The wire must go UNDER the lifted leaf (its roll and the flap lying over the other page)
// but stay ON the leaf where it is threaded through it: the leaf's own binding margin
// (half gutter + its holes). Leaving that margin out of the mask also makes the shape end
// clean: when the leaf has landed on the other page (radius 0, mirrored), only its margin
// lies under the wire, so nothing is hidden on the last frame (no pop when the overlay hides).
//
// Same cylinder as CurlSpreadShader: page space q = (σ·across, along) from the hinge, the
// sheet's paper is [g/2, W′] × [0, H]; overlay = sp_toOverlay(q, landed: false).
// ─────────────────────────────────────────────────────────────────────────────

/// The leaf of an open book that is turning in the frame the overlay shows now (see `CurlController.spreadLeaf`).
public struct CurlSpreadLeaf: Sendable {
    let geometry: CurlSpread
    /// +1 lifting the recto (forward), −1 the verso (backward)
    let sigma: Double
    let holdTop: Bool
    let frame: CurlFrame
    let fold: CurlFold

    /// The side being lifted (.forward = recto, .backward = verso).
    public var direction: FlipDirection { sigma > 0 ? .forward : .backward }

    /// Region of the overlay (its own points) the lifted leaf covers, leaving out the leaf's first
    /// `bindingMargin` points from its binding edge (the wire is threaded there and stays on top).
    /// Empty at rest and once the leaf has landed (as long as the wire lies within the margin).
    public func lifted(bindingMargin: CGFloat) -> CurlSheetShape {
        let g = geometry
        let lo = Double(g.halfGutter) + Double(max(bindingMargin, 0))
        guard frame.isValid, lo < frame.W - 1e-6 else { return .none }
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let sigma = self.sigma, holdTop = self.holdTop, H = frame.H
        let hinge = Double(g.hinge), x0 = Double(lift.minX), y0 = Double(lift.minY)
        let horizontal = g.axis == .horizontal
        let outline = CurlSheetShape.liftedOutline(
            fold: fold, paper: (lo, frame.W, H),
            toView: { q in
                let across = sigma * q.x
                let along = holdTop ? H - q.y : q.y
                return horizontal ? CurlVec(x0 + along, hinge + across) : CurlVec(hinge + across, y0 + along)
            },
            clip: CGRect(origin: .zero, size: g.overlaySize))
        return CurlSheetShape(outline: outline)
    }

    /// The leaf of an automatic spread turn (flip: the canonical arc) at `progress` (0 = flat, 1 = landed) —
    /// the same frame `CurlController.renderSpreadStills` draws (tests · QA).
    public static func turn(spread g: CurlSpread, direction: FlipDirection, holdTop: Bool = false,
                            stiffness: Double = 1, progress: Double) -> CurlSpreadLeaf {
        let sigma = direction == .forward ? 1.0 : -1.0
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let across = Double(g.axis == .vertical ? lift.width : lift.height)
        let along = Double(g.axis == .vertical ? lift.height : lift.width)
        let frame = CurlFrame.spread(W: Double(g.halfGutter) + across, H: along, halfGutter: Double(g.halfGutter),
                                     stiffness: stiffness)
        let finger: CurlVec
        if progress >= 1 {
            finger = frame.E
        } else if progress <= 0 {
            finger = frame.K
        } else {
            let x = frame.fingerX(progress: progress, forward: true)
            finger = CurlVec(x, CurlArc(frame).y(atX: x))
        }
        return CurlSpreadLeaf(geometry: g, sigma: sigma, holdTop: holdTop, frame: frame, fold: frame.fold(finger))
    }
}
