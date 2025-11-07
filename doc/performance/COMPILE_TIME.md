# Reducing Shader Compile Time (Practical Guide)

Practical steps for faster first-time shader compiles on slower systems:
- Prefer `basic/` presets (single-pass `scanline-basic.slang`) and root TV/monitor presets (`trinitron-ntsc`, `flat-ntsc`, `trinitron-pal`, `flat-pal`) over composite/S-Video/RF system presets.
- Remove non-essential passes (bezel, phosphor, extra bandlimit) while tuning; fewer passes mean fewer separate compiles.
- Biggest first-load offenders: `composite-pal.slang`, `rf-ntsc.slang`, `composite.slang`, `svideo.slang`, `sys-component.slang`, `bezel.slang`, `scanline-advanced.slang`.
- Enable logging to see compile progress: Settings → Logging → Enable Logging=On; Log to File=On; Level=INFO (or DEBUG). Log file: portable → `retroarch.log` next to `retroarch.exe`; installed → `%APPDATA%\\RetroArch\\retroarch.log`. Search for `slang`, `compiling`, `SPIR-V`, `GLSL`.

## Major Compile-Time Offenders (Table)

| Pass / Feature | File(s) / Preset Examples | Primary Compile-Time Cost Driver | Typical Worst-Case | Immediate Mitigation | Advanced / Optional Mitigation |
| -------------- | ------------------------- | -------------------------------- | ------------------ | -------------------- | ------------------------------ |
| S-Video decode | `svideo.slang` (`sfc-snes-svideo.slangp`, `pce-tgfx16.slangp`) | Single 128-iteration Gaussian loop with dynamic early-exit | 128 iterations prepared | Cap loop to 32 or 48 | Make limit a user param; precompute weights into 1D LUT texture |
| Composite decode (NTSC) | `composite.slang`, `rf-ntsc.slang` (`sfc-snes-composite.slangp`, `twinfc-nes.slangp`) | Large filter span (`FILTER_SIZE_YC`) + negative pre-roll `N` | 64–96 effective taps | Clamp max filter size to 32 | Split luma/chroma passes; approximate far samples with lower precision |
| Composite decode (PAL) | `composite-pal.slang` | Longer PAL chroma period increases taps | 96–128 effective taps | Same clamp (≤32) | Provide PAL “fast” preset variant with reduced color resolution |
| System component decode | `sys-component.slang` (`sfc-snes.slangp`, `mdm1-genm1m2-composite.slangp`) | 128-iteration Gaussian loop identical to S-Video | 128 iterations | Cap to 32 or 48 | Replace Gaussian with Kaiser/bicubic approximation (fewer samples) |
| Anisotropic mask sampling | `scanline-advanced.slang` (monitor/TV presets using advanced pass) | Dynamic sample count up to 12 based on `max_aniso` | 12 samples per pixel | Clamp to 4–6 | Quantize anisotropy; bake variants per level |
| Bezel diffusion / bloom | `bezel.slang` (any preset adding bezel) | Nested dynamic loop: `diffusion_steps * 8` | 10 * 8 = 80 iterations | Cap `diffusion_steps` ≤4 | Merge directional samples; use separable blur chain |
| Phosphor luma / chroma passes | `phosphor-luma.slang`, `phosphor-chroma.slang` | Additional full-screen passes | +2 passes | Disable while tuning | Combine into single fused pass (requires rewrite) |
| Display RGB bandlimit | `display-rgb-bandlimit.slang` (`display-rgb-bandlimit` presets) | Convolution loop size | 32–48 taps | Lower bandwidth (higher sigma inverse) ensuring ≤32 taps | Precompute kernel in uniform buffer / push constants |
| System RGB bandlimit | `sys-rgb-bandlimit.slang`, `sys-display-rgb-bandlimit.slang` | Extra convolution pass before display | +1 pass, 32–48 taps | Temporarily disable | Merge with decode pass (code fusion) |
| Subpixel mask switch | `subpixel_masks.h` (advanced mask IDs) | Large compile-time switch with many constant branches | 25 branches | Use simpler mask (e.g. mask 1–5) | Texture-driven mask atlas, reduce static branching |
| Long preset chain | Complex system presets (RF / composite + bandlimit + phosphor + bezel) | Many distinct passes (each compiled separately) | 8–12 passes total | Start from simplified preset | Provide tiered “fast / balanced / full” preset families |

Interpret the table left-to-right: identify which feature you are using, check its worst-case cost, apply the Immediate Mitigation first, then consider Advanced Mitigation only if you still need more speed and are comfortable editing shader code.

### Quick Selection Guidance
1. If first load >10s: reduce 128-iteration loops and remove bezel.
2. If still slow: clamp composite/PAL filter size and anisotropic samples.
3. If GPU is very low-end (integrated Intel): temporarily remove phosphor + extra bandlimit passes.

## Troubleshooting

| Symptom | Likely Cause | Evidence to Look For (Log) | Remedy (Fast) | Remedy (Detailed) |
| ------- | ------------ | -------------------------- | ------------- | ----------------- |
| Preset takes >10s to appear | 128-iteration decode loop(s) | Lines with `Compiling slang shader: svideo.slang` or `sys-component.slang` slow timestamps | Reduce loop bounds to 32 | Replace Gaussian with precomputed LUT; keep quality slider |
| Long hang at 60–80% GPU utilization during first load | Large composite/PAL filter span | Repeated compile messages for `composite-pal.slang` | Clamp `FILTER_SIZE_YC` ≤32 | Provide alternate fast PAL preset variant |
| Bezel causes extra multi-second delay | High `diffusion_steps` value | Log shows compile of `bezel.slang` late in sequence | Cap steps ≤4 or remove bezel | Replace with cached static texture bezel |
| Mask pass compile slower than expected | Anisotropic sampling count high | Log entry: `scanline-advanced.slang` compile time noticeably larger than others | Clamp samples ≤4 | Quantize anisotropy; prepare discrete variants |
| Multiple sequential compiles of same file | Driver cache disabled / settings changed | Duplicate compile lines with same filename | Restart RetroArch; ensure shader cache enabled (Video settings) | Clear GPU shader cache directory so future compiles are clean and reused |
| Black screen briefly before image appears | All passes waiting on final compile | Log shows final pass compile just before image | Remove lowest-priority passes (bezel, phosphor) | Stage passes: start with basic preset, then layer features |
| Crash or out-of-memory during compile (rare) | Extremely high loop bounds on low-end GPU | Last log lines show entry into large loop shader before crash | Lower all loop caps (128→32, 12→4) | Profile memory usage; split preset into multiple simpler presets |
| Visual quality drop after mitigations | Loop/sample cap too aggressive | Compare before/after screenshots | Raise cap slightly (32→48, 4→6) | Implement adaptive sampling (conditional increase near edges) |
| PAL looks desaturated after fast tweaks | Filter size reduction clipped chroma period | Log shows reduced taps for PAL shader | Slightly increase filter cap (32→40) | Implement PAL chroma averaging optimization |

### Platform Logging Paths
| Platform | Log Location (Default) |
| -------- | ---------------------- |
| Windows Portable | `retroarch.log` next to `retroarch.exe` |
| Windows Installed | `%APPDATA%\RetroArch\retroarch.log` |
| Linux / BSD | `$XDG_CONFIG_HOME/retroarch/retroarch.log` or `~/.config/retroarch/retroarch.log` |
| macOS (Homebrew / App) | `~/Library/Application Support/RetroArch/retroarch.log` or `~/.config/retroarch/retroarch.log` |

Enable logging via config (alternative to GUI): add or edit in `retroarch.cfg`:
```
log_to_file = "true"
log_verbosity = "1"        # 0=error, 1=info, 2=debug
```
Optional: set `log_dir` if you want a custom path.

### How to Read the Log Efficiently
1. Search for `Compiling slang shader` – note timestamps between entries.
2. Long gaps → culprit shader. Cross-reference table above.
3. After first successful load, reload the same preset; if times drop sharply, cache is working.
4. If times remain high, GPU driver may be rebuilding cache (update drivers / reboot).

### When to Consider Advanced Mitigations
Apply advanced optimizations only if: (a) Immediate mitigations still yield >5s first-load times, or (b) you are packaging presets for distribution and want best out-of-box experience on very low-end hardware.

## Technical Background

### Why Do Loops Slow Compilation?

1. **Loop Unrolling:** Compilers try to unroll loops for better performance
   - Large loops = massive unrolled code = slow compilation
   
2. **Register Allocation:** Each loop iteration needs register space
   - 128 iterations = potential 128x register pressure
   
3. **Branch Prediction:** Dynamic bounds create multiple code paths
   - Compiler must generate code for all possible paths

4. **Shader Variants:** Some drivers compile multiple specializations
   - Each variant multiplies compilation time

### Why These Specific Limits?

- **32 iterations:** Sweet spot for Gaussian filters (covers ~3σ)
- **4-6 samples:** Sufficient for anisotropic filtering at reasonable distortion
- **Early exit:** Preserves quality while limiting worst-case compilation
