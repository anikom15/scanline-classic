# phosphor-chroma.slang — Performance Notes

Summary
- Converts weighted chromaticities to RGB, with optional white point scaling.

Hot Parameters
- PHOSPHOR_CHROMA_BYPASS: Bypass to return input.
- SCALE_W: Extra math to normalize to white; negligible cost.

Cost Drivers
- One source sample + small matrix math per pixel. Very light.

Tuning Strategy
- Leave enabled; has minimal performance impact.

Quick Profiles
- Low/Med/High: Default settings; turn BYPASS=1 for A/B comparisons only
