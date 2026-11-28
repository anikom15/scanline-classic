// Filename: send-did-common.slang
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
// Dyadic interval derivative pyramid
// ----------------------------------
// Input:  Packed signed 1D derivative samples in RGBA
// Output: Causal averages of adjacent input-level samples, with the first
//         sample extended to the left. Levels after DeltaV are packed as a
//         continuous 1D stream for both pixel and DSP inputs.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name SendDID
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS)

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SendSourceSize;
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
    float DSP_WORKING_FS;
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
#define DSP_WORKING_FS config.DSP_WORKING_FS

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
} global;

struct SendDIDState {
    float frame_height;
    float base_frame_width;
    float input_span;
    float output_frame_width;
    float data_length;
    float texture_fits;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out SendDIDState vSendDIDState;

SendDIDState compute_send_did_state()
{
    SendDIDState state;

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

#ifdef SEND_PIXEL_DOMAIN
    float base_frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
#else
    float base_frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
#endif
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, base_frame_width,
        ceil(contract_data_length(base_frame_width, state.frame_height))), 1.0);
    state.base_frame_width = contract_pixel_packed_width(state.data_length);
    state.texture_fits = contract_pixel_texture_fits(config.SendSourceSize.xy, state.data_length, state.base_frame_width) ? 1.0 : 0.0;
    float base_area = config.SendSourceSize.x * config.SendSourceSize.y;
    float source_area = max(config.SourceSize.x * config.SourceSize.y, 1.0);
    state.input_span = exp2(round(log2(max(base_area / source_area, 1.0))));
    state.output_frame_width = config.OutputSize.x;
    if (state.input_span == 1.0)
        state.texture_fits = state.texture_fits > 0.5 &&
            config.SourceSize.x >= state.base_frame_width &&
            config.SourceSize.y >= ceil(state.data_length / state.base_frame_width) ? 1.0 : 0.0;
    else
        state.texture_fits = state.texture_fits > 0.5 &&
            source_area >= ceil(state.data_length / state.input_span) ? 1.0 : 0.0;
    float output_count = ceil(state.data_length / (2.0 * state.input_span));
    if (state.input_span < state.data_length &&
        config.OutputSize.x * config.OutputSize.y < output_count)
        state.texture_fits = 0.0;

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vSendDIDState = compute_send_did_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in SendDIDState vSendDIDState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float output_x = floor(UV.x);
    float output_y = floor(UV.y);

    if (vSendDIDState.texture_fits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    if (vSendDIDState.input_span >= vSendDIDState.data_length) {
        FragColor = vec4(0.0);
        return;
    }
    int frame_width = int(vSendDIDState.base_frame_width);
    int input_span = int(vSendDIDState.input_span);
    int data_length = int(vSendDIDState.data_length);
    int output_width = int(vSendDIDState.output_frame_width);
    int input_index = (int(output_y) * output_width + int(output_x)) * 2 * input_span;
    if (input_index >= data_length) {
        FragColor = vec4(0.0);
        return;
    }
    int input_width = input_span == 1 ? frame_width : int(config.SourceSize.x);
    // Both indices lie on the input level's grid; the first repeats at the field start.
    vec4 sample0 = sample_pyramid_signal(Source, input_index, input_width, input_span, data_length);
    vec4 sample1 = sample_pyramid_signal(Source, input_index - input_span, input_width, input_span, data_length);

    FragColor = 0.5 * (sample0 + sample1);
}
