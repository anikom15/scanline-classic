# rf-ntsc.slang — Performance Notes

Summary
- NTSC composite with RF carrier modulation/demod plus notch/comb filtering; heavier than pure composite due to RF mixing stage.

Hot Parameters
- FILTER_SIZE_YC: Loop bound; wider = more iterations.
- FILTER_ENCODE: Prefilter adds texture reads.
- COMB_FILTER_TAPS: Additional vertical samples per iteration.
- ENCODE/SIGNAL_BANDWIDTH_*: Lower bandwidth → larger sigma → more Gaussian coverage. Keep ≥0.6 MHz.

Cost Drivers
- RF modulation math (single extra sincos + multiply sequence per iteration).
- Symmetric Gaussian loop (bounded by FILTER_SIZE_YC); each side iteration includes comb taps + carrier trig.

Tuning Strategy
- Reduce FILTER_SIZE_YC first for large savings (e.g. 14 → 10 → 8).
- Disable FILTER_ENCODE unless testing encode chain fidelity.
- Use COMB_FILTER_TAPS=1 for performance; 2–3 only for difficult color-artifact material.

Quick Profiles
- Low: FILTER_SIZE_YC=8–10, FILTER_ENCODE=0, COMB_FILTER_TAPS=1
- Med: FILTER_SIZE_YC=12–14, COMB_FILTER_TAPS=2
- High: FILTER_SIZE_YC=16, FILTER_ENCODE=1, COMB_FILTER_TAPS=3
- Ref: FILTER_SIZE_YC=20+, tuned bandwidths
