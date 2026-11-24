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
//         sample extended to the left. Each level is aligned to the original
//         row grid; interpolation bridges row boundaries in the 1D signal.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name SendDID
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

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

struct SendDIDState {
    float frame_height;
    float base_frame_width;
    float input_span;
    float output_frame_width;
    float data_length;
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
    float base_storage_width = max(config.SendSourceSize.x, 1.0);
    state.base_frame_width = base_frame_width;
    state.input_span = max(round(base_storage_width / max(config.SourceSize.x, 1.0)), 1.0);
    state.output_frame_width = max(ceil(base_frame_width / (2.0 * state.input_span)), 1.0);
    state.data_length = max(ceil(contract_data_length(base_frame_width, state.frame_height)), 1.0);

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

    if (output_x >= vSendDIDState.output_frame_width ||
        output_y >= vSendDIDState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    int frame_width = int(vSendDIDState.base_frame_width);
    int input_span = int(vSendDIDState.input_span);
    int data_length = int(vSendDIDState.data_length);
    int input_index = int(output_y) * frame_width + int(output_x) * 2 * input_span;
    if (input_index >= data_length) {
        FragColor = vec4(0.0);
        return;
    }

    vec4 sample0 = sample_row_aligned_signal(
        Source,
        input_index,
        frame_width,
        input_span,
        data_length);
    vec4 sample1 = sample_row_aligned_signal(
        Source,
        input_index - input_span,
        frame_width,
        input_span,
        data_length);

    FragColor = 0.5 * (sample0 + sample1);
}
