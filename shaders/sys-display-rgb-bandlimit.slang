#version 450

// Filename: sys-display-rgb-bandlimit.slang
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
// Combined System + Display RGB bandlimit
// ------------------------------
// Input: Voltage
// Output: Voltage
//
// Consolidates two cascaded Gaussian bandlimit passes into a single pass
// using variance addition: sigma_total = sqrt(sigma_sys^2 + sigma_disp^2)

#include "common.inc"
#include "modulation.inc"
#include "bandlimit.inc"

#include "menus/parameters/user-common.inc"
#include "menus/parameters/display-rgb.inc"
#include "menus/parameters/sys-rgb.inc"
#include "menus/parameters/sys-timing.inc"

#pragma name SysDisplayRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

#pragma parameter SYS_DISPLAY_RGB_BANDLIMIT_BYPASS "Bypass System+Display RGB Bandlimit" 0.0 0.0 1.0 1.0

// Push constants with combined parameter sets
layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float SYS_DISPLAY_RGB_BANDLIMIT_BYPASS;
    float V_LINES_PER_FIELD;
    float V_INTERLACE_LINES;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float SHORTEN_ODD_FIELD_TIME;
    float SYS_BANDWIDTH_R;
    float SYS_BANDWIDTH_G;
    float SYS_BANDWIDTH_B;
    float SYS_CUTOFF_ATTEN_R;
    float SYS_CUTOFF_ATTEN_G;
    float SYS_CUTOFF_ATTEN_B;
    float DISPLAY_BANDLIMIT_R;
    float DISPLAY_BANDLIMIT_G;
    float DISPLAY_BANDLIMIT_B;
    float DISPLAY_CUTOFF_ATTEN_R;
    float DISPLAY_CUTOFF_ATTEN_G;
    float DISPLAY_CUTOFF_ATTEN_B;
} config;

#define SYS_DISPLAY_RGB_BANDLIMIT_BYPASS config.SYS_DISPLAY_RGB_BANDLIMIT_BYPASS
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define V_INTERLACE_LINES config.V_INTERLACE_LINES
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#define SYS_BANDWIDTH_R config.SYS_BANDWIDTH_R
#define SYS_BANDWIDTH_G config.SYS_BANDWIDTH_G
#define SYS_BANDWIDTH_B config.SYS_BANDWIDTH_B

#define SYS_CUTOFF_ATTEN_R config.SYS_CUTOFF_ATTEN_R
#define SYS_CUTOFF_ATTEN_G config.SYS_CUTOFF_ATTEN_G
#define SYS_CUTOFF_ATTEN_B config.SYS_CUTOFF_ATTEN_B

#define DISPLAY_BANDLIMIT_R config.DISPLAY_BANDLIMIT_R
#define DISPLAY_BANDLIMIT_G config.DISPLAY_BANDLIMIT_G
#define DISPLAY_BANDLIMIT_B config.DISPLAY_BANDLIMIT_B

#define DISPLAY_CUTOFF_ATTEN_R config.DISPLAY_CUTOFF_ATTEN_R
#define DISPLAY_CUTOFF_ATTEN_G config.DISPLAY_CUTOFF_ATTEN_G
#define DISPLAY_CUTOFF_ATTEN_B config.DISPLAY_CUTOFF_ATTEN_B

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float DISPLAY_BIAS_R;
    float DISPLAY_BIAS_G;
    float DISPLAY_BIAS_B;
    float DISPLAY_GAIN_R;
    float DISPLAY_GAIN_G;
    float DISPLAY_GAIN_B;
    float USER_BLUE_ONLY;
} global;

#define DISPLAY_BIAS_R global.DISPLAY_BIAS_R
#define DISPLAY_BIAS_G global.DISPLAY_BIAS_G
#define DISPLAY_BIAS_B global.DISPLAY_BIAS_B

#define DISPLAY_GAIN_R global.DISPLAY_GAIN_R
#define DISPLAY_GAIN_G global.DISPLAY_GAIN_G
#define DISPLAY_GAIN_B global.DISPLAY_GAIN_B

#define USER_PICTURE global.USER_PICTURE
#define USER_BRIGHTNESS global.USER_BRIGHTNESS
#define USER_GAMMA global.USER_GAMMA
#define USER_BLUE_ONLY global.USER_BLUE_ONLY

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec3 sigma;
layout(location = 2) out vec3 gain;
layout(location = 3) out vec3 bias;
layout(location = 4) out TimebaseConfig tb;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Precompute filter characteristics
    tb = compute_timebase(
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

    vec3 sigma_sys;
    vec3 sigma_disp;

    sigma_sys.x = sigma_tb(tb, SYS_BANDWIDTH_R, SYS_CUTOFF_ATTEN_R);
    sigma_sys.y = sigma_tb(tb, SYS_BANDWIDTH_G, SYS_CUTOFF_ATTEN_G);
    sigma_sys.z = sigma_tb(tb, SYS_BANDWIDTH_B, SYS_CUTOFF_ATTEN_B);
    sigma_disp.x = sigma_tb(tb, DISPLAY_BANDLIMIT_R, DISPLAY_CUTOFF_ATTEN_R);
    sigma_disp.y = sigma_tb(tb, DISPLAY_BANDLIMIT_G, DISPLAY_CUTOFF_ATTEN_G);
    sigma_disp.z = sigma_tb(tb, DISPLAY_BANDLIMIT_B, DISPLAY_CUTOFF_ATTEN_B);

    // Combine cascaded Gaussians via variance addition (sigma_total^2 = sigma1^2 + sigma2^2)
    sigma = sqrt(sigma_sys * sigma_sys + sigma_disp * sigma_disp);

    // Amplifier parameters
    gain = vec3(
        pow(10.0, DISPLAY_GAIN_R / 20.0),
        pow(10.0, DISPLAY_GAIN_G / 20.0),
        pow(10.0, DISPLAY_GAIN_B / 20.0));
    bias = vec3(
        DISPLAY_BIAS_R * 7.143e-3,
        DISPLAY_BIAS_G * 7.143e-3,
        DISPLAY_BIAS_B * 7.143e-3);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec3 sigma;
layout(location = 2) in vec3 gain;
layout(location = 3) in vec3 bias;
layout(location = 4) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (SYS_DISPLAY_RGB_BANDLIMIT_BYPASS > 0.5)
    {
        // Bypass: output unfiltered source
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Single Gaussian lobe convolution with combined sigma
    vec3 color = bandlimit_convolve_gaussian_x(vTexCoord, config.OutputSize, Source, sigma);
    
    // RGB amplifier
    color = gain * (color + bias);

    // Apply blue-only filter
    color.r *= 1.0 - USER_BLUE_ONLY;
    color.g *= 1.0 - USER_BLUE_ONLY;

    FragColor = vec4(color, 1.0);
}
