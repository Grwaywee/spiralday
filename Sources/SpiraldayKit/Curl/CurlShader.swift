import CoreGraphics
import simd

/// Uniforms shared with the shader (layout must match `CurlUniforms` in the MSL below).
struct CurlUniforms {
    /// Page view size in points (screen orientation).
    var viewSize: SIMD2<Float>
    /// Drawable pixels per point.
    var pixelScale: SIMD2<Float>
    /// Page space size (W ⟂ binding, H along the binding).
    var pageSize: SIMD2<Float>
    /// A point on the fold axis, and the axis normal toward the free edge.
    var axisPoint: SIMD2<Float>
    var normal: SIMD2<Float>
    /// Cylinder radius in points.
    var radius: Float
    /// 1 when the binding is on top (page space = screen transposed).
    var transposed: Float
    /// 0…1 strength of lift-dependent shading.
    var effect: Float
    var pad: Float = 0

    init(frame: CurlFrame, fold: CurlFold, pixelSize: CGSize) {
        let vw = Double(frame.view.width), vh = Double(frame.view.height)
        viewSize = SIMD2(Float(vw), Float(vh))
        pixelScale = SIMD2(Float(Double(pixelSize.width) / vw), Float(Double(pixelSize.height) / vh))
        pageSize = SIMD2(Float(frame.W), Float(frame.H))
        axisPoint = SIMD2(Float(fold.axisPoint.x), Float(fold.axisPoint.y))
        normal = SIMD2(Float(fold.normal.x), Float(fold.normal.y))
        radius = Float(fold.radius)
        transposed = frame.edge == .top ? 1 : 0
        effect = Float(fold.effect)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page curl fragment shader — one full-screen triangle, everything per pixel.
//
// Cylinder model (page space, d = signed distance from the fold axis toward the
// free edge, r = radius). Layers, bottom → top:
//   under page                          always
//   FRONT of the curling page           d ≤ 0 flat (s = q), 0 < d ≤ r lower half of the roll
//   BACK of the curling page            0 ≤ d ≤ r upper half, d ≤ 0 flap lying at height 2r
// Every validity edge is anti-aliased from screen-space derivatives.
//
// Compiled at runtime (device.makeLibrary(source:)): the Metal toolchain is not
// required to build the app.
// ─────────────────────────────────────────────────────────────────────────────

enum CurlShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CurlUniforms {
        float2 viewSize;
        float2 pixelScale;
        float2 pageSize;
        float2 axisPoint;
        float2 normal;
        float  radius;
        float  transposed;
        float  effect;
        float  pad;
    };

    struct CurlVertexOut {
        float4 position [[position]];
    };

    vertex CurlVertexOut curl_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        CurlVertexOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline float curl_hash(float2 p) {
        uint2 q = uint2(int2(floor(p)) + int2(65536));
        uint h = (q.x * 0x8da6b343u) ^ (q.y * 0xd8163841u);
        h ^= h >> 15; h *= 0x2c1b3c6du;
        h ^= h >> 12; h *= 0x297a2d39u;
        h ^= h >> 15;
        return float(h) * (1.0 / 4294967296.0);
    }

    static inline float curl_noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = curl_hash(i);
        float b = curl_hash(i + float2(1.0, 0.0));
        float c = curl_hash(i + float2(0.0, 1.0));
        float d = curl_hash(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    // signed distance to the page rectangle (positive inside), page units
    static inline float curl_box(float2 s, float2 size) {
        float2 m = min(s, size - s);
        return (m.x < 0.0 || m.y < 0.0) ? -length(min(m, 0.0)) : min(m.x, m.y);
    }

    // the same distance in screen pixels: each axis is scaled by how fast s moves per
    // pixel (derivatives of s itself, never of the min(), so no seams along diagonals)
    static inline float curl_boxPx(float2 s, float2 size) {
        float2 k = float2(length(float2(dfdx(s.x), dfdy(s.x))), length(float2(dfdx(s.y), dfdy(s.y))));
        float2 m = min(s, size - s) / max(k, 1e-5);
        return (m.x < 0.0 || m.y < 0.0) ? -length(min(m, 0.0)) : min(m.x, m.y);
    }

    static inline float curl_sq(float x) { return x * x; }

    fragment float4 curl_fragment(CurlVertexOut in [[stage_in]],
                                  constant CurlUniforms &U [[buffer(0)]],
                                  texture2d<float> topTex [[texture(0)]],
                                  texture2d<float> underTex [[texture(1)]],
                                  sampler smp [[sampler(0)]]) {
        const float3 paperFront = float3(252.0, 251.0, 247.0) / 255.0;   // #FCFBF7
        const float3 paperBack  = float3(242.0, 239.0, 232.0) / 255.0;   // #F2EFE8

        float2 frag = in.position.xy;
        float2 qs = frag / U.pixelScale;                 // screen points
        bool tr = U.transposed > 0.5;
        float2 q = tr ? qs.yx : qs;                      // page space
        float px = 2.0 / (U.pixelScale.x + U.pixelScale.y);
        float W = U.pageSize.x;
        float2 N = U.normal;
        float r = U.radius;
        float rs = max(r, 1e-4);
        float fx = U.effect;

        // ── geometry ────────────────────────────────────────────────────────
        float d = dot(q - U.axisPoint, N);
        // saturate: with fast math r / r may round above 1 (asin → NaN)
        float a = asin(saturate(clamp(d, 0.0, r) / rs)); // 0 at the crease … π/2 at the silhouette
        float cosA = cos(a);
        // arc length u from the axis → source point s = q + N (u − d)
        float2 sF = q + N * (min(d, 0.0) + r * a - d);                      // front: flat + lower half
        float2 sB = q + N * (r * (M_PI_F - a) + max(-d, 0.0) - d);           // back: upper half + flap
        bool flat = d <= 0.0;

        // ── sampling (top level so derivatives stay valid) ─────────────────
        float2 inv = 1.0 / U.viewSize;
        float2 uvQ = qs * inv;
        float2 uvF = (tr ? sF.yx : sF) * inv;
        float2 uvB = (tr ? sB.yx : sB) * inv;
        float2 dFx = dfdx(uvF), dFy = dfdy(uvF);
        float2 dBx = dfdx(uvB), dBy = dfdy(uvB);
        float4 under = underTex.sample(smp, uvQ, level(0.0));
        float4 front = topTex.sample(smp, uvF, gradient2d(flat ? float2(0.0) : dFx, flat ? float2(0.0) : dFy));
        // show-through is diffused by the paper fibres: sample ~1.5 mip levels softer
        float4 thru  = topTex.sample(smp, uvB, gradient2d(dBx * 3.0, dBy * 3.0));

        // ── coverage (anti-aliased validity) ────────────────────────────────
        float sdF = curl_box(sF, U.pageSize);
        float sdFpx = curl_boxPx(sF, U.pageSize);
        float sdBpx = curl_boxPx(sB, U.pageSize);
        float covSil = saturate((r - d) / px + 0.5);
        float covF = flat ? 1.0 : saturate(sdFpx + 0.5) * covSil;
        float covB = r > 0.0 ? saturate(sdBpx + 0.5) * covSil : 0.0;

        // ── under page: soft drop shadow of the lifted sheet ───────────────
        float dropW = 0.012 * W + 1.6 * r;
        float g = 1.0 - smoothstep(0.0, dropW, max(d - r, 0.0));
        float h = smoothstep(-0.5 * dropW, 0.2 * dropW, sdF);
        float drop = 0.30 * fx * g * g * h;
        float3 underCol = under.rgb * (1.0 - drop);

        // ── front of the curling page ───────────────────────────────────────
        // inside of the roll turns away from the light; occlusion at the crease;
        // soft shadow of the flap lying above it; thin paper edge on the rolled part
        float shadeF = flat ? 1.0 : (0.78 + 0.22 * cosA - 0.04 * sin(a));
        float crease = fx * smoothstep(-0.9 * rs, 0.3 * rs, d);
        float outB = max(-sdBpx, 0.0) * px;
        float flapBlur = 1.5 + 1.1 * r;
        float flapShadow = d <= r ? 0.2 * fx * (1.0 - smoothstep(0.0, flapBlur, outB)) : 0.0;
        float edgeF = (1.0 - smoothstep(0.0, 1.5, sdFpx)) * smoothstep(0.0, 0.6, a);
        float3 frontCol = front.rgb * (shadeF * (1.0 - 0.10 * crease) * (1.0 - flapShadow) * (1.0 - 0.14 * edgeF));

        // ── back of the curling page ────────────────────────────────────────
        // paper back with its own grain + faint mirrored show-through of the ink
        float3 ink = saturate(1.0 - thru.rgb / paperFront);
        float3 backCol = paperBack * (1.0 - 0.065 * ink);
        float2 texPx = U.viewSize * U.pixelScale;
        float squeeze = max(length(dBx * texPx), length(dBy * texPx));
        float grainFade = saturate(2.2 - squeeze);
        float fine = curl_hash(sB * U.pixelScale.x * 0.8) - 0.5;
        float mottle = curl_noise(sB * (1.0 / 18.0)) - 0.5;
        backCol *= 1.0 + 0.028 * fine * grainFade + 0.020 * mottle;
        // diffuse = −cos φ on the upper half (1 on the flap), soft highlight near the top of the roll
        float diffuse = cosA;
        float spec = 0.075 * exp(-curl_sq((a - 0.42) / 0.24));
        float edgeB = 1.0 - smoothstep(0.0, 1.5, sdBpx);
        backCol = backCol * ((0.66 + 0.30 * diffuse) * (1.0 - 0.18 * edgeB)) + spec;

        // ── composite ───────────────────────────────────────────────────────
        float3 col = mix(underCol, frontCol, covF);
        col = mix(col, backCol, covB);

        // dither only where the image is shaded (flat regions stay bit-exact)
        bool touched = (covF > 0.0 && (!flat || crease > 0.0 || flapShadow > 0.0)) || covB > 0.0 || drop > 0.0;
        if (touched) {
            col += (curl_hash(frag + 7.0) - 0.5) * (1.0 / 255.0);
        }
        return float4(col, 1.0);
    }
    """
}

// ─────────────────────────────────────────────────────────────────────────────
// Spread mode (an open spiral-bound book, iPad): one overlay covers the whole book (both pages, the open gap with
// the coil and a bleed along the binding). The leaf CURLS like the single page above — the same cylinder, the same
// shading, back face and shadows — and lies down MIRRORED about the coil axis on the opposite page. It hangs on the
// coil by its holes: once the roll has reached them, the binding strip turns about the coil (θ) while the roll turns
// the rest of the way (CurlSpreadFold.swift):
//   front     the lifted page (its live content)            frontTex  @ lifted page rect
//   back      the page that lands on the other side          backTex   @ opposite page rect
//   revealed  the page under the lifted one (nil = desk)     revealedTex @ lifted page rect
// Every texture is read at the place where that page lives on screen, so the mirror comes for free and the landing
// frame is exactly the new live pages. Output is premultiplied alpha: where the leaf does not cover, the live pages
// / the desk show. While θ = 0 every value is computed as on the single page. Kept in its own source (own library)
// so the single-page shader is untouched (the Mac never builds this one).
// ─────────────────────────────────────────────────────────────────────────────

/// Uniforms of the spread shader (layout must match `CurlSpreadUniforms` in the MSL below).
struct CurlSpreadUniforms {
    /// Overlay points: the lifted page, the page on the other side (x, y, w, h).
    var liftRect: SIMD4<Float>
    var oppRect: SIMD4<Float>
    /// Board edge colour (rgb) and strength (a, 0 = paper).
    var rim: SIMD4<Float>
    var viewSize: SIMD2<Float>
    var pixelScale: SIMD2<Float>
    /// Page space size (W′ = half gap + page length across the binding, H along it).
    var pageSize: SIMD2<Float>
    /// The cylinder in the leaf's plane (σ-space): a point on its axis, the normal toward the free edge, the radius.
    var axisPoint: SIMD2<Float>
    var normal: SIMD2<Float>
    var radius: Float
    var effect: Float
    /// Overlay coordinate of the hinge line = the coil's axis (x for a vertical binding, y for a horizontal one).
    var hinge: Float
    /// +1 lifting the recto (forward), −1 lifting the verso (backward).
    var sigma: Float
    var halfGutter: Float
    /// 1: the far corner along the binding is held (page y runs from the other end).
    var holdTop: Float
    /// 1: horizontal binding (weekly: top / bottom pages).
    var horizontal: Float
    var hasRevealed: Float
    /// 0 at rest (the back face cannot show).
    var lifted: Float
    /// The binding strip's turn about the coil axis (0 … π), its cosine and sine (exactly ±1 · 0 at both ends).
    var theta: Float
    var cosTheta: Float
    var sinTheta: Float
    var pad: Float = 0

    init(fold f: CurlSpreadFold, geometry g: CurlSpread, sigma: Double, holdTop: Bool, rim: SIMD3<Float>?, stiffness: Double,
         hasRevealed: Bool, pixelScale: SIMD2<Float>) {
        let lift = sigma > 0 ? g.rectoRect : g.versoRect
        let opp = sigma > 0 ? g.versoRect : g.rectoRect
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
        liftRect = rect(lift)
        oppRect = rect(opp)
        self.rim = stiffness > 1.01 ? (rim.map { SIMD4($0.x, $0.y, $0.z, 1) } ?? .zero) : .zero
        viewSize = SIMD2(Float(g.overlaySize.width), Float(g.overlaySize.height))
        self.pixelScale = pixelScale
        pageSize = SIMD2(Float(f.W), Float(f.H))
        axisPoint = SIMD2(Float(f.fold.axisPoint.x), Float(f.fold.axisPoint.y))
        normal = SIMD2(Float(f.fold.normal.x), Float(f.fold.normal.y))
        radius = Float(f.fold.radius)
        effect = Float(f.fold.effect)
        hinge = Float(g.hinge)
        self.sigma = Float(sigma)
        halfGutter = Float(g.halfGutter)
        self.holdTop = holdTop ? 1 : 0
        horizontal = g.axis == .horizontal ? 1 : 0
        self.hasRevealed = hasRevealed ? 1 : 0
        lifted = f.lifted ? 1 : 0
        theta = Float(f.theta)
        cosTheta = Float(f.cosTheta)
        sinTheta = Float(f.sinTheta)
    }
}

enum CurlSpreadShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CurlSpreadUniforms {
        float4 liftRect;
        float4 oppRect;
        float4 rim;
        float2 viewSize;
        float2 pixelScale;
        float2 pageSize;
        float2 axisPoint;
        float2 normal;
        float  radius;
        float  effect;
        float  hinge;
        float  sigma;
        float  halfGutter;
        float  holdTop;
        float  horizontal;
        float  hasRevealed;
        float  lifted;
        float  theta;
        float  cosTheta;
        float  sinTheta;
        float  pad;
    };

    struct SpreadVertexOut {
        float4 position [[position]];
    };

    vertex SpreadVertexOut curl_spread_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        SpreadVertexOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline float sp_hash(float2 p) {
        uint2 q = uint2(int2(floor(p)) + int2(65536));
        uint h = (q.x * 0x8da6b343u) ^ (q.y * 0xd8163841u);
        h ^= h >> 15; h *= 0x2c1b3c6du;
        h ^= h >> 12; h *= 0x297a2d39u;
        h ^= h >> 15;
        return float(h) * (1.0 / 4294967296.0);
    }

    static inline float sp_box(float2 s, float2 size) {
        float2 m = min(s, size - s);
        return (m.x < 0.0 || m.y < 0.0) ? -length(min(m, 0.0)) : min(m.x, m.y);
    }

    static inline float sp_boxPx(float2 s, float2 size) {
        float2 k = float2(length(float2(dfdx(s.x), dfdy(s.x))), length(float2(dfdx(s.y), dfdy(s.y))));
        float2 m = min(s, size - s) / max(k, 1e-5);
        return (m.x < 0.0 || m.y < 0.0) ? -length(min(m, 0.0)) : min(m.x, m.y);
    }

    static inline float sp_sq(float x) { return x * x; }

    // page space of the turning leaf → overlay points (landed: where it lies after the turn)
    static inline float2 sp_toOverlay(float2 s, bool landed, constant CurlSpreadUniforms &U) {
        float acr = (landed ? -U.sigma : U.sigma) * s.x;
        float alg = U.holdTop > 0.5 ? U.pageSize.y - s.y : s.y;
        return U.horizontal > 0.5 ? float2(U.liftRect.x + alg, U.hinge + acr)
                                  : float2(U.hinge + acr, U.liftRect.y + alg);
    }

    fragment float4 curl_spread_fragment(SpreadVertexOut in [[stage_in]],
                                         constant CurlSpreadUniforms &U [[buffer(0)]],
                                         texture2d<float> frontTex [[texture(0)]],
                                         texture2d<float> backTex [[texture(1)]],
                                         texture2d<float> revealedTex [[texture(2)]],
                                         sampler smp [[sampler(0)]]) {
        const float3 paperFront = float3(252.0, 251.0, 247.0) / 255.0;   // #FCFBF7

        float2 frag = in.position.xy;
        float2 P = frag / U.pixelScale;                  // overlay points
        bool hz = U.horizontal > 0.5;
        float W = U.pageSize.x;
        float H = U.pageSize.y;
        float hg = U.halfGutter;
        float across = hz ? P.y - U.hinge : P.x - U.hinge;
        float along = hz ? P.x - U.liftRect.x : P.y - U.liftRect.y;
        float2 q = float2(U.sigma * across, U.holdTop > 0.5 ? H - along : along);
        float px = 2.0 / (U.pixelScale.x + U.pixelScale.y);
        float2 N = U.normal;
        float r = U.radius;
        float rs = max(r, 1e-4);
        float fx = U.effect;
        float th = U.theta;
        float cT = U.cosTheta;
        float sT = U.sinTheta;
        bool pivot = th > 0.0;
        // past upright the strip shows its back and nothing of the leaf lies over anything else
        bool upright = th > M_PI_2_F;

        // ── geometry: the single page's cylinder (d, a, sF, sB) ──────────────
        // the strip turned by θ about the coil moves the roll on screen: dS = distance from the roll's centre line,
        // 0 … r sin θ the part of the roll right after the strip (dS = d while θ = 0)
        float d = dot(q - U.axisPoint, N);
        float ax = U.axisPoint.x - N.y / N.x * (q.y - U.axisPoint.y);
        float dS = d + ((1.0 - cT) * ax + r * sT) * N.x;
        float a = asin(saturate(clamp(dS, 0.0, r) / rs));  // 0 at the crease … π/2 at the silhouette
        float cosA = cos(a);
        float rsT = r * sT;
        bool flat = upright || dS <= rsT;
        // arc length past the axis of the lower layer (the strip / flat part · lower half of the roll) and of the
        // upper one (upper half of the roll · the flap) → source points s = q + N (u − d)
        float cTs = abs(cT) < 1e-4 ? (cT < 0.0 ? -1e-4 : 1e-4) : cT;
        float uFlat = cT == 1.0 ? d : d + q.x * (1.0 / cTs - 1.0) * N.x;
        float uLo = flat ? uFlat : r * (a - th);
        float uHi = r * (M_PI_F - a - th) + max(-dS, 0.0);
        float2 sF = q + N * (uLo - d);
        float2 sB = q + N * (uHi - d);
        bool landed = fx <= 0.0;
        bool frontFlat = flat && !pivot;                 // the page itself, untouched
        bool lowerBack = flat && cT < 0.0;               // the strip past upright

        // ── sampling (top level so derivatives stay valid) ─────────────────
        float2 uvF = (sp_toOverlay(sF, false, U) - U.liftRect.xy) / U.liftRect.zw;
        float2 uvB = (sp_toOverlay(sB, true, U) - U.oppRect.xy) / U.oppRect.zw;
        float2 uvL = (sp_toOverlay(sF, true, U) - U.oppRect.xy) / U.oppRect.zw;
        float2 uvT = (sp_toOverlay(sB, false, U) - U.liftRect.xy) / U.liftRect.zw;
        float2 uvR = (P - U.liftRect.xy) / U.liftRect.zw;
        float2 dFx = dfdx(uvF), dFy = dfdy(uvF);
        float2 dBx = dfdx(uvB), dBy = dfdy(uvB);
        float2 dLx = dfdx(uvL), dLy = dfdy(uvL);
        float2 dTx = dfdx(uvT), dTy = dfdy(uvT);
        float4 front = frontTex.sample(smp, uvF, gradient2d(frontFlat ? float2(0.0) : dFx, frontFlat ? float2(0.0) : dFy));
        float4 back = backTex.sample(smp, uvB, gradient2d(landed ? float2(0.0) : dBx, landed ? float2(0.0) : dBy));
        float4 backLow = backTex.sample(smp, uvL, gradient2d(landed ? float2(0.0) : dLx, landed ? float2(0.0) : dLy));
        float4 revealed = revealedTex.sample(smp, uvR, level(0.0));
        // ink of the front shows faintly through the thin paper (softer: fibres diffuse it)
        float4 thru = frontTex.sample(smp, uvT, gradient2d(dTx * 3.0, dTy * 3.0));

        // ── coverage: the leaf's paper is s ∈ [g/2, W′] × [0, H] ─────────
        float2 bo = float2(hg, 0.0);
        float2 bs = float2(W - hg, H);
        float sdF = sp_box(sF - bo, bs);
        float sdFpx = sp_boxPx(sF - bo, bs);
        float sdBpx = sp_boxPx(sB - bo, bs);
        float covSil = saturate((r - dS) / px + 0.5);
        // past upright the strip ends at the axis and the roll where the strip begins (they meet without a seam)
        float lowOK = (!upright || uFlat <= 0.0) ? 1.0 : 0.0;
        float upOK = (!upright || dS <= rsT) ? 1.0 : 0.0;
        float covF = saturate(sdFpx + 0.5) * (flat ? lowOK : covSil);
        float covB = U.lifted > 0.5 ? saturate(sdBpx + 0.5) * covSil * upOK : 0.0;

        // ── shadows ─────────────────────────────────────────────────────────
        // the rolled part over the revealed page (beyond the top of the roll; past upright: beyond the strip's edge)
        float dropW = 0.012 * W + 1.6 * r;
        float beyond = upright ? (q.x - hg * cT) * N.x : dS - r;
        float g = 1.0 - smoothstep(0.0, dropW, max(beyond, 0.0));
        float h = smoothstep(-0.5 * dropW, 0.2 * dropW, sdF);
        float drop = 0.30 * fx * g * g * h;
        // the flap lying above: soft shadow around its edge, on whichever side it is (both pages)
        float outB = max(-sdBpx, 0.0) * px;
        bool underFlap = upright ? dS <= rsT : dS <= r;
        float flap = underFlap ? 0.22 * fx * (1.0 - smoothstep(0.0, 1.5 + 1.1 * r + 0.02 * W, outB)) : 0.0;
        // occlusion where the leaf stands up from the coil (both pages)
        float hingeOcc = 0.10 * fx * (1.0 - smoothstep(0.0, 0.08 * W, abs(q.x)));

        // ── what is below the leaf ──────────────────────────────────────────
        bool inLift = uvR.x >= 0.0 && uvR.x <= 1.0 && uvR.y >= 0.0 && uvR.y <= 1.0;
        float4 base;
        if (inLift && U.hasRevealed > 0.5) {
            base = float4(revealed.rgb * (1.0 - drop) * (1.0 - flap) * (1.0 - hingeOcc), 1.0);
        } else {
            // the other page (live, below this overlay), the gap, the desk: only shadow —
            // within the book's length along the binding (the bleed beyond it only carries the leaf itself)
            float inBook = (along >= 0.0 && along <= H) ? 1.0 : 0.0;
            base = float4(0.0, 0.0, 0.0, saturate(drop + flap + hingeOcc) * inBook);
        }

        // ── front of the leaf (the strip turned by θ is lit by its tilt) ───
        float tiltF = flat ? th : a;
        float shadeF = frontFlat ? 1.0 : (0.78 + 0.22 * cos(tiltF) - 0.04 * sin(tiltF));
        float crease = fx * smoothstep(-0.9 * rs, 0.3 * rs, dS - rsT);
        float flapShadow = underFlap ? 0.2 * fx * (1.0 - smoothstep(0.0, 1.5 + 1.1 * r, outB)) : 0.0;
        float edgeF = (1.0 - smoothstep(0.0, 1.5, sdFpx)) * smoothstep(0.0, 0.6, tiltF);
        float3 frontCol = front.rgb * (shadeF * (1.0 - 0.10 * crease) * (1.0 - flapShadow) * (1.0 - 0.14 * edgeF));
        // a board shows its thickness: a thin rim in the cover colour while it turns
        float rimPx = 1.5 * U.pixelScale.x;
        frontCol = mix(frontCol, U.rim.rgb, U.rim.a * fx * (1.0 - smoothstep(0.0, rimPx, sdFpx)));

        // ── back of the leaf = the page that lands on the other side ────────
        float3 ink = saturate(1.0 - thru.rgb / paperFront);
        float spec = 0.075 * exp(-sp_sq((a - 0.42) / 0.24));
        float edgeB = 1.0 - smoothstep(0.0, 1.5, sdBpx);
        // lit like the single page while it moves; exactly the page once it lies flat (fx = 0)
        float light = mix(1.0, (0.66 + 0.30 * cosA) * (1.0 - 0.18 * edgeB), fx);
        float3 backCol = back.rgb * (1.0 - 0.035 * fx * ink) * light + spec * fx;
        backCol = mix(backCol, U.rim.rgb, U.rim.a * fx * (1.0 - smoothstep(0.0, rimPx, sdBpx)));
        // the strip past upright: its back, tilted π − θ from lying face down
        float aL = M_PI_F - th;
        float3 inkL = saturate(1.0 - front.rgb / paperFront);
        float edgeL = 1.0 - smoothstep(0.0, 1.5, sdFpx);
        float lightL = mix(1.0, (0.66 + 0.30 * cos(aL)) * (1.0 - 0.18 * edgeL), fx);
        float3 lowBackCol = backLow.rgb * (1.0 - 0.035 * fx * inkL) * lightL + 0.075 * exp(-sp_sq((aL - 0.42) / 0.24)) * fx;
        lowBackCol = mix(lowBackCol, U.rim.rgb, U.rim.a * fx * (1.0 - smoothstep(0.0, rimPx, sdFpx)));

        // ── composite (premultiplied) ───────────────────────────────────────
        float4 col = base;
        col = mix(col, float4(lowerBack ? lowBackCol : frontCol, 1.0), covF);
        col = mix(col, float4(backCol, 1.0), covB);

        // dither only where the image is shaded and opaque (flat / landed regions stay bit-exact)
        bool shadedF = pivot ? fx > 0.0 : !flat;
        bool touched = (covF > 0.0 && (shadedF || crease > 0.0 || flapShadow > 0.0)) || (covB > 0.0 && fx > 0.0)
                       || drop > 0.0 || flap > 0.0 || hingeOcc > 0.0;
        if (touched && col.a > 0.999) {
            col.rgb = saturate(col.rgb + (sp_hash(frag + 7.0) - 0.5) * (1.0 / 255.0));
        }
        return col;
    }
    """
}
