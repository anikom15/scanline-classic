# NTSC Composite Video Theory

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
## Overview

The National Television System Committee (NTSC) standard defines analog color television transmission used primarily in North America, Japan, and parts of South America. NTSC encodes luminance (brightness) and chrominance (color) information into a single composite signal through quadrature amplitude modulation of a color subcarrier. Understanding this encoding and decoding process is essential for accurate composite video simulation.

## Historical Context

NTSC color television was standardized in 1953 as a backward-compatible extension to existing black-and-white television. Key design constraints:

1. **Backward compatibility**: Color signal must produce acceptable monochrome image on B&W receivers
2. **Channel bandwidth**: 6 MHz total including audio (4.2 MHz video bandwidth)
3. **Interference minimization**: Color information must not significantly degrade luminance
4. **Flicker reduction**: Interlaced scanning at 59.94 fields/second (reduced from 60 Hz to accommodate color subcarrier)

## Signal Structure

### Timing Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Field rate | 59.94 Hz | Exactly 60/1.001 Hz |
| Frame rate | 29.97 Hz | Two interlaced fields per frame |
| Lines per frame | 525 | 483 active, remainder in VBI |
| Active lines (visible) | ~480–486 | Varies by receiver overscan |
| Horizontal frequency | 15.734 kHz | 525 × 29.97 Hz |
| Color subcarrier | 3.579545 MHz | Exactly 455/2 × fH |

### Signal Components

An NTSC composite signal consists of:

$$
\text{Composite} = Y + C \cos(2\pi f_{sc} t + \phi)
$$

where:
- $Y$ is the luminance (luma) component
- $C$ is the modulated chrominance amplitude
- $f_{sc}$ is the color subcarrier frequency (3.579545 MHz)
- $\phi$ is the subcarrier phase encoding hue information

## Color Encoding (YIQ)

### Colorspace Transformation

NTSC converts RGB signals to YIQ colorspace to separate luminance from chrominance:

$$
\begin{bmatrix} Y \\ I \\ Q \end{bmatrix} = \begin{bmatrix}
0.299 & 0.587 & 0.114 \\
0.596 & -0.274 & -0.322 \\
0.211 & -0.523 & 0.312
\end{bmatrix} \begin{bmatrix} R \\ G \\ B \end{bmatrix}
$$

**Note**: The exact matrix varies by era and implementation. Later standards (SMPTE 170M, post-1987) use BT.601 primaries with slightly different coefficients:

$$
\begin{bmatrix} Y \\ I \\ Q \end{bmatrix} = \begin{bmatrix}
0.2990 & 0.5870 & 0.1140 \\
0.5959 & -0.2746 & -0.3213 \\
0.2115 & -0.5227 & 0.3112
\end{bmatrix} \begin{bmatrix} R \\ G \\ B \end{bmatrix}
$$

**Component definitions**:
- **Y** (luminance): Weighted sum of RGB optimized for human brightness perception
- **I** (in-phase): Orange-cyan axis; wider bandwidth (1.3 MHz)
- **Q** (quadrature): Green-magenta axis; narrower bandwidth (0.4 MHz)

The I and Q axes are rotated 33° from the U and V axes (used in PAL) to align with flesh-tone perception, the most critical color for viewers.

### Quadrature Modulation

I and Q signals modulate the color subcarrier in quadrature (90° phase difference):

$$
C(t) = I(t) \cos(2\pi f_{sc} t) + Q(t) \sin(2\pi f_{sc} t)
$$

This allows both color components to occupy the same frequency band without interference, recoverable through synchronous demodulation.

### Subcarrier Frequency Selection

The subcarrier frequency 3.579545 MHz was chosen carefully:

1. **Interleaving**: Positioned at an odd multiple of half the line frequency (455/2 × fH), causing subcarrier phase to alternate line-to-line. This interleaving minimizes visibility of color subcarrier in luminance.

2. **Bandwidth**: High enough to avoid visibility in the luminance band but low enough to fit within the 4.2 MHz video bandwidth alongside high-frequency luma detail.

3. **Sound carrier separation**: Provides adequate spacing from the 4.5 MHz audio carrier to minimize interference.

## Bandwidth Allocation

NTSC's composite nature requires careful bandwidth management:

| Component | Bandwidth | Notes |
|-----------|-----------|-------|
| Luminance (Y) | 0–4.2 MHz | Shared with chrominance; notch filtered in color receivers |
| I (in-phase chroma) | ±1.3 MHz | Wider bandwidth for critical colors |
| Q (quadrature chroma) | ±0.4 MHz | Narrower; human eye less sensitive to these hues |
| Full chroma (practical) | ±0.5 MHz | Most consumer equipment limits both I and Q equally |

**Compromise**: High-frequency luminance detail (3.0–4.2 MHz) occupies the same spectrum as chrominance. This leads to cross-contamination:
- **Luminance → chroma**: High-frequency luma detail appears as false color (rainbow artifacts on sharp edges)
- **Chroma → luminance**: Color transitions create luminance artifacts (dot crawl, hanging dots)

## Color Burst and Synchronization

Each line begins with a color burst: 8–10 cycles of the subcarrier at reference phase and amplitude, placed on the "back porch" after the horizontal sync pulse.

**Purpose**:
1. Frequency reference for receiver's subcarrier regeneration
2. Phase reference (defines 0° = yellow, aligning with the -(B-Y) axis in practice)
3. Amplitude reference for automatic color control (ACC) circuits

The burst phase is inverted every field in NTSC to facilitate 3D comb filtering, though simple receivers ignore this.

## Demodulation Methods

Receivers must separate Y and C from the composite signal, then recover I and Q from the modulated chrominance.

### Notch Filtering

**Luminance path**: Apply a notch filter at 3.58 MHz to remove color subcarrier from Y
**Chrominance path**: Apply a bandpass filter centered at 3.58 MHz to isolate C

**Advantages**: Simple, low cost
**Disadvantages**: 
- Removes legitimate high-frequency luma detail
- Leaves chroma contamination in luma at frequencies away from 3.58 MHz
- No separation of cross-luminance from true chroma

### Comb Filtering

Exploits the line-to-line phase reversal of the color subcarrier. Delaying the signal by one line (63.56 µs) and adding or subtracting yields:

**Luma comb**: 
$$Y = \frac{\text{Line}_n + \text{Line}_{n-1}}{2}$$
In-phase components (luma) add; out-of-phase components (chroma) cancel.

**Chroma comb**:
$$C = \frac{\text{Line}_n - \text{Line}_{n-1}}{2}$$
Out-of-phase components (chroma) add; in-phase components (luma) cancel.

**Advantages**: Superior Y/C separation with minimal high-frequency luma loss
**Disadvantages**: 
- Requires 1H delay line (analog) or line buffer (digital)
- Vertical color/luma transitions cause artifacts
- Fails on signals where chroma phase does not follow standard (video games, computer graphics)

**Multi-tap comb filters**: Use 2H, 3H, or more delay lines to better handle motion and transitions. Higher tap counts improve separation but increase cost and may introduce lag.

| Taps | Delay Lines | Quality | Typical Use |
|------|-------------|---------|-------------|
| 2-line (1H) | 1 | Good | Consumer TVs (1980s–90s) |
| 3-line (2H) | 2 | Better | Higher-end consumer equipment |
| Adaptive | 2+ | Best | Professional equipment, modern chips |

### Adaptive Comb Filtering

Modern decoders analyze temporal and spatial characteristics to selectively apply comb filtering:

- **Static areas**: Use multi-tap comb for maximum separation
- **Motion/transitions**: Fall back to notch filtering or spatial interpolation to avoid artifacts

Adaptive algorithms add significant complexity but provide the best balance of sharpness and artifact suppression.

### Synchronous Demodulation

After isolating C, recover I and Q by multiplying with synchronized subcarrier references:

$$I = C(t) \times 2\cos(2\pi f_{sc} t + \phi_{\text{burst}})$$
$$Q = C(t) \times 2\sin(2\pi f_{sc} t + \phi_{\text{burst}})$$

Low-pass filtering removes the sum-frequency terms (7.16 MHz), leaving the baseband I and Q signals.

**Phase-locked loop (PLL)**: Regenerates a stable 3.58 MHz oscillator locked to the color burst, providing phase coherence for demodulation. Phase errors cause hue shifts (e.g., "NTSC = Never The Same Color").

## Artifacts and Limitations

### Dot Crawl

The color subcarrier's line-to-line phase reversal creates a pattern of moving dots along vertical color boundaries. Caused by chroma energy leaking into the luminance channel.

**Mitigation**: Comb filtering (sacrifices vertical chroma resolution)

### Hanging Dots

Subcarrier visibility near sharp horizontal edges in the chrominance signal. Appears as colored dots that "hang" on edges.

**Cause**: Chroma signal contains high-frequency components (sharp color transitions) that exceed the ideal narrow-band assumption.

### Cross-Color (Rainbow Artifacts)

High-frequency luminance detail (thin lines, textures) near the subcarrier frequency is misinterpreted as chrominance, producing false rainbow colors.

**Example**: Diagonal lines, herringbone patterns, fine textures in video games

**Mitigation**: Better Y/C separation (comb filtering), prefiltering before encoding

### Cross-Luminance

Chrominance signal contaminating luminance, appearing as crawling patterns or edge distortion.

**Mitigation**: Comb filtering, chroma bandwidth limiting

### Chroma Phase Errors

Multipath interference, poor subcarrier regeneration, or differential phase distortion causes hue shifts. Traditionally corrected with manual "tint" control on consumer TVs.

### Limited Color Resolution

The narrow chroma bandwidth (~0.5 MHz practical, 1.3/0.4 MHz theoretical) limits color detail:

- Horizontal chroma resolution: ~40–60 color cycles per line (~120–180 pixels at 640 horizontal)
- Vertical chroma resolution: Compromised by comb filtering (averages across lines)

This is why NTSC "looks softer" in color areas compared to luminance detail.

## NTSC Variants

### NTSC-M (North America, Japan 120V regions)

Standard 525-line, 59.94 Hz, 3.579545 MHz subcarrier

### NTSC-J (Japan)

Identical timing to NTSC-M but different setup level (black level pedestal):
- NTSC-M: 7.5 IRE setup (black at 7.5% above blanking)
- NTSC-J: 0 IRE setup (black at blanking level, like PAL)

This affects gamma and black level reproduction.

### NTSC 4.43

Rare variant using PAL's 4.43 MHz subcarrier on 525-line/60 Hz timing. Used in some VCRs and video equipment for international compatibility.

## S-Video (Y/C Separation)

S-Video (Super Video, Y/C) physically separates luminance and chrominance before transmission using separate cables:

- **Y**: Luminance (0–4.2 MHz)
- **C**: Modulated chrominance (centered at 3.58 MHz)

**Advantages**:
- Eliminates dot crawl, cross-color, and cross-luminance artifacts inherent to composite
- Preserves full luminance bandwidth without notch filtering
- No comb filtering artifacts

**Disadvantages**:
- Chroma still bandwidth-limited and subject to phase errors
- More expensive connectors and cabling
- Not available on all equipment (TV RF, VCRs without S-Video output)

S-Video is often considered the optimal balance between quality and practicality for analog video.

## RF Modulation (Channel 3/4)

Consumer game consoles and early computers often output RF-modulated NTSC on television channels 3 (60–66 MHz) or 4 (66–72 MHz).

**Additional degradation**:
- Audio and video carriers frequency-modulated onto RF carrier
- Susceptibility to RF interference and multipath
- Reduced video bandwidth due to channel filtering
- Additional demodulation step in TV tuner introduces noise

RF output is the lowest-quality analog connection, exhibiting all composite artifacts plus RF-specific issues.

## NTSC in Scanline Classic

The shader's NTSC simulation pipeline:

1. **Encoding** (`composite-mod/prefilter.slang`, `composite-iq.slang`, `iq-*.slang`):
   - RGB → YIQ colorspace conversion
   - Optional prefiltering to reduce cross-color
   - Quadrature modulation onto 3.579545 MHz subcarrier
   - RF modulation (optional, for RF simulation)

2. **Decoding** (`composite.slang`, `composite-demod.slang`, `svideo.slang`):
   - Notch/comb filtering for Y/C separation (selectable modes)
   - Synchronous demodulation to recover I and Q
   - Optional feedback filtering to remove residual chroma from luma
   - Gaussian filtering to simulate receiver bandwidth limits

3. **Parameters**:
   - `COLOR_FILTER_MODE`: Selects notch, comb (1–3 taps), hybrid, or feedback demodulation
   - `DISPLAY_BANDWIDTH_Y/C`: Receiver lowpass filtering (higher = sharper but more artifacts)
   - `SC_FREQ_MODE`: Selects NTSC (3.579545 MHz) or custom subcarrier
   - `V_FREQ`, `V_LINES_PER_FIELD`: Timing base for accurate phase computation

The shader faithfully reproduces NTSC artifacts (dot crawl, rainbowing, chroma phase errors) while allowing users to select idealized decoding (comb filtering) or authentic low-quality decoding (notch filtering, RF path) based on aesthetic preference.

## References

- SMPTE 170M-2004: Composite Analog Video Signal – NTSC for Studio Applications
- ITU-R Recommendation BT.470-6: Conventional Television Systems
- ITU-R Recommendation BT.601: Studio Encoding Parameters of Digital Television for Standard 4:3 and Wide-Screen 16:9 Aspect Ratios
- Poynton, Charles. "YUV and Luminance Considered Harmful." In *Digital Video and HD*, 2012.
- Benson, K. Blair, and Jerry Whitaker. *Television Engineering Handbook*, McGraw-Hill, 1992.