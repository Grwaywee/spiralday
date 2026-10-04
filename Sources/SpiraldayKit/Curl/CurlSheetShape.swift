import CoreGraphics
import Foundation
import simd

// ─────────────────────────────────────────────────────────────────────────────
// The lifted part of a turning sheet, seen from above — for hosts that draw something
// ON the binding above the curl overlay (the spiral rings).
//
// The overlay paints the page below, the flat part of the turning sheet and the lifted
// part (the roll and the flap lying on top) in one opaque pass. Rings belong between
// those layers: over the page below and over the flat part of the sheet (it is threaded
// through them), under everything of the sheet that has left the paper. A host that keeps
// its rings above the overlay masks them with this shape, frame by frame.
//
// Same cylinder model as CurlShader (page space, d = signed distance from the fold axis
// toward the free edge): a page point at arc length u > 0 from the axis lies at
//   d = r·sin(u / r)   on the roll (u ≤ π r)
//   d = π r − u        on the flap lying at height 2r (u > π r)
// so the lifted region is the image of { page points with u > 0 } under u ↦ d, along
// lines parallel to the axis. Clipped to the overlay (the page view): a sheet that has
// slid past the binding is not drawn, so it hides nothing there.
// ─────────────────────────────────────────────────────────────────────────────

/// The region the lifted sheet covers in the page view (points, screen orientation, origin top-left).
public struct CurlSheetShape: Equatable, Sendable {
    /// Closed outline of the lifted sheet inside the page view. Empty when nothing is lifted there.
    public var outline: [CGPoint]

    public init(outline: [CGPoint]) {
        self.outline = outline
    }

    public static let none = CurlSheetShape(outline: [])

    public var isEmpty: Bool { outline.count < 3 }

    /// Even-odd point test (the outline is a simple polygon).
    public func contains(_ p: CGPoint) -> Bool {
        guard !isEmpty else { return false }
        var inside = false
        var j = outline.count - 1
        for i in outline.indices {
            let a = outline[i], b = outline[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// The outline as a path (for a mask: add the host's bounds and fill even-odd).
    public var path: CGPath {
        let p = CGMutablePath()
        guard !isEmpty else { return p }
        p.addLines(between: outline)
        p.closeSubpath()
        return p
    }

    /// Lifted sheet of an automatic turn (flip / swipe / backward drag: the canonical arc) at `progress`
    /// (0 = nothing turned, 1 = done; backward: 0 = the previous page still hidden past the binding).
    public static func turn(edge: BindingEdge, pageSize: CGSize, direction: FlipDirection, progress: Double) -> CurlSheetShape {
        let frame = CurlFrame(edge: edge, view: pageSize)
        guard frame.isValid else { return .none }
        let forward = direction == .forward
        let x = frame.fingerX(progress: progress, forward: forward)
        let finger = CurlVec(x, CurlArc(frame).y(atX: x))
        return CurlSheetShape(frame: frame, fold: frame.fold(finger))
    }

    /// Lifted sheet with the held corner at `finger`, in normalised page space like `CurlController.renderStills`
    /// ((0,0) binding/top … (1,1) the held corner; x < 0 is past the binding).
    public static func held(edge: BindingEdge, pageSize: CGSize, finger: CGPoint) -> CurlSheetShape {
        let frame = CurlFrame(edge: edge, view: pageSize)
        guard frame.isValid else { return .none }
        return CurlSheetShape(frame: frame, fold: frame.fold(CurlVec(Double(finger.x) * frame.W, Double(finger.y) * frame.H)))
    }

    // MARK: geometry

    init(frame: CurlFrame, fold: CurlFold) {
        outline = Self.outline(frame: frame, fold: fold)
    }

    private static func outline(frame f: CurlFrame, fold: CurlFold) -> [CGPoint] {
        let N = CurlMath.normalize(fold.normal, CurlVec(1, 0))
        let T = CurlVec(-N.y, N.x)
        let A = fold.axisPoint
        let r = max(fold.radius, 0)
        let halfTurn = Double.pi * r

        // the part of the page beyond the axis, in (t along the axis, u across it)
        let corners = [CurlVec(0, 0), CurlVec(f.W, 0), CurlVec(f.W, f.H), CurlVec(0, f.H)].map {
            CurlVec(simd_dot($0 - A, T), simd_dot($0 - A, N))
        }
        let beyond = clip(corners) { $0.y }      // u ≥ 0
        guard beyond.count >= 3 else { return [] }

        func depth(_ u: Double) -> Double {
            guard r > 1e-6 else { return -u }
            return u <= halfTurn ? r * sin(u / r) : halfTurn - u
        }

        // sample t: evenly, at the polygon's corners, and densely where an edge crosses the roll
        let ts = beyond.map(\.x)
        guard let t0 = ts.min(), let t1 = ts.max(), t1 - t0 > 1e-6 else { return [] }
        var samples = (0...128).map { t0 + (t1 - t0) * Double($0) / 128 }
        samples += ts
        for i in beyond.indices {
            let a = beyond[i], b = beyond[(i + 1) % beyond.count]
            guard abs(b.y - a.y) > 1e-9 else { continue }
            for k in 0...16 {
                let u = halfTurn * Double(k) / 16
                let s = (u - a.y) / (b.y - a.y)
                if s > 0, s < 1 { samples.append(a.x + (b.x - a.x) * s) }
            }
        }
        samples = samples.map { min(max($0, t0), t1) }.sorted()

        var upper: [CurlVec] = [], lower: [CurlVec] = []
        var last = -Double.infinity
        for t in samples where t - last > 1e-7 {
            last = t
            guard let (uLo, uHi) = span(beyond, at: t) else { continue }
            let dLo = depth(uLo), dHi = depth(uHi)
            let top = (uLo <= halfTurn / 2 && halfTurn / 2 <= uHi) ? r : max(dLo, dHi)
            upper.append(A + T * t + N * top)
            lower.append(A + T * t + N * min(dLo, dHi))
        }
        guard upper.count >= 2 else { return [] }
        let ring = upper + lower.reversed()

        // page space → view (screen orientation), then keep what the overlay shows
        let view = ring.map { f.edge == .top ? CurlVec($0.y, $0.x) : $0 }
        let w = Double(f.view.width), h = Double(f.view.height)
        var poly = clip(view) { $0.x }
        poly = clip(poly) { w - $0.x }
        poly = clip(poly) { $0.y }
        poly = clip(poly) { h - $0.y }
        guard poly.count >= 3, abs(area(poly)) > 0.25 else { return [] }
        return poly.map { CGPoint(x: $0.x, y: $0.y) }
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
        return lo <= hi ? (max(lo, 0), max(hi, 0)) : nil
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
            if (da >= 0) != (db >= 0) {
                out.append(a + (b - a) * (da / (da - db)))
            }
        }
        return out
    }

    private static func area(_ poly: [CurlVec]) -> Double {
        var s = 0.0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }
}

// MARK: - Live: the sheet the overlay is drawing

extension CurlController {
    /// Watches the lifted sheet: `handler` runs on the main thread for every frame the overlay draws
    /// (right after it is encoded, before it reaches the screen) with the lifted part in that frame
    /// (`CurlSheetShape.none` when nothing is lifted inside the page view). Nothing is called while the
    /// overlay is hidden — `isActive` turning false means nothing is lifted.
    ///
    /// While anyone watches, the overlay presents its frames with the Core Animation transaction, so a
    /// layer the host changes in `handler` (a mask over the rings) appears on exactly the same display
    /// frame as the sheet. Keep the returned token; the watch ends when it is released or cancelled.
    public func watchLiftedSheet(_ handler: @escaping @MainActor (CurlSheetShape) -> Void) -> CurlSheetWatch {
        let watch = CurlSheetWatch(handler)
        guard let view = makeOverlayView() as? CurlMetalView else { return watch }
        let box: CurlSheetWatchers
        if let existing = curlSheetWatchers.object(forKey: view) {
            box = existing
        } else {
            box = CurlSheetWatchers()
            curlSheetWatchers.setObject(box, forKey: view)
            let draw = view.onFrame
            view.onFrame = { [weak self, weak box] v in
                // 지켜보는 쪽이 있으면 그림을 CA 트랜잭션과 함께 내보낸다 (가림판과 같은 프레임에)
                let watched = box?.isWatched == true
                if watched { v.presentsWithTransaction = true }
                draw?(v)
                guard watched, let self, let box else { return }
                box.notify(self.liftedSheet ?? .none)
            }
        }
        box.add(watch)
        return watch
    }
}

/// A live watch of the lifted sheet (see `CurlController.watchLiftedSheet`).
@MainActor
public final class CurlSheetWatch {
    fileprivate var handler: (@MainActor (CurlSheetShape) -> Void)?

    fileprivate init(_ handler: @escaping @MainActor (CurlSheetShape) -> Void) {
        self.handler = handler
    }

    public func cancel() { handler = nil }
}

@MainActor
private final class CurlSheetWatchers {
    private var watches: [Weak] = []

    private struct Weak { weak var watch: CurlSheetWatch? }

    var isWatched: Bool {
        watches.removeAll { $0.watch?.handler == nil }
        return !watches.isEmpty
    }

    func add(_ w: CurlSheetWatch) { watches.append(Weak(watch: w)) }

    func notify(_ shape: CurlSheetShape) {
        for w in watches { w.watch?.handler?(shape) }
    }
}

/// Watchers per overlay view (the controller's view is created once and kept).
@MainActor
private let curlSheetWatchers = NSMapTable<CurlMetalView, CurlSheetWatchers>.weakToStrongObjects()
