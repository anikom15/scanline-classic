#version 450

/* Filename: svideo.slang

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
#include "filter.h"

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ;
    float H_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float FILTER_ENCODE;
    float ENCODE_FILTER_BANDWIDTH_Y;
    float ENCODE_FILTER_BANDWIDTH_C;
    float ENCODE_CUTOFF_ATTEN_Y;
    float ENCODE_CUTOFF_ATTEN_C;
    float SIGNAL_BANDWIDTH_Y;
    float SIGNAL_BANDWIDTH_C;
    float FILTER_CUTOFF_ATTEN_Y;
    float FILTER_CUTOFF_ATTEN_C;
    float FILTER_SIZE_YC;
    float BW_MODE;
} config;

#pragma parameter V_LINES_PER_FIELD "Video Lines per Field" 262.5 0.0 540.0 0.5
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD

#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten Odd Field Time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#pragma parameter SC_FREQ "Subcarrier Frequency (0=3.58 MHz, 1=4.43 MHz)" 0.0 0.0 1.0 1.0
#define SC_FREQ config.SC_FREQ
#define SC_FREQ_HZ mix(NTSC_FSC, PAL_FSC, SC_FREQ)

#pragma parameter H_FREQ "Horizontal Frequency (kHz)" 15.73426 1.0 100.0 0.001
#define H_FREQ config.H_FREQ
#define H_FREQ_HZ (H_FREQ * 1.0e3)

#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal Blank Inactive Length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal Blank Inactive Unit (0=px, 1=µs, 2=%% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter FILTER_ENCODE "Enable Encode Prefilter (0=Off, 1=On)" 1.0 0.0 1.0 1.0
#define FILTER_ENCODE config.FILTER_ENCODE

#pragma parameter ENCODE_FILTER_BANDWIDTH_Y "Encode Prefilter Bandwidth Y (MHz)" 5.4 0.0 75.0 0.1
#define ENCODE_FILTER_BANDWIDTH_Y config.ENCODE_FILTER_BANDWIDTH_Y
#pragma parameter ENCODE_FILTER_BANDWIDTH_C "Encode Prefilter Bandwidth C (MHz)" 1.3 0.0 3.0 0.01
#define ENCODE_FILTER_BANDWIDTH_C config.ENCODE_FILTER_BANDWIDTH_C

#pragma parameter ENCODE_CUTOFF_ATTEN_Y "Encode Cutoff Attenuation Y (dB)" 3.0 0.0 30.0 1.0
#define ENCODE_CUTOFF_ATTEN_Y config.ENCODE_CUTOFF_ATTEN_Y
#pragma parameter ENCODE_CUTOFF_ATTEN_C "Encode Cutoff Attenuation C (dB)" 2.0 0.0 30.0 1.0
#define ENCODE_CUTOFF_ATTEN_C config.ENCODE_CUTOFF_ATTEN_C

#pragma parameter SIGNAL_BANDWIDTH_Y "Signal Bandwidth Y (MHz)" 6.75 0.0 75.0 0.1
#define SIGNAL_BANDWIDTH_Y config.SIGNAL_BANDWIDTH_Y
#pragma parameter SIGNAL_BANDWIDTH_C "Signal Bandwidth C (MHz)" 1.79 0.0 3.0 0.01
#define SIGNAL_BANDWIDTH_C config.SIGNAL_BANDWIDTH_C

#pragma parameter FILTER_CUTOFF_ATTEN_Y "Filter Cutoff Attenuation Y (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_Y config.FILTER_CUTOFF_ATTEN_Y
#pragma parameter FILTER_CUTOFF_ATTEN_C "Filter Cutoff Attenuation C (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_C config.FILTER_CUTOFF_ATTEN_C

#pragma parameter FILTER_SIZE_YC "Gaussian Filter Radius Y/C" 14.0 0.0 40.0 1.0
#define FILTER_SIZE_YC config.FILTER_SIZE_YC

#pragma parameter BW_MODE "Black & White Mode (0=Off, 1=On)" 0 0 1 1
#define BW_MODE config.BW_MODE

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (LINE_TIME * V_LINES_PER_FIELD)

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
    vec3 color = vec3(0.0); // texture(Source, vTexCoord).rgb;

    // Get all values needed for t:
    // field * FIELD_TIME + line * LINE_TIME + x * pixel_time
    float field = float(config.FrameCount % 2u);
    float field_time = FIELD_TIME * field;
    float line = floor(vTexCoord.y * config.SourceSize.y);
    float inactive_pixels;
    if (H_BLANK_INACTIVE_UNIT < 0.5)
        inactive_pixels = H_BLANK_INACTIVE_LEN;
    else if (H_BLANK_INACTIVE_UNIT < 1.5)
        inactive_pixels = H_BLANK_INACTIVE_LEN * 1.0e-6
            * H_FREQ_HZ * config.SourceSize.x;
    else
        inactive_pixels = H_BLANK_INACTIVE_LEN / 100.0
            * config.SourceSize.x;
    float total_pixels = config.SourceSize.x + inactive_pixels;
    float pixel_time = LINE_TIME / total_pixels;
    field_time -= pixel_time * field * SHORTEN_ODD_FIELD_TIME;

    // Prefilter characteristics
    vec3 sigma_encode = sigma601(
        vec3(
            ENCODE_FILTER_BANDWIDTH_Y,
            ENCODE_FILTER_BANDWIDTH_C,
            ENCODE_FILTER_BANDWIDTH_C),
        vec3(
            ENCODE_CUTOFF_ATTEN_Y,
            ENCODE_CUTOFF_ATTEN_C,
            ENCODE_CUTOFF_ATTEN_C),
        config.OutputSize.x);

    sigma_encode = mix(sigma_encode, vec3(0.0), 1.0 - FILTER_ENCODE);

    // Modulation + Filter + Demodulation
    vec3 sigma = sigma601(
        vec3(
            SIGNAL_BANDWIDTH_Y,
            SIGNAL_BANDWIDTH_C,
            SIGNAL_BANDWIDTH_C),
        vec3(
            FILTER_CUTOFF_ATTEN_Y,
            FILTER_CUTOFF_ATTEN_C,
            FILTER_CUTOFF_ATTEN_C),
        config.OutputSize.x);

    float f = 0.5 - fract(config.OutputSize.x * vTexCoord.x);
    vec2 tex = floor(config.OutputSize.xy * vTexCoord)
        * (config.OutputSize.zw) + 0.5 * (config.OutputSize.zw);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    vec3 w;
    vec3 wsum = vec3(0.0);
    vec3 pixel;
    float n = -FILTER_SIZE_YC;
    float chroma;

    do {
        float offset = (tex.x + n * dx.x)
            * config.SourceSize.x;
        float t = field_time + line * LINE_TIME + offset * pixel_time;

        pixel = texture(Source, tex + n * dx).rgb;
        chroma = pixel.g * sin(2.0 * PI * SC_FREQ_HZ * t)
            + pixel.b * cos(2.0 * PI * SC_FREQ_HZ * t);
        pixel.r = pixel.r + BW_MODE * chroma;
        pixel.g = chroma * sin(2.0 * PI * SC_FREQ_HZ * t)
            * (1.0 - BW_MODE);
        pixel.b = chroma * cos(2.0 * PI * SC_FREQ_HZ * t)
            * (1.0 - BW_MODE);
        w = vec3(
            gaussian(n + f, sigma.x + sigma_encode.x),
            gaussian(n + f, sigma.y + sigma_encode.y),
            gaussian(n + f, sigma.z + sigma_encode.z));
        color = color + w * pixel;
        wsum = wsum + w;
        n = n + 1.0;
    } while (n <= FILTER_SIZE_YC);
    color = color / wsum;

    // Adjust chroma amplitude
    color.g *= 2.0;
    color.b *= 2.0;
    FragColor = vec4(color, 1.0);
}