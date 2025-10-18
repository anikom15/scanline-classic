#version 450

/* Filename: composite.slang

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
    float BW_MODE;
    float SIGNAL_BANDWIDTH_Y;
    float SIGNAL_BANDWIDTH_C;
    float FILTER_CUTOFF_ATTEN_Y;
    float FILTER_CUTOFF_ATTEN_C;
    float FILTER_SIZE_YC;
    float COLOR_FILTER_MODE;
    float OVERSAMPLE_FACTOR;
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

#pragma parameter BW_MODE "Black & White Mode (0=Off, 1=On)" 0 0 1 1
#define BW_MODE config.BW_MODE

#pragma parameter SIGNAL_BANDWIDTH_Y "Signal Bandwidth Y (MHz)" 6.75 0.0 75.0 0.1
#define SIGNAL_BANDWIDTH_Y config.SIGNAL_BANDWIDTH_Y
#pragma parameter SIGNAL_BANDWIDTH_C "Signal Bandwidth C (MHz)" 1.3 0.0 6.75 0.01
#define SIGNAL_BANDWIDTH_C config.SIGNAL_BANDWIDTH_C

#pragma parameter FILTER_CUTOFF_ATTEN_Y "Filter Cutoff Attenuation Y (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_Y config.FILTER_CUTOFF_ATTEN_Y
#pragma parameter FILTER_CUTOFF_ATTEN_C "Filter Cutoff Attenuation C (dB)" 2.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_C config.FILTER_CUTOFF_ATTEN_C

#pragma parameter FILTER_SIZE_YC "Gaussian Filter Radius Y/C" 14.0 0.0 40.0 1.0
#define FILTER_SIZE_YC config.FILTER_SIZE_YC

#pragma parameter COLOR_FILTER_MODE "Color Filter Mode (0=Notch, 1=Comb, 2=Notch+Comb, 3=Feedback)" 0.0 0.0 3.0 1.0
#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#pragma parameter OVERSAMPLE_FACTOR "Oversample Factor" 1.0 1.0 16.0 1.0
#define OVERSAMPLE_FACTOR config.OVERSAMPLE_FACTOR

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

const vec3 TEN = vec3(10.0, 10.0, 10.0);

void main()
{
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

    // Modulation + Filter + Demodulation
    vec3 color = vec3(0.0); //texture(Source, vTexCoord).rgb;
    float f = 0.5 - fract(config.SourceSize.x * vTexCoord.x);

    vec3 c = 1.0 / pow(
        TEN, vec3(
            -FILTER_CUTOFF_ATTEN_Y,
            -FILTER_CUTOFF_ATTEN_C,
            -FILTER_CUTOFF_ATTEN_C)
        / TEN);
    vec3 res = vec3(
        720.0 / 6.75 * SIGNAL_BANDWIDTH_Y,
        720.0 / 6.75 * SIGNAL_BANDWIDTH_C,
        720.0 / 6.75 * SIGNAL_BANDWIDTH_C);
    vec3 sigma = vec3(
        sqrt(log(c.r)) / (res.x / (OVERSAMPLE_FACTOR * config.SourceSize.x)),
        sqrt(log(c.g)) / (res.y / (OVERSAMPLE_FACTOR * config.SourceSize.x)),
        sqrt(log(c.b)) / (res.z / (OVERSAMPLE_FACTOR * config.SourceSize.x)));

    vec2 tex = floor(config.SourceSize.xy * vTexCoord)
        * (config.SourceSize.zw) + 0.5 * (config.SourceSize.zw);
    vec2 dx = vec2(config.SourceSize.z, 0.0) / OVERSAMPLE_FACTOR;

    vec3 w;
    vec3 wsum = vec3(0.0);
    vec3 pixel;
    float n = -OVERSAMPLE_FACTOR * FILTER_SIZE_YC;
    float composite;
    float chroma;

    // Notch filter characteristics
    vec2 notch_res = vec2(
        720.0 / 6.75 * (SC_FREQ_HZ / 1.0e6 - SIGNAL_BANDWIDTH_C),
        720.0 / 6.75 * (SC_FREQ_HZ / 1.0e6 + SIGNAL_BANDWIDTH_C));
    vec2 notch_sigma = vec2(
        sqrt(log(c.g)) / (notch_res.x / (OVERSAMPLE_FACTOR * config.SourceSize.x)),
        sqrt(log(c.g)) / (notch_res.y / (OVERSAMPLE_FACTOR * config.SourceSize.x)));
    notch_sigma = notch_sigma * step(COLOR_FILTER_MODE, 0.5);
    float luma_hp = 0.0;
    float w_hp = 0.0;
    float wsum_hp = 0.0;

    do
    {
        float offset = (tex.x + n * dx.x)
            * config.SourceSize.x;
        pixel = texture(Source, tex + n * dx).rgb;
        float t = field_time + line * LINE_TIME + offset * pixel_time;
        chroma = pixel.g * sin(2.0 * PI * SC_FREQ_HZ * t)
            + pixel.b * cos(2.0 * PI * SC_FREQ_HZ * t);
        composite = pixel.r + chroma;
        pixel.r = composite;
        pixel.g = composite * sin(2.0 * PI * SC_FREQ_HZ * t)
            * (1.0 - BW_MODE);
        pixel.b = composite * cos(2.0 * PI * SC_FREQ_HZ * t)
            * (1.0 - BW_MODE);

        /*
        if (COLOR_FILTER_MODE > 2.0) {
            // Feedback filter
            chroma = pixel.g * sin(2.0 * PI * SC_FREQ_HZ * t)
                + pixel.b * cos(2.0 * PI * SC_FREQ_HZ * t);
            pixel.r = composite - BW_MODE * chroma;
        }
        */

        w = vec3(
            gaussian(n + f, sigma.x + notch_sigma.x),
            gaussian(n + f, sigma.y),
            gaussian(n + f, sigma.z));

        // Notch high-pass portion
        w_hp = 1.0 - gaussian(n + f, notch_sigma.y);
        luma_hp -= w_hp * pixel.r;
        wsum_hp += -w_hp;

        color += w * pixel;
        wsum += w;
        n = n + 1.0;
    } while (n <= FILTER_SIZE_YC);
    color = color / wsum;
    color.r = luma_hp / wsum_hp;
    color.g = 0.0;
    color.b = 0.0;
    //color.r += luma_hp;

    /*
    if (COLOR_FILTER_MODE < 1.0) {
        // Notch filter characteristics
        vec2 notch_res = vec2(
            720.0 / 6.75 * (SC_FREQ_HZ - SIGNAL_BANDWIDTH_C),
            720.0 / 6.75 * (SC_FREQ_HZ + SIGNAL_BANDWIDTH_C));
        vec2 notch_sigma = vec2(
            sqrt(log(c.g)) / (notch_res.x / (OVERSAMPLE_FACTOR * config.SourceSize.x)),
            sqrt(log(c.g)) / (notch_res.y / (OVERSAMPLE_FACTOR * config.SourceSize.x)));

        vec2 w_notch;
        vec2 wsum_notch = vec2(0.0, 1.0);
        // Notch filter weights
        // w.r += gaussian(n + f, notch_sigma.x)
        //    + 1.0 - gaussian(n + f, notch_sigma.y);
        w_notch.x = gaussian(n + f, notch_sigma.x);
        w_notch.y = gaussian(n + f, notch_sigma.y);
        w.r += w_notch.x + 1.0 - w_notch.y;
    }
    */

    // Adjust chroma amplitude
    color.g *= 2.0;
    color.b *= 2.0;
    FragColor = vec4(color, 1.0);
}