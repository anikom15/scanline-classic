# Timing Profiles Plan

## Goal

Replace individual timing parameters with a build-generated catalog of system
timing profiles. A preset selects one stable system profile ID; the profile
selects among its timing modes using runtime inputs and applicable global
options.

Keep one pixel-domain `frameh.slang` and preserve the contract's independent
getters. All timing-dependent passes must resolve the same profile from the
same original-source inputs.

## Profile Data

Each profile describes one system and contains:

- An explicit, stable ID and a default timing mode.
- One or more named timing modes with exact clock and carrier ratios, field
  lengths and ordering, interlace behavior, and system-specific line adjustments.
- The supported output modes for each timing mode, documented independently
  from the rules that select timing. Multiple output modes may share one timing
  mode; an output mode is not itself a timing mode.
- Ordered selection rules and any supported option-driven remapping.
- References and confidence for the timing data; preset estimates are not
  automatically verified hardware measurements.

An arcade system may have one timing mode, a console may have several, and a
computer may have many. A single SFC NTSC timing mode covers all eight documented
NTSC output modes, including progressive and interlaced output.

Each timing mode declares physical line counts and durations for even and odd
fields, for both scan types, and identifies the first field at `FrameCount = 0`.
For example, SFC NTSC interlaced fields have 263 even lines and 262 odd lines;
PAL has 313 even and 312 odd. The `field_lines` values determine the current
field's storage height, while `field_clocks` determines carrier phase. Physical durations in
`field_clocks` are positive integers or exact `[numerator, denominator]` pairs. After
reduction, numerators must be less than 2^52 and denominators at most 2^20;
these bounds keep the shader's integer intermediates exactly representable.
`pixel_clock_multiplier` is an exact positive `[numerator, denominator]` ratio
relative to the subcarrier. After reduction, each component must be at most
2^24, and the ratio at most 500. The float clock path uses this ratio for
frequency calculations; carrier phase uses its exact reciprocal. Legacy
profile 0 retains its decimal timing parameters.
The `raster` section specifies the interlace detection threshold. Storage
uses the current field's line count; `FIELD_ODD` reverses field ordering.
Neither physical line count nor a nominal width alone determines field
duration: `field_clocks` accounts for shortened and lengthened lines.

Profiles specify vertical sync and back-porch lines and horizontal sync and
either front- or back-porch pixel-clock cycles; remaining blanking follows from
the field and source dimensions. SFC has 3 vertical sync lines and 15 back-porch lines,
and 100 horizontal sync clocks and 152 back-porch clocks. The vertical pulse
is asserted across all three lines; horizontal sync is asserted at the start
of every line. Line 1 starts at vertical sync: picture begins on line 19 and
at zero-based clock 252. A 224-line picture ends on line 242; a 239-line
picture extends through line 257. In a 262-line field these leave 20 or 5
blank lines at the bottom, respectively. A 1,024-clock picture leaves 88
blank clocks at the end of a normal 1,364-clock line. PAL and interlaced
fields extend downward, adding bottom blanking rather than moving the picture.
Profile 0 retains the legacy approximate sync. Future profiles may
use estimates based on NTSC, PAL or GTF. Presentation centers the active area
independently of the physical storage padding. For interlaced output, beam
scaling and centering use the combined height of both fields (equivalently,
their average field height); storage still uses the current field's actual
line count.

`line_overrides` identifies exceptional line lengths by scan type, field
parity, one-based line number from the start of vertical sync, and total clock
count. SFC NTSC/PAL-M progressive odd line 259 contains 1,360 clocks; PAL
interlaced odd line 18 contains 1,368. The timing reference uses its own line
numbering for these exceptions; PAL's shift wraps across the field boundary.
The generator checks each overridden field's line lengths against its declared
`field_clocks`. The packed field and downstream signal passes use the resulting
time-ordered stream. Pixel- and working-rate streams use nearly square,
power-of-two storage strides independent of the timing line width. The final
display resamplers map the stream back to fixed-width presentation rows and
apply deskew within the resampling filter. At other sample rates, line boundaries and field lengths round
up to the next stored sample; the display filter uses the unrounded physical
H-sync time to correct the resulting fractional line-start displacement.
The debug deskew bypass exposes the rounded presentation instead. The mapping adds or removes clocks at the end of the
line; the timing reference does not specify their exact placement within the
blanking interval. A mode may instead specify repeating odd/even `line_clocks`;
line parity restarts at line 1 in every field. The declared field clocks must
match the summed lines and overrides.

PSX profile 2 uses 3,412 clocks on odd NTSC lines and 3,413 on even lines;
PAL uses 3,405 throughout. Progressive fields contain 263 NTSC or 314 PAL
lines. Interlaced even/odd fields contain 263/262 NTSC and 313/312 PAL lines;
NTSC starts even and PAL starts odd. One vertical sync line and 11 back-porch
lines put the nominal picture on line 13. Horizontal sync is 100 clocks. The
nominal front porch is 100 clocks on the first line; picture placement stays
fixed relative to H-sync as line lengths change. Thus the NTSC front porch
is 100 clocks on 3,412-clock lines and 101 clocks on 3,413-clock lines.
The nominal picture heights are 240 NTSC and 288 PAL lines.
Source dimensions are centered around that nominal picture and clipped at the
physical field boundaries. Widths 256, 320, 368, 512 and 640 use clock factors
10, 8, 7, 5 and 4 respectively. The largest supported width not exceeding the
reported width is selected (widths below 256 use 256); cropping and overscan
can therefore be misidentified as another mode. Interlace is inferred above
360 lines for NTSC or 432 for PAL; cropping or overscan across these thresholds
is ambiguous. These pulse widths, positioning rules, and thresholds are profile
assumptions, not comprehensive hardware measurements.

This storage mapping describes integer-clock line overrides. Fractional field
durations remain supported for phase calculations, but a general sub-clock
storage representation has not been implemented.

Build-time validation should reject duplicate IDs, invalid ratios, missing
targets, and ambiguous rules without explicit precedence. Profile IDs must not
change when profiles are reordered or added. Invalid IDs and invalid runtime
inputs must produce an explicit diagnostic rather than silently selecting a
different system.

## Selection

Rules can use frontend-reported refresh rate, original source width, height,
and area. Rules select a timing mode before any derived timing is computed.
`OriginalSize` describes the frontend input texture, not necessarily the active
video area. The initial SFC implementation assumes the documented dimensions
and nominal 50/60 Hz rates, including rates rounded to two decimal places; the
profile supplies the actual clocks rather than deriving them from those rates.

Initial SFC behavior:

1. Select NTSC by default.
2. Select PAL when the validated 50 Hz trigger matches.
3. If `OPTION_REPLACE_NTSC_PALM` is enabled, replace a selected NTSC mode with
   PAL-M; leave a selected PAL mode unchanged.

The initial SFC selector uses a 55 Hz boundary, tolerant of both nominal and
documented rates. NTSC and PAL-M have the same eight documented SFC output modes
and cannot be reliably distinguished using size and refresh alone. The
[canonical timing reference](https://www.scanlineclassic.com/theory/timings.html)
describes PAL-M timings extrapolated from the maintenance guide. Its PAL-M
pixel clock is six times the 3,575,611 Hz subcarrier, i.e. 21,453,666 Hz before
rounding; the reference's displayed rates appear to use the rounded clock and
can differ in their last digits. Field lengths and even-first ordering match NTSC.

Saturn-style width-dependent clocks and computer scan-rate selection are
future profile applications, not assumptions about what the current frontend
signals can distinguish. Add them only after establishing timing references
and reliable triggers.

## Implementation

1. Define the profile schema and build-time validation, then encode SFC NTSC,
   PAL, and PAL-M modes. The initial schema supports subcarrier-multiplied
   clocks and explicit rational field durations; extend it before migrating
   systems with other clock models.
2. Generate shared shader-readable profile data and selection logic.
   Ensure global options are visible before profile selection is compiled.
   Keep the source shader shared rather than generating `frameh` variants.
3. Update the contract and timing-dependent passes to resolve the profile
   consistently. Preserve exact rational field-phase arithmetic and the
   separation between physical timing and raster storage.
   Older `compute_timebase` consumers still use their approximate legacy phase
   calculation and the profile's `field_adjustment` compatibility flag, not
   the explicit field durations. Migrate those consumers before relying on
   arbitrary field patterns throughout the signal chain.
4. Migrate preset inputs from timing fields to stable profile IDs. SFC presets
   use ID 1, PSX uses ID 2, and other systems retain ID 0 and their legacy timing parameters.
   The shared shaders still expose legacy timing controls until those systems
   are migrated; those controls do not override the SFC profile. Preserve
   display and signal-chain settings; consolidating system timing does not
   necessarily merge NTSC and PAL display presets.
5. Update parameter documentation and migration guidance for existing saved
   presets and overrides. Keep consumer preferences and educational controls
   separate from hardware timing data.

## Mode-Change Phase Policy

Each timing mode has an initial carrier phase relative to the primary mode,
defaulting to zero. At any field count, calculate phase as though the selected
mode and current interlace behavior had applied since `FrameCount = 0`.
Switching modes or interlace behavior can therefore cause a phase discontinuity;
no actual elapsed-time or oscillator continuity is implied. The global phase
offset remains additive. Test mode switches and returns at the same field count.

## Verification

- Compare SFC NTSC, PAL, and extrapolated PAL-M timings with the canonical
  reference. Exercise every documented output mode under its timing mode.
- Verify PAL-M progressive phase includes the four-clock shortened odd field.
- Test rule boundaries, precedence, default behavior, option remapping, invalid
  inputs, and consistent selection across passes.
- Test progressive and interlaced field lengths, field ordering, and carrier
  phase within +/-1 degree, including long-running field counts and the chosen
  mode-transition behavior.
- Verify packed sample counts, exceptional-line boundaries, sync placement,
  and presentation row mapping for both field orders and sample rates.
- Exercise equal half-line fields, fractional-clock durations, and geometry
  independent of physical timing.
- Verify generated preset IDs and representative shader variants, then test
  actual frontend/core refresh and dimension reporting.
- Measure shader compilation size, runtime cost, sampler and push-constant
  limits, and framebuffer capacity. Build-time generation does not remove
  runtime resource limits.
