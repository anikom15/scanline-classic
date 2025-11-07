# scanline-advanced.slang — Performance Notes

Summary
- Full CRT geometry + bicubic resampling + scanline/mask. Most feature-rich and most expensive of the pack.

Hot Parameters
- MASK_TYPE, MASK_SCALE: Enables subpixel mask; costs 1 texture lookup per tap plus optional anisotropic samples.
- FOCUS: Changes Mitchell–Netravali coefficients; cost stable, but sharper focus can amplify aliasing (benefits from mask filtering).
- SCAN_TYPE, MAX_SCAN_RATE, LINE_DOUBLER: Adjust vertical stepping; interlace and line-doubler change sampling density.
- DEFLECTION_ANGLE, SCREEN_ANGLE_H/V, MAGNETIC_CORRECTION, TRAPEZOID_*, CORNER_*, S_CORRECTION_*: Geometry math; cost scales with derivatives and mask filtering in distorted regions.

Cost Drivers
- 4×4 bicubic kernel: 16 samples per pixel via `pixel()` helper. Relatively fixed cost.
- Subpixel mask filtering: `mask_anisotropic()` adds up to 4 extra samples in extreme distortion; otherwise 1 filtered mask sample.
- Derivatives (dFdx/dFdy) for mask anisotropy.

Tuning Strategy
- On 1080p or dim panels, set MASK_TYPE=1.0 (off). On 1440p/4K, keep MASK_SCALE≥1.5 and choose simpler masks (e.g., 24) to reduce aliasing.
- For speed, reduce curvature: set DEFLECTION_ANGLE ≤ 60°, SCREEN_ANGLE_* ≤ 20°, and zero out electronic corrections you don't need.
- Use FOCUS ~0.5 for balanced sharpness; extreme values don’t change cost but may require more mask filtering to hide ringing.
- Keep LINE_DOUBLER=0 unless emulating progressive PC content; it increases vertical sampling.

Quick Profiles
- Low: MASK_TYPE=1, DEFLECTION_ANGLE=0, SCREEN_ANGLE_*=0, MAGNETIC_CORRECTION=0, FOCUS=0.5
- Med: MASK_TYPE=24, MASK_SCALE=2.0, DEFLECTION_ANGLE=90, SCREEN_ANGLE_*=30/20, modest corrections
- High: MASK_TYPE per display, MASK_SCALE=1.0–2.0, full geometry, MAGNETIC_CORRECTION 0.3–0.6
- Ref: Same as High, tweak FOCUS per game, geometry tuned to test patterns
