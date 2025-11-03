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

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float RGB_BANDLIMIT_BYPASS;
    float SIGNAL_BANDWIDTH_R;
    float SIGNAL_BANDWIDTH_G;
    float SIGNAL_BANDWIDTH_B;
    float FILTER_CUTOFF_ATTEN_R;
    float FILTER_CUTOFF_ATTEN_G;
    float FILTER_CUTOFF_ATTEN_B;
    float SIGNAL_GAIN_R;
    float SIGNAL_GAIN_G;
    float SIGNAL_GAIN_B;
    float SIGNAL_OFFSET_R;
    float SIGNAL_OFFSET_G;
    float SIGNAL_OFFSET_B;
} config;

#pragma parameter RGB_BANDLIMIT_BYPASS "RGB Bandlimit Bypass" 0.0 0.0 1.0 1.0
#define RGB_BANDLIMIT_BYPASS config.RGB_BANDLIMIT_BYPASS

#pragma parameter SIGNAL_BANDWIDTH_R "Signal Bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_R config.SIGNAL_BANDWIDTH_R
#pragma parameter SIGNAL_BANDWIDTH_G "Signal Bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_G config.SIGNAL_BANDWIDTH_G
#pragma parameter SIGNAL_BANDWIDTH_B "Signal Bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_B config.SIGNAL_BANDWIDTH_B

#pragma parameter FILTER_CUTOFF_ATTEN_R "Filter Cutoff Attenuation R (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_R config.FILTER_CUTOFF_ATTEN_R
#pragma parameter FILTER_CUTOFF_ATTEN_G "Filter Cutoff Attenuation G (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_G config.FILTER_CUTOFF_ATTEN_G
#pragma parameter FILTER_CUTOFF_ATTEN_B "Filter Cutoff Attenuation B (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_B config.FILTER_CUTOFF_ATTEN_B

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

vec3 gaussian3(float x, vec3 sigma)
{
    float x2 = sq(x);
    vec3 k = -0.5 / (sigma * sigma);
    return exp(k * x2);
}

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
    // Standard texturing coordinates (source pixel grid)
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 A = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * config.OutputSize.zw;

    // Accumulated color
    vec3 color = vec3(0.0);
    vec3 wsum = vec3(0.0);

    // Step size in texture coordinates
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    // Filter parameters
    vec3 sigma = sigma601(
        vec3(
            SIGNAL_BANDWIDTH_R,
            SIGNAL_BANDWIDTH_G,
            SIGNAL_BANDWIDTH_B),
        vec3(
            FILTER_CUTOFF_ATTEN_R,
            FILTER_CUTOFF_ATTEN_G,
            FILTER_CUTOFF_ATTEN_B),
        config.OutputSize.x);

    // Center point (n = 0)
    vec3 pixel = texture(Source, Tex).rgb;
    vec3 w = gaussian3(A.x, sigma);
    color = w * pixel;
    wsum  = w;

    // Gaussian right and left lobes
    const float THRESHOLD = 1.0 / 510.0;

    for (int n = 1; n <= 128; ++n) {
        float nf = float(n) + A.x;
        w = gaussian3(nf, sigma);

        vec3 pr = texture(Source, Tex + float(n) * dx).rgb;
        vec3 pl = texture(Source, Tex - float(n) * dx).rgb;

        vec3 wpr = w * pr;
        vec3 wpl = w * pl;

        // stop when both sides are negligible
        if (all(lessThan(w, vec3(THRESHOLD))))
            break;

        color += wpr + wpl;
        wsum  += w + w;
    }
    color /= wsum;

    color.r = color.r * SIGNAL_GAIN_R + SIGNAL_OFFSET_R;
    color.g = color.g * SIGNAL_GAIN_G + SIGNAL_OFFSET_G;
    color.b = color.b * SIGNAL_GAIN_B + SIGNAL_OFFSET_B;

    color = mix(color, texture(Source, vTexCoord).rgb, RGB_BANDLIMIT_BYPASS);
    FragColor = vec4(color, 1.0);
}
