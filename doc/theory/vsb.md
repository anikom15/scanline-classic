# VSB (Vestigial Sideband) Modulation Theory

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

Vestigial Sideband (VSB) modulation is the transmission method used by analog television systems to fit high-quality video into limited RF channel bandwidth. Instead of transmitting both AM sidebands in full, the upper sideband is preserved while the lower sideband is partially suppressed. This asymmetry substantially reduces occupied spectrum while retaining demodulation compatibility with envelope/synchronous receiver architectures.

In Scanline Classic, VSB behavior is modeled explicitly in the analytic I/Q path used by the composite encoder/decoder stages, allowing control over vestige ratio, reconstruction strategy, and associated artifact tradeoffs.

## Historical and System Context

### Why VSB Was Adopted

Conventional double-sideband AM would require roughly twice the baseband video bandwidth, which is incompatible with practical terrestrial TV channel allocations. For example, NTSC broadcast channels allocate 6 MHz total for picture and sound carriers. VSB addresses this by:

1. Preserving most luminance detail in the full upper sideband
2. Retaining a controlled lower vestige for stable demodulation behavior near carrier
3. Leaving spectrum headroom for audio carriers and channel guard requirements

### Relation to NTSC, PAL, and SECAM

- NTSC and PAL both use VSB for RF video transmission.
- SECAM also uses VSB for the luminance component, even though chroma itself is FM-based.
- Exact vestige width and IF shaping differ by regional system and receiver design.

## VSB Asymmetry Parameter

Define the vestigial ratio as:

$$
K_{\mathrm{VSB}} = \frac{B_{\mathrm{vestige}}}{B_{\mathrm{full}}}
$$

where $B_{\mathrm{vestige}}$ is the lower-sideband vestige width and $B_{\mathrm{full}}$ is the full upper-sideband video bandwidth.

In the weighted reconstruction method used by the shader, the demodulation coefficient $\alpha$ is negative and typically near $-K_{\mathrm{VSB}}$:

$$
s_{\mathrm{rec}} = I + \alpha Q, \quad \alpha < 0
$$

The negative sign follows from Hilbert-phase quadrature conventions and the spectral asymmetry introduced by VSB filtering.

## Broadcast Specification Ranges

### NTSC (525/59.94)

- Full upper sideband: +4.2 MHz
- Vestigial lower sideband: -0.75 MHz
- Nominal ratio: $K_{\mathrm{VSB}} = 0.75 / 4.2 \approx 0.179$
- Practical reconstruction weight: $\alpha \approx -0.18$ to $-0.27$

### PAL (625/50 families)

- Full upper sideband: typically +5.0 MHz
- Vestige: -0.75 MHz (common) or -1.25 MHz (extended IF shaping)
- Ratios:
   - $0.75/5.0 = 0.15$
   - $1.25/5.0 = 0.25$
- Practical reconstruction weight: $\alpha \approx -0.15$ to $-0.32$

### SECAM (625/50 families)

- Luminance sideband planning remains VSB-like
- Typical upper sideband: +5.0 to +5.5 MHz
- Typical vestige: -1.0 to -1.25 MHz
- Typical ratio range: $K_{\mathrm{VSB}} \approx 0.18$ to $0.23$

## Summary Table

| Standard      | Lines | Full Sideband | Vestige | K_VSB (ratio) | α (typical demod weight) |
|---------------|-------|---------------|---------|---------------|---------------------------|
| **NTSC**      | 525   | 4.2 MHz       | 0.75 MHz| 0.179         | -0.18 to -0.27            |
| **PAL**       | 625   | 5.0 MHz       | 0.75 MHz| 0.150         | -0.15 to -0.20            |
| **PAL** (ext) | 625   | 5.0 MHz       | 1.25 MHz| 0.250         | -0.25 to -0.32            |
| **SECAM**     | 625   | 5.5 MHz       | 1.0 MHz | 0.182         | -0.18 to -0.24            |

## Mathematical Interpretation

Let the reconstructed baseband spectrum be decomposed into upper and lower contributions around carrier:

$$
S(f) = S_{+}(f>0) + S_{-}(f<0)
$$

After analytic conversion and asymmetric filtering:

- $I$ tracks the in-phase full-band component
- $Q$ tracks quadrature content tied to vestigial asymmetry

The weighted method uses:

$$
S_{\mathrm{rec}} \approx I + \alpha Q
$$

with $\alpha < 0$ so vestigial contribution is restored constructively instead of cancelled.

## Implementation in Scanline Classic

### Signal Path Stages

The VSB path is implemented through the following shader chain:

1. `composite-iq.slang`: forms analytic I/Q from composite-domain source signal
2. `iq-filter.slang`: applies asymmetric low-pass shaping (full-band I, vestigial Q)
3. `iq-noise.slang`: optional RF impairments (noise, ghosts, impulse disturbance, phase jitter)
4. `iq-demod.slang`: reconstructs baseband using either Hilbert inversion or weighted blend

### Demodulation Modes

`iq-demod.slang` supports two reconstruction strategies:

- **Hilbert inversion**
   $$
   s = I_{\mathrm{lp}} - \mathcal{H}\{Q_{\mathrm{lp}}\}
   $$
- **Weighted combination**
   $$
   s = I_{\mathrm{lp}} + \alpha Q_{\mathrm{lp}}
   $$

The weighted path is computationally cheaper and useful for real-time tuning, while the Hilbert-based path better reflects strict analytic inversion behavior.

## Practical Implications for Preset Design

- Lower $|\alpha|$ (or smaller vestige ratio) generally yields cleaner luma but can under-reconstruct vestigial detail.
- Higher $|\alpha|$ restores more low-frequency vestigial energy but can increase color/luma contamination if mismatched.
- VSB settings interact strongly with composite decoding mode, chroma bandwidth, and noise stages, so they should be tuned as part of the full encode/decode chain rather than in isolation.

## References

- ITU-R Recommendation BT.470-6: Conventional Analog Television Systems
- ITU-R Recommendation BT.1700: Characteristics of Composite Video Signals for Conventional Television Systems
- SMPTE 170M: Composite Analog Video Signal — NTSC for Studio Applications
- EBU Technical documentation on PAL/SECAM analog television transmission and baseband/video limits
- Benson, K. Blair, and Jerry Whitaker. *Television Engineering Handbook*. McGraw-Hill, 1992.
