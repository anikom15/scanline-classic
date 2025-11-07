# Theory Documentation

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

## Relationship to Other Documentation

- **README.md**: User-facing quick start and parameter descriptions
- **doc/PARAMETERS.md**: Parameter cheatsheet with typical values
- **doc/performance/**: Per-shader performance tuning and quality profiles
- **doc/performance/COMPILE_TIME.md**: Compile-time optimization analysis
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

---

*Scanline Classic shader pack by W. M. Martinez*
