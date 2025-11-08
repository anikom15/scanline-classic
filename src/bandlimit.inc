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