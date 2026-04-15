#version 450

// Filename: frameh.slang
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
// Horizontal frame storage
// ------------------------
// Maps active raster data into a framed field buffer stored in the
// top-left of a 2x-sized intermediate texture.
//
// The output is a true clock-domain raster: each line spans `ClocksPerLine`
// samples, active source texels are held for `ClockFactor` clock samples, and
// blanking remains at 1-sample clock resolution. RGB stores the raster sample
// value for each clock sample, while A stores `phase_rel_sample`. The packed
// data grid stays anchored to geometry / line carry; any field-dependent
// timebase phase is reconstructed downstream from the contract API rather than
// baked into the storage placement or a texture-carried metadata payload.

#pragma name FrameH
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/scanraster.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_FRAME_HEADER " —— Debug Frame —— " 0.0 0.0 0.0 0.0
#pragma parameter FRAME_VIZ_ACTIVE "Show active content" 1.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_BLANKING "Show frame blanking (yellow)" 0.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_PADDING "Show padding (magenta)" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

// Push constants
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
    float SHORTEN_ODD_FIELD_TIME;
    float SCANLINE_BLANK_WEIGHT;
    float PHASE_ZERO;
    float FIELD_ODD;


#ifdef OPTION_DEBUG
    float FRAME_VIZ_ACTIVE;
    float FRAME_VIZ_BLANKING;
    float FRAME_VIZ_PADDING;
#endif  // OPTION_DEBUG

} config;

#define FieldCount config.FrameCount

#ifdef OPTION_DEBUG
#define FRAME_VIZ_ACTIVE config.FRAME_VIZ_ACTIVE
#define FRAME_VIZ_BLANKING config.FRAME_VIZ_BLANKING
#define FRAME_VIZ_PADDING config.FRAME_VIZ_PADDING
#endif  // OPTION_DEBUG

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define PHASE_ZERO config.PHASE_ZERO
#define FIELD_ODD config.FIELD_ODD

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float FrameWidth;
layout(location = 2) flat out float FrameHeight;
layout(location = 3) flat out float FS_ORIGINAL;
layout(location = 5) flat out float FullFrameHeight;
layout(location = 6) flat out float IsInterlaced;
layout(location = 7) flat out float Field;
layout(location = 8) flat out float ClocksPerLine;
layout(location = 9) flat out float ClockFactor;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    FS_ORIGINAL = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);

    ClocksPerLine = contract_clocks_per_line(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    ClockFactor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    FrameWidth = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

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

    FullFrameHeight = contract_full_frame_height(
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

    IsInterlaced = contract_is_interlaced(
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

    Field = contract_field(FieldCount);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 3) flat in float FS_ORIGINAL;
layout(location = 6) flat in float IsInterlaced;
layout(location = 7) flat in float Field;
layout(location = 8) flat in float ClocksPerLine;
layout(location = 9) flat in float ClockFactor;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

float current_field_parity()
{
    return (IsInterlaced > 0.5) ? mod(Field + FIELD_ODD, 2.0) : 0.0;
}

bool sample_maps_to_active_time(
    float output_x,
    float output_y,
    out vec2 source_sample_pos)
{
    float frame_height_int = ceil(FrameHeight);
    float field_parity = current_field_parity();
    float active_source_height = (IsInterlaced > 0.5)
        ? max(floor((config.SourceSize.y - field_parity + 1.0) * 0.5), 0.0)
        : config.SourceSize.y;

    float line_index = floor(output_y);
    int line_index_int = int(line_index);
    int clock_factor_int = max(int(floor(ClockFactor + 0.5)), 1);
    float clock_factor = float(clock_factor_int);
    float active_width = config.SourceSize.x * clock_factor;
    float active_left = (FrameWidth - active_width) * 0.5;
    float active_top = floor((frame_height_int - active_source_height) * 0.5);

    // Keep the wrapped line-carry in integer clock space so the storage grid
    // stays field-stable and does not drift across wrap boundaries when
    // `line_index` grows. Field/timebase phase is reconstructed downstream via
    // the contract helpers and is intentionally not baked into `source_x`.
    int phase_step_clocks_int = int(floor(ClocksPerLine + 0.5)) % clock_factor_int;
    int row_phase_clocks_int = (line_index_int * phase_step_clocks_int) % clock_factor_int;
    float phase_clocks = float(row_phase_clocks_int);

    // Output samples live directly in the pixel-clock domain. Active source
    // texels are held for `ClockFactor` clocks, while blanking remains at the
    // native 1-clock resolution.
    float source_x = (output_x - active_left - phase_clocks) / clock_factor;

    bool in_active_y = line_index >= active_top && line_index < active_top + active_source_height;
    if (!in_active_y) {
        source_sample_pos = vec2(-1.0);
        return false;
    }

    bool in_active_x = source_x >= 0.0 && source_x < config.SourceSize.x;
    if (!in_active_x) {
        source_sample_pos = vec2(-1.0);
        return false;
    }

    float active_y = line_index - active_top;
    float source_y = (IsInterlaced > 0.5) ? (active_y * 2.0 + field_parity) : active_y;
    source_sample_pos = vec2(source_x, source_y);
    return true;
}

vec3 fetch_source_sample(float source_x, float source_y)
{
    if (source_x < 0.0 || source_x >= config.SourceSize.x ||
        source_y < 0.0 || source_y >= config.SourceSize.y) {
        return vec3(0.0);
    }

    vec2 texel = vec2(source_x + 0.5, source_y + 0.5) * config.SourceSize.zw;
    return texture(Source, texel).rgb;
}

vec3 sample_active_content(vec2 source_sample_pos)
{
    float source_x = floor(source_sample_pos.x);
    float source_y = floor(source_sample_pos.y);
    return fetch_source_sample(source_x, source_y);
}

void main()
{
    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);

    float frame_width_int = ceil(FrameWidth);
    float frame_height_int = ceil(FrameHeight);
    bool in_frame_x = (output_x >= 0.0 && output_x < frame_width_int);
    bool in_frame_y = (output_y >= 0.0 && output_y < frame_height_int);
    bool in_frame = in_frame_x && in_frame_y;

    if (!in_frame) {
#ifdef OPTION_DEBUG
        if (FRAME_VIZ_PADDING > 0.5) {
            FragColor = vec4(vec3(1.0, 0.0, 1.0) * 0.5, 0.0);
        } else {
            FragColor = vec4(0.0);
        }
#else
        FragColor = vec4(0.0);
#endif  // OPTION_DEBUG
        return;
    }

    vec2 source_sample_pos;
    bool in_active = sample_maps_to_active_time(output_x, output_y, source_sample_pos);

    vec3 color = in_active ? sample_active_content(source_sample_pos) : vec3(0.0);

#ifdef OPTION_DEBUG
    if (!in_active && in_frame && FRAME_VIZ_BLANKING > 0.5) {
        color = vec3(1.0, 1.0, 0.0) * 0.5;
    } else if (!in_frame && FRAME_VIZ_PADDING > 0.5) {
        color = vec3(1.0, 0.0, 1.0) * 0.5;
    }
#endif  // OPTION_DEBUG

    FragColor = vec4(color, 1.0);
}
