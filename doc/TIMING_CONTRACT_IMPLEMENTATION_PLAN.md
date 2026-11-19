# Timing Contract Implementation Plan

## Goal
Replace texture-packed timing metadata with a contract-oriented API based on:

- independent per-item timing getters in `shaders/contract.inc`
- explicit DSP sample-rate uniforms from `shaders/menus/parameters/dsp.inc`
- `phase_rel_sample` carried in alpha only

## Contract Rules
1. One getter per contract item a vertex shader needs.
2. Public getters must be independent; no required call ordering.
3. `FS_CURRENT` is not transported as metadata.
4. DSP stages use explicit uniforms:
   - `DSP_WORKING_FS`
   - `DSP_OUTPUT_FS`
5. `FS_ORIGINAL` remains the primary timing-derived source rate.

## Canonical Contract Items
### Source-timing items
- `FS_ORIGINAL`
- `FrameWidth`
- `FrameHeight`
- `FullFrameHeight`
- `IsInterlaced`

### Frame-varying items
- `Field`
- `INITIAL_FIELD_PHASE_FRAC`

### Stage-local derived items
These are recomputed locally and are not carried as metadata:
- `Tin`
- `Delta`
- `DataLength`
- filter taps / sigma / cutoff terms
- frame placement / blanking geometry

### Per-fragment carried item
- `phase_rel_sample` in alpha

## Implementation Phases
### Phase 1: Contract scaffolding
- Add `shaders/contract.inc`
- Implement independent getters for the canonical source/frame items
- Keep the old low-level math in `modulation.inc` as the backend during migration

### Phase 2: Source-of-truth framing stage
- Update `shaders/frameh.slang` to use `contract.inc`
- Replace direct timing derivation blocks with contract getters
- Keep alpha carrying `phase_rel_sample`

### Phase 3: Frame consumer stage
- Update `shaders/framev.slang` to compute framing from contract getters/uniforms only
- Remove dependency on metadata texture reads

### Phase 4: DSP / resampler stages
- Use `dsp.inc` for `DSP_WORKING_FS` and `DSP_OUTPUT_FS`
- Stop relying on transported `FS_CURRENT`
- Keep output addressing and resampling geometry stage-local
- First targets:
  - `shaders/sys-bandlimit.slang`
  - `shaders/display-rgb-bandlimit-fir.slang`

### Phase 5: Cleanup
- Remove obsolete metadata timing transport once all target shaders are migrated
- Reduce the public surface of `modulation.inc`

## Verification
After each phase:

```powershell
c:/Users/Westley/source/repos/scanline-classic/.venv/Scripts/python.exe scripts/lint_shaders.py
```

Also verify in RetroArch that:
- no SLANG reflection errors appear
- framing and resampling still behave correctly
- `phase_rel_sample` continuity is preserved
