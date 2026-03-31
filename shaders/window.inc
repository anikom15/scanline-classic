/* Filename: window.inc

   Shared windowed-sinc utilities for IQ modulation/demodulation.
   Contains Blackman-Harris 4-term window and windowed-sinc coefficient helpers.
*/

// Standard sinc function (normalized to cycles/sample)
// Safe for n = 0 due to limit definition
float sinc(float n, float fc_norm)
{
    return abs(n) < EPS
        ? 2.0 * fc_norm : sin(2.0 * PI * fc_norm * n) / (PI * n);
}

// Blackman-Harris 4-term window
// Stopband: ~92 dB, mainlobe width = 8π/N
// Superior phase linearity and stopband rejection compared to Kaiser
float blackman_harris_4term(float n, float N)
{
    const float a0 = 0.35875;
    const float a1 = 0.48829;
    const float a2 = 0.14128;
    const float a3 = 0.01168;

    float Ne = max(N - 1.0, 1.0);
    float k = n + 0.5 * Ne;        // center at (N-1)/2
    float x = 2.0 * PI * k / Ne;   // use N-1 denominator

    return a0 - a1 * cos(x) + a2 * cos(2.0 * x) - a3 * cos(3.0 * x);
}

// Hamming window
// Stopband: ~43 dB, mainlobe width = 4π/N
// Efficient window for baseband IQ filtering with minimal ringing (~1.5% overshoot)
float hamming(float n, float N)
{
    const float a0 = 0.54;
    const float a1 = 0.46;

    float Ne = max(N - 1.0, 1.0);
    float k = n + 0.5 * Ne;        // center at (N-1)/2
    float x = 2.0 * PI * k / Ne;   // use N-1 denominator

    return a0 - a1 * cos(x);
}

// Modified Bessel function I0(x) approximation
// Accurate to ~1e-7 for practical range |x| <= 20
// Uses polynomial approximation for efficient GPU computation
float kaiser_i0(float x)
{
    float ax = abs(x);
    if (ax < 3.75) {
        // Polynomial approximation for small arguments
        float y = sq(x / 3.75);
        return 1.0 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492
            + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))));
    } else {
        // Asymptotic approximation for large arguments
        float y = 3.75 / ax;
        return (exp(ax) / sqrt(ax)) * (0.39894228 + y * (0.01328592
            + y * (0.00225319 + y * (-0.00157565 + y * (0.00916281
            + y * (-0.02057706 + y * (0.02635537 + y * (-0.01647633
            + y * 0.00392377))))))));
    }
}

// Kaiser window with tunable ripple parameter
// beta: ripple control parameter (higher = more stopband rejection)
// Common values:
//   beta ≈ 5.0  → ~50 dB stopband, 0.3 dB passband ripple
//   beta ≈ 5.87 → ~62 dB stopband, 0.2 dB passband ripple
//   beta ≈ 8.6  → ~70 dB stopband
//   beta ≈ 10.6 → ~92 dB stopband
float kaiser(float n, float N, float beta)
{
    float Ne = max(N - 1.0, 1.0);
    float k = n + 0.5 * Ne;        // center at (N-1)/2
    float alpha = 2.0 * k / Ne - 1.0;

    // Normalized argument for I0: β√(1 - α²)
    float arg = beta * sqrt(max(1.0 - sq(alpha), 0.0));
    return kaiser_i0(arg) / kaiser_i0(beta);
}


// Kaiser beta from desired attenuation (dB)
float kaiser_beta_from_atten(float A)
{
    if (A <= 21.0) return 0.0;
    if (A < 50.0) return 0.5842 * pow(A - 21.0, 0.4) + 0.07886 * (A - 21.0);
    return 0.1102 * (A - 8.7);
}
