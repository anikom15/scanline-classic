# Rendering Pipeline Outline (Famicom Canonical Example)

Copyright (c)  2026  W. M. Martinez.

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.

This document maps the canonical preset `professional/famicom.slangp` to the HDR-programming workflow language from the Slang specification:

`direct processing -> direct display processing -> eotf -> linear light processing -> presentation -> inverse eotf/encoding`

The goal is to make stage boundaries explicit so SDR/WCG/HDR variants remain predictable and maintainable.

## Compact diagram (at a glance)

```text
Input
  │
  ├─ Stage 0 (control plane): menu/passthrough
  │    Pass 0: menu-famicom-sdr
  │
  ├─ 1) Direct processing (signal-domain transport + decode)
  │    Pass 1..9: frameh → famicom-special → filter → composite-iq → iq-filter
  │               → iq-noise → iq-demod → composite-prefilter → composite-demod
  │
  ├─ 2) Direct display processing (display-side analog conditioning)
  │    Pass 10..11: display-rgb-bandlimit → limiter
  │
  ├─ 3) EOTF (virtual display linearization)
  │    Pass 12: crt-linear
  │
  ├─ 4) Linear light processing (optical/display-physics domain)
  │    Pass 13..17: framev → phosphor-trichrome → beam → mask → curve
  │
  ├─ 5) Presentation (tone/gamut policy)
  │    Pass 18: color-sdr
  │
  └─ 6) Inverse EOTF / encoding (output contract)
       Pass 19: bezel-sdr → Backbuffer (SDR R8G8B8A8_UNORM)
```

### Variant overlay (SDR vs WCG vs HDR)

Stages **1–4** are shared (`direct processing -> direct display processing -> eotf -> linear light processing`).
Only the presentation/output tail changes:

```text
Shared trunk (passes 1..17)
  ↓
Stage 5: Presentation policy
  ├─ SDR: tone/gamut fit for Rec.709 SDR target
  ├─ WCG: tone/gamut fit for wide-gamut container (for example BT.2020 / P3)
  └─ HDR: tone/gamut policy for HDR headroom (may be reduced/conditional)
  ↓
Stage 6: Output encoding contract
  ├─ SDR path: inverse EOTF / gamma-referred SDR encode -> R8G8B8A8_UNORM backbuffer
  ├─ WCG path: wide-gamut SDR-style encode (target-dependent)
  └─ HDR path: HDR10 PQ encoding according to final-pass format contract
```

## Why this stage model

A large preset chain is easier to reason about when each operation is assigned to a physical model:

- **Signal model**: source and transport electronics (voltage-domain behavior).
- **Display signal model**: display-side analog conditioning before light emission.
- **Virtual display EOTF**: conversion from display-referred signal to linear light.
- **Light model**: optical/light-domain behavior where energy-like operations are stable.
- **Presentation model**: fit linear working data to output target limits.
- **Output encoding contract**: final transfer-function/output-format write to backbuffer.

At the project level, this structure is a deliberate tradeoff: it keeps the expensive signal and display-physics modeling stable across presets, while limiting SDR/WCG/HDR differences to the presentation/encoding tail. That reduces maintenance churn and keeps variant generation predictable even as output targets evolve.

Terminology mapping to Slang HDR programming is intentional: this document's **direct processing + direct display processing** corresponds to Slang Stage 1 real-world signal modeling, **eotf** corresponds to the virtual display EOTF transition, **linear light processing** corresponds to Slang Stage 2, and **presentation + inverse eotf/encoding** corresponds to Slang Stage 3 plus presentation encoding.

For this project, HDR output terminology is **HDR10 only**. In practice, that means the HDR endpoint is treated as **HDR output (PQ encoding)** under the final-pass output contract, rather than scRGB.

This follows the Slang guidance that complex pipelines should keep conversions intentional and isolate presentation/encoding near the end of the chain.

## Pass-to-stage crosswalk for `famicom.slangp`

### Stage 0: Parameter/menu plumbing (control plane)

- **Pass 0**: `menu-famicom-sdr.slang`
- Purpose: parameter ordering and UI exposure only (passthrough data path).

### 1) Direct processing (signal-domain transport + decode)

Treat source as normalized video signal levels, then model console/transport/decoder behavior.

- **Pass 1**: `frameh.slang` (horizontal framing in signal path)
- **Pass 2**: `famicom-special.slang` (Famicom output waveform synthesis)
- **Pass 3**: `filter.slang` (Famicom filter + DPD behavior)
- **Pass 4**: `composite-iq.slang` (analytic composite baseband extraction)
- **Pass 5**: `iq-filter.slang` (VSB/IQ channel shaping)
- **Pass 6**: `iq-noise.slang` (AWGN/ghost/impulse/jitter injection)
- **Pass 7**: `iq-demod.slang` (IQ demod back to baseband)
- **Pass 8**: `composite-prefilter.slang` (Y/C separation prefilter)
- **Pass 9**: `composite-demod.slang` (composite decode to display RGB-like signal)

**Physical model rationale**: this stage emulates transmission, modulation, noise, and decoder electronics before any light-domain assumptions are made.

### 2) Direct display processing (display-side analog conditioning)

Model the display electronics that condition decoded RGB before light conversion.

- **Pass 10**: `display-rgb-bandlimit.slang` (display RGB amp/bandlimit/cutoff)
- **Pass 11**: `limiter.slang` (voltage limiter + sharpness + colorimetry controls in display-signal context)

**Physical model rationale**: these are still signal-domain operations (gun-drive preparation and safety/rolloff behavior), not optical light transport.

### 3) EOTF (virtual display linearization)

Move from gamma/display-referred signal domain into linear-light working data.

- **Pass 12**: `crt-linear.slang` (BT.1886-style linearization and luminance mapping)

**Physical model rationale**: this is the explicit **virtual display EOTF** boundary. After this pass, subsequent blending/reconstruction should be treated as linear-light operations.

### 4) Linear light processing (optical/display-physics domain)

Operate in linear YrYgYb/light domain for physically meaningful compositing and reconstruction.

- **Pass 13**: `framev.slang` (vertical framing/zero-stuffing; linear-domain raster handling)
- **Pass 14**: `phosphor-trichrome.slang` (phosphor decay/persistence)
- **Pass 15**: `beam.slang` (beam spot/geometry/resample)
- **Pass 16**: `mask.slang` (aperture/slot/shadow mask simulation)
- **Pass 17**: `curve.slang` (curvature warp/filtering in linear space)

**Physical model rationale**: these stages represent beam-light emission, phosphor response, and screen optics where linear-light math reduces brightness and halo artifacts.

### 5) Presentation (target fitting: tone/gamut policy)

Fit linear working data into the intended output-referred target.

- **Pass 18**: `color-sdr.slang`
  - tone-map policy selection
  - gamut mapping/compression policy
  - SDR-target color conversion

**Physical model rationale**: this is where the image is prepared for the delivery target (SDR in this preset), consistent with Slang’s presentation stage guidance.

### 6) Inverse EOTF / encoding (final output contract)

Encode for output and write final backbuffer-compatible result.

- **Pass 19**: `bezel-sdr.slang`
  - output-stage bezel/glow composition
  - final SDR output write (`R8G8B8A8_UNORM` target contract)

**Physical model rationale**: final pass behavior is tied to the output transfer-function contract and backbuffer format. In SDR presets this is gamma/sRGB-referred output; in HDR variants this stage family maps to HDR10 (PQ) contracts.

## Practical design implications

- Keep **Stages 1–4** largely target-agnostic so the same signal/optical model can feed SDR/WCG/HDR variants.
- Keep **Stages 5–6** target-specific (SDR vs WCG vs HDR), minimizing churn when output policy changes.
- Treat EOTF and encoding boundaries as explicit, single-responsibility transitions to avoid hidden gamma mistakes.
- Validate final behavior against output-format expectations for the final pass/backbuffer path.

## Notes for HDR/WCG variants

The same stage topology applies to WCG/HDR presets; only presentation/encoding policy changes:

- **WCG**: wider gamut target fit before final encoding.
- **HDR (HDR10 PQ path)**: presentation may reduce or skip tone/gamut operations depending on headroom, then encode according to the selected final-pass format contract.

This is the main reason to keep early/mid passes in a stable signal/linear-light structure and defer output-specific decisions to the final stages.
