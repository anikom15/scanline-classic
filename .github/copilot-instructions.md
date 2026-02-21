# Copilot Instructions for scanline-classic

## Project purpose and architecture
- This repo is a data-driven RetroArch shader/preset build system, not just shader source files.
- Core flow: `presetdata/input/*.json` (preset definitions) + `presetdata/pipelines/*.json` + `presetdata/params/*.json` -> `external/presetgen/presetgen.py` -> SDR `.slangp` presets in `out/presets/uhd-4k-sdr`.
- After SDR generation, `scripts/generate_*` produces WCG/HDR/FHD variants from SDR outputs.
- Shader passes are modular; output-stage bezel integration is wired via pipeline JSON (example: `presetdata/pipelines/misc/post.json` uses `bezel-sdr`).

## Critical workflow commands
- Full build (recommended): `python build.py` (or `python build.py --jobs 8 -v`).
- Trimmed distribution build: `python build-trim.py` (expects `out/` already generated).
- Local install helper: `install.bat` copies `out/*` to a user-local RetroArch path.
- Libretro merge helper: `merge.bat` runs build + trim and copies `out-trim/*` into `../slang-shaders/bezel/scanline-classic`.
- Build script auto-prefers `.venv/Scripts/python.exe` on Windows when present.

## Where to edit for common tasks
- Edit shader behavior in `shaders/*.slang` and shared includes in `shaders/*.inc`.
- Edit user-facing parameter ranges/defaults in menu include files (example: `shaders/menus/parameters/output-bezel.inc`).
- Edit preset composition in `presetdata/input/**` (example: `presetdata/input/consumer/sfc.json`).
- Edit pipeline stage wiring in `presetdata/pipelines/**`.
- Edit reusable parameter packs in `presetdata/params/**`.

## Project-specific conventions
- Prefer changing source-of-truth inputs (`presetdata`, `shaders`, `scripts`) over generated outputs.
- Do not manually edit generated files in `out/` or `out-trim/` unless explicitly doing a one-off debug check.
- WCG/HDR preset generation is transform-based:
  - `scripts/generate_wcg_presets.py` swaps `-sdr.slang` -> `-wcg.slang`.
  - `scripts/generate_hdr_presets.py` swaps `-sdr.slang` -> `-hdr.slang` and removes last-pass `scale_type` as a RetroArch HDR workaround.
- WCG/HDR menu shaders are generated from SDR menu shaders by include rewriting (`scripts/generate_wcg_menu.py`, `scripts/generate_hdr_menu.py`).

## Integration and dependency boundaries
- `external/presetgen/` is a vendored dependency used by `build.py`; keep compatibility with its schemas and CLI behavior.
- JSON schema expectations live in `external/presetgen/*.schema.json`; invalid preset/pipeline/param JSON will break generation.
- `build.py` runs generation in parallel (`ThreadPoolExecutor`), so avoid introducing non-thread-safe shared mutable state in scripts.

## Validation expectations for AI edits
- If touching preset generation or scripts, run at least: `python build.py`.
- If touching trim logic, also run: `python build-trim.py`.
- If touching bezel/glow shader params, verify both source and menu parameter includes stay aligned (for example `bezel-base.slang` push constants vs `output-bezel.inc` pragmas).
- Keep edits minimal and preserve existing naming/layout conventions in shader params and JSON keys.
