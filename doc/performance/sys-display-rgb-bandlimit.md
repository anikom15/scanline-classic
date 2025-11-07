# sys-display-rgb-bandlimit.slang — Performance Notes

Summary
- Merges system and display RGB bandlimits in one pass via variance addition. Faster than two separate passes.

Hot Parameters
- SYS_* and DISPLAY_* bandwidth/attenuation: Combined into sigma_total; lower bandwidth → larger sigma → more samples. Keep ≥0.6 MHz per setting.
- SYS_DISPLAY_RGB_BANDLIMIT_BYPASS: Set to 1 to skip.

Cost Drivers
- Single horizontal Gaussian convolution with sigma_total; cost grows with combined sigma. Sigma inversely related to bandwidth.

Tuning Strategy
- Prefer this pass instead of chaining `sys-rgb-bandlimit` + `display-rgb-bandlimit`.
- Keep bandwidths reasonable (≥0.6 MHz) to avoid excessive sigma_total and loop cost.

Quick Profiles
- Low: BYPASS=1
- Med: SYS_* and DISPLAY_* at ~6.75 MHz / 3 dB
- High: Channel-specific
