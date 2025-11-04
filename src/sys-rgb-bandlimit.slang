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
#include "filter.h"

#pragma name SysRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
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
    float SYS_BIAS_B;
} config;

#pragma parameter SYS_RGB_BANDLIMIT_HEADER " ==== System RGB Bandlimit Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter SYS_RGB_BANDLIMIT_BYPASS "System RGB bandlimit bypass" 0.0 0.0 1.0 1.0
#define SYS_RGB_BANDLIMIT_BYPASS config.SYS_RGB_BANDLIMIT_BYPASS

#pragma parameter SYS_BANDWIDTH_R "System bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#define SYS_BANDWIDTH_R config.SYS_BANDWIDTH_R
#pragma parameter SYS_BANDWIDTH_G "System bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#define SYS_BANDWIDTH_G config.SYS_BANDWIDTH_G
#pragma parameter SYS_BANDWIDTH_B "System bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#define SYS_BANDWIDTH_B config.SYS_BANDWIDTH_B

#pragma parameter SYS_CUTOFF_ATTEN_R "System cutoff attenuation R (dB)" 3.0 0.0 30.0 1.0
#define SYS_CUTOFF_ATTEN_R config.SYS_CUTOFF_ATTEN_R
#pragma parameter SYS_CUTOFF_ATTEN_G "System cutoff attenuation G (dB)" 3.0 0.0 30.0 1.0
#define SYS_CUTOFF_ATTEN_G config.SYS_CUTOFF_ATTEN_G
#pragma parameter SYS_CUTOFF_ATTEN_B "System cutoff attenuation B (dB)" 3.0 0.0 30.0 1.0
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
#define SYS_BIAS_B config.SYS_BIAS_B

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
            SYS_BANDWIDTH_R,
            SYS_BANDWIDTH_G,
            SYS_BANDWIDTH_B),
        vec3(
            SYS_CUTOFF_ATTEN_R,
            SYS_CUTOFF_ATTEN_G,
            SYS_CUTOFF_ATTEN_B),
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

    color.r = color.r * SYS_GAIN_R + SYS_BIAS_R;
    color.g = color.g * SYS_GAIN_G + SYS_BIAS_G;
    color.b = color.b * SYS_GAIN_B + SYS_BIAS_B;

    color = mix(color, texture(Source, vTexCoord).rgb, SYS_RGB_BANDLIMIT_BYPASS);
    FragColor = vec4(color, 1.0);
}
