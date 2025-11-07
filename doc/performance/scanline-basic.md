# scanline-basic.slang — Performance Notes

Summary
- Lightweight single-pass CRT look with bicubic kernel and scanline logic; fastest general preset.

Hot Parameters
- FOCUS: Controls bicubic sharpness. Cost fixed; choose ~0.5 for Trinitron-like.
- SCAN_TYPE, MAX_SCAN_RATE, LINE_DOUBLER, INTER_OFF: Affect vertical stepping. LINE_DOUBLER can increase sampling density on low-res content.
- ZOOM: Pure coordinate math; negligible discrete cost.

Cost Drivers
- 4×4 bicubic (16 samples) with scanline modulation.

Tuning Strategy
- Keep LINE_DOUBLER=0 for consoles; enable only for PC-like progressive content.
- Use FOCUS between 0.4–0.6; extreme sharpness may reveal ringing without quality benefit.
- Prefer this shader on low-end GPUs and handhelds.

Quick Profiles
- Low: FOCUS=0.45, LINE_DOUBLER=0, SCAN_TYPE=2
- Med: FOCUS=0.5, SCAN_TYPE per system
- High: Pair with external mask/bezel pass if desired
