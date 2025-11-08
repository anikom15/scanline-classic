# Gaussian Low-Pass Filter Design Guide

## Overview

The shaders in this collection use Gaussian filters for anti-aliasing and bandwidth limiting. This document explains the mathematical foundation, design principles, and practical parameter selection for the `sigma_tb()` function in `src/modulation.inc`.

## Theory

### Time-Domain Gaussian Kernel

The Gaussian filter kernel in the spatial (time) domain is:

$$w(x) = \exp\left(-\frac{x^2}{2\sigma^2}\right)$$

where:
- $x$ is the sample offset in pixels (texels)
- $\sigma$ is the standard deviation in pixels

### Frequency Response

The magnitude response in the frequency domain is:

$$|H(f)| = \exp(-2\pi^2 \sigma^2 f^2)$$

where $f$ is frequency in cycles per pixel.

### Design Equation

Given a desired attenuation $A$ (in dB) at cutoff frequency $f_c$, we solve for $\sigma$:

1. Define the linear magnitude ratio at cutoff: $a = 10^{-A/20}$
2. From the frequency response: $a = \exp(-2\pi^2 \sigma^2 f_c^2)$
3. Taking the natural logarithm: $\ln a = -2\pi^2 \sigma^2 f_c^2$
4. Solving for $\sigma$:

$$\sigma = \frac{\sqrt{-2 \ln a}}{2\pi f_c} = \frac{\sqrt{(A/10) \ln 10}}{2\pi f_c}$$

The simplified form avoids computing very small values and is more numerically stable:

$$\sigma = \frac{\sqrt{0.23026 \cdot A}}{2\pi f_c}$$

where $0.23026 \approx \ln(10)/10$.

## Attenuation Scaling

For a Gaussian filter designed with attenuation $A_c$ at cutoff $f_c$, the attenuation at any frequency $f$ scales quadratically:

$$A(f) = A_c \cdot \left(\frac{f}{f_c}\right)^2$$

**Example:** If $f_c = 6.75$ MHz with $A_c = 24$ dB:
- At 6.75 MHz: 24 dB
- At 8.0 MHz: 24 × (8.0/6.75)² = 33.7 dB
- At 10.0 MHz: 24 × (10.0/6.75)² = 52.7 dB

## Cascaded Stages

When cascading multiple Gaussian filters, their responses combine:

**Linear scale:** magnitudes multiply
$$|H_{\text{total}}| = |H_1| \times |H_2| \times \cdots$$

**dB scale:** attenuations add
$$A_{\text{total}} = A_1 + A_2 + \cdots$$

For identical stages:
$$A_{\text{total}}(f) = N \cdot A_c \cdot \left(\frac{f}{f_c}\right)^2$$

The combined standard deviation is:
$$\sigma_{\text{total}} = \sqrt{\sigma_1^2 + \sigma_2^2 + \cdots}$$

For $N$ identical stages:
$$\sigma_{\text{total}} = \sqrt{N} \cdot \sigma$$

## Anti-Aliasing Design Strategy

### Key Concept

**Do not set $f_c$ at Nyquist!** The Gaussian's gentle roll-off means setting $f_c = f_{\text{Nyquist}}$ provides minimal alias protection.

Instead, use one of these approaches:

1. **Set $f_c$ below Nyquist** with modest attenuation (3–6 dB)
2. **Set $f_c$ at or above Nyquist** with high attenuation (20–40 dB)
3. **Use cascaded stages** to achieve steep roll-off with moderate per-stage blur

### Target Attenuations

For digital sampling at rate $f_s$ (Nyquist $f_N = f_s/2$):

| Application | Target at Nyquist | Typical Design |
|-------------|-------------------|----------------|
| 8-bit ADC | 40–50 dB | $f_c = 0.8f_N$, $A_c = 25$ dB |
| 10-bit ADC | 50–60 dB | $f_c = 0.75f_N$, $A_c = 30$ dB |
| 12-bit ADC | 60–70 dB | $f_c = 0.7f_N$, $A_c = 35$ dB |
| Light touch AA | 20–30 dB | $f_c = f_N$, $A_c = 20$ dB |

### Design Formulas

Given target attenuation $A_N$ at Nyquist $f_N$:

**Option 1: Fix attenuation $A_c$, solve for cutoff**
$$f_c = f_N \cdot \sqrt{\frac{A_c}{A_N}}$$

**Option 2: Fix cutoff $f_c$, solve for attenuation**
$$A_c = A_N \cdot \left(\frac{f_c}{f_N}\right)^2$$

## Practical Examples

### Example 1: Single-Stage Light AA (13.5 MHz sampling)

**Goal:** Minimal blur, basic alias protection

**Parameters:**
- Sampling rate: $f_s = 13.5$ MHz
- Nyquist: $f_N = 6.75$ MHz
- Cutoff: `cutoff_freq_mhz = 6.75`
- Attenuation: `cutoff_atten_db = 24.0`

**Result:**
- At 6.75 MHz (Nyquist): 24 dB
- At 8.0 MHz: 33.7 dB
- $\sigma \approx 0.75$ pixels (very tight kernel)

**Assessment:** Minimal passband blur, marginal AA. Good for pre-filtered content.

### Example 2: Two-Stage Strong AA (13.5 MHz sampling)

**Goal:** 40 dB attenuation at 8 MHz

**Parameters per stage:**
- Cutoff: `cutoff_freq_mhz = 8.0`
- Attenuation: `cutoff_atten_db = 20.0`

**Combined result:**
- At 8.0 MHz: 40 dB ✓
- At 6.75 MHz (Nyquist): 28.4 dB
- At 10.0 MHz: 62.5 dB
- Per-stage $\sigma \approx 0.58$ pixels
- Combined $\sigma_{\text{total}} \approx 0.82$ pixels

**Assessment:** Sharp filter with excellent alias protection above 8 MHz. Suitable for 8-bit ADC with content extending to 7–8 MHz.

### Example 3: Conservative AA for Wide Bandwidth

**Goal:** 40 dB at Nyquist, preserve maximum passband

**Single-stage parameters:**
- Cutoff: `cutoff_freq_mhz = 5.4`
- Attenuation: `cutoff_atten_db = 25.6`

**Result:**
- At 5.4 MHz: 25.6 dB
- At 6.75 MHz (Nyquist): 40 dB ✓
- $\sigma \approx 1.2$ pixels (moderate blur)

**Assessment:** Moderate passband attenuation, strong Nyquist protection. Good for unfiltered analog sources.

## Shader Implementation

### Using `sigma_tb()`

```glsl
#include "modulation.inc"

// Compute timebase configuration
TimebaseConfig tb = compute_timebase(
    float(FrameCount),
    vTexCoord,
    OriginalSize.x,
    OutputSize.x,
    V_FREQ,
    V_LINES_PER_FIELD,
    SHORTEN_ODD_FIELD_TIME,
    SC_FREQ_MODE,
    SC_FREQ,
    H_BLANK_INACTIVE_LEN,
    H_BLANK_INACTIVE_UNIT);

// Calculate sigma for desired cutoff and attenuation
float sigma = sigma_tb(tb, cutoff_freq_mhz, cutoff_atten_db);

// Apply horizontal Gaussian convolution
vec3 filtered = bandlimit_convolve_gaussian_x(vTexCoord, OutputSize, Source, vec3(sigma));
```

### Two-Stage Cascade

```glsl
// Pass 1: First stage
float sigma1 = sigma_tb(tb1, 8.0, 20.0);
vec3 stage1_output = bandlimit_convolve_gaussian_x(vTexCoord, OutputSize, Source, vec3(sigma1));

// Pass 2: Second stage (operates on stage1_output)
float sigma2 = sigma_tb(tb2, 8.0, 20.0);
vec3 final_output = bandlimit_convolve_gaussian_x(vTexCoord, OutputSize, Stage1, vec3(sigma2));

// Result: 40 dB at 8 MHz
```

## Limitations and Considerations

### Kernel Truncation

The horizontal convolution loops in `bandlimit.inc` use up to 32 taps per side with early exit when weights fall below threshold (1/510).

**When $\sigma$ is large** (typically $\sigma > 12$ pixels), the Gaussian tail extends beyond 32 samples, causing:
- Premature truncation
- Reduced actual attenuation vs. design target
- Energy normalization error

**Guideline:** Keep $\sigma \lesssim 10$ pixels for accurate filter response. Use cascaded stages rather than single high-$\sigma$ filters.

### Frequency vs. Spatial Domain

The `cutoff_freq_mhz` parameter specifies **analog frequency** (MHz). The function converts this to cycles-per-pixel using:

$$f_c(\text{cycles/pixel}) = f_c(\text{Hz}) \times \text{pixel\_time\_px}$$

For accurate results, ensure `tb.pixel_time_px` is properly computed by `compute_timebase()` based on your output resolution and timing parameters.

### Gaussian Phase Response

Gaussian filters are **zero-phase** (symmetric impulse response), meaning:
- No phase distortion
- No group delay variation with frequency
- Excellent for preserving waveform shape

This is why Gaussians are preferred for video processing despite their gentle roll-off compared to sharper filters (windowed-sinc, Chebyshev, etc.).

## Quick Reference Table

| $f_c / f_N$ | $A_c$ (dB) | $A_N$ (dB) | Passband | Alias Protection | Use Case |
|-------------|------------|------------|----------|------------------|----------|
| 1.0 | 20 | 20 | Excellent | Weak | Light touch, pre-filtered |
| 1.0 | 24 | 24 | Excellent | Moderate | Minimal blur, basic AA |
| 0.9 | 20 | 25 | Very good | Good | Balanced |
| 0.8 | 25 | 40 | Good | Strong | 8-bit ADC |
| 0.75 | 30 | 56 | Moderate | Very strong | 10-bit ADC |

**Two-stage alternative:** $f_c = f_N$, $A_c = 20$ dB per stage → $A_N = 40$ dB combined with $\sigma_{\text{total}} \approx 1.0$ pixel.

## Further Reading

- `src/modulation.inc` - Implementation of `sigma_tb()` and `compute_timebase()`
- `src/bandlimit.inc` - Gaussian convolution implementation (`bandlimit_convolve_gaussian_x()`)
- `doc/theory/crt.md` - CRT display bandwidth characteristics
- `doc/PARAMETERS.md` - User-facing parameter descriptions

---

*Last updated: 2025-11-07*
