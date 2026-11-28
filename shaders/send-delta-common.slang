// Filename: send-delta-common.slang
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
// Signal delta utility
// --------------------
// Input: Real RGB voltage
// Output: Per-channel signed DeltaV (RGBA)
//
// Computes the causal first difference
// ΔV[n] = V[n] - V[n-1] over the packed 1D signal carried between
// `frameh.slang` and `framev.slang`. The operation is intentionally
// sample-rate independent: it works directly in sample units, needs only two
// taps, and uses the contract-derived frame geometry only to unwrap the 1D
// sample index across row boundaries.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name DeltaV
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS)

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
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
} global;

struct DeltaVState {
    float data_length;
    float storage_width;
    float texture_fits;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out DeltaVState vDeltaVState;

DeltaVState compute_delta_v_state()
{
    DeltaVState state;

#ifdef SEND_PIXEL_DOMAIN
    double frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
#else
    double frame_width = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS), DSP_WORKING_FS);
#endif
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
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, frame_width,
        contract_data_length(frame_width, frame_height)), 1.0);
    state.data_length = ceil(state.data_length);
    state.storage_width = contract_pixel_packed_width(state.data_length);
    state.texture_fits = contract_pixel_texture_fits(config.OutputSize.xy, state.data_length, state.storage_width) &&
        contract_pixel_texture_fits(config.SourceSize.xy, state.data_length, state.storage_width) ? 1.0 : 0.0;

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vDeltaVState = compute_delta_v_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in DeltaVState vDeltaVState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

// `sys-sync` can carry modeled sync in alpha, so all four channels are inputs.
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

    float storage_width = vDeltaVState.storage_width;
    if (vDeltaVState.texture_fits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    if (output_x >= storage_width) {
        FragColor = vec4(0.0);
        return;
    }
    float field_output_index = output_y * storage_width + output_x;
    if (field_output_index >= vDeltaVState.data_length) {
        FragColor = vec4(0.0);
        return;
    }

    float input_data_limit = max(vDeltaVState.data_length - 1.0, 0.0);
    float prev_index = max(field_output_index - 1.0, 0.0);

    vec4 current_signal = fetch_signal_sample(field_output_index, storage_width, input_data_limit);
    vec4 previous_signal = fetch_signal_sample(prev_index, storage_width, input_data_limit);

    FragColor = current_signal - previous_signal;
}
