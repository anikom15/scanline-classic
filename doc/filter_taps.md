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

Use a fixed 32 MHz SD working rate. The boundary shader here is one of
`display-*-filter.slang` which outputs data in Display DSP domain.
Working fields use 1024 by 1024 packed textures; `sys-bandlimit.slang`
checks both the pixel-domain source and working-domain destination.

### Current Shaders

`sys-bandlimit.slang` - Gaussian or BW polyphase lowpass
`sys-component.slang` - Gaussian or BW lowpass
`sys-yc-filter.slang` - Gaussian or BW lowpass and bandpass
`display-composite.slang` - Gaussian notch/bandpass and line-comb separation
`display-svideo-demod.slang` - PAL simple, delay-line, or adaptive chroma decoding
`sharpen.slang` - dual Gaussian luma bandpass enhancement
`cv-iq.slang` / `iq-cv.slang` - half-rate analytic conversion and reconstruction

The system lowpass designs share Gaussian gain and Butterworth cutoff and
prewarped-coefficient calculations in `lowpass.inc`, while retaining their separate guards,
tap limits and delay handling.

The experimental `rgb-component-composite-iq` system pipeline places the new
pair after composite encoding without changing the existing RF presets. The
`sfc-composite-iq-test` preset exercises it. I and Q
are the even-indexed composite samples and their Hilbert transform respectively,
packed at 16 MHz; the original field length and 32 MHz packing are restored by
the second pass. The generated polyphase FIR coefficients use the analog
threshold (with at least 40 dB attenuation) and a 1 MHz design transition.
The synthesis residual preserves DC;
the reference response error is below 1% from DC through 6 MHz away from field
edges. Repeat-edge extension applies at the field boundaries. Frequencies
outside that range, especially near Nyquist, are not guaranteed to reconstruct.

## SD Display DSP domain

SD output is fixed at 16 MHz. The Kaiser tap caps use the 32 MHz input
sample rate because the filter taps are evaluated on the working grid.
The separate VGA path uses the pixel clock as its input rate and accepts an
output rate, defaulting to the pixel clock when set to zero. SD presentation
targets are 2048 by 512 texels.
The display resamplers check both their packed input and the actual line
lengths and field height against their output allocation; undersized textures
produce magenta.

### Current Shaders

`display-component-filter.inc` - Kaiser polyphase lowpass
`display-rgb-filter.slang` - Kaiser polyphase lowpass

The Kaiser designs use a minimum effective transition width of 0.5 MHz.
If the requested stopband is less than 0.5 MHz above the cutoff, the
design preserves the cutoff and uses an effective stopband of cutoff +
0.5 MHz; the requested parameter is not changed.
The component, S-Video, and RGB designs share Kaiser tap-count and gain
calculations in `window.inc`; their cutoff and gain guards remain distinct.
At the default RGB settings the filter attenuates the 8 MHz output Nyquist
frequency by about 46 dB.

## Build-time generation

`build.py` calculates and reports the worst-case tap caps before packaging.
It generates `out/shaders/filter-taps.inc` from the reference rates, UI parameter
ranges, common truncation thresholds and shader design constants. The build
rejects unrecognized truncation thresholds in the in-scope Gaussian and
Butterworth designs. Run
`python scripts/generate_filter_taps.py` to regenerate the output include separately.
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