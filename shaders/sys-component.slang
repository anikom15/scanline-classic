#version 450

// Filename: sys-component.slang
//
// Copyright (C) 2025-2026 W. M. Martinez
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
// System-level component amplifier and filter
// -------------------------------
// Input: Voltage (RGB color space)
// Output: Voltage (YC color space)
//
// Encodes RGB into a chosen luma-chroma color space (YIQ / YPbPr / YUV / YDbDr / YCbCr),
// then optionally bandlimits each component with a horizontal Gaussian (lobe technique) to
// approximate analog system bandwidth. Component-wise SYS_GAIN/SYS_BIAS are applied after filtering.
//
// Notes:
// - YDbDr is implemented by first computing YUV, then scaling chroma:
//     Db = (1.333 / 0.436) * U  ≈  3.05688 * U
//     Dr = (-1.333 / 0.615) * V ≈ -2.16829 * V
// - Filtering is performed in the color space domain, not RGB, to better emulate analog chains.
// - Bypasses:
//     SYS_COMPONENT_BYPASS          -> output source RGB unmodified (skip color conversion + filter)
//     SYS_COMPONENT_FILTER_BYPASS   -> convert to selected color space and apply SYS_GAIN/BIAS, but skip filtering

#pragma name SysComponent
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-component.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_COMPONENT_HEADER " —— Debug Sys Component —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_COMPONENT_BYPASS "Bypass system component stage" 0.0 0.0 1.0 1.0
#pragma parameter SYS_COMPONENT_FILTER_BYPASS "Bypass system component filter" 0.0 0.0 1.0 1.0
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

    // Color model selection
    float YC_MODEL;

    // Per-component analog bandlimit (MHz/dB).
    float SYS_BANDWIDTH_Y;
    float SYS_BANDWIDTH_C;
    float SYS_CUTOFF_ATTEN_Y;
    float SYS_CUTOFF_ATTEN_C;
    float DSP_WORKING_FS;
} config;

// Short-hand macros

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ

#define YC_MODEL config.YC_MODEL

#define SYS_BANDWIDTH_Y config.SYS_BANDWIDTH_Y
#define SYS_BANDWIDTH_C config.SYS_BANDWIDTH_C
#define SYS_CUTOFF_ATTEN_Y config.SYS_CUTOFF_ATTEN_Y
#define SYS_CUTOFF_ATTEN_C config.SYS_CUTOFF_ATTEN_C
#define DSP_WORKING_FS config.DSP_WORKING_FS

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;

    // Post-filter gain/bias per component
    float SYS_GAIN_Y;
    float SYS_GAIN_C;
    float SYS_BIAS_Y;
    float SYS_BIAS_C;

#ifdef OPTION_DEBUG
    // Bypasses
    float SYS_COMPONENT_BYPASS;        // 0 or 1
    float SYS_COMPONENT_FILTER_BYPASS; // 0 or 1
#endif                                 // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define SYS_COMPONENT_BYPASS global.SYS_COMPONENT_BYPASS
#define SYS_COMPONENT_FILTER_BYPASS global.SYS_COMPONENT_FILTER_BYPASS
#endif  // OPTION_DEBUG

#define SYS_GAIN_Y global.SYS_GAIN_Y
#define SYS_GAIN_C global.SYS_GAIN_C
#define SYS_BIAS_Y global.SYS_BIAS_Y
#define SYS_BIAS_C global.SYS_BIAS_C

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec3 gain;
layout(location = 2) out vec3 bias;
layout(location = 3) flat out vec3 sigma;
layout(location = 4) flat out vec3 kernelGain;
layout(location = 6) flat out float FrameWidth;
layout(location = 7) flat out float FrameHeight;
layout(location = 8) flat out float DataLength;
layout(location = 9) flat out float Taps;

const float MAX_TAPS = 71.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float fs_current = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);

    FrameWidth = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    FrameHeight = contract_frame_height(
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
    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);

    // Normalize the analog Gaussian design into working-sample units before
    // evaluating the discrete kernel on the current DSP sample grid.
    vec3 sigma_seconds = vec3(
        gaussian_sigma(SYS_BANDWIDTH_Y * 1.0e6, SYS_CUTOFF_ATTEN_Y),
        gaussian_sigma(SYS_BANDWIDTH_C * 1.0e6, SYS_CUTOFF_ATTEN_C),
        gaussian_sigma(SYS_BANDWIDTH_C * 1.0e6, SYS_CUTOFF_ATTEN_C));

    float sigma_max_seconds = max(sigma_seconds.x, max(sigma_seconds.y, sigma_seconds.z));
    float t_support_seconds = gaussian_decay_time(sigma_max_seconds, FILTER_THRESHOLD_ANALOG);

    sigma = sigma_seconds * fs_current;
    Taps = max(1.0, min(2.0 * ceil(t_support_seconds * fs_current) + 1.0, MAX_TAPS));

    kernelGain = vec3(0.0);
    for (int k = 0; k < int(Taps); ++k) {
        float dt = float(k) - (Taps - 1.0) / 2.0;
        kernelGain += vec3(
            gaussian(dt, sigma.x),
            gaussian(dt, sigma.y),
            gaussian(dt, sigma.z));
    }
    kernelGain = max(kernelGain, vec3(EPS));

    gain = vec3(
        pow(10.0, SYS_GAIN_Y / 20.0),
        pow(10.0, SYS_GAIN_C / 20.0),
        pow(10.0, SYS_GAIN_C / 20.0));
    bias = vec3(
        SYS_BIAS_Y * 10e-3,
        SYS_BIAS_C * 10e-3,
        SYS_BIAS_C * 10e-3);
}

#pragma stage fragment

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec3 gain;
layout(location = 2) in vec3 bias;
layout(location = 3) flat in vec3 sigma;
layout(location = 4) flat in vec3 kernelGain;
layout(location = 6) flat in float FrameWidth;
layout(location = 7) flat in float FrameHeight;
layout(location = 8) flat in float DataLength;
layout(location = 9) flat in float Taps;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec4 fetch_input_sample(float sample_index, float frame_width, float input_data_limit)
{
    int frame_width_i = max(int(frame_width + 0.5), 1);
    int input_data_limit_i = max(int(input_data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, input_data_limit))),
        0, input_data_limit_i);
    int texel_y = clamped_index_i / frame_width_i;
    int texel_x = clamped_index_i - texel_y * frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(config.SourceSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SourceSize.y) - 1, 0));

    return texelFetch(Source, ivec2(texel_x, texel_y), 0);
}

void main()
{
#ifdef OPTION_DEBUG
    if (SYS_COMPONENT_BYPASS >= 1.0) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    if (SYS_COMPONENT_FILTER_BYPASS >= 1.0) {
        vec4 source_sample = texture(Source, vTexCoord);
        vec3 yc = rgb_to_luma_chroma(source_sample.rgb, YC_MODEL);
        FragColor = vec4(gain * (yc + bias), source_sample.a);
        return;
    }
#endif  // OPTION_DEBUG

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float output_x = floor(UV.x);
    float output_y = floor(UV.y);

    if (output_x >= FrameWidth || output_y >= FrameHeight) {
        FragColor = vec4(0.0);
        return;
    }

    float output_index = output_y * FrameWidth + output_x;
    if (output_index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    vec4 center_sample = fetch_input_sample(output_index, FrameWidth, DataLength - 1.0);
    vec3 accum = vec3(0.0);
    int center = (int(Taps) - 1) / 2;

    for (int k = 0; k < int(Taps); ++k) {
        int tap_offset = k - center;
        float dt = float(tap_offset);
        vec3 coeff = vec3(
            gaussian(dt, sigma.x),
            gaussian(dt, sigma.y),
            gaussian(dt, sigma.z));
        vec3 yc = rgb_to_luma_chroma(
            fetch_input_sample(output_index + float(tap_offset), FrameWidth, DataLength - 1.0).rgb,
            YC_MODEL);
        accum += coeff * yc;
    }

    vec3 outyc = accum / kernelGain;
    FragColor = vec4(gain * (outyc + bias), center_sample.a);
}
