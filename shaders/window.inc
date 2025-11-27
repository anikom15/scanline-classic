/* Filename: window.inc

   Shared windowed-sinc utilities for IF modulation/demodulation.
   Contains Kaiser I0 approximation, Kaiser window, and
   lowpass/bandpass windowed-sinc coefficient helpers.
*/

// Modified Bessel function I0(x) - polynomial approximation
float bessel_i0(float x)
{
    float ax = abs(x);
    if (ax < 3.75) {
        float y = x / 3.75;
        y = y * y;
        return 1.0 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492
            + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))));
    } else {
        float y = 3.75 / ax;
        return (exp(ax) / sqrt(ax)) * (0.39894228 + y * (0.01328592
            + y * (0.00225319 + y * (-0.00157565 + y * (0.00916281
            + y * (-0.02057706 + y * (0.02635537 + y * (-0.01647633
            + y * 0.00392377))))))));
    }
}

// Kaiser window, safe domain via clamped radius
float kaiser_window(float n, float N, float beta)
{
    float halfN = max(0.5 * N, 1e-6);
    float r = abs(n) / halfN;  // 0 at center, 1 at edge
    float t = 1.0 - clamp(r * r, 0.0, 1.0);
    float denom = max(bessel_i0(beta), 1e-6);
    float arg = beta * sqrt(t);
    return bessel_i0(arg) / denom;
}

// Windowed-sinc lowpass coefficient (normalized cutoff fc in cycles/sample)
float sinc_lowpass_coeff(float n, float fc_norm, float beta, float N)
{
    float sinc;
    if (abs(n) < EPS) {
        sinc = 2.0 * fc_norm;  // integral of ideal LP at n=0
    } else {
        float x = 2.0 * PI * fc_norm * n;
        sinc = sin(x) / (PI * n);
    }
    float w = kaiser_window(n, N, beta);
    return sinc * w;
}

// Windowed-sinc bandpass coefficient using difference of two lowpass sincs
float sinc_bandpass_coeff(float n, float fc_upper, float fc_lower, float beta, float N)
{
    float sinc_upper, sinc_lower;
    if (abs(n) < EPS) {
        sinc_upper = 2.0 * fc_upper;
        sinc_lower = 2.0 * fc_lower;
    } else {
        float x_upper = 2.0 * PI * fc_upper * n;
        float x_lower = 2.0 * PI * fc_lower * n;
        sinc_upper = sin(x_upper) / (PI * n);
        sinc_lower = sin(x_lower) / (PI * n);
    }
    float bandpass_sinc = sinc_upper - sinc_lower;
    float window = kaiser_window(n, N, beta);
    return bandpass_sinc * window;
}
