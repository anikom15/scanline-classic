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
    float FILTER_ENCODE;
    float SIGNAL_BANDWIDTH_Y;
    float SIGNAL_BANDWIDTH_C;
    float FILTER_CUTOFF_ATTEN_Y;
    float FILTER_CUTOFF_ATTEN_C;
    float FILTER_SIZE_YC;
    float COLOR_FILTER_MODE;
    float NOTCH_OFFSET_L;
    float NOTCH_OFFSET_R;
    float COMB_FILTER_TAPS;
    float NOTCH_COMB_W;
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
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal Blank Inactive Unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter FILTER_ENCODE "Filter Encode (0=Off, 1=On)" 1.0 0.0 1.0 1.0
#define FILTER_ENCODE config.FILTER_ENCODE

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

#pragma parameter COLOR_FILTER_MODE "Color Filter Mode (0=BS, 1=Comb, 2=0·1, 3=Feedback, 4=Off)" 0.0 0.0 4.0 1.0
#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#pragma parameter NOTCH_OFFSET_L "Notch Filter Left Cutoff Offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_L config.NOTCH_OFFSET_L
#pragma parameter NOTCH_OFFSET_R "Notch Filter Right Cutoff Offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_R config.NOTCH_OFFSET_R

#pragma parameter COMB_FILTER_TAPS "Comb Filter Taps" 1 1 3 1
#define COMB_FILTER_TAPS config.COMB_FILTER_TAPS

#pragma parameter NOTCH_COMB_W "Notch-Comb Mixing Weight" 0.5 0.0 1.0 0.1
#define NOTCH_COMB_W config.NOTCH_COMB_W

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (LINE_TIME * V_LINES_PER_FIELD)

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float BW_MODE;
    float NOTCH_TEST_LP;
    float NOTCH_TEST_HP;
} global;

#pragma parameter BW_MODE "Monochrome Display (0=Off, 1=On)" 0 0 1 1
#define BW_MODE global.BW_MODE

#pragma parameter NOTCH_TEST_LP "Notch Filter Test Lowpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_LP global.NOTCH_TEST_LP

#pragma parameter NOTCH_TEST_HP "Notch Filter Test Highpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_HP global.NOTCH_TEST_HP

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

vec3 prefilter(vec2 tex, vec2 dx, float f, vec3 sigma, int N)
{
    vec3 color = vec3(0.0);
    vec3 wsum = vec3(0.0);

    for (int n = -N; n <= FILTER_SIZE_YC; ++n) {
        vec3 pixel = texture(Source, tex + n * dx).rgb;
        vec3 w = vec3(
            gaussian(n + f, sigma.x),
            gaussian(n + f, sigma.y),
            gaussian(n + f, sigma.z));
        color = color + w * pixel;
        wsum = wsum + w;
    }
    return color / wsum;
}

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

    vec3 color = vec3(0.0); // texture(Source, vTexCoord).rgb;
    vec3 color_notch = vec3(0.0);
    vec3 color_comb = vec3(0.0);
    vec3 color_raw = vec3(0.0);

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
        sqrt(log(c.r)) / (res.x / config.OutputSize.x),
        sqrt(log(c.g)) / (res.y / config.OutputSize.x),
        sqrt(log(c.b)) / (res.z / config.OutputSize.x));

    float f = 0.5 - fract(config.OutputSize.x * vTexCoord.x);
    vec2 tex = floor(config.OutputSize.xy * vTexCoord)
        * (config.OutputSize.zw) + 0.5 * (config.OutputSize.zw);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    vec3 w;
    vec3 wsum = vec3(0.0);
    vec3 wsum_notch = vec3(0.0);
    vec3 wsum_comb = vec3(0.0);
    vec3 wsum_raw = vec3(0.0);
    vec3 pixel;
    float n = -FILTER_SIZE_YC;
    float composite;
    float chroma;

    // Notch prefilter characteristics
    vec2 notch_res = vec2(
        720.0 / 6.75 * (SC_FREQ_HZ / 1.0e6 + NOTCH_OFFSET_L),
        720.0 / 6.75 * (SC_FREQ_HZ / 1.0e6 - NOTCH_OFFSET_R));
    vec2 notch_sigma = vec2(
        sqrt(log(c.g)) / (notch_res.x / config.OutputSize.x),
        sqrt(log(c.g)) / (config.OutputSize.x / notch_res.y));
    float identity = 0.0;
    float t_identity = 0.0;
    float luma_hp = 0.0;
    float wsum_hp = 0.0;

    // Comb prefilter data
    vec2 comb_dy = vec2(0.0, -1.0 * config.SourceSize.w);

    // Modulation + Demodulation + Filtering
    do {
        float offset = (tex.x + n * dx.x)
            * config.SourceSize.x;
        // Encode prefilter
        if (FILTER_ENCODE > 0.5) {
            pixel = prefilter(tex + n * dx, dx, f, sigma, int(FILTER_SIZE_YC));
        } else {
            pixel = texture(Source, tex + n * dx).rgb;
        }
        float t = field_time + line * LINE_TIME + offset * pixel_time;
        chroma = pixel.g * sin(2.0 * PI * SC_FREQ_HZ * t)
            + pixel.b * cos(2.0 * PI * SC_FREQ_HZ * t);
        composite = pixel.r + chroma;

        if (n >= -0.5 && n <= 0.5) {
            identity = composite;
            t_identity = t;
        }

        pixel.r = composite;
        pixel.g = composite * sin(2.0 * PI * SC_FREQ_HZ * t);
        pixel.b = composite * cos(2.0 * PI * SC_FREQ_HZ * t);

        // Raw unfiltered portion
        w = vec3(
            gaussian(n + f, sigma.x),
            gaussian(n + f, sigma.y),
            gaussian(n + f, sigma.z));

        color_raw += w * pixel;
        wsum_raw += w;

        // Notch prefilter portion
        w = vec3(
            gaussian(n + f, sigma.x + notch_sigma.x),
            gaussian(n + f, sigma.y),
            gaussian(n + f, sigma.z));
        color_notch += w * pixel;
        wsum_notch += w;

        // Notch high-pass portion
        w.x = gaussian(n + f, notch_sigma.y);
        luma_hp += composite * w.x;
        wsum_hp += w.x;

        // Comb prefilter portion
        mat3 comb_taps_yuv = mat3(
            texture(Source, tex + n * dx + comb_dy).rgb,
            texture(Source, tex + n * dx + 2.0 * comb_dy).rgb,
            texture(Source, tex + n * dx + 3.0 * comb_dy).rgb
        );
        mat3 comb_vectors = mat3(
            vec3(1.0,
                sin(2.0 * PI * SC_FREQ_HZ * (t - LINE_TIME)),
                cos(2.0 * PI * SC_FREQ_HZ * (t - LINE_TIME))),
            vec3(1.0,
                sin(2.0 * PI * SC_FREQ_HZ * (t - 2.0 * LINE_TIME)),
                cos(2.0 * PI * SC_FREQ_HZ * (t - 2.0 * LINE_TIME))),
            vec3(1.0,
                sin(2.0 * PI * SC_FREQ_HZ * (t - 3.0 * LINE_TIME)),
                cos(2.0 * PI * SC_FREQ_HZ * (t - 3.0 * LINE_TIME))));
        vec3 comb_taps_composite = vec3(
            dot(comb_taps_yuv[0], comb_vectors[0]),
            dot(comb_taps_yuv[1], comb_vectors[1]),
            dot(comb_taps_yuv[2], comb_vectors[2]));

        if (COMB_FILTER_TAPS < 2) {
            chroma = 0.5 * (composite - comb_taps_composite.x);
            pixel.r = 0.5 * (composite + comb_taps_composite.x);
        } else if (COMB_FILTER_TAPS < 3) {
            chroma = 0.5 * (0.5 * composite - comb_taps_composite.x - 0.5 * comb_taps_composite.y);
            pixel.r = 0.5 * (0.5 * composite + comb_taps_composite.x + 0.5 * comb_taps_composite.y);
            chroma *= 2.0;
        } else {
            chroma = 1.0 / 3.0 * (0.5 * composite - comb_taps_composite.x - comb_taps_composite.y - 0.5 * comb_taps_composite.z);
            pixel.r = 1.0 / 3.0 * (0.5 * composite + comb_taps_composite.x + comb_taps_composite.y + 0.5 * comb_taps_composite.z);
            chroma *= 3.0;
        }
        pixel.g = chroma * sin(2.0 * PI * SC_FREQ_HZ * t);
        pixel.b = chroma * cos(2.0 * PI * SC_FREQ_HZ * t);

        w = vec3(
            gaussian(n + f, sigma.x),
            gaussian(n + f, sigma.y),
            gaussian(n + f, sigma.z));

        color_comb += w * pixel;
        wsum_comb += w;

        n = n + 1.0;
    } while (n <= FILTER_SIZE_YC);
    color_notch /= wsum_notch;
    color_notch.r += identity - luma_hp / wsum_hp;
    color_comb /= wsum_comb;
    color_raw /= wsum_raw;

    if (COLOR_FILTER_MODE < 0.5) {
        if (NOTCH_TEST_LP > 0.5) {
            color_notch.r -= identity - luma_hp / wsum_hp;
        } else if (NOTCH_TEST_HP > 0.5) {
            color_notch.r = identity - luma_hp / wsum_hp;
        }
        color = color_notch;
    } else if (COLOR_FILTER_MODE < 1.5) {
        color = color_comb;
    } else if (COLOR_FILTER_MODE < 2.5) {
        color = mix(color_notch, color_comb, NOTCH_COMB_W);
    } else if (COLOR_FILTER_MODE < 3.5) {
        chroma = 2.0 * color_raw.g * sin(2.0 * PI * SC_FREQ_HZ * t_identity)
            + 2.0 * color_raw.b * cos(2.0 * PI * SC_FREQ_HZ * t_identity);
        color_raw.r = identity - chroma;
        color = color_raw;
    } else {
        color = color_raw;
    }

    if (BW_MODE > 0.5) {
        color = color_raw;
        color.g = 0.0;
        color.b = 0.0;
    }

    // Adjust chroma amplitude
    color.g *= 2.0;
    color.b *= 2.0;
    FragColor = vec4(color, 1.0);
}