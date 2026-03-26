# Theory Documentation

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

This folder contains in-depth technical documentation on the television and display technologies simulated by Scanline Classic. These documents are written in a professional, academic tone and provide the theoretical foundation for understanding shader parameters and their real-world counterparts.

## Contents

### [crt.md](crt.md) — CRT Display Theory
Comprehensive coverage of cathode ray tube display technology:
- Electron gun operation and beam formation
- Deflection systems (electrostatic vs electromagnetic)
- Phosphor characteristics and persistence
- Shadow masks and aperture grilles (Trinitron)
- Geometric distortion (pincushion, barrel, curvature)
- Scanning process (interlaced, progressive, blanking)
- Beam focus and resolution limits
- Color reproduction and gamma
- Monochrome CRT variants

**Key topics**: Deflection angles, spot size, phosphor decay, mask patterns, underscan/overscan, transfer functions

### [ntsc.md](ntsc.md) — NTSC Composite Video Theory
Detailed analysis of the National Television System Committee color encoding standard:
- Historical context and design constraints
- YIQ colorspace and quadrature amplitude modulation
- Subcarrier frequency selection (3.579545 MHz) and interleaving
- Bandwidth allocation and Y/C spectrum overlap
- Color burst synchronization
- Demodulation methods (notch, comb, adaptive)
- Artifacts: dot crawl, cross-color, cross-luminance, rainbow effects
- S-Video (Y/C) advantages
- RF modulation degradation
- NTSC variants (NTSC-M, NTSC-J, NTSC 4.43)

**Key topics**: Composite encoding, I/Q modulation, comb filtering, phase errors, chrominance bandwidth

### [pal.md](pal.md) — PAL Composite Video Theory
In-depth examination of the Phase Alternating Line standard:
- PAL's phase alternation mechanism and error correction
- YUV colorspace encoding
- Subcarrier frequency (4.43361875 MHz) and 4-line pattern
- Delay-line demodulation for hue stability
- PAL variants (PAL-B/G/I/D/K/M/N) by region
- Artifacts: Hannover bars, dot crawl, cross-color
- Comparison with NTSC (advantages and trade-offs)
- PAL-M and PAL-N special cases
- S-Video in PAL systems

**Key topics**: V-switch phase alternation, delay-line averaging, swinging burst, vertical chroma resolution, hue stability

### [3do.md](3do.md) — 3DO Video and Interpolation Theory
Theory and implementation rationale for 3DO-specific interpolation behavior in Scanline Classic:
- Historical context for low-resolution 3DO content and display-path reconstruction
- Analysis of `3do-interpolation.slang` modes (nearest, bilinear, special)
- Corner-quadrant interpolation model (encoded vs luminance-predicted corner weights)
- Distance-weighted directional blending (horizontal, vertical, diagonal)
- Tradeoffs between blockiness reduction and edge-preserving behavior
- Integration role of `sys/3do-special*.json` before downstream analog simulation

**Key topics**: Directional interpolation, corner weights, subpixel reconstruction, heuristic edge preservation, 3DO preset integration

### [famicom.md](famicom.md) — Famicom/NES Video Synthesis Theory
Technical background for Famicom-specific shader paths that reconstruct composite waveform behavior and RGB monitor output:
- `famicom-special.slang` packed palette/level/emphasis decode into voltage waveform output
- IRE-level lookup model and phase-driven 12-step gating behavior
- Emphasis-bit phase gating and PAL toggle behavior for regional timing variants
- `famicom-rgb.slang` RP2C03/2C03-style palette decode path
- Pipeline mapping for RF/composite (`famicom-special`) vs RGB (`famicom-rgb`) presets

**Key topics**: NES/Famicom color synthesis, waveform-domain modeling, emphasis behavior, 2C03 palette decode, composite vs RGB paths

### [vsb.md](vsb.md) — Vestigial Sideband (VSB) Modulation Theory
Technical treatment of Vestigial Sideband modulation in analog television systems, including historical context, broadcast constraints, and shader implementation:
- Why VSB was adopted for bandwidth-limited analog broadcast channels
- K_VSB parameter as the vestigial-to-full sideband bandwidth ratio
- Broadcast specification ranges across NTSC, PAL, and SECAM luminance paths
- Mathematical interpretation of negative α in weighted reconstruction
- Scanline Classic signal path: `composite-iq` → `iq-filter` → `iq-noise` → `iq-demod`
- Practical preset-design implications and tradeoffs

**Key topics**: Vestigial sideband modulation, analog broadcast constraints, K_VSB ratio, bandwidth asymmetry, I/Q reconstruction, Hilbert inversion, weighted demodulation

### [comb-filter.md](comb-filter.md) — Comb Filter Technology
Theory and evolution of comb-filter Y/C separation, from notch-era analog receivers to adaptive spatio-temporal decoders and shader-domain implementations:
- Historical progression: notch/bandpass, line comb, adaptive digital, and 3D comb methods
- Signal-theory basis of line-comb sum/difference separation
- Decoder-family tradeoffs: notch, 1H/2H line comb, motion-adaptive and multi-frame approaches
- Artifact analysis: dot crawl, cross-color, cross-luminance, and motion mismatch
- Scanline Classic mapping of notch/comb behavior in `composite-prefilter` and `composite-demod`
- Design perspective on physical decoder limits versus explicit numerical shader control

**Key topics**: Composite Y/C separation, line comb theory, motion-adaptive decoding, 2D/3D comb filtering, artifact tradeoffs, composite decoder design, shader mapping

### [gaussian.md](gaussian.md) — Gaussian Filter Design
Mathematical design and practical application of Gaussian low-pass filters used for anti-aliasing and bandwidth limiting in the shader pipeline:
- Time-domain kernel and frequency-domain magnitude response formulas
- Design equation for solving sigma given a desired attenuation at a target cutoff frequency
- Quadratic attenuation scaling above the cutoff and cascaded multi-stage responses
- Anti-aliasing strategy: staying below Nyquist at cutoff and using cascaded stages for steep roll-off
- Single-stage and two-stage cascade examples with target attenuations
- Shader implementation via `sigma_tb()` for timebase-aware calculations
- Zero-phase (symmetric) response and kernel truncation limitations

**Key topics**: Gaussian filters, anti-aliasing, bandwidth limiting, sigma calculation, attenuation scaling, cascaded filtering, zero-phase response

### [filters.md](filters.md) — Filter Loop Implementation
Design and optimization of filter loop implementations balancing frequency response, performance, and compilation efficiency:
- Frequency specifications for composite (3 MHz), luminance, and chrominance (0.6 MHz) channels
- Loop cap strategy by filter type: Gaussian 8–24 taps, sinc 44, Hilbert 31
- Symmetric tap-pair iteration halving computation while maintaining bandwidth targets
- Gaussian filter design rationale using the 3σ rule to determine required tap count
- Sinc filter design for IQ modulation with slow 1/n amplitude decay requiring deep tails
- Early-exit logic terminating iteration when weights fall below 1/255 (one 8-bit LSB)

**Key topics**: Filter loop optimization, bandwidth limiting, Gaussian filters, sinc filters, Hilbert transform, early-exit logic, frequency response constraints

### [rendering.md](rendering.md) — Rendering Pipeline Architecture
Six-stage rendering pipeline mapping preset signal processing to physical domains (signal, display electronics, light, and output encoding) for maintainable SDR/WCG/HDR variants:
- Stage 1 (Direct processing): Signal-domain transport, modulation, noise, and decoder emulation
- Stage 2 (Display processing): Display-side analog conditioning prior to light conversion
- Stage 3 (EOTF): Explicit virtual display linearization boundary (BT.1886-style)
- Stage 4 (Linear light): Physical phosphor, beam, mask, and optical processing
- Stage 5 (Presentation): Tone mapping and gamut fitting for target output (SDR/WCG/HDR)
- Stage 6 (Encoding): Final output contract write (sRGB SDR, wide-gamut, or HDR10 PQ)
- Variant generation strategy keeping stages 1–4 shared and varying only stages 5–6

**Key topics**: Rendering pipeline stages, signal domain modeling, EOTF linearization, linear light processing, tone mapping, SDR/WCG/HDR variants, presentation encoding

## Relationship to Other Documentation

- **README.md**: User-facing quick start and parameter descriptions
- **doc/PARAMETERS.md**: Parameter cheatsheet with typical values
- **doc/theory/** (this folder): Deep technical background for understanding *why* parameters exist and their real-world basis

## Usage

These theory documents are intended for:
- Users seeking deeper understanding of CRT and analog video technology
- Developers implementing or modifying the shaders
- Researchers comparing simulation accuracy to real hardware
- Enthusiasts interested in television engineering history

For practical usage, start with the README and parameter guides. Consult theory docs when you need to understand the underlying phenomena being simulated.

## Further Reading

Each theory document includes a "References" section citing industry standards (ITU-R, SMPTE, IEC) and authoritative textbooks. These sources provide additional depth beyond the scope of this documentation.
