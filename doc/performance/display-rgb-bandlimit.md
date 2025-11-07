# display-rgb-bandlimit.slang — Performance Notes

Summary
- Horizontal Gaussian bandlimit directly in RGB.

Hot Parameters
- DISPLAY_BANDWIDTH_R/G/B & DISPLAY_CUTOFF_ATTEN_*: Determine sigma per channel. Lower bandwidth → larger sigma → more samples. Keep ≥0.6 MHz for performance.
- DISPLAY_RGB_BANDLIMIT_BYPASS: Mixes in unfiltered source; set to 1.0 to disable cost.

Cost Drivers
- Single lobe-based Gaussian convolution (loop implemented in helper). Cost grows with sigma; sigma inversely related to bandwidth.

Tuning Strategy
- Prefer chroma-only limitation elsewhere; keep RGB display bandwidth reasonable (≥0.6 MHz per channel) if performance-critical.

Quick Profiles
- Low: BYPASS=1.0
- Med: Bandwidths ~6.75 MHz, 3 dB cutoff
- High: Tune per channel as needed
