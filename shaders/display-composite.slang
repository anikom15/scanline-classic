#version 450

// Filename: display-composite-prefilter.slang
//
// Copyright (C) 2025 W. M. Martinez
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Display-side Composite decoder I, prefilter stage
// ----------------------------------------------------------------
// Input: Composite video baseband signal (CV, not RGB/YPbPr)
// Output contract: Y and C separated in the subcarrier domain, with C retained
// as the modulated chroma signal on f_SC. The stage is allowed to implement any
// of the legacy notch / bandpass / comb variants internally, but the public
// contract must remain stable: Y plus C_modulated_on_fsc, not a different
// output space. The actual filter implementation is left as a TODO so the
// timing geometry and output contract remain easy to reason about.

#pragma name DisplayCompositePrefilter
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/display-composite.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_COMPOSITE_PREFILTER_HEADER " —— Debug Display Composite Prefilter —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPOSITE_PREFILTER_BYPASS "Bypass display composite prefilter" 0.0 0.0 1.0 1.0
#pragma parameter DESKEW_BYPASS "Bypass integrated deskew" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;
    float PHASE_ZERO;
    float SHORTEN_ODD_FIELD_TIME;

    float BW_MODE;

#ifdef OPTION_DEBUG
    float DISPLAY_COMPOSITE_PREFILTER_BYPASS;
    float DESKEW_BYPASS;
#endif  // OPTION_DEBUG
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define DSP_OUTPUT_FS config.DSP_OUTPUT_FS
#define PHASE_ZERO config.PHASE_ZERO
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define BW_MODE config.BW_MODE

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;

#ifdef OPTION_DEBUG
    float DISPLAY_COMPOSITE_PREFILTER_BYPASS;
    float DESKEW_BYPASS;
#endif  // OPTION_DEBUG
} global;

#ifdef OPTION_DEBUG
#define DISPLAY_COMPOSITE_PREFILTER_BYPASS global.DISPLAY_COMPOSITE_PREFILTER_BYPASS
#define DESKEW_BYPASS global.DESKEW_BYPASS
#endif  // OPTION_DEBUG

struct TimingContract
{
    float fs_original;
    float fs_working;
    float fs_output;
    float fsc_hz;
    float initial_subcarrier_phase_frac;
    float frame_height;
    float input_frame_width;
    float output_frame_width;
    float input_data_length;
    float output_data_length;
    float delta;
    float deskew_sample_ratio;
    float line_carry_clocks;
    float clock_factor;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out TimingContract tc;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Timing source-of-truth now comes from the DSP contract, not from the
    // nominal texture dimensions. These values define the actual data-space
    // geometry the filter should operate on.
    float fs_original = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);

    float frame_height = contract_frame_height(
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    float working_sample_rate = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);

    float output_sample_rate = contract_output_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    float fsc_hz = contract_subcarrier_freq_hz(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ);

    float initial_subcarrier_phase_frac = contract_initial_subcarrier_phase_frac(
        config.OriginalSize.xy,
        config.OriginalFPS,
        config.FrameCount,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        SC_FREQ_MODE,
        SC_FREQ,
        H_FREQ_MODE,
        H_FREQ,
        V_FREQ_MODE,
        V_FREQ,
        SHORTEN_ODD_FIELD_TIME,
        PHASE_ZERO);

    float input_frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);

    float output_frame_width = contract_output_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    float input_data_length = max(contract_data_length(input_frame_width, frame_height), 1.0);
    float output_data_length = max(contract_data_length(output_frame_width, frame_height), 1.0);

    float line_carry_clocks = contract_line_carry_clocks(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    float clock_factor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    tc.fs_original = fs_original;
    tc.fs_working = working_sample_rate;
    tc.fs_output = output_sample_rate;
    tc.fsc_hz = fsc_hz;
    tc.initial_subcarrier_phase_frac = initial_subcarrier_phase_frac;
    tc.frame_height = frame_height;
    tc.input_frame_width = input_frame_width;
    tc.output_frame_width = output_frame_width;
    tc.input_data_length = input_data_length;
    tc.output_data_length = output_data_length;
    tc.delta = output_data_length / max(input_data_length, EPS);
    tc.deskew_sample_ratio = output_sample_rate / max(fs_original, EPS);
    tc.line_carry_clocks = line_carry_clocks;
    tc.clock_factor = clock_factor;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in TimingContract tc;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
#ifdef OPTION_DEBUG
    if (DISPLAY_COMPOSITE_PREFILTER_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
#endif  // OPTION_DEBUG

    // The actual composite prefilter kernel is intentionally left as a TODO.
    // The contract-derived values above are the stable quantities that any
    // implementation must respect, regardless of whether it runs a notch/bandpass
    // 1D filter, an analog comb, or an adaptive spatially-aware comb.
    //
    // Public output contract:
    // - input: composite video baseband (CV)
    // - output: Y + C_modulated_on_fsc, with C still referenced to f_SC and the
    //   same phase convention as the display-side subcarrier domain
    // - implementation detail: any internal comb / remodulation may vary, but the
    //   output contract must not drift to a different data space
    //
    // Remaining work for the actual filter:
    // - convert the input from source texel space to contract data space
    // - derive the bandpass / notch / comb kernel centers from tc.fs_output / tc.fs_working
    // - use tc.delta and tc.output_frame_width to build a rate-stable sample grid
    // - keep Y/C separation phase-aligned with tc.fsc_hz and tc.initial_subcarrier_phase_frac
    // - handle odd/even field and line carry in a contract-aware way
    //
    // For now we only return the center sample so the shader compiles and the
    // contract values remain explicit for the next implementation pass.
    vec4 sample0 = texture(Source, vTexCoord);
    FragColor = vec4(sample0.r, sample0.g, sample0.b, 1.0);
}
