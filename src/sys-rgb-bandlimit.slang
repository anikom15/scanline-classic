#version 450

/* Filename: sys-rgb-bandlimit.slang

   Copyright (C) 2025 W. M. Martinez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include "common.h"
#include "color.h"
#include "bandlimit.inc"
#include "modulation.inc"

#pragma name SysRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float SYS_RGB_BANDLIMIT_BYPASS;
    float SYS_BANDWIDTH_R;
    float SYS_BANDWIDTH_G;
    float SYS_BANDWIDTH_B;
    float SYS_CUTOFF_ATTEN_R;
    float SYS_CUTOFF_ATTEN_G;
    float SYS_CUTOFF_ATTEN_B;
    float SYS_GAIN_R;
    float SYS_GAIN_G;
    float SYS_GAIN_B;
    float SYS_BIAS_R;
    float SYS_BIAS_G;
} config;

#pragma parameter SYS_RGB_BANDLIMIT_HEADER " ==== System RGB Bandlimit Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter SYS_RGB_BANDLIMIT_BYPASS "System RGB bandlimit bypass" 0.0 0.0 1.0 1.0
#define SYS_RGB_BANDLIMIT_BYPASS config.SYS_RGB_BANDLIMIT_BYPASS

#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
#define V_FREQ config.V_FREQ

#pragma parameter V_LINES_PER_FIELD "Video lines per field" 262.5 0.0 540.0 0.5
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD

#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#define SC_FREQ_MODE config.SC_FREQ_MODE

#pragma parameter SC_FREQ "Custom subcarrier frequency (MHz)" 3.579545 0.0 10.0 0.000001
#define SC_FREQ config.SC_FREQ

#define H_FREQ_HZ (V_FREQ * V_LINES_PER_FIELD)

#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter SYS_BANDWIDTH_R "System bandwidth R (MHz)" 5.4 0.0 75.0 0.01
#define SYS_BANDWIDTH_R config.SYS_BANDWIDTH_R
#pragma parameter SYS_BANDWIDTH_G "System bandwidth G (MHz)" 5.4 0.0 75.0 0.01
#define SYS_BANDWIDTH_G config.SYS_BANDWIDTH_G
#pragma parameter SYS_BANDWIDTH_B "System bandwidth B (MHz)" 5.4 0.0 75.0 0.01
#define SYS_BANDWIDTH_B config.SYS_BANDWIDTH_B

#pragma parameter SYS_CUTOFF_ATTEN_R "System cutoff attenuation R (dB)" 12.5 0.0 30.0 1.0
#define SYS_CUTOFF_ATTEN_R config.SYS_CUTOFF_ATTEN_R
#pragma parameter SYS_CUTOFF_ATTEN_G "System cutoff attenuation G (dB)" 12.5 0.0 30.0 1.0
#define SYS_CUTOFF_ATTEN_G config.SYS_CUTOFF_ATTEN_G
#pragma parameter SYS_CUTOFF_ATTEN_B "System cutoff attenuation B (dB)" 12.5 0.0 30.0 1.0
#define SYS_CUTOFF_ATTEN_B config.SYS_CUTOFF_ATTEN_B

#pragma parameter SYS_GAIN_R "System gain R" 1.0 0.0 10.0 0.1
#define SYS_GAIN_R config.SYS_GAIN_R
#pragma parameter SYS_GAIN_G "System gain G" 1.0 0.0 10.0 0.1
#define SYS_GAIN_G config.SYS_GAIN_G
#pragma parameter SYS_GAIN_B "System gain B" 1.0 0.0 10.0 0.1
#define SYS_GAIN_B config.SYS_GAIN_B

#pragma parameter SYS_BIAS_R "System bias R" 0.0 -1.0 1.0 0.01
#define SYS_BIAS_R config.SYS_BIAS_R
#pragma parameter SYS_BIAS_G "System bias G" 0.0 -1.0 1.0 0.01
#define SYS_BIAS_G config.SYS_BIAS_G
#pragma parameter SYS_BIAS_B "System bias B" 0.0 -1.0 1.0 0.01

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float SYS_BIAS_B;
} global;

#define SYS_BIAS_B global.SYS_BIAS_B

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
    // Compute Gaussian sigma in uv-texel units via Rec.601 scaling
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        config.OriginalSize.x,
        config.OutputSize.x,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT
    );
    vec3 sigma;
    sigma.x = sigma_tb(tb, SYS_BANDWIDTH_R, SYS_CUTOFF_ATTEN_R);
    sigma.y = sigma_tb(tb, SYS_BANDWIDTH_G, SYS_CUTOFF_ATTEN_G);
    sigma.z = sigma_tb(tb, SYS_BANDWIDTH_B, SYS_CUTOFF_ATTEN_B);

    // Single-pass lobe-based horizontal Gaussian convolution
    vec3 color = bandlimit_convolve_gaussian_x(vTexCoord, config.OutputSize, Source, sigma);

    // Apply per-channel gain and bias
    color.r = color.r * SYS_GAIN_R + SYS_BIAS_R;
    color.g = color.g * SYS_GAIN_G + SYS_BIAS_G;
    color.b = color.b * SYS_GAIN_B + SYS_BIAS_B;

    // Bypass mix
    color = mix(color, texture(Source, vTexCoord).rgb, SYS_RGB_BANDLIMIT_BYPASS);
    FragColor = vec4(color, 1.0);
}
