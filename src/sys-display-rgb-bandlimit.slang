#version 450

/* Filename: sys-display-rgb-bandlimit.slang

   Combined System + Display RGB bandlimit
   - Consolidates two cascaded Gaussian bandlimit passes into a single pass
     using variance addition: sigma_total = sqrt(sigma_sys^2 + sigma_disp^2)
   - Retains lobe-summation technique for precise horizontal filtering

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

#pragma name SysDisplayRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

// Push constants with combined parameter sets
layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;

    // Global bypass for the combined bandlimit
    float SYS_DISPLAY_RGB_BANDLIMIT_BYPASS;

    // System (source) chain parameters
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

    // Display chain parameters
    float DISPLAY_BANDLIMIT_R;
    float DISPLAY_BANDLIMIT_G;
    float DISPLAY_BANDLIMIT_B;
    float DISPLAY_CUTOFF_ATTEN_R;
    float DISPLAY_CUTOFF_ATTEN_G;
    float DISPLAY_CUTOFF_ATTEN_B;
} config;

#pragma parameter SYS_DISPLAY_RGB_BANDLIMIT_HEADER " ==== System + Display RGB Bandlimit Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter SYS_DISPLAY_RGB_BANDLIMIT_BYPASS "Sys+Display RGB bandlimit bypass" 0.0 0.0 1.0 1.0

#pragma parameter SYS_BANDWIDTH_R "System bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter SYS_BANDWIDTH_G "System bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter SYS_BANDWIDTH_B "System bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter SYS_CUTOFF_ATTEN_R "System cutoff attenuation R (dB)" 3.0 0.0 30.0 1.0
#pragma parameter SYS_CUTOFF_ATTEN_G "System cutoff attenuation G (dB)" 3.0 0.0 30.0 1.0
#pragma parameter SYS_CUTOFF_ATTEN_B "System cutoff attenuation B (dB)" 3.0 0.0 30.0 1.0
#pragma parameter SYS_GAIN_R "System gain R" 1.0 0.0 10.0 0.1
#pragma parameter SYS_GAIN_G "System gain G" 1.0 0.0 10.0 0.1
#pragma parameter SYS_GAIN_B "System gain B" 1.0 0.0 10.0 0.1
#pragma parameter SYS_BIAS_R "System bias R" 0.0 -1.0 1.0 0.01
#pragma parameter SYS_BIAS_G "System bias G" 0.0 -1.0 1.0 0.01
#pragma parameter SYS_BIAS_B "System bias B" 0.0 -1.0 1.0 0.01

#pragma parameter DISPLAY_BANDLIMIT_R "Display bandwidth R (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter DISPLAY_BANDLIMIT_G "Display bandwidth G (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter DISPLAY_BANDLIMIT_B "Display bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter DISPLAY_CUTOFF_ATTEN_R "Display cutoff attenuation R (dB)" 3.0 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_G "Display cutoff attenuation G (dB)" 3.0 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_B "Display cutoff attenuation B (dB)" 3.0 0.0 30.0 1.0

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
    // Compute per-stage sigmas (in uv texel units) using Rec.601 scaling
    vec3 sigma_sys = sigma601(
        vec3(config.SYS_BANDWIDTH_R, config.SYS_BANDWIDTH_G, config.SYS_BANDWIDTH_B),
        vec3(config.SYS_CUTOFF_ATTEN_R, config.SYS_CUTOFF_ATTEN_G, config.SYS_CUTOFF_ATTEN_B),
        config.OutputSize.x);

    vec3 sigma_disp = sigma601(
        vec3(config.DISPLAY_BANDLIMIT_R, config.DISPLAY_BANDLIMIT_G, config.DISPLAY_BANDLIMIT_B),
        vec3(config.DISPLAY_CUTOFF_ATTEN_R, config.DISPLAY_CUTOFF_ATTEN_G, config.DISPLAY_CUTOFF_ATTEN_B),
        config.OutputSize.x);

    // Combine cascaded Gaussians via variance addition (sigma_total^2 = sigma1^2 + sigma2^2)
    vec3 sigma_total = sqrt(sigma_sys * sigma_sys + sigma_disp * sigma_disp);

    // Single Gaussian lobe convolution with combined sigma
    vec3 color = bandlimit_convolve_gaussian_x(vTexCoord, config.OutputSize, Source, sigma_total);

    // Apply per-stage gains and biases sequentially (matches two-pass behavior)
    color.r = color.r * config.SYS_GAIN_R + config.SYS_BIAS_R;
    color.g = color.g * config.SYS_GAIN_G + config.SYS_BIAS_G;
    color.b = color.b * config.SYS_GAIN_B + config.SYS_BIAS_B;

    // Global bypass back to unfiltered source
    color = mix(color, texture(Source, vTexCoord).rgb, config.SYS_DISPLAY_RGB_BANDLIMIT_BYPASS);

    FragColor = vec4(color, 1.0);
}
