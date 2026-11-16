#version 450

// Filename: noise-dac.slang
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
// DAC-stage RGB noise injection in the DSP sample domain
// ------------------------------------------------------
// Input: RGB voltage
// Output: RGB voltage
//
// Extracted from `noise-rgb.slang` to model DAC-stage noise contribution only.
//
// Covered effects:
//  - broadband AWGN
//  - sample jitter / phase noise

#pragma name NoiseDAC
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "subframe.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/noise-dac.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DAC_NOISE_HEADER " —— Debug DAC Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter DAC_NOISE_BYPASS "Bypass DAC noise" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 SysRGBBandlimitSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    uint CurrentSubFrame;
    uint TotalSubFrames;
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

    float DAC_NOISE_AWGN_DB;
    float DAC_NOISE_JITTER_UI;
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
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define DAC_NOISE_AWGN_DB config.DAC_NOISE_AWGN_DB
#define DAC_NOISE_JITTER_UI config.DAC_NOISE_JITTER_UI

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float PHASE_ZERO;
    float RGB_NOISE_PRESET;
    float RGB_NOISE_CLOCK_HARMONIC;
    float SHORTEN_ODD_FIELD_TIME;

#ifdef OPTION_DEBUG
    float DAC_NOISE_BYPASS;
#endif  // OPTION_DEBUG
} global;

#define PHASE_ZERO global.PHASE_ZERO
#define RGB_NOISE_PRESET global.RGB_NOISE_PRESET
#define SHORTEN_ODD_FIELD_TIME global.SHORTEN_ODD_FIELD_TIME

#ifdef OPTION_DEBUG
#define DAC_NOISE_BYPASS global.DAC_NOISE_BYPASS
#endif  // OPTION_DEBUG

struct NoiseDACState {
    float frame_width;
    float frame_height;
    float data_length;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseDACState vNoiseState;

NoiseDACState compute_noise_state()
{
    NoiseDACState state;

    state.frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    state.frame_height = contract_frame_height(
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
    state.data_length = max(contract_data_length(state.frame_width, state.frame_height), 1.0);

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vNoiseState = compute_noise_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in NoiseDACState vNoiseState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

vec4 sample_signal_linear(float sample_index, NoiseDACState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float index0 = floor(clamped_index);
    float frac = clamped_index - index0;

    vec4 s0 = fetch_input_sample(Source, config.SourceSize.xy, index0, state.frame_width, state.data_length);
    vec4 s1 = fetch_input_sample(Source, config.SourceSize.xy, min(index0 + 1.0, data_limit), state.frame_width, state.data_length);
    return mix(s0, s1, frac);
}

float compute_jitter_samples(float sample_index, int output_y_i, uint frame, float jitter_ui)
{
    float jitter_amp = jitter_ui * 0.02;
    if (jitter_amp <= 0.0)
        return 0.0;

    float line_jitter = gaussian_noise3(
        uvec2(frame ^ 0x6D2B79F5u, uint(output_y_i)),
        frame,
        0x91E10DA5u).x * jitter_amp;
    float fine_jitter = tpdf_blue_noise_1x(vec2(sample_index, float(output_y_i)), frame) * jitter_amp;

    return line_jitter + 0.5 * fine_jitter;
}

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= vNoiseState.frame_width || output_y >= vNoiseState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    float sample_index = output_y * vNoiseState.frame_width + output_x;

#ifdef OPTION_DEBUG
    if (DAC_NOISE_BYPASS > 0.5) {
        FragColor = fetch_input_sample(
            Source,
            config.SourceSize.xy,
            sample_index,
            vNoiseState.frame_width,
            vNoiseState.data_length);
        return;
    }
#endif  // OPTION_DEBUG

    float awgn_db = DAC_NOISE_AWGN_DB;
    float jitter_ui = DAC_NOISE_JITTER_UI;
    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    float jitter_samples = compute_jitter_samples(sample_index, output_y_i, frame, jitter_ui);
    float jittered_index = sample_index + jitter_samples;

    vec4 jittered_sample = sample_signal_linear(jittered_index, vNoiseState);

    vec3 awgn_noise = gaussian_noise3(
        uvec2(uint(output_x_i), uint(output_y_i)),
        frame,
        0xD3ADB33Fu);
    float awgn_sigma = db_to_linear(awgn_db);

    vec3 color = jittered_sample.rgb + awgn_sigma * awgn_noise;
    FragColor = vec4(color, jittered_sample.a);
}
