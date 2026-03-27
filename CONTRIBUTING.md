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
