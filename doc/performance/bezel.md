# bezel.slang — Performance Notes

Summary
- Adds bezel/background plus glow diffusion around a viewport.

Hot Parameters
- GLOW_DIFFUSION: Outer loop count (num_steps). Effective iterations = num_steps * 8 directions. Largest cost lever.
- GLOW_RADIUS: Spatial extent; larger radius increases sample divergence but loop count remains fixed.
- GLOW_JITTER: Adds randomness—minor extra ALU, no extra fetch count.
- GLOW_VERTICAL_BIAS / GLOW_FALLOFF: Pure math adjustments.

Cost Drivers
- Nested loops: for step in [1..GLOW_DIFFUSION] × 8 directions → 8*num_steps texture samples of PHOSPHOR.

Tuning Strategy
- For portable/iGPU: cap GLOW_DIFFUSION ≤ 2–3, reduce GLOW_RADIUS ≤ 0.04.
- Mid-range GPU: GLOW_DIFFUSION 3–4; high-end: 4–6; above 6 diminishing returns.
- Disable glow entirely by setting GLOW_WEIGHT=0 or BEZEL_BYPASS=1 for performance capture.

Quick Profiles
- Low: GLOW_DIFFUSION=2, GLOW_RADIUS=0.03, GLOW_WEIGHT=0.7
- Med: GLOW_DIFFUSION=3, GLOW_RADIUS=0.05
- High: GLOW_DIFFUSION=4–5, GLOW_RADIUS=0.06
- Ref: GLOW_DIFFUSION=6+, careful tuning of falloff & temperature
