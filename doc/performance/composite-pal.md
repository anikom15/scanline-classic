# composite-pal.slang — Performance Notes

Summary
- PAL-specific composite encode/demod with delay-line chroma and Gaussian filtering.

Hot Parameters
- FILTER_SIZE_YC: Loop radius for Gaussian accumulation; directly controls iteration bound. Higher increases compile/runtime cost.
- ENCODE_FILTER_BANDWIDTH_* and SIGNAL_BANDWIDTH_* with *_CUTOFF_ATTEN_*: Influence sigma; lower bandwidth → larger sigma → more effective taps. Keep ≥0.6 MHz.
- COMB_FILTER_TAPS: 1–3; affects delay-line fetches per loop iteration.
- FILTER_ENCODE: If 1, applies prefiltering (extra texture reads inside loop and optional delay line).

Cost Drivers
- Outer loop from -FILTER_SIZE_YC..+FILTER_SIZE_YC (bounded by parameter). Each iteration may read Source up to 1 + comb taps.
- Carrier math per iteration; optimized but non-trivial.

Tuning Strategy
- Keep FILTER_SIZE_YC ≤ 14 (default) for speed. For handhelds, 8–10 still looks good.
- Prefer COMB_FILTER_TAPS=1 unless edge color separation is critical.
- Disable FILTER_ENCODE when seeking performance; rely on decode-side filtering only.

Quick Profiles
- Low: FILTER_SIZE_YC=8–10, COMB_FILTER_TAPS=1, FILTER_ENCODE=0
- Med: FILTER_SIZE_YC=12–14, COMB_FILTER_TAPS=2
- High: FILTER_SIZE_YC=16–20, COMB_FILTER_TAPS=3
- Ref: FILTER_SIZE_YC=24–32 with careful notch offsets
