# CRT Display Theory

Copyright (c)  2025  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

Cathode ray tube (CRT) displays generate images by directing one or more electron beams across a phosphor-coated screen. The physical properties of this electromechanical process—beam deflection, phosphor persistence, aperture grille structures, and geometric distortion—form the basis for accurate CRT simulation in the Scanline Classic shader set.

## Fundamental Components

### Electron Gun and Beam Formation

The electron gun generates a focused beam of electrons that strikes the phosphor coating on the inner surface of the display's faceplate. Key characteristics include:

- **Beam intensity**: Modulated by grid voltage to control brightness
- **Beam focus**: Determined by electrostatic or electromagnetic lens assemblies
- **Beam convergence**: In color CRTs, three beams (red, green, blue) must converge precisely at the shadow mask or aperture grille

### Deflection Systems

CRTs employ electromagnetic deflection coils mounted around the tube neck to control beam position. Two deflection modes exist:

| Property | Electrostatic | Electromagnetic |
|----------|---------------|-----------------|
| Deflection mechanism | Electric field between plates | Magnetic field from coils |
| Deflection linearity | Linear | Nonlinear (requires correction) |
| Typical applications | Oscilloscopes, small displays | Televisions, computer monitors |
| Deflection angle range | 0–60° | 60–125° |

**Electromagnetic deflection** dominates consumer CRTs and introduces pincushion distortion due to the nonlinear relationship between coil current and beam position. The distortion increases with deflection angle, producing characteristic geometric aberrations at screen edges.

### Phosphor Layer

The phosphor coating converts electron beam energy into visible light through fluorescence and phosphorescence:

- **Fluorescence**: Immediate light emission during electron bombardment (primary image formation)
- **Phosphorescence**: Delayed emission after bombardment ceases (persistence/decay)

Persistence characteristics vary by phosphor composition:

| Phosphor Type | Decay Time | Typical Application |
|---------------|------------|---------------------|
| P1 (green) | Medium (24 ms) | Oscilloscopes |
| P3 (yellow) | Short (1 ms) | Early color TV |
| P4 (white) | Short-medium (0.2–50 ms) | Monochrome monitors |
| P22 (RGB) | Short (varies by primary) | Color TV and monitors |
| P31 (green) | Medium-long (30–50 ms) | Radar displays, terminals |
| P38 (orange) | Short | Amber monitors |

Modern color CRTs typically use P22 phosphors with decay constants optimized for 50–60 Hz refresh rates. The exponential decay produces a characteristic motion blur and reduces flicker perception.

### Shadow Mask and Aperture Grille

Color CRTs require a structure to ensure each electron beam strikes only its corresponding phosphor color. Two primary technologies exist:

**Shadow Mask** (most computer monitors, many TVs):
- Perforated metal sheet with circular or slot-shaped holes
- Phosphor dots arranged in triangular triads or vertical stripes
- Provides excellent color purity but blocks ~75–85% of beam energy
- Subject to thermal expansion (doming) under sustained high brightness

**Aperture Grille** (Sony Trinitron, Mitsubishi Diamondtron):
- Vertically tensioned wires with gaps for electron beam passage
- Phosphor stripes in vertical columns
- Higher light transmission (~85–90%) yields brighter, more saturated images
- Cylindrical screen curvature (horizontal axis only)
- Requires one or two horizontal damper wires to prevent vibration

| Feature | Shadow Mask | Aperture Grille |
|---------|-------------|-----------------|
| Structure | Perforated sheet | Vertical wires |
| Phosphor pattern | Dots or slots | Vertical stripes |
| Screen curvature | Spherical | Cylindrical |
| Brightness | Moderate | High |
| Typical pitch | 0.25–0.31 mm | 0.24–0.27 mm |

## Geometric Distortion

### Pincushion Distortion

Electromagnetic deflection combined with a flat or slightly curved screen produces pincushion distortion, where straight lines bow inward toward screen edges. The distortion results from the fixed distance between the deflection center and screen corners versus edges.

**Mathematical basis**: For a deflection angle $\theta$ from center, the distance from the deflection point to the screen surface varies as:

$$
r(\theta) = \frac{d}{\cos(\theta)}
$$

where $d$ is the perpendicular distance to the screen center. This nonuniform distance causes edge compression.

**Correction methods**:
- Electronic circuits adjust drive waveforms (common in computer monitors)
- Accept distortion as authentic to the CRT aesthetic (common in TV emulation)

### Barrel/Cushion Screen Curvature

Early CRTs used spherical screens with large radius of curvature to maintain uniform electron beam path length. Later designs employed:

- **Curved screens**: Radius matched to deflection geometry (80s–90s consumer CRTs)
- **Flat screens**: Compensation via aspherical screen profile and electronic correction (late 90s–2000s)

The screen angle parameters in Scanline Classic simulate various curvature profiles:

| Configuration | Typical Values | Description |
|---------------|----------------|-------------|
| Bubble CRT (80s TV) | `SCREEN_ANGLE_X/Y`: 60° | Pronounced spherical curvature |
| Trinitron (90s) | `X`: 60°, `Y`: 30° | Cylindrical (vertical curvature only) |
| Flat Trinitron (late 90s) | `X`: 30°, `Y`: 0–15° | Nearly flat with slight horizontal curve |
| True flat (2000s) | `X/Y`: 0° | No geometric curvature |

### Underscan and Overscan

**Overscan**: Deliberate expansion of the raster beyond the visible screen area to hide blanking intervals and edge nonlinearities. Consumer TVs typically overscan 5–10% on each edge.

**Underscan**: Reduction of the active image area within the screen boundaries. Used in:
- Broadcast monitors (to see full transmitted frame including safe areas)
- Computer monitors (to ensure edge pixels are visible)
- High-quality presentations (to minimize geometric distortion visibility)

## Scanning Process

### Raster Formation

The electron beam traces horizontal lines (scanlines) from left to right, then returns to trace the next line downward. This process occurs continuously at the vertical refresh rate.

**Interlaced scanning**: Historically used to reduce flicker on 50–60 Hz displays. The beam traces odd-numbered lines in one field, then even-numbered lines in the next field.

| Mode | Fields per Frame | Lines per Field | Effective Refresh |
|------|------------------|-----------------|-------------------|
| 480i (NTSC) | 2 | 262.5 | 59.94 Hz per field, 29.97 Hz per frame |
| 576i (PAL) | 2 | 312.5 | 50 Hz per field, 25 Hz per frame |
| 480p (progressive) | 1 | 480 | 59.94 Hz |
| 720p | 1 | 720 | 59.94 Hz or 60 Hz |

**Line doubling**: Some CRTs and scalers duplicate low-resolution lines to fill higher-resolution displays, reducing scanline visibility and flicker.

### Blanking Intervals

During horizontal and vertical retrace (beam return), the beam is blanked (turned off) to prevent unwanted illumination. These intervals occupy:

- **Horizontal blanking**: ~16–25% of total line time (includes sync and porch periods)
- **Vertical blanking**: ~5–10% of total frame time (includes VBI data, closed captions, teletext)

The front and back porch parameters in Scanline Classic (`H_FRONT`, `H_BACK`, `V_FRONT`, `V_BACK`) simulate these intervals and affect geometry calculations by defining the active picture area.

## Beam Focus and Resolution

### Spot Size

The electron beam has finite width (spot size), typically 0.3–0.8 mm at the screen surface. Spot size determines:

- **Effective resolution**: Smaller spot yields sharper image
- **Scanline definition**: Larger spot causes adjacent scanlines to blend
- **Brightness**: Smaller spot concentrates energy, increasing phosphor excitation but reducing coverage

The `FOCUS` parameter in Scanline Classic models beam focus by adjusting the Mitchell-Netravali bicubic filter coefficients. Lower values simulate defocused beams with broader, overlapping scanlines; higher values produce sharp, distinct scanlines.

### Resolution Limits

CRT resolution is limited by:

1. **Spot size**: Minimum resolvable detail determined by beam diameter
2. **Phosphor pitch**: Shadow mask or aperture grille spacing
3. **Video bandwidth**: Electronic circuit bandwidth limits horizontal resolution
4. **Deflection precision**: Magnetic field uniformity affects beam positioning accuracy

Typical maximum resolutions:

| CRT Type | Max Resolution | Video Bandwidth | Typical Dot Pitch |
|----------|----------------|-----------------|-------------------|
| 15" SVGA monitor | 800×600 | ~60 MHz | 0.28 mm |
| 19" XGA monitor | 1024×768 | ~80 MHz | 0.26 mm |
| 21" SXGA monitor | 1280×1024 | ~135 MHz | 0.24 mm |
| HDTV (1080i) | 1920×1080i | ~37 MHz (Y) | ~0.6 mm equivalent |

## Color Reproduction

### Phosphor Primaries

Color CRTs use three phosphor types emitting red, green, and blue light. The chromaticity coordinates of these primaries define the CRT's color gamut.

**Common standards**:

| Standard | Red (x,y) | Green (x,y) | Blue (x,y) | White Point | Era/Application |
|----------|-----------|-------------|------------|-------------|-----------------|
| SMPTE-C (BT.601 NTSC) | 0.630, 0.340 | 0.310, 0.595 | 0.155, 0.070 | D65 | NTSC television (post-1987) |
| EBU (BT.601 PAL) | 0.640, 0.330 | 0.290, 0.600 | 0.150, 0.060 | D65 | PAL television |
| BT.709/sRGB | 0.640, 0.330 | 0.300, 0.600 | 0.150, 0.060 | D65 | HDTV, computer monitors |
| P22 (typical) | 0.625, 0.340 | 0.280, 0.605 | 0.150, 0.063 | ~9300K | Consumer CRTs (actual) |

Real CRTs often used "bluer" white points (9300K–11000K) for perceived increased brightness in retail environments, deviating from D65 (6500K) broadcast standards.

### Gamma and Transfer Function

CRTs exhibit a nonlinear relationship between input voltage and light output, approximated by a power function:

$$
L = V^\gamma
$$

where $L$ is luminance, $V$ is normalized voltage, and $\gamma$ typically ranges from 2.35 to 2.5 for CRTs. Video signals are pre-corrected with the inverse transfer function (gamma encoding) to compensate.

The `TRANSFER_FUNCTION` parameter in Scanline Classic selects between:
- **1.0**: Video gamma (~2.2–2.4) for broadcast content
- **2.0**: sRGB transfer function (piecewise, approximates 2.2) for computer graphics

## Monochrome CRTs

Monochrome displays use a single phosphor type, typically:

- **Green** (P31, P1): Most common for computer terminals; reduced eye strain
- **Amber** (P38): Popular in business computing (late 80s)
- **White** (P4): Used in oscilloscopes and some early computers
- **Cyan/blue**: Specialized applications

"Paper white" displays blend multiple phosphors to approximate printed page appearance, improving readability for text-heavy applications.

## References and Further Reading

- ITU-R Recommendation BT.601: Studio encoding parameters of digital television
- ITU-R Recommendation BT.709: Parameter values for HDTV standards
- IEC 61966-2-1: sRGB color space specification
- SMPTE 170M: Composite analog video signal (NTSC)
- Benson, K. Blair, and Jerry Whitaker. *Television Engineering Handbook*. McGraw-Hill, 1992.
- Poynton, Charles. *Digital Video and HD: Algorithms and Interfaces*. Morgan Kaufmann, 2012.