// Filename: send-mag-delta-v-common.slang
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
// Signal magnitude-delta utility
// ------------------------------
// Input: Real RGB voltage
// Output: Per-channel MagDeltaV (RGBA)
//
// Computes the magnitude of the causal first difference
// |ΔV[n]| = |V[n] - V[n-1]| over the packed 1D signal carried between
// `frameh.slang` and `framev.slang`. The operation is intentionally
// sample-rate independent: it works directly in sample units, needs only two
// taps, and uses the contract-derived frame geometry only to unwrap the 1D
// sample index across row boundaries.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name MagDeltaV
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

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
    float DSP_WORKING_FS;
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

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

struct MagDeltaVState {
    float frame_width;
    float frame_height;
    float data_length;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out MagDeltaVState vMagDeltaVState;

MagDeltaVState compute_mag_delta_v_state()
{
    MagDeltaVState state;

#ifdef SEND_PIXEL_DOMAIN
    state.frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
#else
    state.frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
#endif
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
    vMagDeltaVState = compute_mag_delta_v_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in MagDeltaVState vMagDeltaVState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

// `sys-sync` can carry modeled sync in alpha, so MagDeltaV consumes all four
// channels as signal inputs and outputs the causal magnitude delta per channel.
vec4 fetch_signal_sample(float sample_index, float frame_width, float data_limit)
{
    int frame_width_i = max(int(frame_width + 0.5), 1);
    int data_limit_i = max(int(data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, data_limit))),
        0, data_limit_i);
    int texel_y = clamped_index_i / frame_width_i;
    int texel_x = clamped_index_i - texel_y * frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(config.SourceSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SourceSize.y) - 1, 0));

    return texelFetch(Source, ivec2(texel_x, texel_y), 0);
}

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float output_x = floor(UV.x);
    float output_y = floor(UV.y);

    if (output_x >= vMagDeltaVState.frame_width || output_y >= vMagDeltaVState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    float field_output_index = output_y * vMagDeltaVState.frame_width + output_x;
    if (field_output_index >= vMagDeltaVState.data_length) {
        FragColor = vec4(0.0);
        return;
    }

    float input_data_limit = max(vMagDeltaVState.data_length - 1.0, 0.0);
    float prev_index = max(field_output_index - 1.0, 0.0);

    vec4 current_signal = fetch_signal_sample(field_output_index, vMagDeltaVState.frame_width, input_data_limit);
    vec4 previous_signal = fetch_signal_sample(prev_index, vMagDeltaVState.frame_width, input_data_limit);

    FragColor = abs(current_signal - previous_signal);
}
