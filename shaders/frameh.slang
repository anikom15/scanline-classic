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
// RGB stores the raster sample value for each framed sample, while A stores
// `phase_rel_sample`. Timing and frame geometry are reconstructed downstream
// from the contract API rather than a texture-carried metadata payload.

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
    float DOUBLE_REFRESH;
    float SCANLINE_BLANK_WEIGHT;
    float PHASE_ZERO;

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
#define PHASE_ZERO config.PHASE_ZERO

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
layout(location = 4) flat out float INITIAL_FIELD_PHASE_FRAC;
layout(location = 5) flat out float FullFrameHeight;
layout(location = 6) flat out float IsInterlaced;
layout(location = 7) flat out float Field;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    FS_ORIGINAL = contract_fs_original(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    FrameWidth = contract_frame_width(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

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

    INITIAL_FIELD_PHASE_FRAC = contract_initial_field_phase_frac(
        FieldCount,
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ,
        PHASE_ZERO);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 3) flat in float FS_ORIGINAL;
layout(location = 4) flat in float INITIAL_FIELD_PHASE_FRAC;
layout(location = 5) flat in float FullFrameHeight;
layout(location = 6) flat in float IsInterlaced;
layout(location = 7) flat in float Field;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

bool sample_maps_to_active_time(float output_x, float output_y, out float source_sample_index)
{
    float frame_width_int = ceil(FrameWidth);
    float frame_height_int = ceil(FrameHeight);
    float active_left = floor((frame_width_int - config.SourceSize.x) * 0.5);
    float active_top = floor((frame_height_int - config.SourceSize.y) * 0.5);

    float line_index = floor(output_y);
    float field_output_index = line_index * FrameWidth + output_x;
    float input_index = floor(field_output_index);

    float line_active_start = floor(line_index * FrameWidth + active_left);
    float line_active_end = line_active_start + config.SourceSize.x;

    bool in_active_y = line_index >= active_top && line_index < active_top + config.SourceSize.y;
    bool in_active_x = input_index >= line_active_start && input_index < line_active_end;

    if (!(in_active_x && in_active_y)) {
        source_sample_index = -1.0;
        return false;
    }

    float active_x = input_index - line_active_start;
    float active_y = line_index - active_top;
    source_sample_index = active_y * config.SourceSize.x + active_x;
    return true;
}

vec3 sample_active_content(float source_sample_index)
{
    float input_data_limit = max(config.SourceSize.x * config.SourceSize.y - 1.0, 0.0);
    float sample_index = clamp(source_sample_index, 0.0, input_data_limit);

    vec2 texel =
        vec2(mod(sample_index, config.SourceSize.x) + 0.5, floor(sample_index / config.SourceSize.x) + 0.5)
        * config.SourceSize.zw;
    return texture(Source, texel).rgb;
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

    float source_sample_index;
    bool in_active = sample_maps_to_active_time(output_x, output_y, source_sample_index);

    vec3 color = in_active ? sample_active_content(source_sample_index) : vec3(0.0);
    float field_output_index = output_y * FrameWidth + output_x;
    float PhaseRelSample = fract(field_output_index);

#ifdef OPTION_DEBUG
    if (!in_active && in_frame && FRAME_VIZ_BLANKING > 0.5) {
        color = vec3(1.0, 1.0, 0.0) * 0.5;
    } else if (!in_frame && FRAME_VIZ_PADDING > 0.5) {
        color = vec3(1.0, 0.0, 1.0) * 0.5;
    }
#endif  // OPTION_DEBUG

    FragColor = vec4(color, PhaseRelSample);
}
