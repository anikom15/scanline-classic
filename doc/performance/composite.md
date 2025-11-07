# composite.slang — Performance Notes

Summary
- Simulates full NTSC/PAL composite encode + demod + filtering with selectable color separation (notch, comb, hybrid, feedback).

Hot Parameters
- COLOR_FILTER_MODE: Switches algorithm; comb (1) and hybrid (2) add extra texture fetches; feedback (3) adds carrier remod math.
- COMB_FILTER_TAPS: 1–3 adjusts vertical reference lines used; higher taps increase per-pixel fetches (each tap requires multiple additional samples).
- DISPLAY_BANDWIDTH_Y/C & DISPLAY_CUTOFF_ATTEN_*: Affect Gaussian sigma—lower bandwidth → larger sigma → more iterations before early exit. Keep ≥0.6 MHz.
- NOTCH_OFFSET_L/R: Alters notch sigma; extreme values can widen effective filter radius.

Cost Drivers
- Horizontal Gaussian loop (≤32 symmetrical iterations with early exit).
- Comb filter texture fetches per tap and per side (R/L samples); cost grows with COMB_FILTER_TAPS.
- Carrier phase and sincos per sample (optimized but constant overhead).

Tuning Strategy
- If compile or runtime cost is high, first lower COMB_FILTER_TAPS to 1, then switch COLOR_FILTER_MODE to 0 (notch only) or 4 (raw) for max savings.
- Avoid setting DISPLAY_BANDWIDTH_C too low (keep ≥0.6 MHz); excessively low bandwidth increases sigma and loop cost. Default ~1.3–1.79 MHz is reasonable for retro sources.
- Use BW_MODE to skip chroma calculations when emulating monochrome displays.

Quick Profiles
- Low: COLOR_FILTER_MODE=0, COMB_FILTER_TAPS=1, DISPLAY_BANDWIDTH_C=1.3
- Med: COLOR_FILTER_MODE=2, COMB_FILTER_TAPS=2, DISPLAY_BANDWIDTH_C=1.79
- High: COLOR_FILTER_MODE=1 or 2, COMB_FILTER_TAPS=3
- Ref: COLOR_FILTER_MODE=3 (feedback), COMB_FILTER_TAPS=3, precise notch offsets
