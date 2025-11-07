# Parameters Cheatsheet

A quick reference to common parameters across Scanline Classic presets and shaders. Values shown are typical ranges; see per‑shader `.md` files in `doc/performance/` and the full README for deeper context.

## Display & Scan
- SCAN_TYPE (1=Interlace, 2=Progressive)
  - Use 1 for classic consoles/TV; 2 for most PCs. Affects scanline cadence.
- MAX_SCAN_RATE (lines)
  - Highest expected active lines (e.g., 480, 576, 720, 1080). Controls scanline gap strength and interlace threshold.
- LINE_DOUBLER (0/1)
  - Doubles vertical sampling for low-res sources. Great for progressive PC modes; reduces scanline darkness.
- INTER_OFF (0..1)
  - Interlace odd/even line phase. Usually not critical.

## Geometry & Framing
- DEFLECTION_ANGLE (°)
  - Pincushion strength; 0 = flat. 90–110 mimics many CRTs. Lower for subtle.
- PIN_DISTORTION_TYPE (1=Electrostatic/linear, 2=Magnetic/nonlinear)
  - Linear is stable at small angles; magnetic looks more authentic at large angles.
- SCREEN_ANGLE_H / SCREEN_ANGLE_V (°)
  - Barrel (face) curvature by axis. 0 = flat, 30–60 common. Set one axis for Trinitron‑like.
- TRAPEZOID_STRENGTH, CORNER_STRENGTH, S_CORRECTION_H/V
  - Electronic geometry corrections. Leave 0 for pure CRT distortion; raise slightly to square up edges.
- UNDERSCAN (%)
  - Shrinks view to reduce edge distortion; 5–15% typical for broadcast/PC monitors.
- H_SIZE / V_SIZE; H_POS / V_POS
  - Viewport scaling and offset. Use for framing and minor centering.
- ZOOM
  - Global scale in Basic shader. Keep 1.0 unless needed to fill screen.

## Resampling & Focus
- FOCUS (0..1)
  - Mitchell–Netravali shape (sharpness vs. ringing). ~0.5 = Trinitron‑like, <0.4 softer, >0.6 sharper.

## Subpixel Mask
- MASK_TYPE (1..25; 1=off)
  - Shadow/slot/aperture layouts. Use 24 for a safe Trinitron‑style. Avoid masks on <1080p or dim panels.
- MASK_SCALE (Advanced)
  - Scales mask frequency. 1–2 common; larger = coarser grille.

## Color & Space
- TRANSFER_FUNCTION (1=video/crt, 2=sRGB)
  - Use 1 for video content; 2 for sRGB pipeline content.
- COLOR_MODE (1=Mono A, 2=Mono A+B, 3=RGB)
  - Monochrome and color simulation modes used by phosphor passes.
- LUMINANCE_WEIGHT_[RGB]
  - Grayscale weights for mono pipelines (BT.601: 0.2124/0.7011/0.0866).
- CHROMA_[A/B/C]_(X/Y/WEIGHT)
  - Primary chromaticities and luminance weights. See README’s recommendations.
- SCALE_W (0/1)
  - Auto-scale to the white point; avoid clipping at the expense of absolute brightness.
- COLOR_SPACE (1=sRGB, 2=BT.2020, 3=DCI-P3, 4=Adobe RGB)
  - Output transform for unmanaged displays.

## Signal Chain (Composite / S-Video / RF / Component)
- V_FREQ, V_LINES_PER_FIELD
  - Timing base for carrier and field phase (e.g., 59.94/262.5 NTSC; 50/312.5 PAL).
- H_BLANK_INACTIVE_LEN; H_BLANK_INACTIVE_UNIT (0=px,1=µs,2=%active)
  - Inactive horizontal pixels to compute total pixels per line (phase accuracy).
- SC_FREQ_MODE (0=Auto,1=NTSC,2=PAL,3=Custom) and SC_FREQ (MHz)
  - Subcarrier frequency selection. Prefer explicit NTSC/PAL for stability.
- DISPLAY_BANDWIDTH_Y/C (MHz) and DISPLAY_CUTOFF_ATTEN_[Y/C] (dB)
  - Low-pass Gaussian parameters for demodulated luma/chroma. Higher bandwidth = sharper image and smaller sigma (fewer samples, better performance). Don't go below ~0.6 MHz or cost increases significantly.
- FILTER_SIZE_YC (PAL/RF)
  - Explicit Gaussian half‑radius. Higher = more loop iterations; 8–14 typical.
- COMB_FILTER_TAPS (1..3)
  - Color separation taps; higher removes dot crawl but adds vertical fetches.
- FILTER_ENCODE (PAL/RF)
  - Prefilter before modulation; off for speed.
- FEEDBACK_FILTER_MODE (composite-demod)
  - Removes re‑modulated chroma from luma; extra math cost.

## Phosphor
- PHOSPHOR_LUMA_BYPASS / PHOSPHOR_CHROMA_BYPASS
  - Bypass these passes if you don’t want persistence/tri‑primary mapping.
- PHOSPHORESCENSE_[A/B/C], PHOS_EXP_[A/B/C], PHOS_TRAP_[A/B/C]
  - Persistence decay; adjust A/B/C channels for multi‑phosphor behavior.

## Bandlimit (RGB / YC)
- SYS_/DISPLAY_*_BANDWIDTH_[RGB or YUV] (MHz) and *_CUTOFF_ATTEN_* (dB)
  - Gaussian sigma per channel. Higher bandwidth = sharper and lower sigma (fewer samples, faster). Keep ≥0.6 MHz to avoid excessive blur and high cost.
- *_BANDLIMIT_BYPASS or *_FILTER_BYPASS
  - Skip the convolution stage entirely; big perf win.
- sys-display-rgb-bandlimit.slang
  - Prefer combining system+display bandlimits into one pass where possible.

## Performance tips (quick)
- Displays <1080p or dim: MASK_TYPE=1 (off). At 1440p/4K, try MASK_TYPE=24 and MASK_SCALE=1.5–2.
- Keep COMB_FILTER_TAPS low (1–2). Use notch (COLOR_FILTER_MODE=0) when in doubt.
- Reduce FILTER_SIZE_YC to 8–12 on handhelds. Defaults are chosen to converge fast with early exit.
- Use SVIDEO_FILTER_BYPASS=1 for gameplay, off for captures.
- Geometry: set DEFLECTION_ANGLE/SCREEN_ANGLE modestly or 0 for speed; disable unneeded electronic corrections.

 See also:
 - doc/performance/COMPILE_TIME.md — compile-time hotspots and rationale behind capped loops
 - doc/performance/ — per-shader performance notes and quality profiles
