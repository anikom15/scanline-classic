#version 450

// Filename: digital-svideo.slang
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
// Digital composite modulation: YCbCr → composite baseband (digital)
// -------------------------------------------------------------------
// Input: YCbCr video (Y in R, Cb in G, Cr in B)
// Output: YC (Y in R, modulated C in G)
//
// Performs digital color subcarrier modulation using explicit phase
// accumulation per pixel. Supports NTSC (227.5 cycles/line) and
// PAL (283.75 cycles/line) standards.
//
// Simplified: no timebase struct, no encoder setup pedestal. PAL
// alternation inferred from subcarrier frequency (PAL if > 4 MHz).

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"

#pragma name DigitalCompositeMod
#pragma format A2B10G10R10_UNORM_PACK32

#pragma parameter DIGITAL_COMPOSITE_MOD_BYPASS "Bypass digital composite mod" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    vec4 FrameSize;
    float OriginalFPS;
    uint FrameCount;
    float DIGITAL_COMPOSITE_MOD_BYPASS;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float V_FREQ_MODE;
    float V_FREQ;
    float H_BLANK_FUZZ;
    float SHORTEN_ODD_FIELD_TIME;
} config;

#define DIGITAL_COMPOSITE_MOD_BYPASS config.DIGITAL_COMPOSITE_MOD_BYPASS
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float line_phase_step;
layout(location = 2) out float field_phase_offset;
layout(location = 3) out float pal_sign_flag;
layout(location = 4) out float phase_per_pixel;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    // Use shared timebase to derive carrier phase parameters consistently
    TimebaseConfig tb_full = compute_timebase(
        config.FrameCount,
        TexCoord,
        config.OriginalSize.xy,
        config.OutputSize.xy,
        config.FrameSize.xy,
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

    CarrierPhaseConfig tb = extract_carrier_phase(tb_full);

    // Horizontal scale factor derived from timebase timing
    float h_scale = tb_full.pixel_time / tb.pixel_time_px;
    float scaled_total_pixels = tb_full.h_pixels * h_scale;
    float h_offset = (config.OutputSize.x - scaled_total_pixels) * 0.5;

    // Phase increment per output pixel (radians)
    phase_per_pixel = 2.0 * PI * tb.sc_freq_hz * tb.pixel_time_px;

    // Field phase offset includes centering
    field_phase_offset = tb.field_phase + h_offset * phase_per_pixel;

    // Line-to-line phase advance from fractional cycles-per-line
    float cycles_per_line = tb.sc_freq_hz / tb.h_freq_hz;
    line_phase_step = 2.0 * PI * fract(cycles_per_line);

    // PAL alternation flag: PAL (>4 MHz) flips V-axis chroma every line
    pal_sign_flag = step(4.0e6, tb.sc_freq_hz);
}

#pragma stage fragment

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float line_phase_step;
layout(location = 2) in float field_phase_offset;
layout(location = 3) in float pal_sign_flag;
layout(location = 4) in float phase_per_pixel;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (DIGITAL_COMPOSITE_MOD_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Pixel and line positions
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float pixel_x = floor(UV.x);
    float line = floor(UV.y);

    // Sample input YCbCr using scaled pixel coordinate
    vec3 ycbcr = texture(Source, vTexCoord).rgb;

    // Adjust chroma to signed range
    ycbcr.gb -= vec2(0.5);

    // Phase accumulation per pixel within scaled range
    float line_phase = line * line_phase_step;
    
    // Phase calculation: starts at 0 for top-left (pixel_x=0)
    // Includes line phase, field offset, and initial offset
    float phase = mod(pixel_x * phase_per_pixel + line_phase + field_phase_offset + PI, 2.0 * PI) - PI;

    // Carrier and PAL V-axis alternation
    vec2 carrier = sincos_phase_raw(phase);
    float pal_sign = 1.0 - 2.0 * mod(line, 2.0) * pal_sign_flag;

    // Modulate Cb/Cr onto subcarrier (Cb→sin, Cr→cos with PAL alternation)
    float chroma = ycbcr.g * carrier.x + pal_sign * ycbcr.b * carrier.y;

    // Scale for worst-case peak (sqrt(2) * 0.5 ≈ 0.707) and offset to UNORM [0, 1]
    // Peak occurs when Cb and Cr are both ±0.5 and aligned with carrier phase
    const float INV_SQRT2 = 0.70710678;
    chroma = chroma * INV_SQRT2 + 0.5;

    FragColor = vec4(ycbcr.r, chroma, 0.0, 1.0);
}