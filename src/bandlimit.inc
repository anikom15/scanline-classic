// Shared bandlimit utilities (Gaussian lobe-based 1D convolution)
// Requires: common.h (gaussian3), GLSL 450+ context

// Perform horizontal Gaussian bandlimit via lobe summation.
// - vTexCoord: normalized texture coordinates (0..1)
// - OutputSize: vec4(width, height, 1/width, 1/height)
// - Source: sampler2D of the source image
// - sigma: per-channel Gaussian standard deviations in texel units (uv domain)
// Returns filtered RGB color.
vec3 bandlimit_convolve_gaussian_x(vec2 vTexCoord, vec4 OutputSize, sampler2D Source, vec3 sigma)
{
    // Convert to pixel space
    vec2 UV = vTexCoord * OutputSize.xy;

    // Horizontal subpixel handling: shift only X by -0.5 to land on pixel edge
    float UX = UV.x - 0.5;

    // Fractional horizontal position relative to chosen base pixel
    float Ax = fract(UX);

    // Base texel center (X adjusted, Y unchanged)
    float baseX = (floor(UX) + 0.5) * OutputSize.z;
    float baseY = (floor(UV.y) + 0.5) * OutputSize.w;
    vec2 Tex = vec2(baseX, baseY);

    // Accumulators
    vec3 color = vec3(0.0);
    vec3 wsum  = vec3(0.0);

    vec2 dx = vec2(OutputSize.z, 0.0);

    // Center lobe (n = 0): Gaussian centered, Ax is residual offset
    vec3 pixel = texture(Source, Tex).rgb;
    vec3 w0 = gaussian3(Ax, sigma);
    color = w0 * pixel;
    wsum  = w0;

    const float THRESHOLD = 1.0 / 510.0;

    // Symmetric lobes: use (n + Ax) for right, (n - Ax) for left
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);

        // Distances from true subpixel center
        vec3 wr = gaussian3(nf + Ax, sigma);
        vec3 wl = gaussian3(nf - Ax, sigma);

        // Early out only if BOTH sides negligible
        if (all(lessThan(wr, vec3(THRESHOLD))) &&
            all(lessThan(wl, vec3(THRESHOLD))))
            break;

        vec3 pr = texture(Source, Tex + nf * dx).rgb;
        vec3 pl = texture(Source, Tex - nf * dx).rgb;

        color += wr * pr + wl * pl;
        wsum  += wr + wl;
    }

    return color / wsum;
}