# composite-demod.slang — Performance Notes

Summary
- Demodulates composite where input R=Y and G=C, reconstructing baseband Y and quadrature C with Gaussian smoothing; optional feedback filter.

Hot Parameters
- FEEDBACK_FILTER_MODE: If enabled, extra remod step per sample; moderate ALU overhead.
- DISPLAY_BANDWIDTH_Y/C & DISPLAY_CUTOFF_ATTEN_*: Control Gaussian sigma (loop extent). Lower bandwidth → larger sigma → more samples. Keep ≥0.6 MHz.
- SC_FREQ_MODE/SC_FREQ/H_BLANK_*: Timebase only; fixed cost.
- BW_MODE: Monochrome shortcuts in output mapping.

Cost Drivers
- Symmetric Gaussian loop (max 32) + per-sample sincos and chroma math; two texture reads per iteration (R/L).

Tuning Strategy
- Disable FEEDBACK_FILTER_MODE for speed if quality allows.
- Don't reduce bandwidth too far (keep ≥0.6 MHz); excessively low bandwidth increases sigma and sample count. Default values are reasonable.

Quick Profiles
- Low: FEEDBACK_FILTER_MODE=0, DISPLAY_BANDWIDTH_C≈1.3, Y≈5.5
- Med: Defaults
- High: Increase bandwidths carefully for capture quality
