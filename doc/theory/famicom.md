# Famicom/NES Video Synthesis Theory

Copyright (c)  2026  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

## Overview

This document explains the Famicom-specific shader path in Scanline Classic, primarily implemented by:

- `famicom-special.slang` (waveform-domain composite/RF source synthesis)
- `famicom-rgb.slang` (palette-index-to-RGB path using RP2C03/2C03-era palette data)

Unlike generic RGB pipelines, these shaders model behavior closer to the console’s internal color code generation and analog output characteristics. The intent is to start from encoded palette/state information and reconstruct either:

1. a voltage-like waveform for downstream composite/RF decode stages, or
2. an RGB monitor path for arcade/Sharp-style use cases.

## Historical Background

The Famicom/NES Picture Processing Unit (PPU) does not operate like a modern framebuffer with arbitrary 24-bit RGB. Instead, it outputs color information through phase-related color codes and discrete luminance levels, with additional emphasis bits altering output.

Consumer systems then route this through RF/composite encoding and TV decoding, introducing characteristic artifacts (dot crawl, hue shifts, chroma blur, decoder-dependent color differences). Professional or modified paths (e.g., arcade RP2C03 families, RGB monitor setups, Sharp C1 class workflows) can bypass parts of that chain.

A key design choice in Scanline Classic is to represent these as separate pipelines:

- **Famicom RF/composite path**: synthesize waveform first, then run composite-domain filters and demodulation.
- **Famicom RGB path**: decode palette index directly to RGB while preserving packed emphasis behavior.

## `famicom-special.slang`: Waveform Reconstruction

### Packed Input Interpretation

The shader expects source RGB channels to carry packed logical fields:

- `R`: color code (0–15)
- `G`: luminance level (0–3)
- `B`: emphasis bits (0–7)

This packed representation is unpacked per pixel and transformed into voltage-domain states.

### IRE-Level Tables

The shader contains explicit low/high voltage tables (in IRE units) for each color/level combination, including separate emphasized variants. Values include sync-adjacent and active-image ranges and are normalized for downstream processing.

Conceptually, each pixel emits a two-level waveform, with phase-gated high/low switching:

$$
V(t) \in \{V_{\text{low}}(c,\ell,e),\;V_{\text{high}}(c,\ell,e)\}
$$

where $c$ is color code, $\ell$ is luminance level, and $e$ is emphasis state.

### Phase Construction and 12-Step Color Cycle

The fragment stage builds phase in fractional-cycle space using line index, pixel position, field phase, and a system offset. It then maps phase into a 12-step index and applies a half-cycle gate for the selected color.

This matches the common NES/Famicom modeling pattern where chroma emerges from phase relationships rather than direct U/V component storage.

### Emphasis Bit Gating

Emphasis bits are modeled as phase-selective attenuation behavior (except protected colors E/F path), reflecting hardware-era observations that emphasis is not a simple per-channel multiply in composite space.

In practical terms, emphasis modifies waveform level tables before final high/low output selection, which later affects decoded hue and saturation.

### PAL Toggle for Phase Alternation

`PAL` support modifies phase sign behavior line-to-line and applies a PAL-specific offset. This allows the same synthesis model to feed PAL-like downstream decoding in appropriate pipelines (e.g., NES EU variants).

## `famicom-rgb.slang`: Palette Decode Path

`famicom-rgb.slang` is designed for RGB-output scenarios, using an embedded 64-color table (`PALETTE_2C03`) consistent with RP2C03/2C03-family style output.

Pipeline behavior:

1. unpack color/level/emphasis from packed source channels,
2. compute palette index as `level * 16 + color`,
3. fetch RGB triplet from the static table,
4. apply emphasis modifier (`apply_emphasis_max`) and output normalized RGB.

This path bypasses composite synthesis/demod artifacts and is suitable for arcade/monitor interpretations (for example, PlayChoice/Nintendo VS/Sharp RGB-oriented configurations in preset definitions).

## Pipeline Integration in Scanline Classic

### Composite/RF-oriented presets

`famicom-special` appears in pipelines such as:

- `presetdata/pipelines/sys/famicom-composite.json`
- `presetdata/pipelines/sys/famicom-rf.json`
- `presetdata/pipelines/sys/nes-eu-composite.json`
- `presetdata/pipelines/sys/nes-eu-rf.json`

These then proceed through composite-IQ/filter/noise/demod stages and display-domain processing.

### RGB-oriented presets

`famicom-rgb` appears in:

- `presetdata/pipelines/sys/famicom-rgb.json`
- `presetdata/pipelines/sys/famicom-svideo.json`

and in corresponding preset inputs (for example `professional/famicom-c1.json` and `arcade/nvs.json`).

## What These Shaders Attempt to Accomplish

1. **Preserve source-domain logic**: start from console-like color code and level semantics instead of assuming pre-decoded linear RGB.
2. **Model output-path differences**: separate waveform/composite behavior from RGB monitor behavior.
3. **Expose meaningful controls**: allow timing, bandwidth, and differential phase distortion tuning in ways that map to known hardware-era phenomena.
4. **Support regional behavior**: include PAL/NTSC phase handling where relevant.

## Limits and Tradeoffs

- The waveform model is intentionally compact and deterministic; it cannot capture every revision-specific analog nuance across all PPU variants.
- The RGB table path represents one hardware-family interpretation (2C03 style), not a universal “true NES palette.”
- Real-world output depends strongly on downstream decoder, display calibration, and cabling path; presets should be tuned as complete chains.

## References

1. NESdev Wiki (hardware behavior and community measurements):
   - https://www.nesdev.org/wiki/PPU_palettes
   - https://www.nesdev.org/wiki/Colour_emphasis
   - https://www.nesdev.org/wiki/NTSC_video
2. FirebrandX NES palette notes and comparisons:
   - http://www.firebrandx.com/nespalette.html
3. Wikipedia, “Nintendo Entertainment System” (regional hardware/video context):
   - https://en.wikipedia.org/wiki/Nintendo_Entertainment_System
4. Scanline Classic source:
   - `shaders/famicom-special.slang`
   - `shaders/famicom-rgb.slang`
   - `shaders/menus/parameters/famicom.inc`
   - `presetdata/pipelines/sys/famicom-composite.json`
   - `presetdata/pipelines/sys/famicom-rf.json`
   - `presetdata/pipelines/sys/famicom-rgb.json`
