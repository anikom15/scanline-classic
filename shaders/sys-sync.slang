#version 450

// Filename: sys-sync.slang
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
// System sync processing
// --------------------------------------------
// Input: RGB voltage
// Output: RGB voltage
//   CSync/RGBHV, TTL - Alpha channel carries sync information
//   RGsB - Green channel carries sync information
//
// Processes system sync signals
// Supports RGBHV, CSync, TTL, and RGsB
// Uses high for blanking-active and low for blanking-off
// For Sync on Y, use sys-sync-y.slang
// For CVBS, use sys-sync-cvbs.slang

#pragma name SysSync
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-sync.inc"

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
    float FIELD_ODD;
    float DSP_WORKING_FS;
    float SYS_SYNC_TYPE;
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
#define FIELD_ODD config.FIELD_ODD
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define SYS_SYNC_TYPE config.SYS_SYNC_TYPE

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

struct SyncState {
    float base_frame_width;
    float working_frame_width;
    float frame_height;
    float active_left_base;
    float active_top;
    float active_source_height;
    float clock_factor;
    float clocks_per_line;
    float x_scale_to_base;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out SyncState vSyncState;

SyncState compute_sync_state()
{
    SyncState state;

    state.base_frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    state.working_frame_width = contract_working_frame_width(
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
    state.clocks_per_line = contract_clocks_per_line(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    state.clock_factor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    float frame_height_int = ceil(state.frame_height);
    float is_interlaced = contract_is_interlaced(
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
    float field = contract_field(config.FrameCount);
    float field_parity = (is_interlaced > 0.5) ? mod(field + FIELD_ODD, 2.0) : 0.0;

    state.active_source_height = (is_interlaced > 0.5)
        ? max(floor((config.OriginalSize.y - field_parity + 1.0) * 0.5), 0.0)
        : config.OriginalSize.y;
    state.active_top = floor((frame_height_int - state.active_source_height) * 0.5);

    float active_width_base = config.OriginalSize.x * max(state.clock_factor, 1.0);
    state.active_left_base = (state.base_frame_width - active_width_base) * 0.5;
    state.x_scale_to_base = state.base_frame_width / max(state.working_frame_width, 1.0);

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vSyncState = compute_sync_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in SyncState vSyncState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

const float BLANKING_APPROX_FRACTION = 0.07;

vec4 fetch_source_texel(int x, int y)
{
    if (x < 0 || y < 0 || x >= int(config.SourceSize.x) || y >= int(config.SourceSize.y))
        return vec4(0.0);

    return texelFetch(Source, ivec2(x, y), 0);
}

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = floor(UV.x);
    float output_y = floor(UV.y);

    vec4 sample_in = fetch_source_texel(output_x_i, output_y_i);

    float frame_height_int = ceil(vSyncState.frame_height);
    bool in_frame_x = output_x >= 0.0 && output_x < vSyncState.working_frame_width;
    bool in_frame_y = output_y >= 0.0 && output_y < frame_height_int;
    bool in_frame = in_frame_x && in_frame_y;

    int clock_factor_int = max(int(floor(vSyncState.clock_factor + 0.5)), 1);
    int phase_step_clocks_int = int(floor(vSyncState.clocks_per_line + 0.5)) % clock_factor_int;
    int row_phase_clocks_int = (output_y_i * phase_step_clocks_int) % clock_factor_int;
    float phase_clocks = float(row_phase_clocks_int);

    float base_x = output_x * vSyncState.x_scale_to_base;
    float source_x_base = (base_x - vSyncState.active_left_base - phase_clocks) / max(vSyncState.clock_factor, 1.0);
    bool in_active_x = source_x_base >= 0.0 && source_x_base < config.OriginalSize.x;
    bool in_active_y = output_y >= vSyncState.active_top
        && output_y < vSyncState.active_top + vSyncState.active_source_height;
    bool in_active = in_frame && in_active_x && in_active_y;

    float h_phase = base_x / max(vSyncState.base_frame_width, 1.0);
    float v_phase = output_y / max(vSyncState.frame_height, 1.0);

    bool in_h_blanking_window = h_phase >= 0.0 && h_phase < BLANKING_APPROX_FRACTION;
    bool in_v_blanking_window = v_phase >= 0.0 && v_phase < BLANKING_APPROX_FRACTION;

    float h_blanking_active = (!in_active_x && in_frame_x && in_h_blanking_window) ? 1.0 : 0.0;
    float v_blanking_active = (!in_active_y && in_frame_y && in_v_blanking_window) ? 1.0 : 0.0;
    float blanking_active = (h_blanking_active > 0.5 || v_blanking_active > 0.5) ? 1.0 : 0.0;

    vec3 color = sample_in.rgb;
    float alpha = sample_in.a;

    const float sync_ref_low = 0.0;
    const float sync_ref_ttl = -3.5;
    const float sync_ref_csync = -0.4;

    if (SYS_SYNC_TYPE < 0.5) {
        // CSync/RGBHV: Alpha channel carries sync information
        alpha = blanking_active * sync_ref_csync;
    } else if (SYS_SYNC_TYPE < 1.5) {
        // TTL: Alpha channel carries sync information
        alpha = blanking_active * sync_ref_ttl;
    } else {
        // RGsB: sync rides on green; alpha passes through unchanged.
        color.g += blanking_active * sync_ref_csync;
        alpha = sync_ref_low;
    }

    FragColor = vec4(color, alpha);
}
