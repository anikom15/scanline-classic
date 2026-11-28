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
// DAC-stage RGB noise injection in the pixel-clock domain
// ------------------------------------------------------
// Input: RGB voltage
// Output: RGB voltage
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

#include "menus/parameters/noise-dac.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#include "raster-mapping.inc"
#define TIMING_PROFILE_MODE timingProfileMode

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DAC_NOISE_HEADER " —— Debug DAC Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter DAC_NOISE_BYPASS "Bypass DAC noise" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    uint CurrentSubFrame;
    uint TotalSubFrames;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float DAC_NOISE_AWGN_DB;
    float DAC_NOISE_JITTER_UI;
    float PIXEL_CLOCK_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float SC_FREQ_FRAC11;
    float SC_FREQ_FRAC6;
} config;

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, config.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define DAC_NOISE_AWGN_DB config.DAC_NOISE_AWGN_DB
#define DAC_NOISE_JITTER_UI config.DAC_NOISE_JITTER_UI

layout(std140, set = 0, binding = 0) uniform UBO
{
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;

#ifdef OPTION_DEBUG
    float DAC_NOISE_BYPASS;
#endif  // OPTION_DEBUG
} global;

#ifdef OPTION_DEBUG
#define DAC_NOISE_BYPASS global.DAC_NOISE_BYPASS
#endif  // OPTION_DEBUG

struct NoiseDACState {
    float frame_width;
    float frame_height;
    float data_length;
    float packed_width;
    float texture_fits;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseDACState vNoiseState;
layout(location = 6) flat out vec4 vRasterPattern;
layout(location = 7) flat out ivec2 vRasterExceptions;

NoiseDACState compute_noise_state(int timingProfileMode)
{
    NoiseDACState state;

    state.frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
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
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, global.FIELD_ODD, state.frame_width,
        ceil(contract_data_length(state.frame_width, state.frame_height))), 1.0);
    state.packed_width = contract_pixel_packed_width(state.data_length);
    state.texture_fits = contract_pixel_texture_fits(config.OutputSize.xy, state.data_length, state.packed_width) &&
        contract_pixel_texture_fits(config.SourceSize.xy, state.data_length, state.packed_width) ? 1.0 : 0.0;

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    int timingProfileMode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);
    timing_profile_raster_descriptor(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount,
        global.FIELD_ODD, vRasterPattern, vRasterExceptions);
    vNoiseState = compute_noise_state(timingProfileMode);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in NoiseDACState vNoiseState;
layout(location = 6) flat in vec4 vRasterPattern;
layout(location = 7) flat in ivec2 vRasterExceptions;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

vec4 sample_signal_linear(float sample_index, NoiseDACState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float index0 = floor(clamped_index);
    float frac = clamped_index - index0;

    float packed_width = state.packed_width;
    vec4 s0 = fetch_input_sample(Source, config.SourceSize.xy, index0, packed_width, data_limit);
    vec4 s1 = fetch_input_sample(Source, config.SourceSize.xy, min(index0 + 1.0, data_limit), packed_width, data_limit);
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

    float packed_width = vNoiseState.packed_width;
    if (vNoiseState.texture_fits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    float sample_index = output_y * packed_width + output_x;
    if (output_x >= packed_width || sample_index >= vNoiseState.data_length) {
        FragColor = vec4(0.0);
        return;
    }

    vec2 raster = raster_position(vRasterPattern, vRasterExceptions, sample_index, vNoiseState.frame_width);
    int raster_y_i = int(raster.y);

#ifdef OPTION_DEBUG
    if (DAC_NOISE_BYPASS > 0.5) {
        FragColor = fetch_input_sample(
            Source,
            config.SourceSize.xy,
            sample_index,
            packed_width,
            vNoiseState.data_length - 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    float awgn_db = DAC_NOISE_AWGN_DB;
    float jitter_ui = DAC_NOISE_JITTER_UI;
    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    float jitter_samples = compute_jitter_samples(sample_index, raster_y_i, frame, jitter_ui);
    float jittered_index = sample_index + jitter_samples;

    vec4 jittered_sample = sample_signal_linear(jittered_index, vNoiseState);

    vec4 awgn_noise = gaussian_noise4(
        uvec2(uint(raster.x), uint(raster_y_i)),
        frame,
        0xD3ADB33Fu);
    float awgn_sigma = db_to_linear(awgn_db);

    vec4 color_sync = vec4(jittered_sample.rgb + awgn_sigma * awgn_noise.rgb, jittered_sample.a);
    FragColor = color_sync;
}
