#version 450

/* Filename: bandlimit.slang

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
#include "filter.h"
#include "bandlimit.inc"

#pragma name DisplayRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float DISPLAY_RGB_BANDLIMIT_BYPASS;
    float DISPLAY_BANDLIMIT_R;
    float DISPLAY_BANDLIMIT_G;
    float DISPLAY_BANDLIMIT_B;
    float DISPLAY_CUTOFF_ATTEN_R;
    float DISPLAY_CUTOFF_ATTEN_G;
    float DISPLAY_CUTOFF_ATTEN_B;
    float DISPLAY_GAIN_R;
    float DISPLAY_GAIN_G;
    float DISPLAY_GAIN_B;
    float DISPLAY_BIAS_R;
    float DISPLAY_BIAS_G;
    float DISPLAY_BIAS_B;
} config;

#pragma parameter DISPLAY_RGB_BANDLIMIT_HEADER " ==== Display RGB Bandlimit Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter DISPLAY_RGB_BANDLIMIT_BYPASS "Display RGB bandlimit bypass" 0.0 0.0 1.0 1.0
#define DISPLAY_RGB_BANDLIMIT_BYPASS config.DISPLAY_RGB_BANDLIMIT_BYPASS

#pragma parameter DISPLAY_BANDLIMIT_R "Display bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#define DISPLAY_BANDLIMIT_R config.DISPLAY_BANDLIMIT_R
#pragma parameter DISPLAY_BANDLIMIT_G "Display bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#define DISPLAY_BANDLIMIT_G config.DISPLAY_BANDLIMIT_G
#pragma parameter DISPLAY_BANDLIMIT_B "Display bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#define DISPLAY_BANDLIMIT_B config.DISPLAY_BANDLIMIT_B

#pragma parameter DISPLAY_CUTOFF_ATTEN_R "Display cutoff attenuation R (dB)" 3.0 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_R config.DISPLAY_CUTOFF_ATTEN_R
#pragma parameter DISPLAY_CUTOFF_ATTEN_G "Display cutoff attenuation G (dB)" 3.0 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_G config.DISPLAY_CUTOFF_ATTEN_G
#pragma parameter DISPLAY_CUTOFF_ATTEN_B "Display cutoff attenuation B (dB)" 3.0 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_B config.DISPLAY_CUTOFF_ATTEN_B

#pragma parameter DISPLAY_GAIN_R "Display gain R" 1.0 0.0 10.0 0.1
#define DISPLAY_GAIN_R config.DISPLAY_GAIN_R
#pragma parameter DISPLAY_GAIN_G "Display gain G" 1.0 0.0 10.0 0.1
#define DISPLAY_GAIN_G config.DISPLAY_GAIN_G
#pragma parameter DISPLAY_GAIN_B "Display gain B" 1.0 0.0 10.0 0.1
#define DISPLAY_GAIN_B config.DISPLAY_GAIN_B

#pragma parameter DISPLAY_BIAS_R "Display offset R" 0.0 -1.0 1.0 0.01
#define DISPLAY_BIAS_R config.DISPLAY_BIAS_R
#pragma parameter DISPLAY_BIAS_G "Display offset G" 0.0 -1.0 1.0 0.01
#define DISPLAY_BIAS_G config.DISPLAY_BIAS_G
#pragma parameter DISPLAY_BIAS_B "Display offset B" 0.0 -1.0 1.0 0.01
#define DISPLAY_BIAS_B config.DISPLAY_BIAS_B

layout(std140, set = 0, binding = 0) uniform UBO
{
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
    // Compute Gaussian sigma in uv-texel units via Rec.601 scaling
    vec3 sigma = sigma601(
        vec3(
            DISPLAY_BANDLIMIT_R,
            DISPLAY_BANDLIMIT_G,
            DISPLAY_BANDLIMIT_B),
        vec3(
            DISPLAY_CUTOFF_ATTEN_R,
            DISPLAY_CUTOFF_ATTEN_G,
            DISPLAY_CUTOFF_ATTEN_B),
        config.OutputSize.x);

    // Single-pass lobe-based horizontal Gaussian convolution
    vec3 color = bandlimit_convolve_gaussian_x(vTexCoord, config.OutputSize, Source, sigma);

    // Apply per-channel gain and bias
    color.r = color.r * DISPLAY_GAIN_R + DISPLAY_BIAS_R;
    color.g = color.g * DISPLAY_GAIN_G + DISPLAY_BIAS_G;
    color.b = color.b * DISPLAY_GAIN_B + DISPLAY_BIAS_B;

    // Bypass mix
    color = mix(color, texture(Source, vTexCoord).rgb, DISPLAY_RGB_BANDLIMIT_BYPASS);
    FragColor = vec4(color, 1.0);
}
