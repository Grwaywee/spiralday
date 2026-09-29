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
