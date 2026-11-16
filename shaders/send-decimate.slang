#version 450

// Filename: send-decimate.slang
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
// Signal decimation utility (analog shift)
// ----------------------------------------
// Input:  Packed 1D DSP signal in RGB
// Output: Linearly decimated packed 1D DSP signal in RGB
//
// This pass replaces the old texture-mipmap approximation for `MagDeltaV`.
// Instead of filtering each 2D row independently, it unwraps the signal over
// the contract-defined top-left raster and performs horizontal-only linear
// decimation in the canonical 1D sample domain. This preserves continuity when
// the decimated pair straddles a stored row boundary.
//
// The pass can simulate analog causality by phase shifting according to mip
// level if `ANALOG_DECIMATE` is enabled.

#pragma name SendDecimate
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SysRGBBandlimitSize;
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
    float ANALOG_DECIMATE;
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
#define ANALOG_DECIMATE config.ANALOG_DECIMATE

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

struct SendDecimateState {
    float mip_level;
    float frame_height;
    float input_frame_width;
    float output_frame_width;
    float input_data_length;
    float output_data_length;
    float horizontal_ratio;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out SendDecimateState vSendDecimateState;

SendDecimateState compute_send_decimate_state()
{
    SendDecimateState state;

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

    float base_frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    float base_storage_width = max(config.SysRGBBandlimitSize.x, 1.0);
    float input_storage_scale = config.SourceSize.x / base_storage_width;
    float output_storage_scale = config.OutputSize.x / base_storage_width;
    state.mip_level = -log2(output_storage_scale);

    // Use the contract-derived working frame width as the source of truth for
    // the active 1D data area, and scale it by each mip stage's storage ratio
    // relative to `SysRGBBandlimitSize` rather than by the padded texture width.
    state.input_frame_width = max(1.0,
        round(base_frame_width * max(input_storage_scale, 0.0)));
    state.output_frame_width = max(1.0,
        round(base_frame_width * max(output_storage_scale, 0.0)));
    state.input_data_length = max(contract_data_length(
        state.input_frame_width,
        state.frame_height), 1.0);
    state.output_data_length = max(contract_data_length(
        state.output_frame_width,
        state.frame_height), 1.0);
    state.horizontal_ratio = state.input_frame_width / max(state.output_frame_width, 1.0);

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vSendDecimateState = compute_send_decimate_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in SendDecimateState vSendDecimateState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

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

    if (output_x >= vSendDecimateState.output_frame_width ||
        output_y >= vSendDecimateState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    float field_output_index = output_y * vSendDecimateState.output_frame_width + output_x;
    if (field_output_index >= vSendDecimateState.output_data_length) {
        FragColor = vec4(0.0);
        return;
    }

    // Shift input to the left for analog decimation.
    // Guard against mip_level == 0 (identity-scale stage) so this pass can be
    // reused safely without generating INF/NaN sample positions.
    float mip_level_divisor = (abs(vSendDecimateState.mip_level) > EPS)
        ? vSendDecimateState.mip_level
        : 1.0;
    float input_sample_pos = (field_output_index + 0.5 - ANALOG_DECIMATE / mip_level_divisor)
        * vSendDecimateState.horizontal_ratio - 0.5;
    float input_data_limit = max(vSendDecimateState.input_data_length - 1.0, 0.0);
    float input_pos_floor = floor(input_sample_pos);
    float input_frac = input_sample_pos - input_pos_floor;

    vec4 sample0 = fetch_signal_sample(
        input_pos_floor,
        vSendDecimateState.input_frame_width,
        input_data_limit);
    vec4 sample1 = fetch_signal_sample(
        input_pos_floor + 1.0,
        vSendDecimateState.input_frame_width,
        input_data_limit);

    FragColor = mix(sample0, sample1, input_frac);
}
