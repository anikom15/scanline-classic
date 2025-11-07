# Performance Overview

This folder documents performance characteristics and tuning guidance for each shader in the Scanline Classic pack. It supplements [`doc/performance/COMPILE_TIME.md`](COMPILE_TIME.md) (which focuses on global compilation bottlenecks) with per-shader parameter impact, quality trade‑offs, and recommended presets for different GPUs.

## Reading this guide
For each shader you'll find:
- Summary: What the shader does and typical use cases.
- Hot Parameters: Parameters that most affect GPU shader compilation time or runtime cost.
- Cost Drivers: Loops, texture samples, derivatives, branching.
- Tuning Strategy: How to lower cost while preserving visual fidelity.
- Quick Profiles: Suggested parameter sets for Low / Medium / High / Reference quality.
- When to Bypass: Situations where disabling a pass has minimal impact.

If you just want a fast baseline on an integrated GPU or handheld device:
1. Prefer presets using `scanline-basic.slang`.
2. Avoid shadow masks unless output vertical resolution >= 1440 and display brightness is high.
3. Keep Gaussian loop radii / tap counts low (defaults are chosen to converge quickly).
4. Disable geometry corrections you do not actively use (set strengths to 0.0).

## General global cost notes
- Horizontal Gaussian loops are capped to 32 symmetric iterations with early exit once weights < 1/510. Increasing radii beyond default rarely improves quality on typical content.
- Anisotropic mask filtering in `scanline-advanced.slang` is capped at 4 samples; increasing this scales compile time and per-pixel cost.
- Comb/notch/feedback filters introduce extra texture fetches per tap; lowering tap counts or switching filter mode reduces cost.
- Multiple passes (e.g. phosphor luma + chroma + bandlimit) multiply total work. In resource‑constrained environments, bypass non-critical passes first.

## Quality tiers (guideline)
| Tier | Target Hardware | Notes |
|------|-----------------|-------|
| Low  | iGPU, handheld (Steam Deck / Switch) | Use Basic, minimal geometry, mask off, reduced bandwidth/chroma loops |
| Med  | Mid-range GPU (GTX 1060 / RX 580) | Moderate geometry, mask optional at 1080p+, retain comb filters if desired |
| High | Modern GPU (RTX 3060+, RDNA2+) | Full advanced shader, mask on at 1440p+, full signal simulation |
| Ref  | Offline capture / screenshots | Max quality parameters; accept longer compile times |

Proceed to individual files for details.
