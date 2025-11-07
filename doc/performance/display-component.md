# display-component.slang — Performance Notes

Summary
- Decodes luma/chroma (YIQ / YPbPr / YUV / YDbDr / YCbCr) back to RGB with optional Gaussian horizontal filtering.

Hot Parameters
- DISPLAY_BANDWIDTH_Y/U/V & DISPLAY_CUTOFF_ATTEN_*: Determine sigma; lower bandwidth → larger sigma → more loop iterations before early exit. Keep ≥0.6 MHz.
- DISPLAY_COMPONENT_FILTER_BYPASS: Skips filtering; performs single decode only.

Cost Drivers
- Symmetric Gaussian loop (max 32) with per-sample decode math (matrix multiply) per side sample.

Tuning Strategy
- For speed, enable DISPLAY_COMPONENT_FILTER_BYPASS=1 unless you need analog blur effect.
- Don't reduce U/V bandwidth too far (keep ≥0.6 MHz); excessively low bandwidth increases sigma and loop cost. Defaults (~1.3 MHz for U/V) are reasonable.

Quick Profiles
- Low: FILTER_BYPASS=1
- Med: BW_U/V≈1.3, ATN_U/V≈3 dB
- High: BW_Y≈6.75, BW_U/V≈1.79
