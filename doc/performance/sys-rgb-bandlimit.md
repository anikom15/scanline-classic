# sys-rgb-bandlimit.slang — Performance Notes

Summary
- System (source) RGB horizontal Gaussian bandlimit.

Hot Parameters
- SYS_BANDWIDTH_R/G/B and SYS_CUTOFF_ATTEN_*: Influence sigma. Lower bandwidth → larger sigma → more samples. Keep ≥0.6 MHz.
- SYS_RGB_BANDLIMIT_BYPASS: Bypass convolution; returns source with gain/bias mix.

Cost Drivers
- Single horizontal Gaussian convolution (helper). Cost scales with sigma; sigma inversely related to bandwidth.

Tuning Strategy
- If chaining with display bandlimit, consider replacing both with `sys-display-rgb-bandlimit` for one-pass variance addition.

Quick Profiles
- Low: BYPASS=1
- Med: 6.75 MHz, 3 dB
- High: Channel-specific tuning
