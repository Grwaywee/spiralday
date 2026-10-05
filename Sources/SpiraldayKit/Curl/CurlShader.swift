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
// the coil and a bleed along the binding). The leaf turns about the coil (CurlHingeLeaf): a mesh of the bowed
// leaf seen through a gentle perspective, its front = the lifted page, its back = the page that lands on the other
// side, over a background pass that draws the page it uncovers and the leaf's soft shadow on both sides.
//   background  revealed page (lifted side, nil = desk) · shadow alpha elsewhere      revealedTex @ lifted page rect
//   leaf        front face  frontTex @ lifted page rect · back face  backTex @ opposite page rect (mirrored)
// Every texture is read at the place where that page lives on screen, so the landing frame is exactly the new live
// pages. 4× MSAA + depth (the bowed leaf can overlap itself on screen). Output is premultiplied alpha: where the
// leaf does not cover, the live pages / the desk show. Its own source and pipelines — the single-page shader above
// is untouched (the Mac never builds these).
// ─────────────────────────────────────────────────────────────────────────────

/// Uniforms of the spread shaders (layout must match `CurlSpreadUniforms` in the MSL below).
struct CurlSpreadUniforms {
    /// Overlay points: the lifted page, the page on the other side (x, y, w, h).
    var liftRect: SIMD4<Float>
    var oppRect: SIMD4<Float>
    /// Board edge colour (rgb) and strength (a, 0 = paper).
    var rim: SIMD4<Float>
    var viewSize: SIMD2<Float>
    /// W′ (half gap + page across), H (along the binding).
    var pageSize: SIMD2<Float>
    /// Overlay coordinate of the hinge line (x for a vertical binding, y for a horizontal one).
    var hinge: Float
    /// +1 lifting the recto (forward), −1 lifting the verso (backward).
    var sigma: Float
    var halfGutter: Float
    var horizontal: Float
    var hasRevealed: Float
    /// 0 at rest / landed (exactly the pages) … 1 in the air.
    var effect: Float
    /// Perspective: camera distance (points).
    var camera: Float
    /// Light toward the source in σ-space (across component) and its height component (normalised together).
    var lightAcross: Float
    var lightZ: Float
    /// The shadow profile spans ±shadowReach·W′ across.
    var shadowReach: Float
    var shadowBins: Float
    var pad: Float = 0
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
        float2 pageSize;
        float  hinge;
        float  sigma;
        float  halfGutter;
        float  horizontal;
        float  hasRevealed;
        float  effect;
        float  camera;
        float  lightAcross;
        float  lightZ;
        float  shadowReach;
        float  shadowBins;
        float  pad;
    };

    static inline float hg_hash(float2 p) {
        uint2 q = uint2(int2(floor(p)) + int2(65536));
        uint h = (q.x * 0x8da6b343u) ^ (q.y * 0xd8163841u);
        h ^= h >> 15; h *= 0x2c1b3c6du;
        h ^= h >> 12; h *= 0x297a2d39u;
        h ^= h >> 15;
        return float(h) * (1.0 / 4294967296.0);
    }

    // ── background: the page the leaf uncovers + the leaf's shadow on both sides ──

    struct HingeBgOut {
        float4 position [[position]];
        float2 point;      // overlay points
    };

    vertex HingeBgOut hinge_bg_vertex(uint vid [[vertex_id]], constant CurlSpreadUniforms &U [[buffer(0)]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        HingeBgOut o;
        o.position = float4(p * 2.0 - 1.0, 1.0, 1.0);
        o.point = float2(p.x, 1.0 - p.y) * U.viewSize;
        return o;
    }

    fragment float4 hinge_bg_fragment(HingeBgOut in [[stage_in]],
                                      constant CurlSpreadUniforms &U [[buffer(0)]],
                                      constant float *shadowLUT [[buffer(1)]],
                                      texture2d<float> revealedTex [[texture(0)]],
                                      sampler smp [[sampler(0)]]) {
        float2 P = in.point;
        bool hz = U.horizontal > 0.5;
        float W = U.pageSize.x, H = U.pageSize.y;
        float across = U.sigma * (hz ? P.y - U.hinge : P.x - U.hinge);
        float along = hz ? P.x - U.liftRect.x : P.y - U.liftRect.y;
        // the shadow profile across (linear between bins), faded at the ends of the binding
        float n = U.shadowBins;
        float t = (across / W + U.shadowReach) / (2.0 * U.shadowReach) * n - 0.5;
        int i0 = clamp(int(floor(t)), 0, int(n) - 1);
        int i1 = clamp(i0 + 1, 0, int(n) - 1);
        float sh = mix(shadowLUT[i0], shadowLUT[i1], saturate(t - floor(t)));
        if (t < -0.5 || t > n - 0.5) sh = 0.0;
        sh *= smoothstep(-5.0, 0.0, along) * (1.0 - smoothstep(H, H + 5.0, along));
        float2 uvR = (P - U.liftRect.xy) / U.liftRect.zw;
        bool inLift = uvR.x >= 0.0 && uvR.x <= 1.0 && uvR.y >= 0.0 && uvR.y <= 1.0;
        if (inLift && U.hasRevealed > 0.5) {
            float4 r = revealedTex.sample(smp, uvR, level(0.0));
            float3 c = r.rgb * (1.0 - sh);
            if (sh > 0.0) c = saturate(c + (hg_hash(in.position.xy + 3.0) - 0.5) * (1.0 / 255.0));
            return float4(c, 1.0);
        }
        return float4(0.0, 0.0, 0.0, sh);
    }

    // ── the leaf: a strip mesh of the bowed sheet (two vertices per profile sample) ──

    struct HingeLeafOut {
        float4 position [[position]];
        float s;           // arc length from the hinge (page across of the lifted page)
        float y;           // along the binding (page y)
        float phi;         // local angle
    };

    vertex HingeLeafOut hinge_leaf_vertex(uint vid [[vertex_id]],
                                          constant CurlSpreadUniforms &U [[buffer(0)]],
                                          constant float4 *profile [[buffer(1)]]) {
        float4 p = profile[vid >> 1];                  // X, Z, s, φ
        float H = U.pageSize.y;
        float y = (vid & 1) ? H : 0.0;
        float k = U.camera / (U.camera - p.y);
        float c = 0.5 * H;
        float acr = U.hinge + U.sigma * p.x * k;
        float alg = c + (y - c) * k;
        bool hz = U.horizontal > 0.5;
        float2 P = hz ? float2(U.liftRect.x + alg, acr) : float2(acr, U.liftRect.y + alg);
        float2 ndc = float2(P.x / U.viewSize.x * 2.0 - 1.0, 1.0 - P.y / U.viewSize.y * 2.0);
        float w = 1.0 / k;
        float depth = 0.5 - 0.4 * p.y / U.camera;
        HingeLeafOut o;
        o.position = float4(ndc * w, depth * w, w);
        o.s = p.z;
        o.y = y;
        o.phi = p.w;
        return o;
    }

    fragment float4 hinge_leaf_fragment(HingeLeafOut in [[stage_in]],
                                        bool front [[front_facing]],
                                        constant CurlSpreadUniforms &U [[buffer(0)]],
                                        texture2d<float> frontTex [[texture(0)]],
                                        texture2d<float> backTex [[texture(1)]],
                                        sampler smp [[sampler(0)]]) {
        const float3 paperFront = float3(252.0, 251.0, 247.0) / 255.0;   // #FCFBF7
        bool hz = U.horizontal > 0.5;
        float fx = U.effect;
        bool flat = fx <= 0.0;
        float s = in.s, y = in.y;
        float W = U.pageSize.x, H = U.pageSize.y;

        // where this point of the leaf lies flat: on its own side (front), mirrored on the other side (back)
        float fa = U.hinge + U.sigma * s;
        float ba = U.hinge - U.sigma * s;
        float2 pf = hz ? float2(U.liftRect.x + y, fa) : float2(fa, U.liftRect.y + y);
        float2 pb = hz ? float2(U.oppRect.x + y, ba) : float2(ba, U.oppRect.y + y);
        float2 uvF = (pf - U.liftRect.xy) / U.liftRect.zw;
        float2 uvB = (pb - U.oppRect.xy) / U.oppRect.zw;
        float2 dFx = dfdx(uvF), dFy = dfdy(uvF);
        float2 dBx = dfdx(uvB), dBy = dfdy(uvB);
        float4 fc = frontTex.sample(smp, uvF, gradient2d(flat ? float2(0.0) : dFx, flat ? float2(0.0) : dFy));
        float4 bc = backTex.sample(smp, uvB, gradient2d(flat ? float2(0.0) : dBx, flat ? float2(0.0) : dBy));
        // the ink of the other side shows faintly through the thin paper (diffused by the fibres)
        float4 thru = frontTex.sample(smp, uvF, gradient2d(dFx * 3.0, dFy * 3.0));

        // light: the face's normal in σ-space (across, z) against a light from above, a little from the top-left
        float phi = in.phi;
        float2 nf = float2(-sin(phi), cos(phi));
        float2 n = front ? nf : -nf;
        float2 L = float2(U.lightAcross, U.lightZ);
        float d = dot(n, L);
        float shade = 1.0 + fx * (0.22 * (d - U.lightZ) - 0.02);
        float sheen = fx * 0.045 * smoothstep(0.90, 1.0, d);

        // the leaf's own edges read as paper (a hairline), a board shows its thickness in the cover colour
        float ws = max(fwidth(s), 1e-4), wy = max(fwidth(y), 1e-4);
        float edgePx = min(min((W - s) / ws, (s - U.halfGutter) / ws), min(y / wy, (H - y) / wy));
        float edge = 1.0 - smoothstep(0.0, 1.4, edgePx);

        float3 col;
        if (front) {
            col = fc.rgb * shade * (1.0 - 0.12 * fx * edge) + sheen;
        } else {
            float3 ink = saturate(1.0 - thru.rgb / paperFront);
            col = bc.rgb * (1.0 - 0.02 * fx * ink) * shade * (1.0 - 0.12 * fx * edge) + sheen;
        }
        col = mix(col, U.rim.rgb, U.rim.a * fx * (1.0 - smoothstep(0.0, 2.2, edgePx)));
        if (!flat) col = saturate(col + (hg_hash(in.position.xy + 7.0) - 0.5) * (1.0 / 255.0));
        return float4(col, 1.0);
    }
    """
}
