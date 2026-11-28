#version 450

// Filename: deskew.slang
//
// Copyright (C) 2026 W. M. Martinez
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
// Final presentation deskew
// -------------------------
// Input: Real RGB voltage
// Output: Real RGB voltage with presentation deskew applied
//
// This stage compensates the visible row-to-row skew introduced when
// the canonical source signal contains a fractional number of display
// pixels per line, where the clock factor is equal to the ratio of
// pixel clock cycles to display pixels per line.
//
// The correction shifts each presentation row by the legacy line carry or,
// for timing profiles, the fractional displacement of its H-sync boundary
// from the rounded stored line start. Alpha is forced to 1.0 to mark that
// canonical DSP processing is complete after this stage.

#pragma name Deskew
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS)

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DESKEW_HEADER " —— Debug Deskew —— " 0.0 0.0 0.0 0.0
#pragma parameter DESKEW_BYPASS "Bypass deskew" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float PIXEL_CLOCK_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float SC_FREQ_FRAC11;
    float SC_FREQ_FRAC6;
} config;

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, global.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, config.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)
#define DSP_OUTPUT_FS (DSP_SD_OUTPUT_FS / 1.0e6)

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;

#ifdef OPTION_DEBUG
    float DESKEW_BYPASS;
#endif  // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define DESKEW_BYPASS global.DESKEW_BYPASS
#else
const float DESKEW_BYPASS = 0.0;
#endif  // OPTION_DEBUG

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out double PresentationFrameWidth;
layout(location = 2) flat out float PresentationFrameHeight;
layout(location = 3) flat out float LineCarryClocksOut;
layout(location = 4) flat out float ClockFactorOut;
layout(location = 5) flat out float SampleRatio;
layout(location = 6) flat out float BaseFrameWidthOut;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float BaseFrameWidth = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    float LineCarryClocks = contract_line_carry_clocks(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    float ClockFactor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    if (TIMING_PROFILE_MODE > 0)
        LineCarryClocks = 0.0;
    float FrameHeight = contract_frame_height(
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
    float fs_original = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);
    float fs_current = contract_output_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    PresentationFrameHeight = FrameHeight;
    PresentationFrameWidth = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_output_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS), max(DSP_WORKING_FS, DSP_OUTPUT_FS));

    // Pass the integer-valued carry and cycle to the fragment stage as floats
    // for cross-driver safety; the fragment shader converts locally to int for
    // exact modular arithmetic.
    SampleRatio = fs_current / max(fs_original, EPS);
    LineCarryClocksOut = LineCarryClocks;
    ClockFactorOut = ClockFactor;
    BaseFrameWidthOut = BaseFrameWidth;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in double PresentationFrameWidth;
layout(location = 2) flat in float PresentationFrameHeight;
layout(location = 3) flat in float LineCarryClocksOut;
layout(location = 4) flat in float ClockFactorOut;
layout(location = 5) flat in float SampleRatio;
layout(location = 6) flat in float BaseFrameWidthOut;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec3 sample_deskewed(float output_x, float output_y, double frame_width)
{
    // Compute the wrapped carry in integer arithmetic to avoid float32
    // precision loss.  At high line numbers (e.g. y=130 for PSX 256px NTSC)
    // the floating-point mod(y * carry * sr, cycle * sr) can land on the wrong
    // side of a cycle boundary, producing a full-cycle error.  Working in
    // integer clocks first keeps the reduction exact.
    int carry_clocks = int(LineCarryClocksOut);
    int clock_factor = int(ClockFactorOut);
    int row_carry_clocks = (clock_factor > 0)
        ? (int(output_y) * carry_clocks) % clock_factor
        : 0;
    float row_shift = float(row_carry_clocks) * SampleRatio;
    if (TIMING_PROFILE_MODE > 0) {
        float clock_start = timing_profile_line_range(TIMING_PROFILE_MODE, config.OriginalSize.y,
            global.FrameCount, global.FIELD_ODD, output_y, BaseFrameWidthOut).x;
        float stored_start = timing_profile_line_range(TIMING_PROFILE_MODE, config.OriginalSize.y,
            global.FrameCount, global.FIELD_ODD, output_y, frame_width).x;
        row_shift += contract_hsync_sample_offset(clock_start, BaseFrameWidthOut, frame_width, stored_start);
    }
    float source_x = output_x + mix(row_shift, 0.0, DESKEW_BYPASS);

    if (source_x < 0.0 || source_x >= frame_width)
        return vec3(0.0);

    vec2 source_uv = (vec2(source_x, output_y) + vec2(0.5)) * config.SourceSize.zw;
    return texture(Source, source_uv).rgb;
}

void main()
{
    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);

    if (output_x >= ceil(PresentationFrameWidth) || output_y >= ceil(PresentationFrameHeight)) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec3 color = sample_deskewed(output_x, output_y, PresentationFrameWidth);
    FragColor = vec4(color, 1.0);
}
