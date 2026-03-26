# 3DO Video and Interpolation Theory

Copyright (c)  2026  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

This document describes the theory and practical intent behind the 3DO-specific shader path in Scanline Classic, centered on `3do-interpolation.slang`. The goal is not to emulate a full 3DO video DAC or display chain by itself, but to recover plausible subpixel structure from low-resolution source content before later composite/S-Video/RF and CRT stages are applied.

In the preset pipeline, this interpolation stage sits early and is followed by signal-domain processing. For example, typical 3DO composite presets route through:

1. `sys/3do-special*.json` (`3do-interpolation`)
2. digital-composite conversion stages
3. display and post stages

That placement reflects a design assumption: interpolation choices should happen before analog-domain bandwidth limiting and chroma/luma interactions.

## Historical Background (Why 3DO Needs a Special Stage)

3DO software often targets low internal resolutions (commonly around 320×240) with a mix of FMV, software-rendered 3D, and 2D assets. Real hardware output then encounters scaling, filtering, and the final display path (composite, S-Video, RF, monitor path), each adding their own blur/aliasing tradeoffs.

Modern emulators can expose very sharp pixel boundaries that are not always representative of period display output. Conversely, plain bilinear interpolation can over-smooth edges and lose intentional directional detail. A specialized interpolation pass attempts to bridge that gap by preserving edge intent while reducing blockiness.

## Shader Intent and Functional Model

`3do-interpolation.slang` offers three modes:

- **Nearest**: Pass-through sampling for pixel-exact block edges.
- **Bilinear**: Standard 2×2 weighted interpolation.
- **Original (special)**: Direction-aware interpolation based on corner-weight quadrants.

The “original/special” mode is the 3DO-specific behavior this document focuses on.

### Corner-Quadrant Concept

The shader models each source texel as having a preferred corner among four possibilities:

- top-left
- top-right
- bottom-left
- bottom-right

Those corners can be provided in two ways:

1. **Encoded mode** (`FAKE_CORNER_WEIGHTS = 0`): read from alpha bits.
2. **Predicted mode** (`FAKE_CORNER_WEIGHTS = 1`): inferred from local luminance gradients.

The predicted mode estimates directional intent by comparing center-pixel luminance to left/right/top/bottom neighbors and biasing toward brighter directions.

### Distance-Weighted Neighbor Blend

When the current sample location falls in a quadrant that does not match the source texel’s preferred corner, the shader selectively pulls neighboring texels from:

- vertical direction,
- horizontal direction,
- diagonal direction,

depending on `SPECIAL_INTERP_V` and `SPECIAL_INTERP_H`.

Neighbor contributions are weighted inversely by distance to each neighbor’s preferred corner:

$$
w_i \propto \frac{1}{d_i + \epsilon}
$$

with normalization:

$$
\hat{w}_i = \frac{w_i}{\sum_j w_j}
$$

The final output mixes original texel color and blended result with a fixed compromise factor (50/50 in the both-directions path), keeping the result stable while still reducing block transitions.

### Practical Interpretation

This is best viewed as a **directional reconstruction heuristic**, not a strict hardware decoder model. It tries to preserve edge orientation and corner continuity that plain bilinear filtering would smear.

## Parameters and Their Real-World Analogs

- `INTERPOLATION_MODE`: chooses baseline reconstruction model (none, linear, directional heuristic).
- `FAKE_CORNER_WEIGHTS`: switches from externally-provided corner metadata to luminance-based estimation.
- `SPECIAL_INTERP_H` / `SPECIAL_INTERP_V`: limits reconstruction to horizontal/vertical directions, useful for tuning texture softness versus edge stability.

These controls map to artistic and perceptual goals rather than single measurable hardware knobs; they are intended to match “how the content feels” on period displays.

## Limits and Tradeoffs

1. **No true per-title hardware metadata**: the corner model is inferred or packed; original console internals do not expose such a direct signal.
2. **Heuristic luminance inference**: gradient-based corner prediction can misread noisy or low-contrast textures.
3. **Not a full analog path model**: RF/composite artifacts are handled in later pipeline stages, not by this shader.

Because of these limits, the 3DO interpolation stage should be tuned together with subsequent composite and CRT parameters, not in isolation.

## Relationship to Other Theory Documents

- `ntsc.md`, `pal.md`, and `comb-filter.md` explain downstream analog behavior once interpolated output enters composite-domain processing.
- `rendering.md` explains why this stage appears early in the pipeline before display-light simulation.

## References

1. Wikipedia, “3DO Interactive Multiplayer” (hardware family overview and video-output context):
   - https://en.wikipedia.org/wiki/3DO_Interactive_Multiplayer
2. RetroRGB, “3DO” (practical signal-path and hardware-output notes):
   - https://www.retrorgb.com/3do.html
3. The 3DO Company development documentation (system programmer and hardware manuals, development-era architecture context).
4. Scanline Classic source:
   - `shaders/3do-interpolation.slang`
   - `presetdata/pipelines/sys/3do-special.json`
   - `presetdata/pipelines/sys/3do-special-pal.json`
   - `presetdata/pipelines/sys/3do-special-240p.json`
