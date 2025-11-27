/* Filename: window.inc

   Shared windowed-sinc utilities for IQ modulation/demodulation.
   Contains Blackman-Harris 4-term window and windowed-sinc coefficient helpers.
*/

// Blackman-Harris 4-term window
// Stopband: ~92 dB, mainlobe width = 8π/N
// Superior phase linearity and stopband rejection compared to Kaiser
float blackman_harris_4term(float n, float N)
{
    const float a0 = 0.35875;
    const float a1 = 0.48829;
    const float a2 = 0.14128;
    const float a3 = 0.01168;
    
    float x = 2.0 * PI * (n + 0.5 * N) / N;  // Center window at n=0
    return a0 - a1 * cos(x) + a2 * cos(2.0 * x) - a3 * cos(3.0 * x);
}

// Windowed-sinc lowpass coefficient (normalized cutoff fc in cycles/sample)
// Uses Blackman-Harris 4-term window for ~92 dB stopband rejection
float sinc_lowpass_bh4(float n, float fc_norm, float N)
{
    float sinc;
    if (abs(n) < EPS) {
        sinc = 2.0 * fc_norm;  // integral of ideal LP at n=0
    } else {
        float x = 2.0 * PI * fc_norm * n;
        sinc = sin(x) / (PI * n);
    }
    float w = blackman_harris_4term(n, N);
    return sinc * w;
}

// Windowed-sinc bandpass coefficient using difference of two lowpass sincs
// Uses Blackman-Harris 4-term window for ~92 dB stopband rejection
float sinc_bandpass_bh4(float n, float fc_upper, float fc_lower, float N)
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
    float window = blackman_harris_4term(n, N);
    return bandpass_sinc * window;
}
