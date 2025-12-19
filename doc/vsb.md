# VSB (Vestigial Sideband) Modulation Reference

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

Vestigial Sideband (VSB) modulation is used in analog television broadcasting to save bandwidth while maintaining compatibility with double-sideband receivers. In VSB, one sideband is transmitted in full while the other is partially suppressed (vestigial).

## K_VSB Parameter

`K_VSB` represents the **vestigial sideband asymmetry factor** — the ratio of vestigial (lower) sideband bandwidth to full (upper) sideband bandwidth:

```
K_VSB = vestige_bandwidth / full_sideband_bandwidth
```

In demodulation, the effective weight `α` used in reconstruction is **negative** to account for:
1. The Q channel being created via Hilbert transform (90° phase shift)
2. VSB's asymmetry where negative frequencies have reduced power
3. The reconstruction formula `composite = I + α·Q` requiring `α ≈ -K_VSB`

## Standard Specifications

### NTSC (525 lines, ~4.95 MHz video bandwidth)

**RF Specification:**
- Picture carrier: channel center + 1.25 MHz
- Full upper sideband: **+4.2 MHz** from picture carrier
- Vestigial lower sideband: **-0.75 MHz** from picture carrier
- Total video bandwidth: 4.95 MHz

**K_VSB Calculation:**
```
K_VSB = 0.75 MHz / 4.2 MHz ≈ 0.1786 (17.86%)
```

**Demodulation Weight:**
- Theoretical: `α ≈ -0.18`
- Practical (with rolloff compensation): `α ≈ -0.27`

### PAL (625 lines, ~5.5-6.0 MHz video bandwidth)

**RF Specification (PAL-B/G/H - most common):**
- Picture carrier: channel edge + 1.25 MHz
- Full upper sideband: **+5.0 MHz** from picture carrier
- Vestigial lower sideband: **-0.75 MHz** (standard) or **-1.25 MHz** (extended)
- Total video bandwidth: 5.5–6.0 MHz

**K_VSB Calculation:**

Standard vestige (0.75 MHz):
```
K_VSB = 0.75 / 5.0 = 0.15 (15%)
α ≈ -0.15 to -0.20
```

Extended vestige (1.25 MHz):
```
K_VSB = 1.25 / 5.0 = 0.25 (25%)
α ≈ -0.25 to -0.32
```

**PAL Characteristics:**
- Wider full sideband (5.0 MHz vs 4.2 MHz NTSC) for better luminance resolution
- Vestige typically same (0.75 MHz), so K_VSB is **smaller** than NTSC
- Some PAL systems use 1.25 MHz vestige for IF filter compatibility

### SECAM (625 lines, ~6.0 MHz video bandwidth)

**Note:** SECAM uses FM for color, not QAM, so VSB applies **only to luminance**.

**RF Specification:**
- Picture carrier positioning varies by variant (SECAM-L/D/K)
- Luminance bandwidth: up to **6.0 MHz** (wider than both NTSC and PAL)
- Vestigial sideband: typically **-1.0 to -1.25 MHz**
- Full upper sideband: **+5.0 to +5.5 MHz**

**K_VSB Calculation:**

Typical case (1.0 MHz vestige, 5.5 MHz upper):
```
K_VSB = 1.0 / 5.5 ≈ 0.182 (18.2%)
α ≈ -0.18 to -0.24
```

Wide vestige (1.25 MHz, 5.5 MHz upper):
```
K_VSB = 1.25 / 5.5 ≈ 0.227 (22.7%)
α ≈ -0.23 to -0.29
```

**SECAM Characteristics:**
- FM color means chroma doesn't contribute to I/Q asymmetry
- Wider luminance bandwidth improves horizontal resolution
- Vestige ratio similar to NTSC despite wider bandwidth

## Summary Table

| Standard      | Lines | I Cutoff | Q Cutoff | K_VSB (ratio) | α (demod weight) |
|---------------|-------|----------|----------|---------------|------------------|
| **NTSC**      | 525   | 4.2 MHz  | 0.75 MHz | 0.179         | -0.18 to -0.27   |
| **PAL**       | 625   | 5.0 MHz  | 0.75 MHz | 0.150         | -0.15 to -0.20   |
| **PAL** (ext) | 625   | 5.0 MHz  | 1.25 MHz | 0.250         | -0.25 to -0.32   |
| **SECAM**     | 625   | 5.5 MHz  | 1.0 MHz  | 0.182         | -0.18 to -0.24   |

## Implementation in Shaders

### Modulation (iq-mod.slang)

The modulation pass applies asymmetric lowpass filtering:
- **I channel**: Lowpass at upper sideband cutoff (e.g., 4.2 MHz for NTSC)
- **Q channel**: Lowpass at vestige cutoff (e.g., 0.75 MHz for NTSC)

This creates the VSB characteristic where positive frequencies have full bandwidth while negative frequencies are attenuated to the vestigial bandwidth.

### Demodulation (iq-demod.slang)

Two reconstruction methods are supported:

#### Method 0: Hilbert Inversion
```
composite = I_lp - Hilbert{Q_lp}
```

Uses the identity `H{H{x}} = -x` to restore the vestigial sideband. Since `Q_analytic = H{composite}` originally:
- Apply matched lowpass to both I and Q
- Compute `Hq = H{Q_lp}` (inverts the original Hilbert)
- Reconstruct: `composite = I_lp - Hq`

#### Method 1: Weighted Combination
```
composite = I_lp + α·Q_lp
```

Direct weighted combination where `α ≈ -K_VSB`:
- Apply matched lowpass to both I and Q
- Combine with negative weight: `composite = I_lp + α·Q_lp`
- The negative weight accounts for phase relationship and VSB asymmetry

**Performance:** Method 1 is ~30-40% faster as it skips Hilbert coefficient calculations.

## Mathematical Background

### Why the Negative Sign in α

The weighted method uses a negative α because:

1. **Phase relationship**: Q was created as `H{composite}` (90° leading phase)
2. **Frequency mapping**: In complex baseband, negative frequencies map to conjugate
3. **VSB asymmetry**: Lower sideband (vestige) is attenuated relative to upper
4. **Reconstruction**: To restore the vestige contribution, we subtract a scaled Q

Mathematical justification:
```
Original spectrum:
  S(f) = S_upper(f>0) + S_vestige(f<0)

After Hilbert + asymmetric LPF:
  I(f) ≈ S_upper(f>0)                    // upper sideband
  Q(f) ≈ -j·sign(f)·S_vestige(f near 0)  // vestige in imaginary

To reconstruct:
  S_reconstructed = I + α·Q  where α ≈ -K_VSB
```

The negative sign ensures constructive addition of the vestige rather than cancellation.

## Shader Pipeline

The complete VSB processing pipeline consists of four passes:

1. **composite-iq.slang**: Generate analytic signal
   - Input: RGB
   - Output: I = composite(t), Q = Hilbert{composite(t)}

2. **iq-mod.slang**: Apply VSB filtering
   - Input: Analytic I/Q
   - Output: I filtered at full bandwidth, Q filtered at vestige bandwidth

3. **iq-noise.slang**: Add RF impairments (optional)
   - Input: Filtered I/Q
   - Output: I/Q with AWGN, ghosts, impulse noise, phase jitter

4. **iq-demod.slang**: Reconstruct composite
   - Input: Noisy I/Q
   - Output: Recovered composite baseband signal

## References

- ATSC A/54: "Recommended Practice: Guide to the Use of the ATSC Digital Television Standard"
- ITU-R BT.470: "Conventional Analogue Television Systems"
- EBU Tech 3213-E: "EBU Standard for Chrominance/Luminance Gains and Delays"
