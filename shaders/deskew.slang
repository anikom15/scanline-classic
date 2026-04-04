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
// This stage compensates the visible row-to-row skew introduced when a
// canonical 1D time signal is presented in a 2D raster with a fractional
// frame width. Timing and sample geometry are reconstructed from
// `contract.inc`; the input texture is treated as storage only.
//
// The correction is applied once, at the last time-aware stage, by shifting
// each row horizontally by the resampled line-carry derived from
// `frameh.slang`. Line 0 stays anchored; lower lines accumulate the per-line
// carry in current output-sample units. Alpha is forced to 1.0 to mark that
// canonical DSP processing is complete after this stage.
//
// For best results, use linear sampling on this pass so the fractional X
// offsets blend smoothly.

#pragma name Deskew
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

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
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;
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

layout(std140, set = 0, binding = 0) uniform UBO
{
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
layout(location = 1) flat out float PresentationFrameWidth;
layout(location = 2) flat out float PresentationFrameHeight;
layout(location = 3) flat out float CarryShiftPerLine;
layout(location = 4) flat out float CarryCycleWidth;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float BaseFrameWidth = contract_frame_width(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
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
    float BaseDataLength = contract_data_length(BaseFrameWidth, FrameHeight);

    float fs_original = contract_fs_original(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    float fs_current = (DSP_OUTPUT_FS > 0.0) ? (DSP_OUTPUT_FS * 1.0e6)
        : (DSP_WORKING_FS > 0.0) ? (DSP_WORKING_FS * 1.0e6)
        : fs_original;

    PresentationFrameHeight = FrameHeight;
    float CurrentDataLength = max(BaseDataLength * (fs_current / max(fs_original, EPS)), 1.0);
    PresentationFrameWidth = CurrentDataLength / max(PresentationFrameHeight, 1.0);

    // Resample FrameH's per-line residual clock carry into the current output
    // sample domain so each successive line receives the correct horizontal
    // offset while keeping line 0 anchored.
    float sample_ratio = fs_current / max(fs_original, EPS);
    CarryShiftPerLine = LineCarryClocks * sample_ratio;
    CarryCycleWidth = max(ClockFactor * sample_ratio, EPS);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float PresentationFrameWidth;
layout(location = 2) flat in float PresentationFrameHeight;
layout(location = 3) flat in float CarryShiftPerLine;
layout(location = 4) flat in float CarryCycleWidth;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec3 sample_deskewed(float output_x, float output_y, float frame_width)
{
    float accumulated_shift = output_y * CarryShiftPerLine;
    float row_shift = (CarryCycleWidth > EPS) ? mod(accumulated_shift, CarryCycleWidth) : 0.0;
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
