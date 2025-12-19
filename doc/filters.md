# Filter Loop Optimization and Design

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

The scanline-classic shader suite uses optimized filter loops with early-exit logic to balance performance and compile time while meeting strict frequency response constraints. All filters use symmetric tap pairs (left + right per iteration) for bandwidth efficiency.

## Filter Specifications

| Constraint | Requirement |
|-----------|-------------|
| Composite, Luminance, RF-IQ filtering on RGB inputs | 3 MHz minimum, cutoff attenuation 2 dB |
| Chrominance, U/V, Notch filters, bandpass filters | 0.6 MHz minimum with cutoff attenuation 2 dB |

## Loop Caps by Filter Type

| Shader | Loop Cap | Taps/Iteration | Effective Radius | Signal Type | Notes |
|--------|----------|---|---|---|---|
| `bandlimit.inc` | 16 | 2 (n=1..16) | 32 total taps | RGB bandlimit (3 MHz) | Generic helper for display RGB; tight Gaussian tails (~7 px radius at 1440 px) |
| `composite-prefilter.slang` | 24 | 2 (n=1..24) | 48 total taps | Composite pre-demod filter (3 MHz) | Notch + bandpass for Y/C separation; 2× safety margin |
| `composite-demod.slang` | 20 | 2 (n=1..20) | 40 total taps | Composite demodulation | Dual-path: Y at 3 MHz (early exit ~8 iter), C at 0.6 MHz (full 20 iter) |
| `sys-component.slang` | 24 | 2 (n=1..24) | 48 total taps | System RGB → Y/C component filter | Per-component Gaussian: Y at 3 MHz, U/V at 0.6 MHz; 24 covers worst-case |
| `composite-iq.slang` | 31 (odd) | 2 (n=1,3,5..31) | 31 taps (Type III FIR) | Hilbert transform (broadband) | **Broadband, not bandwidth-limited**; fixed Type III odd-length FIR with early exit |
| `iq-filter.slang` | 64 | 2 (n=1..64) | 128 total taps | IQ sinc lowpass (0.6 MHz worst-case) | Asymmetric I/Q: I channel 4.2 MHz, Q channel 0.75 MHz; sinc 1/n decay requires deep tail |
| `iq-demod.slang` | 64 | 2 (n=1..64) | 128 total taps | IQ demodulation (0.6 MHz worst-case) | Matched to iq-filter.slang; sinc-based product demod; deep tail for precision |

## Design Rationale

### Gaussian Filters (3–24 loops)

For Gaussian bandlimit filters, the loop cap is determined by the worst-case cutoff frequency:

- **3 MHz signals** (luma, RF-IQ): Gaussian σ ≈ 7 px at 1440 px width
  - Significant taps extend to ~3σ ≈ 21 px = ~10–11 pairs → 16 lobes sufficient
  - Loop cap: **16–24** (16 for display-RGB, 20–24 for composite/component)

- **0.6 MHz signals** (chroma, U/V): Gaussian σ ≈ 14 px at 1440 px width
  - Significant taps extend to ~3σ ≈ 42 px = ~21 pairs → 24 lobes covers generously
  - Loop cap: **20–24** (composite-demod uses 20 with per-component sigmas; sys-component uses 24)

**Why symmetric pairs:** Each loop iteration fetches left+right samples and applies weights. This halves the loop count vs. single-tap convolution while maintaining the same tap span.

### Sinc Filters (64 loops)

For windowed-sinc lowpass (used in IQ modulation/demodulation):

- Sinc decays as $\sim 1/n$, much slower than Gaussian
- 0.6 MHz cutoff at ~14 px radius, but sinc tail extends significantly
- 64 iterations = 128 total taps, ensuring:
  - ~40 dB stopband rejection (Hamming window)
  - Negligible Q-channel leakage into I path (VSB recovery)
  - Early exit via `FILTER_THRESHOLD = 1/255` saves iterations in practice

### Hilbert Transform (31 taps)

- **Not bandwidth-limited** (broadband for full I/Q analytic signal extraction)
- Fixed odd-length Type III FIR (31 taps) with Hann windowing
- Early exit when tap magnitude < `FILTER_THRESHOLD` (typically ~20–25 iterations)
- Single pass; no per-channel differentiation

## Early-Exit Logic

All loops implement early termination when filter weights fall below `FILTER_THRESHOLD = 1.0 / 255.0` (~3.92e-3), chosen as one 8-bit LSB:

- Numerically insignificant for 8-bit video sources
- Prevents compiling excessive dead code
- Typical savings: 20–40% fewer iterations depending on sigma/bandwidth

## Performance Impact at 1440 px Width (Worst Case)

With the `sfc-rf_sfc-jr-rf.slangp` preset at 1440 px output width:

- **Composite path:** 20 iterations × 2 taps = 40 taps per Y/C channel
- **IQ path:** up to 64 iterations × 2 taps = 128 taps per I/Q channel
- **Early exit saves:** ~5–15 iterations typical (depending on sigma/content)

Total render passes: 19 shaders (per preset). Loop optimization targets high-frequency passes: `composite-demod`, `composite-prefilter`, `sys-component`, `iq-filter`, `iq-demod`.

## Constants

All thresholds are unified in `common.inc`:

```glsl
const float FILTER_THRESHOLD = 1.0 / 255.0;  // 8-bit LSB threshold for early loop exit
```

This single constant is used across all filter passes, simplifying maintenance and ensuring consistent numerical behavior.
