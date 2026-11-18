#version 450

// Filename: noise-rgb.slang
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
// RGB noise injection in the DSP sample domain
// --------------------------------------------
// Input: RGB voltage
// Output: RGB voltage
//
// Adds broadband AWGN and simple MagDeltaV-driven crosstalk to the framed 1D
// raster between `frameh.slang` and `framev.slang`.
//
// Model:
//  - `RGB_NOISE_FEEDBACK_DB` is the capacitave feedback level in dB.
//  - `RGB_NOISE_XTALK_DB` is one rejection value for all channels.
//  - Crosstalk drive uses equal contribution from MagDeltaV R/G/B/H/V.

#pragma name NoiseRGB
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "subframe.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/noise-rgb.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_RGB_NOISE_HEADER " —— Debug RGB Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter RGB_NOISE_BYPASS "Bypass RGB noise" 0.0 0.0 1.0 1.0
#pragma parameter RGB_NOISE_VIEW_MAG_DELTAV "View MagDeltaV" 0.0 0.0 2.0 1.0
#pragma parameter RGB_NOISE_MAG_DELTAV_MIP_LOD "MagDeltaV mip LOD" 0.0 0.0 12.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SendSourceSize;
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

    float RGB_NOISE_FEEDBACK_DB;
    float RGB_NOISE_XTALK_DB;

#ifdef OPTION_DEBUG
    float RGB_NOISE_BYPASS;
    float RGB_NOISE_VIEW_MAG_DELTAV;
    float RGB_NOISE_MAG_DELTAV_MIP_LOD;
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
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define RGB_NOISE_FEEDBACK_DB config.RGB_NOISE_FEEDBACK_DB
#define RGB_NOISE_XTALK_DB config.RGB_NOISE_XTALK_DB

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#ifdef OPTION_DEBUG
#define RGB_NOISE_BYPASS config.RGB_NOISE_BYPASS
#define RGB_NOISE_VIEW_MAG_DELTAV config.RGB_NOISE_VIEW_MAG_DELTAV
#define RGB_NOISE_MAG_DELTAV_MIP_LOD config.RGB_NOISE_MAG_DELTAV_MIP_LOD
#endif  // OPTION_DEBUG

struct NoiseRGBState {
    float frame_width;
    float frame_height;
    float data_length;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseRGBState vNoiseState;

NoiseRGBState compute_noise_state()
{
    NoiseRGBState state;

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
layout(location = 1) flat in NoiseRGBState vNoiseState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;  // Mip 12 (1-pixel terminal mip)
layout(set = 0, binding = 2) uniform sampler2D SendSource;
layout(set = 0, binding = 3) uniform sampler2D MagDeltaV;  // Mip 0
layout(set = 0, binding = 4) uniform sampler2D Mip1;
layout(set = 0, binding = 5) uniform sampler2D Mip2;
layout(set = 0, binding = 6) uniform sampler2D Mip3;
layout(set = 0, binding = 7) uniform sampler2D Mip4;
layout(set = 0, binding = 8) uniform sampler2D Mip5;
layout(set = 0, binding = 9) uniform sampler2D Mip6;
layout(set = 0, binding = 10) uniform sampler2D Mip7;
layout(set = 0, binding = 11) uniform sampler2D Mip8;
layout(set = 0, binding = 12) uniform sampler2D Mip9;
layout(set = 0, binding = 13) uniform sampler2D Mip10;
layout(set = 0, binding = 14) uniform sampler2D Mip11;

#ifdef OPTION_XTALK_SAMPLE_COUNT
const int XTALK_SAMPLE_COUNT = OPTION_XTALK_SAMPLE_COUNT;
#else
const int XTALK_SAMPLE_COUNT = 13;
#endif

vec2 mag_delta_v_uv_from_index(float sample_index, NoiseRGBState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float sample_y = floor(clamped_index / max(state.frame_width, 1.0));
    float sample_x = clamped_index - sample_y * state.frame_width;
    vec2 mag_delta_size = max(vec2(textureSize(MagDeltaV, 0)), vec2(1.0));

    return (vec2(sample_x, sample_y) + vec2(0.5)) / mag_delta_size;
}

vec4 sample_mag_delta_v_level(vec2 mag_delta_uv, int lod_i)
{
    if (lod_i <= 0)
        return texture(MagDeltaV, mag_delta_uv);
    if (lod_i == 1)
        return texture(Mip1, mag_delta_uv);
    if (lod_i == 2)
        return texture(Mip2, mag_delta_uv);
    if (lod_i == 3)
        return texture(Mip3, mag_delta_uv);
    if (lod_i == 4)
        return texture(Mip4, mag_delta_uv);
    if (lod_i == 5)
        return texture(Mip5, mag_delta_uv);
    if (lod_i == 6)
        return texture(Mip6, mag_delta_uv);
    if (lod_i == 7)
        return texture(Mip7, mag_delta_uv);
    if (lod_i == 8)
        return texture(Mip8, mag_delta_uv);
    if (lod_i == 9)
        return texture(Mip9, mag_delta_uv);
    if (lod_i == 10)
        return texture(Mip10, mag_delta_uv);
    if (lod_i == 11)
        return texture(Mip11, mag_delta_uv);

    return texture(Source, mag_delta_uv);
}

vec4 sample_mag_delta_v_lod(float sample_index, float lod, NoiseRGBState state)
{
    vec2 mag_delta_uv = mag_delta_v_uv_from_index(sample_index, state);
    float lod_clamped = clamp(lod, 0.0, 11.0);
    int lod0_i = int(floor(lod_clamped));
    int lod1_i = min(lod0_i + 1, 11);
    float lod_frac = lod_clamped - float(lod0_i);

    vec4 sample0 = sample_mag_delta_v_level(mag_delta_uv, lod0_i);
    vec4 sample1 = sample_mag_delta_v_level(mag_delta_uv, lod1_i);
    return mix(sample0, sample1, lod_frac);
}

void main()
{
    vec2 uv = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(uv.x));
    int output_y_i = int(floor(uv.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= vNoiseState.frame_width || output_y >= vNoiseState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    float sample_index = output_y * vNoiseState.frame_width + output_x;

#ifdef OPTION_DEBUG
    if (RGB_NOISE_BYPASS > 0.5) {
        FragColor = fetch_input_sample(
            SendSource,
            config.SendSourceSize.xy,
            sample_index,
            vNoiseState.frame_width,
            vNoiseState.data_length);
        return;
    }

    if (RGB_NOISE_VIEW_MAG_DELTAV > 0.5) {
        vec4 debug_mag_delta_v = sample_mag_delta_v_lod(
            sample_index,
            RGB_NOISE_MAG_DELTAV_MIP_LOD,
            vNoiseState);

        if (RGB_NOISE_VIEW_MAG_DELTAV > 1.5) {
            float a = clamp(debug_mag_delta_v.a, 0.0, 1.0);
            FragColor = vec4(a, a, a, 1.0);
        } else {
            FragColor = vec4(clamp(debug_mag_delta_v.rgb, 0.0, 1.0), 1.0);
        }
        return;
    }
#endif  // OPTION_DEBUG

    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    vec4 sample_signal = fetch_input_sample(
        SendSource,
        config.SendSourceSize.xy,
        sample_index,
        vNoiseState.frame_width,
        vNoiseState.data_length);
    vec4 mag_delta = vec4(0.0);
    for (int i = 0; i < XTALK_SAMPLE_COUNT; ++i) {
        vec4 mag_delta_sample = sample_mag_delta_v_lod(sample_index, float(i), vNoiseState);
        mag_delta += mag_delta_sample;
    }

    float feedback_gain = db_to_linear(RGB_NOISE_FEEDBACK_DB);
    vec3 feedback = feedback_gain * mag_delta.rgb;

    float crosstalk_gain = db_to_linear(RGB_NOISE_XTALK_DB);
    vec3 crosstalk_drive = vec3(
        dot(mag_delta.gba, vec3(1.0)),
        dot(mag_delta.rba, vec3(1.0)),
        dot(mag_delta.rga, vec3(1.0))
    );
    vec3 crosstalk = crosstalk_gain * crosstalk_drive;

    vec3 color = sample_signal.rgb + feedback + crosstalk;

    FragColor = vec4(color, 1.0);  // Sync no longer needed
}
