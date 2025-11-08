# Comb Filter Technology in Television: A Brief History

## Pre-1980: Early Composite Video Separation

Before the 1980s, most consumer televisions used simple filtering methods to separate luminance (Y) and chrominance (C) in composite video signals. The most common approach was the use of a notch filter to attenuate the chroma subcarrier frequency, paired with a band-pass filter to extract chroma. These analog filters were cost-effective but suffered from cross-color and dot-crawl artifacts, especially on high-frequency content and color transitions.

## 1980s: Introduction of Line Comb Filters

In the early 1980s, manufacturers began introducing line comb filters, particularly in higher-end sets. These filters exploited the predictable phase relationship of the color subcarrier between adjacent scanlines (180° phase shift in NTSC, 90° in PAL). By combining information from multiple lines, line comb filters improved separation of Y and C, reducing artifacts and enhancing image clarity. However, they were still limited by motion artifacts and could not fully eliminate cross-luminance and cross-color issues.

## 1990s: Digital and Adaptive Comb Filters

The 1990s saw the rise of digital signal processing in consumer electronics. Digital comb filters, often implemented in integrated circuits, allowed for more precise and adaptive separation of Y and C. Motion-adaptive comb filters analyzed both spatial and temporal correlations, switching between line and frame comb modes depending on scene content. This approach minimized artifacts during motion and further improved picture quality, especially in S-VHS and high-end CRT televisions.

## 2000s: 3D Comb Filters and Advanced Processing

By the late 1990s and early 2000s, 3D (spatio-temporal) comb filters became standard in many TVs, including flat-panel displays. These filters used frame memory to compare multiple fields or frames, enabling sophisticated motion detection and adaptive filtering. The result was near-complete elimination of dot-crawl and cross-color artifacts, with image quality approaching that of true component video. Advanced comb filter technology was also integrated into video processors and upscalers, supporting legacy composite sources in modern displays.

## Legacy and Modern Context

While comb filters are less relevant in the era of digital and component video, their development was crucial for maximizing the quality of analog composite sources. The evolution from simple analog filters to complex digital and adaptive systems reflects broader trends in television technology, balancing cost, complexity, and image fidelity over several decades.

## Technical Overview: Comb Filter Implementations

### Analog Notch and Band-Pass Filters
Early comb filter designs relied on analog circuitry. The notch filter attenuated the chroma subcarrier frequency (e.g., 3.58 MHz for NTSC), while a band-pass filter extracted chroma information. These filters were typically implemented using LC (inductor-capacitor) networks or surface acoustic wave (SAW) devices. The simplicity of this approach made it cost-effective, but it could not fully separate Y and C, resulting in visible artifacts.

**Reference:**
- Whitaker, Jerry C. "The Standard Handbook of Video and Television Engineering." McGraw-Hill, 2003.

### Line Comb Filters
Line comb filters exploit the phase relationship of the color subcarrier between adjacent scanlines. In NTSC, the subcarrier phase inverts every line, allowing the filter to add or subtract signals from consecutive lines to cancel chroma or luma components. Analog implementations used delay lines (often glass or acoustic) to store one or more lines for comparison. Digital line comb filters later replaced analog delay lines with memory buffers, improving reliability and precision.

**Reference:**
- Poynton, Charles. "Digital Video and HDTV: Algorithms and Interfaces." Morgan Kaufmann, 2003.

### Frame (2D) and 3D Comb Filters
Frame comb filters (2D) use information from both spatial (line) and temporal (frame) domains. By comparing pixels across multiple frames, these filters can better distinguish between stationary and moving content, reducing motion artifacts. 3D comb filters extend this approach by analyzing several fields or frames, using frame memory and motion detection algorithms to adaptively blend line and frame comb outputs. These are typically implemented in digital signal processors (DSPs) and require significant memory and computational resources.

**Reference:**
- Tektronix, Inc. "NTSC and PAL Video: Comb Filter Technology." Application Note, 1998.

### Motion-Adaptive Comb Filters
Motion-adaptive comb filters dynamically switch between line, frame, and notch filtering based on detected motion and scene content. When motion is detected, the filter reduces reliance on temporal information to avoid introducing motion artifacts. These filters are common in high-end CRTs, S-VHS decks, and modern video processors. Implementation involves real-time analysis of pixel differences and adaptive blending of filter outputs.

**Reference:**
- Jack, Keith. "Video Demystified: A Handbook for the Digital Engineer." Newnes, 2007.

### PAL-Specific Delay Line Filters
PAL systems use a 1H delay line to exploit the phase alternation of the chroma signal. By averaging the chroma from the current and previous lines, PAL delay line filters cancel phase errors and improve color stability. These were originally implemented with analog glass delay lines and later with digital memory.

**Reference:**
- Watkinson, John. "The Art of Digital Video." Focal Press, 2013.

---
Comb filter technology evolved from simple analog circuits to sophisticated digital and adaptive systems, each stage improving the separation of luminance and chrominance and reducing artifacts. For further reading, see the references above and the technical documentation in this repository.

## Analytical Deep Dive: Notch and Comb Filter Design in composite-mod-prefilter.slang

### Modulated Gaussian Notch and Bandpass Filters
The shader `composite-mod-prefilter.slang` implements a modern, analytical approach to simulating ideal notch and bandpass filters for composite video separation. Instead of using fixed analog filter shapes, it employs modulated Gaussian functions to approximate the frequency response of a band-stop (notch) filter centered on the color subcarrier, and a bandpass filter for chroma extraction.

**Notch Filter Design:**
- The notch filter is realized by convolving the input signal with a Gaussian envelope modulated by a cosine at the subcarrier frequency. This creates a smooth, symmetric attenuation around the chroma subcarrier, with the width and depth controlled by user parameters (`NOTCH_WIDTH`, `NOTCH_CENTER_ATTEN_DB`, `NOTCH_EDGE_ATTEN_DB`).
- The Gaussian window ensures minimal ringing and a well-behaved impulse response, while modulation targets the chroma subcarrier precisely. This approach allows for flexible tuning and avoids the limitations of analog LC or SAW filters, which may have asymmetric or non-ideal responses.
- The filter's parameters are exposed for real-time adjustment, enabling users to balance luma preservation against chroma suppression according to content and preference.

**Bandpass Filter Design:**
- Chroma is extracted using a similar modulated Gaussian, but with a bandpass configuration. The filter passes frequencies near the subcarrier, isolating chroma while minimizing luma leakage. The width and gain are tunable, and the Gaussian shape provides a smooth roll-off.

**References:**
- See the implementation in `src/composite-mod-prefilter.slang` and supporting functions in `src/bandlimit.inc` and `src/modulation.inc`.

### Comb Filter Operation
The comb filter in `composite-mod-prefilter.slang` mimics the physical principle of line comb filters found in analog and digital TVs. It samples previous scanlines, applies phase correction to account for subcarrier drift, and combines signals to cancel chroma or luma components. The number of taps (lines) is configurable, allowing for classic 2-line or 3-line comb filtering.

- The shader reconstructs the composite signal for each tap, applies phase correction, and blends the results according to the selected filter mode (`COLOR_FILTER_MODE`).
- This digital implementation parallels the delay-line comb filters used in real TVs, but with precise phase control and the ability to mix comb and notch outputs for optimal separation.

### Relation to Physical Comb Filters
While the shader's comb filter logic is inspired by physical delay-line filters, it benefits from the precision and flexibility of digital processing. Analog comb filters are limited by physical tolerances, group delay, and noise, whereas the shader can apply exact phase corrections and tap weights. The result is a highly controllable and artifact-resistant separation of Y and C, suitable for emulation and video processing.

### Experimental Adaptive Comb Filter Alternative
For advanced scenarios, the repository includes `adaptive-comb-test.slang`, an experimental shader that adaptively blends between notch and comb filtering based on real-time correlation analysis. This approach is analogous to motion-adaptive comb filters in late-model TVs, dynamically selecting the best separation method for each pixel depending on scene content and motion. See `src/adaptive-comb-test.slang` for details.
