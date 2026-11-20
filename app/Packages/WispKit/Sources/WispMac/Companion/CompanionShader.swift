// Metal Shading Language source for the companion, compiled at runtime (no build-time Metal step needed
// inside the Swift package). Uniform layout: `float4 u[16]`, documented in `CompanionUniforms`.
let companionShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;   // canvas units, (0,0) top-left, (1,1) bottom-right
};

vertex VOut companion_vertex(uint vid [[vertex_id]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 p = corners[vid];
    VOut out;
    out.position = float4(p, 0, 1);
    out.uv = float2((p.x + 1) * 0.5, 1 - (p.y + 1) * 0.5);
    return out;
}

// ---- noise ----------------------------------------------------------------------------------------
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p, int octaves) {
    float v = 0.0;
    float amp = 0.5;
    float2x2 rot = float2x2(float2(0.8, -0.6), float2(0.6, 0.8));
    for (int i = 0; i < octaves; i++) {
        v += amp * vnoise(p);
        p = rot * p * 2.02 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return v;
}

// ---- uniforms -------------------------------------------------------------------------------------
// u[0]  = time, morph (0 arrow .. 1 hand), opacity, unused
// u[1]  = scale, warp, softness, speed
// u[2]  = gloss, style (0 bands, 1 blobs, 2 rays), paletteCount, glow
// u[3]  = extrude.x, extrude.y, shadow.x, shadow.y   (canvas units)
// u[4]  = shadowBlur, shadowAlpha, seed, squash (press/land squash)
// u[5..12] = palette colours (rgb)
// u[13] = glow colour (rgb), unused
// u[14] = outline width (canvas units, 0 = none), outline rgb

static float3 palette(float t, constant float4 *u) {
    int n = int(u[2].z);
    float x = clamp(t, 0.0, 1.0) * float(n - 1);
    int i = min(int(floor(x)), n - 2);
    float f = x - float(i);
    f = f * f * (3.0 - 2.0 * f); // smooth blend between stops
    return mix(u[5 + i].rgb, u[6 + i].rgb, f);
}

// Triangle wave in 0...1: unlike a sine it spends equal time at every value, so every palette stop gets an
// equal share of the surface (a sine piles up at the darkest and brightest colours).
/// Band-limited triangle wave: as the phase changes faster than ~0.3 periods per pixel (warp folds), the
/// value fades to the average so there are no aliased hairlines or speckles.
static float triAA(float x) {
    float w = fwidth(x);
    float v = abs(fract(x) * 2.0 - 1.0);
    v = v * v * (3.0 - 2.0 * v);
    return mix(v, 0.5, clamp((w - 0.12) * 4.0, 0.0, 1.0));
}

static float tri(float x) {
    float v = abs(fract(x) * 2.0 - 1.0);
    // Round the turning points so the darkest/brightest ribbons never form hard creases.
    return v * v * (3.0 - 2.0 * v);
}

// Smooth "liquid light" field: iteratively warped sines give flowing, marbled ribbons with no blockiness.
static float2 liquidWarp(float2 p, float t, float warp, int steps) {
    for (int i = 1; i <= steps; i++) {
        float fi = float(i);
        p += warp * float2(0.55 * sin(fi * 1.3 * p.y + t * (0.6 + 0.13 * fi) + fi * 1.7),
                           0.55 * cos(fi * 1.1 * p.x - t * (0.5 + 0.11 * fi) + fi * 2.3)) / fi;
    }
    return p;
}

static float fluidValue(float2 uv, constant float4 *u) {
    float t = u[0].x * u[1].w;
    float scale = u[1].x;
    float warp = u[1].y;
    float soft = u[1].z;
    int style = int(u[2].y + 0.5);
    // ~scale × 2.4 units across the canvas; the arrow covers about half of it.
    float2 p = (uv - 0.4) * scale * 2.0 + float2(u[4].z, u[4].z * 0.37);

    if (style == 2) {
        // Rays: ribbons stretched along a diagonal, with bright thin cores.
        float2x2 rot = float2x2(float2(0.80, -0.60), float2(0.60, 0.80));
        float2 q = rot * p;
        q = liquidWarp(float2(q.x * 0.55, q.y * 1.6), t, warp * 0.8, 4);
        float s1 = triAA((q.y * 2.6 + q.x * 0.6) * 0.26);
        float core = pow(smoothstep(0.0, 1.0, s1), mix(1.6, 1.1, soft));
        return clamp(core, 0.0, 1.0);
    }
    if (style == 1) {
        // Blobs: large soft pools of colour that drift and merge.
        float2 q = liquidWarp(p * 0.95, t * 0.8, warp * 1.1, 4);
        float phase = (sin(q.x * 2.1) + cos(q.y * 1.8 + q.x * 0.7)) * 0.30 + q.x * 0.16 + q.y * 0.11;
        float v = triAA(phase);
        return mix(smoothstep(0.1, 0.9, v), v, soft);
    }
    // Bands: flowing marbled stripes.
    float2 q = liquidWarp(p, t, warp * 1.15, 5);
    float v = triAA((q.x * 1.7 + q.y * 1.2) * 0.30);
    // Low softness gives glassier ribbons (steeper ramps); high softness keeps long blurred gradients.
    return mix(smoothstep(0.1, 0.9, v), v, soft);
}

struct FOut { float4 color [[color(0)]]; };

static float2 shapeSDF(float2 p, float morph, texture2d<float> a, texture2d<float> h, sampler s) {
    return mix(a.sample(s, p).rg, h.sample(s, p).rg, morph);
}

fragment FOut companion_fragment(VOut in [[stage_in]],
                                 constant float4 *u [[buffer(0)]],
                                 texture2d<float> arrowTex [[texture(0)]],
                                 texture2d<float> handTex [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
    float morph = u[0].y;
    float opacity = u[0].z;
    float2 uv = in.uv;
    // Press/land squash around the hotspot (subtle).
    float squash = u[4].w;
    float2 hot = float2(0.27, 0.13);
    uv = hot + (uv - hot) / float2(1.0 + squash * 0.06, 1.0 - squash * 0.08);

    float2 here = shapeSDF(uv, morph, arrowTex, handTex, s);
    float d = here.x;
    float aa = max(fwidth(d), 0.0008);

    // 3D side: union of the shape slid along the extrusion direction.
    float2 ext = u[3].xy;
    float side = 1e3;
    for (int k = 1; k <= 6; k++) {
        side = min(side, shapeSDF(uv - ext * (float(k) / 6.0), morph, arrowTex, handTex, s).x);
    }
    float sideMask = 1.0 - smoothstep(-aa, aa, side);
    float topMask = 1.0 - smoothstep(-aa, aa, d);

    // Soft drop shadow of the whole extruded object.
    float sh = shapeSDF(uv - u[3].zw, morph, arrowTex, handTex, s).x;
    float shadow = (1.0 - smoothstep(-u[4].x, u[4].x, sh - u[14].x)) * u[4].y;

    // Fluid fill (pattern lives in shape space, so it travels with the companion).
    // Bias towards the bright, saturated middle of the palette (dark tones read as thin ribbons).
    float v = fluidValue(uv, u);
    float3 top = palette(v, u);
    // Luminous cores: the brightest parts of the flow glow slightly, like light inside liquid.
    top += smoothstep(0.75, 1.0, v) * 0.08;

    // Bevel lighting from the top-left. The SDF gradient is only a reliable surface normal close to the
    // edge (deep inside it flips along the shape's centre line), so all lighting stays in a thin rim.
    float e = 0.006;
    float2 grad = float2(shapeSDF(uv + float2(e, 0), morph, arrowTex, handTex, s).x - shapeSDF(uv - float2(e, 0), morph, arrowTex, handTex, s).x,
                         shapeSDF(uv + float2(0, e), morph, arrowTex, handTex, s).x - shapeSDF(uv - float2(0, e), morph, arrowTex, handTex, s).x);
    float gl = length(grad);
    float2 n = gl > 1e-5 ? grad / gl : float2(0.0);
    float rimZone = 1.0 - smoothstep(0.018, 0.034, -d);      // 1 at the edge, 0 deeper than ~3% of the canvas
    float facing = dot(n, normalize(float2(-1.0, -1.0))) * rimZone;
    float gloss = u[2].x;
    float rim = 1.0 - smoothstep(0.0, 0.022, -d);
    top += rim * max(facing, 0.0) * gloss * 0.45;
    top *= 1.0 - rim * max(-facing, 0.0) * 0.22;
    float sheen = smoothstep(0.004, 0.012, -d) * (1.0 - smoothstep(0.016, 0.03, -d)) * max(facing, 0.0);
    top += sheen * gloss * 0.16;

    // Detail creases (hand): darken thin lines.
    float line = here.y;
    float lineMask = (1.0 - smoothstep(0.0045 - aa, 0.0045 + aa, line)) * morph;
    top *= 1.0 - lineMask * 0.38;

    // Side colour: the same fluid, shifted and darkened, darker towards the back.
    float3 sideColor = palette(fluidValue(uv - ext * 0.5, u), u) * 0.58;

    // Outer glow (listening / pointing emphasis).
    float glow = u[2].w;
    float glowA = glow * exp(-max(d, 0.0) * 38.0) * (1.0 - topMask);
    float3 glowColor = u[13].rgb;

    // Composite back to front, premultiplied alpha.
    float4 c = float4(0, 0, 0, shadow * (1.0 - sideMask));
    float4 g = float4(glowColor * glowA, glowA);
    c = g + c * (1.0 - g.a);
    float4 sd = float4(sideColor, 1.0) * sideMask;
    c = sd + c * (1.0 - sd.a);
    float4 tp = float4(clamp(top, 0.0, 1.0), 1.0) * topMask;
    c = tp + c * (1.0 - tp.a);
    // Outline band around the whole silhouette (white or black, like a system pointer's border).
    float ow = u[14].x;
    if (ow > 0.0) {
        float body = min(d, side);
        float ring = (1.0 - smoothstep(ow - aa, ow + aa, body)) * (1.0 - max(topMask, sideMask));
        float4 oc = float4(u[14].yzw, 1.0) * ring;
        c = oc + c * (1.0 - oc.a);
    }

    FOut out;
    out.color = c * opacity;
    if (u[0].w > 0.5) {
        // Debug view: the raw fluid value as greyscale inside the shape.
        out.color = float4(float3(v), 1.0) * topMask;
    }
    return out;
}
"""#
