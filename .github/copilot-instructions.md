# Copilot Instructions for scanline-classic

## Project purpose and architecture
- This repo is a data-driven RetroArch shader/preset build system, not just shader source files.
- Core flow: `presetdata/input/*.json` (preset definitions) + `presetdata/pipelines/*.json` + `presetdata/params/*.json` -> `external/presetgen/presetgen.py` -> `.slangp` presets in `out/presets/<type>` (for example `arcade`, `consumer`, `professional`).
- Shader passes are modular; output-stage bezel integration is wired via pipeline JSON (example: `presetdata/pipelines/misc/post.json` uses `bezel`).

## Critical workflow commands
- Full build (recommended): `python build.py` (or `python build.py --jobs 8 -v`).
- Optional lint-gated build: `python build.py --lint-shaders`.
- Optional strict lint-gated build: `python build.py --lint-shaders --strict-structure`.
- Trimmed distribution build: `python build-trim.py` (expects `out/` already generated).
- Local install helper: `install.bat` copies `out/*` to a user-local RetroArch path.
- Libretro merge helper: `merge.bat` runs build + trim and copies `out-trim/*` into `../slang-shaders/bezel/scanline-classic`.
- Build script auto-prefers `.venv/Scripts/python.exe` on Windows when present.

## Copilot shader authoring expectations
- Before finalizing shader edits in `shaders/*.slang` or `shaders/*.inc`, run `python scripts/lint_shaders.py` and address reported issues for touched files when feasible.
- Preserve shader flow and declaration conventions documented in `doc/SHADER_AUTHORING_CHECKLIST.md`.
- For shader changes, prefer proposing edits that keep lint-compatible ordering and stage structure rather than post-hoc cleanup.

## Where to edit for common tasks
- Edit shader behavior in `shaders/*.slang` and shared includes in `shaders/*.inc`.
- Edit user-facing parameter ranges/defaults in menu include files (example: `shaders/menus/parameters/output-bezel.inc`).
- Edit preset composition in `presetdata/input/**` (example: `presetdata/input/consumer/sfc.json`).
- Edit pipeline stage wiring in `presetdata/pipelines/**`.
- Edit reusable parameter packs in `presetdata/params/**`.

## Project-specific conventions
- Prefer changing source-of-truth inputs (`presetdata`, `shaders`, `scripts`) over generated outputs.
- Do not manually edit generated files in `out/` or `out-trim/` unless explicitly doing a one-off debug check.

## DSP frame contract (`frameh` -> resamplers -> DSP -> resamplers -> `framev`)
- Treat `shaders/frameh.slang` as the canonical start of the framed DSP section. It derives invariant timing/geometry values from uniforms via `shaders/contract.inc` and writes the horizontally framed raster.
- The texture contract from `frameh` to `framev` is intentionally minimal: **RGB carries the signal**, and **alpha carries only mutable per-sample state** (currently `phase_rel_sample`). Do not reintroduce packed metadata texels.
- Reconstruct invariant metadata (`FS_ORIGINAL`, frame width/height, full frame height, interlace state, field, initial field phase, data length) from uniforms with `contract.inc`, not from texture reads.
- `contract_*()` helpers are **vertex-stage setup only** in this pipeline. If a fragment stage needs one of those invariant values, compute it in the vertex shader and pass it as a `flat` varying/attribute.
- Keep `contract_*()` getters **independent**: derive their values from first principles or `modulation.inc`, and do not have one `contract_*()` helper call another.
- `shaders/framev.slang` consumes the `frameh` output and performs vertical centering, zero-stuffing, and scanline blanking from vertex-precomputed state; it should not depend on a metadata texture payload.
- Downstream DSP resamplers such as `shaders/sys-rgb-bandlimit.slang` and `shaders/display-rgb-bandlimit-fir.slang` should derive `Delta`, `Delta_in`, and related timing from `contract_data_length(...)`, `FS_ORIGINAL`, `DSP_WORKING_FS`, and `DSP_OUTPUT_FS`. Use `SourceSize`/`OutputSize` only for final texture-coordinate mapping and output bounds.
- Use `contract_working_sample_rate()` and `contract_output_sample_rate()` instead of open-coding DSP rate fallback/snap logic inside individual shaders. This keeps working/output sample-rate derivation consistent across the pipeline.
- **Sample rate snapping / integral-width contract (2026-04):** The framed 1D signal is stored in 2D using integer row/column decomposition, so `contract_frame_width()` is integral by definition and downstream stored widths must also remain integral. Both resamplers therefore snap their effective sample rates so that `BaseFrameWidth × fs/fs_original` rounds to the nearest integer before computing downstream frame widths. This avoids a row-boundary fractional-sample drift that corrupts FIR coefficients and produces periodic brightness artifacts. The snapping adjustment is < 0.1 % for typical rates. Keep width varyings as `float` for driver portability, and convert to `int` only locally within a shader stage when exact integer arithmetic is needed.

## Current clock-domain presentation model (2026-04)
- Current mental model is: `frameh` -> system resampler (`sys-rgb-bandlimit`) -> DSP / time-domain processing -> output resampler (`display-rgb-bandlimit-fir`), which is the last suitable stage for horizontal deskew before any vertical cross-line presentation sampling -> presentation (`beam`, `mask`, `curve`). This is **not** a typical image-first shader stack.
- `shaders/frameh.slang` now writes a **true clock-domain raster**: each stored line is `ClocksPerLine` samples wide, active source pixels are ZOH-held for `ClockFactor` clock samples, and blanking remains at 1-clock resolution.
- `contract_fs_original()` now represents the stored raster's native sample rate (the pixel clock), and `contract_frame_width()` represents the stored clock-domain width. Use `contract_display_frame_width()` only when a stage needs the intended display/presentation width for aspect or geometry calculations.
- The canonical per-line horizontal carry is `mod(ClocksPerLine, ClockFactor)` clocks. If a presentation-stage shader needs that drift, prefer `contract_line_carry_clocks(...)` and resample the carry into the current sample-rate domain instead of inferring it from texture size.
- `shaders/deskew.slang` is currently a **prototype / diagnostic** carry-correction stage. Because deskew must happen before stages that sample above and below the current line, the preferred long-term home for this correction is a horizontally-only filtering stage such as `shaders/display-rgb-bandlimit-fir.slang`, not `shaders/beam.slang`.
- `shaders/beam.slang` should treat stored clock-domain width and intended display width separately: use `contract_frame_width()` for packed signal mapping and `contract_display_frame_width()` for aspect-ratio / presentation geometry.
- For isolation tests, add source-of-truth debug presets under `presetdata/input/debug/` with matching debug pipelines / params under `presetdata/pipelines/debug/` and `presetdata/params/debug/` rather than mutating main production presets.

## Precision / numeric stability guidance (2026-04)
- Recent PSX 256px debugging showed that **wrapped phase and carry logic can fail catastrophically when computed from large accumulated floats**. A representative failure was in `deskew.slang`: `mod(y * CarryShiftPerLine, CarryCycleWidth)` landed just below an integer cycle boundary at lines like 130 and 150, so `floor()` chose the wrong quotient and produced an almost full-cycle jump instead of zero carry.
- **Prefer integer math for wrapped / cyclic quantities whenever the underlying quantity is logically integral**. Examples: line carry in clocks, modulo cycle counters, row-phase clocks, integer sample bases, and row/column decomposition for texture fetches.
- Current preferred pattern is: **do modular reduction in integer domain first, then convert/rescale to float once at the end**. This is now the recommended approach for `frameh.slang` and `deskew.slang` carry bookkeeping.
- For the resamplers (`sys-rgb-bandlimit.slang`, `display-rgb-bandlimit-fir.slang`), the analog filter design and convolution coefficients should remain floating-point, but precision risk is reduced by splitting large addressing expressions into **whole/integer base + small fractional residual**. Preferred examples include: separate `input_index_int` from `frac_offset`, compute row/column fetch coordinates explicitly, and avoid calling `fract()` or `mod()` on unnecessarily large accumulated floats when a base-plus-residual decomposition is available.
- Practical float32 rule of thumb for resampler addressing: once phase/index magnitudes approach the low millions of samples, sub-sample precision becomes coarse enough that `fract()` / `mod()` on the raw accumulated value can become unreliable. Around ~`2^22` to `2^23` samples (~4.2M to ~8.4M), precision hardening becomes increasingly valuable; by `2^24` (~16.8M), exact integer representation is no longer guaranteed in float32.
- When debugging precision-sensitive artifacts, inspect whether a variable is representing **(a) a genuinely continuous analog quantity** or **(b) an integer-like counter plus a small fractional phase**. Use float math for (a), but strongly prefer integer/base-plus-fraction decomposition for (b).

## Integration and dependency boundaries
- `external/presetgen/` is a vendored dependency used by `build.py`; keep compatibility with its schemas and CLI behavior.
- JSON schema expectations live in `external/presetgen/*.schema.json`; invalid preset/pipeline/param JSON will break generation.
- `build.py` runs generation in parallel (`ThreadPoolExecutor`), so avoid introducing non-thread-safe shared mutable state in scripts.

## Validation expectations for AI edits
- If touching preset generation or scripts, run at least: `python build.py`.
- If changing shader code or shader-related scripts, prefer: `python build.py --lint-shaders`.
- If shader structure/layout rules are relevant, prefer: `python build.py --lint-shaders --strict-structure`.
- If touching trim logic, also run: `python build-trim.py`.
- If touching bezel/glow shader params, verify both source and menu parameter includes stay aligned (for example `bezel-base.slang` push constants vs `output-bezel.inc` pragmas).
- Keep edits minimal and preserve existing naming/layout conventions in shader params and JSON keys.
