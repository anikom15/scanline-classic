# phosphor-luma.slang — Performance Notes

Summary
- Calculates luminance or RGB with phosphor persistence by blending with a feedback texture using a 3-exponent decay model.

Hot Parameters
- PHOSPHOR_LUMA_BYPASS: Full bypass (fastest).
- PHOSPHORESCENSE_[A/B/C], PHOS_EXP_[A/B/C], PHOS_TRAP_[A/B/C]: Control decay curve; do not change per-pixel texture fetch count.
- V_FREQ: Affects decay math scale; negligible impact on cost.

Cost Drivers
- One Source sample + one feedback texture sample per pixel; ALU-heavy decay function.

Tuning Strategy
- If GPU-limited, reduce feedback resolution (preset dependent) or bypass this pass for gameplay.
- Use modest decay rates to avoid needing very high precision.

Quick Profiles
- Low: BYPASS=1.0
- Med: Single decay channel (monochrome COLOR_MODE < 2)
- High: Full RGB persistence (COLOR_MODE=3)
