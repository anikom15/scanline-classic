# Filter Tap Automation Discussion

Filter tap use cases are separated by domain

## Thresholds

Use FILTER_THRESHOLD_ANALOG and FILTER_THRESHOLD_DIGITAL from
`common.inc`.  Any thresholds outside of this, for truncation purposes,
are considered invalid and should be flagged. MAX_TAPS are calculated
from these thresholds using the design sampling rates and work case
parameter values (within UI range) of each filter design.  Boundary
shaders should be considered part of their output domain.

Presets using rates above reference are valid, but consider impact
of truncation and revise criteria as necessary.

## Pixel clock domain

Use a reference design of 64 MHz which corresponds to a working line
width of 4096.  The boundary shader here is `sys-bandlimit.slang`
which inputs data from the pixel clock domain but outputs data in the
System DSP domain.

### Current Shaders

None as of yet

## System DSP domain

Use a reference design of 32 MHz which corresponds to a working line
width of 2048.  The boundary shader here is one of
`display-*-filter.slang` which outputs data in Display DSP domain.
The RGB working buffer is 2064 samples wide to accommodate PAL Mega Drive
timing at the default 32 MHz working rate.

### Current Shaders

`sys-bandlimit.slang` - Gaussian or BW polyphase lowpass
`sys-component.slang` - Gaussian or BW lowpass
`sys-yc-filter.slang` - Gaussian or BW lowpass and bandpass
`display-composite.slang` - Gaussian notch and bandpass separation
`sharpen.slang` - dual Gaussian luma bandpass enhancement

## SD Display DSP domain

Use a reference design of 32 MHz which corresponds to a working line
width of 2048.  This doesn't include HD or SVGA display shaders which
operate at a higher sample rate.  Those will be developed in a future
scope.  But it does include medium res and high res displays like NEC
MultiSync and VGA displays. The default output sample rate is 16 MHz;
32 MHz is the cap-design reference, not the default. Presets can override
the output rate. SD output allocations are 1032 samples wide; higher rates
or unusual timings can require larger allocations.

### Current Shaders

`display-component-filter.inc` - Kaiser polyphase lowpass
`display-rgb-filter.slang` - Kaiser polyphase lowpass

The Kaiser designs use a minimum effective transition width of 0.5 MHz.
If the requested stopband is less than 0.5 MHz above the cutoff, the
design preserves the cutoff and uses an effective stopband of cutoff +
0.5 MHz; the requested parameter is not changed.

## Build-time generation

`build.py` calculates and reports the worst-case tap caps before packaging.
It updates `shaders/filter-taps.inc` from the reference rates, UI parameter
ranges, common truncation thresholds and shader design constants. The build
rejects unrecognized truncation thresholds in the in-scope Gaussian and
Butterworth designs. Run
`python scripts/generate_filter_taps.py` to regenerate the include separately.
Keep the generator's filter equations in sync with the shader implementations.
The caps do not guarantee the same truncation threshold at rates above the
reference rates.

The sharpener operates on separated luma and modulated chroma in the working
domain, before display demodulation and filtering; it is not included in the
current pipelines. Its zero-phase luma filters require no chroma delay. Its
fixed 3 MHz and 8 MHz emphasis peaks can alias at working sample rates below
twice the peak frequency.

The composite prefilter also operates at the working rate, before chroma
demodulation and display-rate conversion. Its notch and bandpass widths are
full widths around the subcarrier; their attenuation settings describe the
Gaussian prototype at half that width. Zero attenuation bypasses the
corresponding filter. With the subcarrier disabled, the output is unfiltered
luma and zero chroma. Comb modes currently fall back to notch/bandpass
separation.

## Out of Scope Shaders

Other shaders are not yet integrated into New DSP, so will not be
considered for now.