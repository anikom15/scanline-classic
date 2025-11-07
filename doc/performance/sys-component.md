# sys-component.slang — Performance Notes

Summary
- Converts RGB to chosen YC model and applies per-component horizontal Gaussian bandlimits.

Hot Parameters
- SYS_BANDWIDTH_Y/U/V and SYS_CUTOFF_ATTEN_*: Control sigma size per component; larger → broader loop support.
- SYS_COMPONENT_FILTER_BYPASS: Skips Gaussian loop; only color conversion + gain/bias (large savings).
- YC_MODEL: Impacts conversion math only; similar cost across models.

Cost Drivers
- Symmetric Gaussian loop (max 32) with 2 texture reads per iteration (R/L) and per-sample RGB→YC conversion.

Tuning Strategy
- If performance-bound, enable SYS_COMPONENT_FILTER_BYPASS=1; leave bandlimit to downstream display stage.
- Keep chroma bandwidths low (≤1.5 MHz) and/or increase cutoff attenuation for smaller effective sigma.

Quick Profiles
- Low: FILTER_BYPASS=1
- Med: BW_U/V≈1.3, ATN_U/V≈3 dB
- High: BW_Y≈6.75, BW_U/V≈1.79
