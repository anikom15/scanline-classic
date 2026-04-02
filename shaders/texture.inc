// Texture sampling helpers (shared)

#ifndef TEXTURE_INC
#define TEXTURE_INC

#define clamp01(uv) clamp((uv), 0.0, 1.0 - EPS)

float bicubic(const float x, const float B, const float C)
{
    float dx = abs(x);

    if (dx < 1.0) {
        float P1 = 2.0 - 3.0 / 2.0 * B - C;
        float P2 = -3.0 + 2.0 * B + C;
        float P3 = 1.0 - 1.0 / 3.0 * B;

        return P1 * dx * dx * dx + P2 * dx * dx + P3;
    } else if ((dx >= 1.0) && (dx < 2.0)) {
        float P1 = -1.0 / 6.0 * B - C;
        float P2 = B + 5.0 * C;
        float P3 = -2.0 * B - 8.0 * C;
        float P4 = 4.0 / 3.0 * B + 4.0 * C;

        return P1 * dx * dx * dx + P2 * dx * dx + P3 * dx + P4;
    } else
        return 0.0;
}

vec4 bicubic4(const float x, const float B, const float C)
{
    return vec4(
        bicubic(x - 2.0, B, C),
        bicubic(x - 1.0, B, C),
        bicubic(x, B, C),
        bicubic(x + 1.0, B, C)
    );
}

// Branchless bicubic tap weights for fractional offset f in [0,1].
// The piecewise region each tap falls in is statically known:
//   tap 0 (.r): outer  dx = 1+f
//   tap 1 (.g): inner  dx = f
//   tap 2 (.b): inner  dx = 1-f
//   tap 3 (.a): outer  dx = 2-f
// Eliminates all branches from the weight computation path.
vec4 bicubic_weights(float f, float B, float C)
{
    // Inner-region polynomial coefficients: P1*dx^3 + P2*dx^2 + P3
    float Pi1 = 2.0 - 1.5 * B - C;
    float Pi2 = -3.0 + 2.0 * B + C;
    float Pi3 = 1.0 - (1.0 / 3.0) * B;

    // Outer-region polynomial coefficients: Po1*dx^3 + Po2*dx^2 + Po3*dx + Po4
    float Po1 = -(1.0 / 6.0) * B - C;
    float Po2 = B + 5.0 * C;
    float Po3 = -2.0 * B - 8.0 * C;
    float Po4 = (4.0 / 3.0) * B + 4.0 * C;

    // Evaluate via Horner's method (minimises multiply count)
    float g = 1.0 - f;
    float h = 1.0 + f;
    float k = 2.0 - f;

    float w1 = ((Pi1 * f + Pi2) * f) * f + Pi3;          // inner, dx = f
    float w2 = ((Pi1 * g + Pi2) * g) * g + Pi3;          // inner, dx = 1-f
    float w0 = ((Po1 * h + Po2) * h + Po3) * h + Po4;   // outer, dx = 1+f
    float w3 = ((Po1 * k + Po2) * k + Po3) * k + Po4;   // outer, dx = 2-f

    return vec4(w0, w1, w2, w3);
}

vec3 sample_clamped(sampler2D source, vec2 uv)
{
    return texture(source, clamp01(uv)).rgb;
}

// Lightweight anisotropic-like fallback for spatial transforms.
// Uses two bilinear samples along the local major distortion axis.
vec3 sample_directional_bilinear(sampler2D source, vec2 uv, vec2 stepxy)
{
    vec2 dx = dFdx(uv);
    vec2 dy = dFdy(uv);

    float dx2 = dot(dx, dx);
    float dy2 = dot(dy, dy);
    vec2 major = (dx2 > dy2) ? dx : dy;
    float major_len = sqrt(max((dx2 > dy2) ? dx2 : dy2, EPS));

    vec2 dir = major / max(major_len, EPS);
    float texel = max(stepxy.x, stepxy.y);
    float footprint = major_len / max(texel, EPS);
    float spread = clamp((footprint - 1.0) * 0.5, 0.0, 1.5);
    vec2 offset = dir * spread * stepxy;

    return 0.5 * (
        texture(source, uv - offset).rgb +
        texture(source, uv + offset).rgb);
}

// Bicubic texture sampling (4x4 Mitchell-Netravali), clamp-to-zero
vec3 sample_bicubic(sampler2D source, vec2 uv, vec2 stepxy, float B, float C)
{
    vec2 pos = uv + stepxy / 2.0;
    vec2 f = fract(pos / stepxy);

    vec4 xtaps = bicubic_weights(f.x, B, C);
    vec4 ytaps = bicubic_weights(f.y, B, C);
    xtaps /= (xtaps.r + xtaps.g + xtaps.b + xtaps.a);
    ytaps /= (ytaps.r + ytaps.g + ytaps.b + ytaps.a);

    vec2 xystart = (-1.5 - f) * stepxy + pos;

    vec4 xpos = vec4(xystart.x,
        xystart.x + stepxy.x,
        xystart.x + stepxy.x * 2.0,
        xystart.x + stepxy.x * 3.0);

    vec3 col = vec3(0.0);

    float y0 = xystart.y;
    col += (texture(source, vec2(xpos.r, y0)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y0)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y0)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y0)).rgb * xtaps.a) * ytaps.r;

    float y1 = xystart.y + stepxy.y;
    col += (texture(source, vec2(xpos.r, y1)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y1)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y1)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y1)).rgb * xtaps.a) * ytaps.g;

    float y2 = xystart.y + stepxy.y * 2.0;
    col += (texture(source, vec2(xpos.r, y2)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y2)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y2)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y2)).rgb * xtaps.a) * ytaps.b;

    float y3 = xystart.y + stepxy.y * 3.0;
    col += (texture(source, vec2(xpos.r, y3)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y3)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y3)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y3)).rgb * xtaps.a) * ytaps.a;

    return col;
}

// Fast bicubic: merges each adjacent tap pair into one hardware bilinear fetch,
// reducing 16 point samples to 4 bilinear samples with identical kernel shape.
// REQUIRES the source sampler to use linear (bilinear) filtering.
// Set filter_linearN = true for this pass in the .slangp preset.
vec3 sample_bicubic_fast(sampler2D source, vec2 uv, vec2 stepxy, float B, float C)
{
    vec2 pos = uv + stepxy / 2.0;
    vec2 f = fract(pos / stepxy);

    vec4 wx = bicubic_weights(f.x, B, C);
    vec4 wy = bicubic_weights(f.y, B, C);
    wx /= (wx.r + wx.g + wx.b + wx.a);
    wy /= (wy.r + wy.g + wy.b + wy.a);

    vec2 xystart = (-1.5 - f) * stepxy + pos;

    // Merged pair weights along each axis
    float wx01 = wx.r + wx.g;
    float wx23 = wx.b + wx.a;
    float wy01 = wy.r + wy.g;
    float wy23 = wy.b + wy.a;

    // Bilinear sample positions: tap_i position + (w_{i+1}/w_pair) * step
    // Guard against degenerate cases (e.g. Catmull-Rom at f=0 where wx23->0)
    float xA = xystart.x + (wx.g / max(wx01, EPS)) * stepxy.x;
    float xB = xystart.x + (2.0 + wx.a / max(wx23, EPS)) * stepxy.x;
    float yA = xystart.y + (wy.g / max(wy01, EPS)) * stepxy.y;
    float yB = xystart.y + (2.0 + wy.a / max(wy23, EPS)) * stepxy.y;

    return
        texture(source, vec2(xA, yA)).rgb * (wx01 * wy01) +
        texture(source, vec2(xB, yA)).rgb * (wx23 * wy01) +
        texture(source, vec2(xA, yB)).rgb * (wx01 * wy23) +
        texture(source, vec2(xB, yB)).rgb * (wx23 * wy23);
}

#endif
