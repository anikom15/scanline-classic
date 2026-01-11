#version 450

// Filename: frame.slang
//
// Copyright (C) 2025 W. M. Martinez
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
// Frame scaling and zero-stuffing
// --------------------------------
// Maps input texture (active content) to full video frame dimensions,
// scales by integer multiples, and applies zero-stuffing (renders each
// scanline once with blanking gaps between).
//
// Includes visualization modes to see full frame and padding regions.

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/scanraster.inc"
#include "menus/parameters/sys-timing.inc"

#pragma name Frame
#pragma format R8G8B8A8_UNORM

#pragma parameter FRAME_VIZ_ACTIVE "Show active content" 1.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_BLANKING "Show frame blanking (yellow)" 0.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_PADDING "Show padding (magenta)" 0.0 0.0 1.0 1.0

// Push constants
layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float FRAME_VIZ_ACTIVE;
    float FRAME_VIZ_BLANKING;
    float FRAME_VIZ_PADDING;
    float V_FREQ_MODE;
    float V_FREQ;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float DOUBLE_REFRESH;
    float SCANLINE_BLANK_WEIGHT;
} config;

#define FRAME_VIZ_ACTIVE config.FRAME_VIZ_ACTIVE
#define FRAME_VIZ_BLANKING config.FRAME_VIZ_BLANKING
#define FRAME_VIZ_PADDING config.FRAME_VIZ_PADDING
#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ

#define DOUBLE_REFRESH config.DOUBLE_REFRESH
#define SCANLINE_BLANK_WEIGHT config.SCANLINE_BLANK_WEIGHT

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float h_scale;
layout(location = 2) out float v_scale;
layout(location = 3) out float full_pad_left;
layout(location = 4) out float full_pad_top;
layout(location = 5) out float active_left_scaled;
layout(location = 6) out float active_top_scaled;
layout(location = 7) out float full_width_int;
layout(location = 8) out float full_height_int;
layout(location = 9) out float is_interlaced;
layout(location = 10) out float field;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Compute timebase configuration
    TimebaseConfig tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.xy,
        config.OutputSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK,
        PIXEL_CLOCK_MODE,
        H_FREQ_MODE,
        H_FREQ,
        V_FREQ_MODE,
        V_FREQ,
        H_BLANK_FUZZ,
        SHORTEN_ODD_FIELD_TIME);

    // Full video dimensions (with blanking) at actual pixel clock rate
    float full_width = tb.h_pixels;
    float full_height = (tb.is_interlaced < 0.5) ? tb.v_lines_per_field : tb.v_lines_per_frame;
    
    full_width_int = floor(full_width);
    full_height_int = floor(full_height);
    is_interlaced = tb.is_interlaced;
    field = tb.field;
    
    // Calculate integer scale factors for each dimension
    h_scale = max(floor(config.OutputSize.x / full_width), 1.0);
    v_scale = max(floor(config.OutputSize.y / full_height), 1.0);
    
    // Scaled full video dimensions
    float scaled_full_width = full_width_int * h_scale;
    float scaled_full_height = full_height_int * v_scale;
    
    // Center the scaled full video within output
    full_pad_left = floor((config.OutputSize.x - scaled_full_width) * 0.5);
    full_pad_top = floor((config.OutputSize.y - scaled_full_height) * 0.5);
    
    // Calculate scaled active region position
    active_left_scaled = full_pad_left + floor((scaled_full_width - config.OriginalSize.x * h_scale) * 0.5);
    active_top_scaled = full_pad_top + floor((scaled_full_height - config.OriginalSize.y * v_scale) * 0.5);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float h_scale;
layout(location = 2) in float v_scale;
layout(location = 3) in float full_pad_left;
layout(location = 4) in float full_pad_top;
layout(location = 5) in float active_left_scaled;
layout(location = 6) in float active_top_scaled;
layout(location = 7) in float full_width_int;
layout(location = 8) in float full_height_int;
layout(location = 9) in float is_interlaced;
layout(location = 10) in float field;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Sample active content with zero-stuffing applied
vec3 sample_active_content(float output_x, float output_y) {
    float scaled_active_x = output_x - active_left_scaled;
    float scaled_active_y = output_y - active_top_scaled;
    
    float original_x = floor(scaled_active_x / h_scale);
    float original_y = floor(scaled_active_y / v_scale);
    float v_scanline_offset = scaled_active_y - (original_y * v_scale);

    vec2 texCoord = (vec2(original_x, original_y) + 0.5) / config.OriginalSize.xy;
    
    // Interlaced field blanking: alternate drawing odd/even lines based on field
    if (is_interlaced > 0.5) {
        if (DOUBLE_REFRESH > 0.5)
            return texture(Source, texCoord).rgb * 0.707;
        // In interlaced mode, only render lines that match the current field
        int field_parity = int(mod(field, 2.0));
        int line_parity = int(mod(original_y, 2.0));
        
        // If this line doesn't match the current field, blank it
        if (line_parity != field_parity)
            return mix(texture(Source, texCoord).rgb, vec3(0.0), SCANLINE_BLANK_WEIGHT / 100.0);
    }
    
    if (v_scanline_offset < 1.0)
        return texture(Source, texCoord).rgb;

    return mix(texture(Source, texCoord).rgb, vec3(0.0), SCANLINE_BLANK_WEIGHT / 100.0);
}

void main()
{
    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);
    
    // Calculate scaled full video dimensions
    float scaled_full_width = full_width_int * h_scale;
    float scaled_full_height = full_height_int * v_scale;
    
    // Boundaries of frame area in output space
    float frame_left = full_pad_left;
    float frame_right = full_pad_left + scaled_full_width;
    float frame_top = full_pad_top;
    float frame_bottom = full_pad_top + scaled_full_height;
    
    // Boundaries of active region in output space
    float active_right = active_left_scaled + config.OriginalSize.x * h_scale;
    float active_bottom = active_top_scaled + config.OriginalSize.y * v_scale;
    
    bool in_frame = (output_x >= frame_left && output_x < frame_right &&
                     output_y >= frame_top && output_y < frame_bottom);
    bool in_active = (output_x >= active_left_scaled && output_x < active_right &&
                      output_y >= active_top_scaled && output_y < active_bottom);
    
    vec3 color;
    
    if (in_active && FRAME_VIZ_ACTIVE > 0.5) {
        color = sample_active_content(output_x, output_y);
    } else if (in_frame && !in_active && FRAME_VIZ_BLANKING > 0.5) {
        color = vec3(1.0, 1.0, 0.0) * 0.75;
    } else if (!in_frame && FRAME_VIZ_PADDING > 0.5) {
        color = vec3(1.0, 0.0, 1.0) * 0.75;
    } else {
        color = vec3(0.0);
    }

    FragColor = vec4(color, 1.0);
}
