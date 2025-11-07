# svideo.slang — Performance Notes

Summary
- S-Video (Y/C) demodulation with Gaussian low-pass for luma/chroma.

Hot Parameters
- DISPLAY_BANDWIDTH_Y/C and DISPLAY_CUTOFF_ATTEN_*: Drive Gaussian sigma; lower bandwidth → larger sigma → more loop iterations before early exit. Keep ≥0.6 MHz.
- SVIDEO_FILTER_BYPASS: If 1, uses center-sample demod only (huge performance win, less smooth).
- SC_FREQ_MODE/SC_FREQ/H_BLANK_*: Timebase math only; cost stable.
- BW_MODE: Monochrome modes can skip chroma work depending on path (see shader logic).

Cost Drivers
- Symmetric horizontal Gaussian loop (max 32). Per iteration: 2 extra texture reads (R/L) + per-sample carrier sincos + chroma math.

Tuning Strategy
- For speed, enable SVIDEO_FILTER_BYPASS=1 for gameplay; disable for captures.
- Don't reduce bandwidth too far (keep ≥0.6 MHz); excessively low bandwidth increases sigma and loop cost. Default values (~1.3–1.79 MHz for C, ~5–6 MHz for Y) are reasonable.
- If still heavy, try slightly increasing DISPLAY_CUTOFF_ATTEN_* (e.g., 3→6 dB) to tighten the filter kernel without changing bandwidth.

Quick Profiles
- Low: SVIDEO_FILTER_BYPASS=1, DISPLAY_BANDWIDTH_C=1.3, DISPLAY_BANDWIDTH_Y=5.0
- Med: SVIDEO_FILTER_BYPASS=0, DISPLAY_BANDWIDTH_C=1.5–1.79
- High: Full defaults; tune USER_* controls for aesthetic preferences
