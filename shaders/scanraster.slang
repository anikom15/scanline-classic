#version 450

// Filename: scanraster-sdr.slang
//
// Copyright (C) 2023 W. M. Martinez
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
// Scan Raster
// ------------
// Input: Normalized RGB signal [0.0, 1.0]
// Output: Linear RGB signal [0.0, 1.0]
//
// Simulates scan raster effect by rendering the input texture
// onto a grid that mimics scanlines.
//
// Fixed scan rate; see multiscan.slang for variable scan rate input.

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/user-common.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/scanraster.inc"

#pragma name ScanRaster
#pragma format R16G16B16A16_SFLOAT

#pragma parameter SCANRASTER_BYPASS "Bypass Scan Raster" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;

    float V_FREQ_MODE;
    float V_FREQ;

    // User settings
    float USER_PICTURE;
    float USER_BRIGHTNESS;

    float V_LINES_PER_FIELD;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK;
    float PIXEL_CLOCK_MODE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float FIELD_ORDER;
    float SHORTEN_ODD_FIELD_TIME;
    float SCANRASTER_BYPASS;
    float SCANLINE_BLANK_WEIGHT;
    float DOUBLE_REFRESH;
} config;

#define USER_PICTURE config.USER_PICTURE
#define USER_BRIGHTNESS config.USER_BRIGHTNESS

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ

#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define FIELD_ORDER config.FIELD_ORDER
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#define SCANRASTER_BYPASS config.SCANRASTER_BYPASS
#define SCANLINE_BLANK_WEIGHT config.SCANLINE_BLANK_WEIGHT

#define DOUBLE_REFRESH config.DOUBLE_REFRESH

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float bt1886_a;
layout(location = 2) out float bt1886_b;
layout(location = 3) flat out int padding_top;
layout(location = 4) flat out int padding_bottom;
layout(location = 5) flat out int integer_scale;
layout(location = 6) out float active_region_start;
layout(location = 7) out float active_region_height;
layout(location = 8) out TimebaseConfig tb;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Precompute BT.1886 parameters for linearization
    const float gamma = 2.4;

    float black_level = 2.0 * USER_BRIGHTNESS / 100.0 - 1.0;
    float white_level = 2.0 * USER_PICTURE / 100.0 + black_level;
    bt1886_a = pow(white_level - black_level, gamma);
    bt1886_b = black_level / (white_level - black_level);

    // Precompute timebase parameters
    tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
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

    // Calculate padding needed for vertical centering with integer scaling
    // Find the largest integer scale factor that fits
    float exact_scale = config.OutputSize.y / config.OriginalSize.y;
    integer_scale = int(floor(exact_scale));

    // Calculate scaled input height using integer scale
    int scaled_input_height = int(config.OriginalSize.y) * integer_scale;
    int total_padding = int(config.OutputSize.y) - scaled_input_height;

    // If odd padding, add remainder to top
    padding_top = (total_padding + 1) / 2;
    padding_bottom = total_padding / 2;

    // Precompute active region parameters for texture coordinate remapping
    active_region_start = float(padding_top) / config.OutputSize.y;
    float active_region_end = float(int(config.OutputSize.y) - padding_bottom) / config.OutputSize.y;
    active_region_height = active_region_end - active_region_start;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float bt1886_a;
layout(location = 2) in float bt1886_b;
layout(location = 3) flat in int padding_top;
layout(location = 4) flat in int padding_bottom;
layout(location = 5) flat in int integer_scale;
layout(location = 6) in float active_region_start;
layout(location = 7) in float active_region_height;
layout(location = 8) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (SCANRASTER_BYPASS > 0.5)
    {
        // Linearize for later stages
        vec3 color = bt1886_linear(texture(Source, vTexCoord).rgb, bt1886_a, bt1886_b);
        FragColor = vec4(color, 1.0);
        return;
    }

    // Output pixel row index (integer)
    int output_y_px = int(floor(vTexCoord.y * config.OutputSize.y));

    // Check if we're in padding region
    if (output_y_px < padding_top || output_y_px >= int(config.OutputSize.y) - padding_bottom) {
        // Render black for padding lines
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Adjust output position to account for top padding
    int adjusted_output_y = output_y_px - padding_top;

    // Remap current Y coordinate from active region to full input texture [0,1]
    float remapped_y = (vTexCoord.y - active_region_start) / active_region_height;
    vec2 remapped_texcoord = vec2(vTexCoord.x, remapped_y);

    // Calculate which input line we should be sampling based on adjusted output position
    float input_line_float = float(adjusted_output_y) / float(integer_scale);
    int input_line = int(floor(input_line_float + 0.5));

    // Determine if we are in progressive or interlaced mode
    bool is_interlaced = (tb.is_interlaced > 0.5);
    float scanline_weight = SCANLINE_BLANK_WEIGHT * 0.01;

    // Field parity (0 for even, 1 for odd) with user-configurable order
    int field = 0;
    if (is_interlaced) {
        if (DOUBLE_REFRESH > 0.5) {
            // Bypass interlacing entirely
            vec3 color = bt1886_linear(texture(Source, remapped_texcoord).rgb, bt1886_a, bt1886_b);
            FragColor = vec4(0.5 * color, 1.0);  // Dim output to represent averaging
            return;
        }
        field = int(mod(tb.field + FIELD_ORDER, 2.0));
    }

    // Compute mask
    float mask = 0.0;

    if (is_interlaced) {
        // Check if this input line belongs to the current field (even/odd parity)
        int line_field = input_line & 1;
        if (line_field == field) {
            // This line belongs to current field; check if we're on the scanline
            int expected_output = input_line * integer_scale;
            mask = (adjusted_output_y == expected_output) ? 1.0 : 0.0;
        }
    } else {
        // Progressive: check if we're on a scanline for this input line
        int expected_output = input_line * integer_scale;
        mask = (adjusted_output_y == expected_output) ? 1.0 : 0.0;
    }

    vec3 color = bt1886_linear(texture(Source, remapped_texcoord).rgb, bt1886_a, bt1886_b);
    vec3 outColor = mix(mix(color, vec3(0.0), scanline_weight), color, mask);
    FragColor = vec4(outColor, 1.0);
}