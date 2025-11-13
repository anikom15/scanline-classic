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

#include "parameters/sys-timing.inc"
#include "parameters/scanraster.inc"

#pragma name ScanRaster
#pragma format R16G16B16A16_SFLOAT

#pragma parameter SCANRASTER_BYPASS "Bypass Scan Raster" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float V_LINES_PER_FIELD;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float FIELD_ORDER;
    float SHORTEN_ODD_FIELD_TIME;
    float SCANRASTER_BYPASS;
    float SCANLINE_BLANK_WEIGHT;
} config;

#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define FIELD_ORDER config.FIELD_ORDER
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#define SCANRASTER_BYPASS config.SCANRASTER_BYPASS
#define SCANLINE_BLANK_WEIGHT config.SCANLINE_BLANK_WEIGHT

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (SCANRASTER_BYPASS > 0.5)
    {
        // Linearize for later stages
        vec3 color = crt_linear(texture(Source, vTexCoord).rgb);
        FragColor = vec4(color, 1.0);
        return;
    }

    TimebaseConfig tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        config.OriginalFPS,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Determine monitor half-resolution (total lines including blanking)
    float design_v_lines = tb.h_freq_hz / config.OriginalFPS;

    // Determine if we are in progressive or interlaced mode
    bool is_interlaced = (config.OriginalSize.y > 1.5 * design_v_lines);
    float scanline_weight = SCANLINE_BLANK_WEIGHT * 0.01;

    // Field parity (0 for even, 1 for odd) with user-configurable order
    int field = 0;
    if (is_interlaced) {
        field = int(mod(tb.field + FIELD_ORDER, 2.0));
    }

    // Output pixel row index (integer)
    int output_y_px = int(floor(vTexCoord.y * config.OutputSize.y));

    // Input line index (integer, with rounding to nearest to avoid edge cases)
    int input_line = int(floor(tb.line + 0.5));

    // Compute mask
    float mask = 0.0;

    if (is_interlaced) {
        // Check if this input line belongs to the current field (even/odd parity)
        int line_field = input_line & 1;  // Bitwise AND with 1 gives exact parity
        if (line_field == field) {
            // This line belongs to current field; map it to output
            int input_line_in_output = int(floor(float(input_line) * config.OutputSize.y / config.OriginalSize.y + 0.5));
            mask = (output_y_px == input_line_in_output) ? 1.0 : 0.0;
        }
    } else {
        // Progressive: map all input lines to output
        int input_line_in_output = int(floor(float(input_line) * config.OutputSize.y / config.OriginalSize.y + 0.5));
        mask = (output_y_px == input_line_in_output) ? 1.0 : 0.0;
    }

    vec3 color = crt_linear(texture(Source, vTexCoord).rgb);
    vec3 outColor = mix(mix(color, vec3(0.0), scanline_weight), color, mask);
    FragColor = vec4(outColor, 1.0);
}