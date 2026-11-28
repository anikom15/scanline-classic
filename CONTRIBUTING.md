# Contributing Handbook

Thank you for contributing to Scanline Classic.

This repository is a **data-driven RetroArch shader/preset build system**. Contributions are expected to preserve deterministic generation, schema compatibility, and shader structure/lint quality.

## 1) Repository model and source of truth

Scanline Classic is generated from source inputs:

- `presetdata/input/*.json` (+ nested folders)
- `presetdata/pipelines/*.json`
- `presetdata/params/*.json`
- `shaders/*.slang` and `shaders/*.inc`
- `scripts/*.py`

Generated output folders are:

- `out/`
- `out-trim/`

### Standard

- Edit source-of-truth files only.
- Do **not** manually edit files in `out/` or `out-trim/` except one-off debugging.

## 2) Local environment

### Required

- Python 3.12 recommended (CI-aligned).
- Dependencies:

```bash
python -m pip install -r external/presetgen/requirements.txt
```

### Optional

- Local `.venv` at repo root. `build.py` will prefer `.venv/Scripts/python.exe` on Windows when present.

## 3) Build and validation commands

Run from repository root.

### Core build

```bash
python build.py
```

### Build with lint gate

```bash
python build.py --lint-shaders
```

### Build with strict structure gate

```bash
python build.py --lint-shaders --strict-structure
```

### Shader lint only

```bash
python scripts/lint_shaders.py
```

### Strict shader lint only

```bash
python scripts/lint_shaders.py --strict-structure
```

### SFC contract timing tests

```bash
python -m unittest discover -s tests -p "test_*timing*.py" -v
```

These tests require `g++` and execute selected functions extracted from the
shader in a C++ compatibility harness; they do not execute GLSL on a GPU.
They resolve the SFC timing profile from the RGB and PAL composite presets,
with and without the PAL-M option. They supply source dimensions and both exact
and rounded frontend field rates explicitly. They also check the Famicom's NTSC
progressive timing using legacy parameters.
Expected timing and phase values are derived independently from the clock
counts in the [SFC timing reference](https://www.scanlineclassic.com/theory/timings.html);
the rates on that page are rounded and may include typographical errors.
The interlaced geometry assertions check the current field's line count and
the combined frame height. Phase expectations use exact clock
ratios and assume field count zero is the first reference field: even for NTSC
and PAL-M, odd for PAL. PAL-M's 6:1 pixel-clock-to-carrier ratio determines its
clock from the given carrier frequency. The reference's displayed rates appear
to use the rounded clock and can differ in their last digits from rates derived
from the 6:1 ratio. PAL-M timings are extrapolated in the reference, not measured.
Tests include reversed field order, nonzero phase offsets, mode changes, and
long-running field counts. These cases do not validate the frame texture or
prove that every timing parameter combination is supported. Additional
N64, Mega Drive and 3DO cases compare phase against their preset's stated
decimal clock values, not independently verified hardware timings.

Timing profiles are defined in `presetdata/timing-profiles.json`; `build.py`
validates them and generates `out/shaders/timing-profiles.inc`. Profile ID 0
retains the legacy timing parameters. SFC uses ID 1, which selects PAL at
55 Hz or below and NTSC above 55 Hz; the PAL-M option remaps only NTSC. The
profile fixes timing values independently of the reported rate. PSX uses ID 2
and the same 55 Hz NTSC/PAL boundary. Its NTSC field alternates 3,412 and
3,413 clocks per line, starting with 3,412 on line 1; PAL lines are 3,405
clocks. Interlace is inferred from source height, so cropping or overscan
across the field-height threshold is ambiguous. Other systems have not yet
been migrated to profiles.
Each `pixel_clock_multiplier` is a positive `[numerator, denominator]` ratio
to the subcarrier; reduced components are at most 2^24 and the ratio at most
500. Phase calculation uses the exact reciprocal rather than a decimal
approximation.

Each timing mode supplies even and odd physical field line counts in
`field_lines`. For SFC NTSC interlace these are 263 even and 262 odd.
`raster` specifies the interlace detection threshold. The shaders use the
selected field's line count for geometry and `field_clocks` for phase.
It also specifies `vertical_sync_lines`, `vertical_back_porch_lines`,
`horizontal_sync_cycles`, and `horizontal_back_porch_cycles`. SFC uses 3 sync
lines followed by 15 blank lines, and 100 sync clocks followed by 152 blank
clocks. Sync is asserted throughout the vertical pulse and at the start of each
line; the rest of each porch is blank but not sync. Picture starts at line 19
and clock 252 (zero-based). A 1,024-clock picture in a 1,364-clock line has
88 trailing blank clocks. Unused picture lines and additional field lines
remain blank at the bottom. Presentation centers the active area independently
of storage padding. Profile 0 retains its legacy approximate sync.
`line_overrides` records exceptional line lengths by scan type, field parity,
and one-based line number, with line 1 at the start of vertical sync. SFC
NTSC/PAL-M progressive odd line 259 has 1,360 clocks; PAL interlaced odd line
18 has 1,368. Profile line numbers need not match the timing reference's
numbering. The generator checks
overridden fields against `field_clocks`, and the packed signal follows those
line boundaries until the display resampler maps it to presentation rows.
The resampler corrects the fractional displacement between the physical
H-sync boundary and the first stored sample of each presentation row. The
debug deskew bypass leaves those rounded boundaries uncorrected.
PSX's nominal picture starts on line 13 after one vertical sync and 11
back-porch lines. Horizontal sync is 100 clocks; the front porch is 100 clocks
on the first line and 101 on the longer NTSC lines, keeping the picture aligned
to H-sync. Nominal heights are 240 NTSC or 288 PAL lines. Source images are
centered on the nominal picture and clipped at physical field boundaries.
Horizontal mode inference chooses the largest supported width not exceeding
the reported width (256 minimum); cropping or overscan can select the wrong
mode. See `doc/TIMING_PROFILES_PLAN.md` for the supported widths, field
patterns and detection thresholds.
Fractional-clock field durations are supported for phase, not yet as a general
sub-clock storage format.
Durations are pixel-clock counts: either positive integers
or `[numerator, denominator]` pairs. Reduced numerators must be less than
2^52 and denominators at most 2^20. `first_field` specifies the field-zero
parity; `FIELD_ODD` reverses it. Tests include equal half-line fields and
fractional clocks at long field counts. The older `compute_timebase` paths
still use approximate legacy phase and the profile's `field_adjustment`
compatibility flag, rather than these explicit durations.

### Trim distribution

```bash
python build-trim.py
```

## 4) CI expectations

Current CI lint gate (`.github/workflows/shader-lint.yml`) runs:

- Default: `python build.py --lint-shaders --jobs 1`
- Strict for pushes to `master` and PRs targeting `master`:
  - `python build.py --lint-shaders --strict-structure --jobs 1`

### Standard

Before requesting review, contributors should run the strict command locally for shader/pipeline/parameter changes.

## 5) Preset data authoring standards

## 5.1 Input presets (`presetdata/input`)

Input presets should compose reusable pipeline and parameter JSON blocks.

Minimum expected fields:

- `filename`
- `type`
- `title`
- `description`
- `pipeline_root`
- `pipelines`

Commonly used fields:

- `parameter_root`
- `parameter_sets`
- `parameter_overrides`

Use existing category and naming patterns (`consumer`, `professional`, region/signal suffixes like `-rf`, `-composite`, `-svideo`) unless there is a clear design reason not to.

## 5.2 Pipelines (`presetdata/pipelines`)

Pipelines define pass wiring and texture/pass options.

### Standard

- Keep pipelines modular and reusable.
- Prefer adding a new focused pipeline JSON over duplicating large pipeline blocks in multiple input presets.
- Preserve output-stage wiring patterns where applicable (for example post-stage bezel integration in `misc/post.json`).

## 5.3 Parameters (`presetdata/params`)

Parameter sets are grouped by domain (`sys`, `disp`, `misc`) and should remain reusable.

### Standard

- Place new parameter sets in the closest existing domain/category.
- Prefer shared parameter sets over large one-off override dictionaries in input presets.
- Keep numeric defaults/ranges consistent with neighboring files and parameter intent.

## 5.4 Schema compatibility

All preset/pipeline/parameter JSON must remain compatible with PresetGen schemas under `external/presetgen`.

## 6) Shader authoring standards

When editing `shaders/*.slang` or `shaders/*.inc`, follow:

- `doc/SHADER_AUTHORING_CHECKLIST.md`

### Required lint/style behavior

- Spaces only (no tabs)
- No trailing whitespace
- No excessive blank-line runs
- K&R control-flow brace style
- Valid stage flow and strict structure when applicable

### Standard

- Run `python scripts/lint_shaders.py` for touched shader/include files.
- For structure-sensitive changes, run strict mode and build lint gate (`--strict-structure`).

## 7) Packaging and trim standards

If touching trim behavior, rules, or distribution composition:

- Validate with `python build-trim.py`
- Review `trim-rules.txt` impact and preserve documented exceptions

## 8) Documentation standards

If behavior, commands, or contributor workflow changes:

- Update relevant docs in the same PR (for example `README.md`, `doc/SHADER_AUTHORING_CHECKLIST.md`, CI docs).

## 9) Pull request standards

Each PR should:

- Be scoped to one coherent change.
- Include a clear description of what changed and why.
- Include local validation commands and outcomes.
- Avoid unrelated refactors.
- Keep generated-output churn out of commits unless explicitly requested by maintainers.

## 10) Pre-merge checklist

- [ ] Changes are in source-of-truth files (not manual edits under `out/` or `out-trim/`).
- [ ] Relevant lint/build commands were run locally.
- [ ] Strict structure checks were run when required.
- [ ] `build-trim.py` was run when trim/packaging logic changed.
- [ ] Documentation was updated when workflow or behavior changed.
