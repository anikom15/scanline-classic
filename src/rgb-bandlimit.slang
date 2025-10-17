#version 450

/* Filename: bandlimit.slang

   Copyright (C) 2020 guest(r) - guest.r@gmail.com
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

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float SIGNAL_BANDWIDTH_R;
    float SIGNAL_BANDWIDTH_G;
    float SIGNAL_BANDWIDTH_B;
    float FILTER_CUTOFF_ATTEN_R;
    float FILTER_CUTOFF_ATTEN_G;
    float FILTER_CUTOFF_ATTEN_B;
    float FILTER_SIZE_RGB;
    float SIGNAL_GAIN_R;
    float SIGNAL_GAIN_G;
    float SIGNAL_GAIN_B;
    float SIGNAL_OFFSET_R;
    float SIGNAL_OFFSET_G;
    float SIGNAL_OFFSET_B;
} config;

#pragma parameter SIGNAL_BANDWIDTH_R "Signal Bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_R config.SIGNAL_BANDWIDTH_R
#pragma parameter SIGNAL_BANDWIDTH_G "Signal Bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_G config.SIGNAL_BANDWIDTH_G
#pragma parameter SIGNAL_BANDWIDTH_B "Signal Bandwidth C (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_B config.SIGNAL_BANDWIDTH_B

#pragma parameter FILTER_CUTOFF_ATTEN_R "Filter Cutoff Attenuation A (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_R config.FILTER_CUTOFF_ATTEN_R
#pragma parameter FILTER_CUTOFF_ATTEN_G "Filter Cutoff Attenuation B (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_G config.FILTER_CUTOFF_ATTEN_G
#pragma parameter FILTER_CUTOFF_ATTEN_B "Filter Cutoff Attenuation C (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_B config.FILTER_CUTOFF_ATTEN_B

#pragma parameter FILTER_SIZE_RGB "Gaussian Filter Radius" 4.0 0.0 40.0 1.0
#define FILTER_SIZE_RGB config.FILTER_SIZE_RGB

#pragma parameter SIGNAL_GAIN_R "Signal Gain R" 1.0 0.0 10.0 0.1
#define SIGNAL_GAIN_R config.SIGNAL_GAIN_R
#pragma parameter SIGNAL_GAIN_G "Signal Gain G" 1.0 0.0 10.0 0.1
#define SIGNAL_GAIN_G config.SIGNAL_GAIN_G
#pragma parameter SIGNAL_GAIN_B "Signal Gain B" 1.0 0.0 10.0 0.1
#define SIGNAL_GAIN_B config.SIGNAL_GAIN_B

#pragma parameter SIGNAL_OFFSET_R "Signal Offset R" 0.0 -1.0 1.0 0.01
#define SIGNAL_OFFSET_R config.SIGNAL_OFFSET_R
#pragma parameter SIGNAL_OFFSET_G "Signal Offset G" 0.0 -1.0 1.0 0.01
#define SIGNAL_OFFSET_G config.SIGNAL_OFFSET_G
#pragma parameter SIGNAL_OFFSET_B "Signal Offset B" 0.0 -1.0 1.0 0.01
#define SIGNAL_OFFSET_B config.SIGNAL_OFFSET_B

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

#define COMPAT_TEXTURE(c,d) texture(c,d)
#define SourceSize config.SourceSize

const vec3 TEN = vec3(10.0, 10.0, 10.0);

void main()
{
    // Filter parameters
    vec3 res = vec3(
        720.0 / 6.75 * SIGNAL_BANDWIDTH_R,
        720.0 / 6.75 * SIGNAL_BANDWIDTH_G,
        720.0 / 6.75 * SIGNAL_BANDWIDTH_B);
    vec3 c = 1.0 / pow(
        TEN, vec3(
            -FILTER_CUTOFF_ATTEN_R,
            -FILTER_CUTOFF_ATTEN_G,
            -FILTER_CUTOFF_ATTEN_B) / TEN);
    vec3 sigma = vec3(
        sqrt(log(c.r)) / (res.x / SourceSize.x),
        sqrt(log(c.g)) / (res.y / SourceSize.x),
        sqrt(log(c.b)) / (res.z / SourceSize.x));

    float f = 0.5 - fract(SourceSize.x * vTexCoord.x);

    vec2 tex = floor(SourceSize.xy * vTexCoord)
        * SourceSize.zw + 0.5 * SourceSize.zw;
    vec3 color = vec3(0.0);
    vec2 dx  = vec2(SourceSize.z, 0.0);

    vec3 w;
    vec3 wsum = vec3(0.0);
    vec3 pixel;
    float n = -FILTER_SIZE_RGB;

    do
    {
        pixel = COMPAT_TEXTURE(Source, tex + n * dx).rgb;
        w = vec3(gaussian(n+f, sigma.x),
                 gaussian(n+f, sigma.y),
                 gaussian(n+f, sigma.z));
        color = color + w * pixel;
        wsum = wsum + w;
        n = n + 1.0;
    } while (n <= FILTER_SIZE_RGB);
    color = color / wsum;

    color.r = color.r * SIGNAL_GAIN_R + SIGNAL_OFFSET_R;
    color.g = color.g * SIGNAL_GAIN_G + SIGNAL_OFFSET_G;
    color.b = color.b * SIGNAL_GAIN_B + SIGNAL_OFFSET_B;
    FragColor = vec4(color, 1.0);
}
