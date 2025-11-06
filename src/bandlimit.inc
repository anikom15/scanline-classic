// Shared bandlimit utilities (Gaussian lobe-based 1D convolution)
// Requires: common.h (gaussian3), GLSL 450+ context

#ifndef BANDLIMIT_INC_GUARD
#define BANDLIMIT_INC_GUARD

/**
 * sigma601
 *
 * Purpose:
 *   Map an analog low-pass "bandwidth" specification—expressed in MHz under a BT.601-like
 *   sampling model—plus a desired attenuation (in dB) at that bandwidth, to a spatial-domain
 *   Gaussian standard deviation (sigma) in texel units. This sigma is used by the Gaussian
 *   lobe summation in bandlimit_convolve_gaussian_x to approximate the desired bandlimit.
 *
 * Parameters:
 *   bandwidth     - Per-channel analog bandwidth in MHz (e.g., 6.75 for BT.601 Nyquist).
 *                   Larger bandwidth => a higher cutoff => a sharper (smaller-sigma) blur.
 *   cutoff_atten  - Per-channel attenuation at the specified bandwidth, in dB (positive).
 *                   Larger attenuation (e.g., 3 dB -> 6 dB) => stronger blur (larger sigma)
 *                   to meet the steeper roll-off at the cutoff.
 *   x             - Current horizontal pixel count used to normalize frequency-to-pixel scaling.
 *                   Pass OutputSize.x so the same MHz spec maps consistently at any resolution.
 *
 * Units and model:
 *   - The function assumes a BT.601 context (13.5 MHz pixel clock, 720 active samples/line).
 *   - Internally we compute:
 *       c    = 10^(cutoff_atten/20)       // linear amplitude ratio at cutoff
 *       res  = (720 / 6.75) * bandwidth   // "effective" cycles per active line at cutoff
 *       sigma = sqrt(ln(c)) / (res / x)   // returned in texels (pixels) per channel
 *
 *   Intuition:
 *   - res scales the requested analog bandwidth into an equivalent cycles-per-line cutoff,
 *     relative to a 720-pixel active region. Multiplying by (x / res) converts that cutoff
 *     to a pixel-domain length scale for the current output width x.
 *   - sqrt(ln(c)) raises sigma as the demanded attenuation in dB increases. If you ask for
 *     more attenuation at the same cutoff frequency, the blur must be stronger.
 *   - Increasing bandwidth lowers sigma (sharper), increasing attenuation raises sigma (softer),
 *     increasing x (more pixels across the same physical width) raises sigma linearly so that
 *     the same MHz spec produces the same physical MTF regardless of resolution.
 */
vec3 sigma601(const vec3 bandwidth, const vec3 cutoff_atten, const float x)
{
    // c = 10^(atten/20)
    vec3 c = 1.0 / pow(vec3(10.0, 10.0, 10.0), vec3(
        -cutoff_atten.r / 20.0,
        -cutoff_atten.g / 20.0,
        -cutoff_atten.b / 20.0));

    // res = (720 / 6.75) * bandwidth(MHz)   => cycles per active line at cutoff
    vec3 res = vec3(
        720.0 / 6.75 * bandwidth.r,
        720.0 / 6.75 * bandwidth.g,
        720.0 / 6.75 * bandwidth.b);

    // sigma in texels
    return vec3(
        sqrt(log(c.r)) / (res.x / x),
        sqrt(log(c.g)) / (res.y / x),
        sqrt(log(c.b)) / (res.z / x));
}

// Perform horizontal Gaussian bandlimit via lobe summation.
// - vTexCoord: normalized texture coordinates (0..1)
// - OutputSize: vec4(width, height, 1/width, 1/height)
// - Source: sampler2D of the source image
// - sigma: per-channel Gaussian standard deviations in texel units (uv domain)
// Returns filtered RGB color.
vec3 bandlimit_convolve_gaussian_x(vec2 vTexCoord, vec4 OutputSize, sampler2D Source, vec3 sigma)
{
    // Standard texturing coordinates (source pixel grid)
    vec2 UV = vTexCoord * OutputSize.xy;
    vec2 A = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * OutputSize.zw;

    // Accumulated color and weights
    vec3 color = vec3(0.0);
    vec3 wsum  = vec3(0.0);

    // Step size in texture coordinates (one texel to the right)
    vec2 dx = vec2(OutputSize.z, 0.0);

    // Center lobe (n = 0)
    vec3 pixel = texture(Source, Tex).rgb;
    vec3 w = gaussian3(A.x, sigma);
    color = w * pixel;
    wsum  = w;

    // Gaussian right and left lobes
    const float THRESHOLD = 1.0 / 510.0;

    for (int n = 1; n <= 32; ++n) {
        float nf = float(n) + A.x;
        w = gaussian3(nf, sigma);

        // Early out when contribution is negligible on all channels
        if (all(lessThan(w, vec3(THRESHOLD))))
            break;

        vec3 pr = texture(Source, Tex + float(n) * dx).rgb;
        vec3 pl = texture(Source, Tex - float(n) * dx).rgb;

        color += w * pr + w * pl;
        wsum  += w + w;
    }

    return color / wsum;
}

#endif // BANDLIMIT_INC_GUARD
