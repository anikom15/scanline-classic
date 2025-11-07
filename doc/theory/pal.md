# PAL Composite Video Theory

## Overview

Phase Alternating Line (PAL) is the color television standard developed in Germany by Walter Bruch and adopted across Europe, Australia, parts of Asia, Africa, and South America starting in 1967. PAL addresses several key NTSC weaknesses—particularly phase distortion sensitivity—through a line-alternating phase technique while maintaining similar quadrature amplitude modulation principles.

## Historical Context and Design Goals

PAL was developed to overcome NTSC's susceptibility to phase errors causing hue shifts. The core innovation: **alternating the phase of the V (or R-Y) color difference signal on successive lines**. This allows simple averaging to cancel phase errors.

**Key design objectives**:
1. **Phase error immunity**: Reduce hue distortion from multipath, differential phase, and receiver oscillator drift
2. **Backward compatibility**: B&W receivers display acceptable monochrome image
3. **Higher line count**: 625 lines vs NTSC's 525 (576 active vs ~480) for improved vertical resolution
4. **50 Hz compatibility**: Match European power grid frequency to minimize mains hum interference

## Signal Structure

### Timing Parameters

| Parameter | PAL-B/G/H/I | Notes |
|-----------|-------------|-------|
| Field rate | 50 Hz | Exactly 50.00 Hz (no fractional offset like NTSC) |
| Frame rate | 25 Hz | Two interlaced fields per frame |
| Lines per frame | 625 | 576 active, remainder in VBI |
| Active lines (visible) | ~574–576 | Varies by receiver overscan |
| Horizontal frequency | 15.625 kHz | 625 × 25 Hz |
| Color subcarrier | 4.43361875 MHz | 283.75 × fH + 25 Hz offset |

**Subcarrier offset**: The +25 Hz offset (1/4 line rate offset from exact half-line frequency multiple) staggers the subcarrier pattern across four lines instead of two, improving subcarrier cancellation in luminance.

### PAL Variants by Region

| Variant | Resolution | Audio Carrier | Video Bandwidth | Primary Regions |
|---------|------------|---------------|-----------------|-----------------|
| PAL-B/G | 625/50 | 5.5 MHz | ~5.0 MHz | Western Europe, Australia |
| PAL-I | 625/50 | 6.0 MHz | ~5.5 MHz | UK, Ireland, Hong Kong |
| PAL-D/K | 625/50 | 6.5 MHz | ~6.0 MHz | Eastern Europe, China |
| PAL-M | 525/59.94 | 4.5 MHz | ~4.2 MHz | Brazil (PAL color, NTSC timing) |
| PAL-N | 625/50 | 4.5 MHz | ~4.2 MHz | Argentina, Uruguay (3.582 MHz subcarrier) |

This document focuses primarily on PAL-B/G/I, the most common variants.

## Color Encoding (YUV)

### Colorspace Transformation

PAL uses YUV colorspace (also called YPbPr or Y(R-Y)(B-Y) in analog contexts):

$$
\begin{bmatrix} Y \\ U \\ V \end{bmatrix} = \begin{bmatrix}
0.299 & 0.587 & 0.114 \\
-0.147 & -0.289 & 0.436 \\
0.615 & -0.515 & -0.100
\end{bmatrix} \begin{bmatrix} R \\ G \\ B \end{bmatrix}
$$

For BT.601 PAL primaries (EBU phosphors):

$$
\begin{bmatrix} Y \\ U \\ V \end{bmatrix} = \begin{bmatrix}
0.2990 & 0.5870 & 0.1140 \\
-0.1471 & -0.2889 & 0.4360 \\
0.6149 & -0.5149 & -0.1000
\end{bmatrix} \begin{bmatrix} R \\ G \\ B \end{bmatrix}
$$

**Component definitions**:
- **Y** (luminance): Identical concept to NTSC; weighted RGB sum for brightness
- **U** (B-Y): Blue color difference, scaled for subcarrier modulation
- **V** (R-Y): Red color difference, scaled for subcarrier modulation

U and V are orthogonal axes representing color information. Unlike NTSC's I/Q (rotated 33°), PAL's U/V align with the blue and red color difference axes.

### Phase Alternation Mechanism

The fundamental PAL innovation: V component phase alternates ±90° on successive lines.

**Line n**: 
$$C_n(t) = U(t) \sin(2\pi f_{sc} t) + V(t) \cos(2\pi f_{sc} t)$$

**Line n+1**: 
$$C_{n+1}(t) = U(t) \sin(2\pi f_{sc} t) - V(t) \cos(2\pi f_{sc} t)$$

A phase error $\Delta\phi$ affects both lines equally in magnitude but oppositely in direction. Averaging two consecutive lines cancels the error:

$$
\frac{C_n + C_{n+1}}{2} = U \sin(\omega t) + V\cos(\omega t + \Delta\phi / 2)
$$

The phase error is reduced by half and affects only V (which the eye is less sensitive to in typical images).

**PAL identifier (Bruch's switch)**: The alternating V phase is indicated by the color burst phase:
- **Line n**: +135° (±U + V burst)
- **Line n+1**: -135° (±U - V burst)

This "swinging burst" allows receivers to identify and synchronize with the V-switch phase.

## Bandwidth Allocation

PAL's wider channel bandwidth (compared to NTSC) provides more spectrum for video:

| Component | Bandwidth | Notes |
|-----------|-----------|-------|
| Luminance (Y) | 0–5.0 MHz (B/G), 0–5.5 MHz (I) | Higher than NTSC's 4.2 MHz |
| U (chroma) | ±1.3 MHz | Symmetric; same as V |
| V (chroma) | ±1.3 MHz | Symmetric; same as U |
| Practical chroma | ±0.57–1.3 MHz | Consumer equipment varies |

**Advantages over NTSC**:
- Higher luminance bandwidth preserves more fine detail
- Symmetric U/V bandwidths simplify filtering (no I/Q asymmetry)
- Greater subcarrier-to-sound spacing reduces cross-modulation

**Trade-off**: The phase alternation mechanism requires delay-line demodulation, increasing receiver cost and complexity.

## Color Burst and Synchronization

Each line includes 10 cycles (±1) of color burst on the back porch, similar to NTSC. However, PAL's burst alternates phase:

- **Odd lines**: Burst phase at +135° (leading the U axis)
- **Even lines**: Burst phase at -135° (lagging the U axis)

This swinging burst serves multiple purposes:
1. Frequency and phase reference for subcarrier regeneration
2. Identification signal (PAL vs NTSC detection)
3. V-switch synchronization (tells decoder which lines have positive/negative V)

The alternation occurs at half the line rate (7.8125 kHz), creating a characteristic PAL identification sequence.

## Demodulation Methods

### Simple Demodulation (Single Line)

Demodulating one line at a time without delay lines yields U correctly but leaves phase errors uncorrected in V:

$$U = C(t) \times 2\sin(2\pi f_{sc} t)$$
$$V = C(t) \times 2\cos(2\pi f_{sc} t) \times \text{V-switch}$$

where V-switch alternates ±1 based on burst phase or line parity.

**Result**: Image displays correctly but inherits NTSC's phase sensitivity. Color errors appear as hue shifts.

**Use case**: Low-cost receivers, NTSC compatibility modes

### Delay-Line Demodulation (PAL Standard)

True PAL receivers incorporate a 1H delay line (64 µs) to average consecutive lines:

1. Demodulate current line: $U_n$, $V_n$
2. Demodulate delayed line: $U_{n-1}$, $-V_{n-1}$ (accounting for phase inversion)
3. Average U: $U_{\text{out}} = \frac{U_n + U_{n-1}}{2}$
4. Difference V: $V_{\text{out}} = \frac{V_n - (-V_{n-1})}{2} = \frac{V_n + V_{n-1}}{2}$

Phase errors affecting both lines equally are cancelled in V; U errors average to half. The result: **hue is stable despite phase distortion**, at the cost of one line of vertical chroma resolution.

**Advantages**:
- Excellent hue stability
- Automatic phase error correction without user adjustment (no "tint" control needed)

**Disadvantages**:
- Loss of vertical chroma resolution (colors vertically averaged across 2 lines)
- Requires precision delay line (expensive in analog era)
- Artifacts at vertical chroma transitions (Hannover bars)

### Simple PAL (No Delay Line)

"Simple PAL" receivers omit the delay line and demodulate each line independently, relying on the eye to average adjacent lines temporally and spatially.

**Behavior**: Hue errors appear as alternating line-by-line shifts that partially cancel perceptually but are visible on close inspection (alternating color fringes).

**Use case**: Budget receivers, early PAL implementations

## Artifacts and Limitations

### Hannover Bars (Venetian Blind Effect)

Vertical chroma edges processed by the delay-line averager produce line-to-line brightness differences, appearing as horizontal bars crawling vertically across color transitions.

**Cause**: The V component on one line may differ significantly from the adjacent line at a vertical edge, but the delay-line forces averaging. The mismatch manifests as luminance error.

**Mitigation**: Adaptive switching (detect vertical edges and bypass averaging) or accept as characteristic PAL artifact

### Dot Crawl

Like NTSC, PAL composite suffers from chroma subcarrier visibility in luminance due to imperfect Y/C separation.

**PAL improvement**: The 4-line subcarrier pattern (283.75fH + 25 Hz offset) provides better cancellation than NTSC's 2-line pattern when viewed dynamically, reducing dot crawl visibility.

### Cross-Color and Cross-Luminance

Identical mechanisms to NTSC: high-frequency luminance detail near the subcarrier frequency is misinterpreted as color, and chroma signal contaminates luminance.

**PAL advantage**: Higher luma bandwidth (5.0–5.5 MHz vs 4.2 MHz) pushes more luma detail above the chroma band, reducing overlap. However, cross-color/cross-luminance still occur.

### Phase Quadrature Error

While PAL corrects for differential phase (hue rotation), it does not correct for differential gain (saturation errors). Gain errors affect color saturation symmetrically, so PAL offers no advantage over NTSC in this regard.

### Vertical Color Resolution

The delay-line averager halves vertical chroma resolution. On 576-line PAL, effective chroma resolution is ~288 lines. Combined with the interlaced field structure, this limits color detail on vertical transitions.

**Mitigation**: S-Video bypasses this by separating Y/C at the source

### PAL Phase Error in Still Images

On static images with large saturated areas, even small residual phase errors after delay-line correction can cause visible hue banding. This is rare but possible with low-quality receivers or extreme multipath.

## Comb Filtering in PAL

PAL benefits from comb filtering similar to NTSC but adapted for the 4-line subcarrier pattern:

**2-line comb**: Averages adjacent lines for luma, subtracts for chroma (basic)
**3D comb (field memory)**: Analyzes temporal correlation to separate static chroma from moving luma
**4-line comb**: Exploits PAL's 4-line subcarrier repeat pattern for superior Y/C separation

Comb filtering removes dot crawl and improves sharpness but can introduce combing artifacts on diagonal edges and during motion.

## PAL-M and PAL-N Special Cases

### PAL-M (Brazil)

Uses NTSC timing (525 lines, 59.94 Hz) with PAL color encoding:
- Subcarrier: 3.575611 MHz (227.5 × fH)
- Combines NTSC's flicker reduction (60 Hz fields) with PAL's hue stability
- Rare outside Brazil; requires specific hardware support

### PAL-N (Argentina, Uruguay)

Standard 625/50 timing but modified subcarrier (3.58205625 MHz) to accommodate 4.5 MHz sound carrier spacing (matching NTSC channel plan).

Both variants maintain PAL's V-switching and delay-line advantages while adapting to regional channel allocations.

## S-Video in PAL

PAL S-Video (Y/C) operates identically to NTSC S-Video: separate luminance and chrominance cables eliminate composite artifacts.

**PAL-specific benefit**: The delay-line averaging artifact (Hannover bars) disappears since Y/C separation occurs before modulation/demodulation. Full vertical chroma resolution is preserved.

PAL S-Video is widely regarded as superior to NTSC S-Video due to:
- Higher luminance bandwidth (5.0–5.5 MHz vs 4.2 MHz)
- Greater source resolution (576 vs ~480 active lines)
- Symmetric U/V bandwidth (no I/Q complexity)

## PAL vs NTSC Summary

| Feature | NTSC | PAL |
|---------|------|-----|
| Lines (active) | 525 (480) | 625 (576) |
| Field rate | 59.94 Hz | 50 Hz |
| Frame rate | 29.97 Hz | 25 Hz |
| Subcarrier | 3.579545 MHz | 4.43361875 MHz |
| Chroma bandwidth | 0.5–1.3/0.4 MHz (I/Q) | 1.3 MHz (U/V symmetric) |
| Luma bandwidth | 4.2 MHz | 5.0–5.5 MHz |
| Phase error correction | None (requires "tint" control) | Automatic (delay-line averaging) |
| Vertical chroma resolution | Full (no delay line required) | Halved (with standard delay-line decoder) |
| Color subcarrier pattern | 2-line repeat | 4-line repeat |
| Subjective color stability | Poor (phase-sensitive) | Excellent (phase-corrected) |
| Subjective sharpness | Moderate | Higher (more lines, bandwidth) |
| Flicker | Less (60 Hz fields) | More (50 Hz fields) |

**Trade-offs**: PAL offers better spatial resolution and hue stability at the cost of lower temporal resolution (50 Hz flicker more visible) and reduced vertical chroma detail.

## PAL in Scanline Classic

The shader's PAL simulation pipeline:

1. **Encoding** (`composite-pal.slang`):
   - RGB → YUV colorspace conversion (EBU primaries)
   - V-switch phase alternation on successive lines
   - Quadrature modulation onto 4.433619 MHz subcarrier
   - Optional prefiltering (FILTER_ENCODE)

2. **Decoding** (`composite-pal.slang`):
   - Comb or notch filtering for Y/C separation
   - Synchronous demodulation with V-switch tracking
   - Delay-line averaging (simulated via multi-tap comb filter)
   - Gaussian filtering to simulate receiver bandwidth limits (FILTER_SIZE_YC)

3. **Parameters**:
   - `COMB_FILTER_TAPS`: 1–3 line delay simulation (3 = full PAL delay-line decoder)
   - `FILTER_SIZE_YC`: Gaussian loop radius; higher values simulate wider bandwidth
   - `SC_FREQ_MODE`: Select PAL subcarrier frequency (4.433619 MHz)
   - `V_FREQ`, `V_LINES_PER_FIELD`: Set to 50 Hz / 312.5 lines for correct PAL timing
   - `ENCODE_FILTER_BANDWIDTH_*`: Prefilter before modulation to reduce cross-color

The shader faithfully reproduces PAL's characteristic look: stable hue, Hannover bars (with 3-tap comb), dot crawl pattern, and the subtle differences from NTSC's artifact spectrum.

## References

- ITU-R Recommendation BT.470-6: Conventional Television Systems (Includes PAL-B/G/H/I specifications)
- ITU-R Recommendation BT.601: Studio Encoding Parameters (EBU primaries for PAL)
- CCIR Report 624-4: Characteristics of Television Systems
- Bruch, Walter. "PAL—A Colour Television System for Europe." *EBU Review*, 1963.
- Benson, K. Blair, and Jerry Whitaker. *Television Engineering Handbook*, McGraw-Hill, 1992.
- Poynton, Charles. *Digital Video and HD: Algorithms and Interfaces*, Morgan Kaufmann, 2012.

---

*This document provides theoretical background for PAL composite simulation in Scanline Classic. For tuning guidance, see `doc/performance/composite-pal.md` and related shader performance notes.*
