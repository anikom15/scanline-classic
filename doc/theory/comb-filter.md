# Comb Filter Technology Theory

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

Comb filtering is a class of luminance/chrominance (Y/C) separation methods used in composite video receivers. Unlike simple notch and band-pass approaches, comb filters exploit periodic subcarrier phase relationships between adjacent lines (and, in advanced forms, adjacent fields/frames) to improve Y/C separation while preserving high-frequency luma detail.

This document summarizes the historical evolution of comb filtering, the underlying signal principles, common artifact tradeoffs, and how these ideas map to the Scanline Classic shader pipeline.

## Historical Evolution

### Early Analog Era (Pre-1980)

Most consumer receivers used a notch filter in the luma path and a band-pass filter in the chroma path. This architecture was inexpensive and robust but produced visible dot crawl, cross-color, and cross-luminance on high-detail scenes.

### Line-Comb Adoption (1980s)

Higher-end televisions introduced 1H delay-line comb filters. In NTSC, the chroma subcarrier phase inverts on adjacent lines, allowing line addition/subtraction to separate Y and C more effectively than notch-only decoding. PAL implementations exploited line relationships differently due to phase alternation and delay-line averaging behavior.

### Digital and Adaptive Decoders (1990s)

Digital memory and DSP enabled adaptive comb filtering. Receivers could classify image regions (static detail, motion, vertical edges) and switch between comb, notch, or blended modes to reduce motion artifacts while retaining sharpness.

### Multi-Frame/3D Comb Processing (Late 1990s–2000s)

Frame-memory decoders introduced 2D/3D spatio-temporal strategies that analyze line and frame correlation simultaneously. These systems substantially reduced classic composite artifacts on stationary content and improved separation for consumer and broadcast-grade equipment.

## Signal-Theory Basis

For a line-comb decoder, adjacent-line operations can be idealized as:

$$
Y \approx \frac{L_n + L_{n-1}}{2}, \qquad
C \approx \frac{L_n - L_{n-1}}{2}
$$

where $L_n$ is the current composite line and $L_{n-1}$ is a delayed line. Under ideal line-to-line chroma phase relationships, luma terms reinforce in the sum while chroma terms reinforce in the difference.

Real signals deviate from the ideal due to motion, vertical color transitions, finite filter bandwidth, and transmission impairments. Practical comb filters therefore use mode switching and weighting rather than fixed subtraction alone.

## Decoder Families and Tradeoffs

### Notch + Band-Pass

- Lowest implementation complexity
- Robust under motion
- Highest residual cross-color/cross-luma and reduced luma sharpness near subcarrier

### Line Comb (1H/2H)

- Better Y/C separation on static content
- Better luma detail retention than notch-only paths
- Susceptible to motion artifacts and vertical transition errors

### Motion-Adaptive / 2D / 3D Comb

- Best overall artifact suppression in mixed-content scenes
- Requires frame memory, classification logic, and higher computational complexity
- Can still fail on rapid motion, noisy sources, or non-standard phase behavior

## Artifacts and Practical Limits

Even advanced comb systems exhibit characteristic limits:

- **Dot crawl**: residual subcarrier leakage into luma near vertical color edges
- **Cross-color**: fine luma detail decoded as false chroma
- **Cross-luminance**: chroma energy decoded as luma texture
- **Motion mismatch**: temporal/line correlation failure in moving regions
- **Vertical chroma compromise**: delay-line and averaging strategies can soften vertical color detail

These tradeoffs explain why many decoders use hybrid pipelines instead of a single fixed filter mode.

## Scanline Classic Implementation Mapping

### Notch/Bandpass Model

`shaders/composite-prefilter.slang` and shared support code in `shaders/bandlimit.inc` and `shaders/modulation.inc` implement a configurable analytical notch/bandpass stage. Modulated Gaussian kernels provide smooth attenuation around the color subcarrier while keeping user control over width and attenuation targets.

### Comb Model

`shaders/composite-prefilter.slang` also implements line-based comb behavior by sampling adjacent-line information, applying phase-aware correction, and combining taps according to selected decode mode (`COLOR_FILTER_MODE`). This mirrors physical delay-line concepts while retaining deterministic digital control over weights and phase handling.

### Decoder Integration

Comb and notch outputs are used as complementary tools in the broader composite decode path (`composite-prefilter.slang` -> `composite-demod.slang`), allowing users to tune between authenticity, artifact profile, and sharpness.

## Design Perspective

In historical receivers, comb quality was bounded by analog delay precision, IF shaping, and cost constraints. In shader space, those physical constraints are replaced by explicit numerical control, making it possible to preserve the characteristic artifact families of composite video while exposing the quality/performance tradeoff as user parameters.

## References

- ITU-R Recommendation BT.470-6: Conventional Analog Television Systems
- SMPTE 170M: Composite Analog Video Signal — NTSC for Studio Applications
- Poynton, Charles. *Digital Video and HD: Algorithms and Interfaces*. Morgan Kaufmann, 2012.
- Whitaker, Jerry C. *The Standard Handbook of Video and Television Engineering*. McGraw-Hill.
- Jack, Keith. *Video Demystified*. Newnes.
- Tektronix application notes on NTSC/PAL composite decoding and comb-filter behavior