#version 450

/* Filename: composite-demod.slang

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

#pragma name CompositeDemod
#pragma format R8G8B8A8_UNORM

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float BYPASS_COMPOSITE_DEMOD;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float COLOR_FILTER_MODE;
    float DISPLAY_BANDWIDTH_Y;
    float DISPLAY_BANDWIDTH_C;
    float DISPLAY_CUTOFF_ATTEN_Y;
    float DISPLAY_CUTOFF_ATTEN_C;
    float FEEDBACK_FILTER_MODE;
    float FEEDBACK_NOTCH_Y_CORRECT;
    float FEEDBACK_RAW_Y_CORRECT;
    float BW_MODE;
} config;

#pragma parameter COMPOSITE_DEMOD_HEADER " ==== Composite Video Demod. Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_COMPOSITE_DEMOD "Bypass Composite demodulation (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define BYPASS_COMPOSITE_DEMOD config.BYPASS_COMPOSITE_DEMOD

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

#pragma parameter COLOR_FILTER_MODE "Filter mode (0=Notch,1=Comb,2=Notch+Comb,3=Off)" 0.0 0.0 3.0 1.0
#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#pragma parameter DISPLAY_BANDWIDTH_Y "Display Luma (Y) bandwidth (MHz)" 5.4 0.0 75.0 0.01
#define DISPLAY_BANDWIDTH_Y config.DISPLAY_BANDWIDTH_Y
#pragma parameter DISPLAY_BANDWIDTH_C "Display Chroma (C) bandwidth (MHz)" 2.7 0.0 15.0 0.01
#define DISPLAY_BANDWIDTH_C config.DISPLAY_BANDWIDTH_C

#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display Y cutoff attenuation (dB)" 12.5 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_Y config.DISPLAY_CUTOFF_ATTEN_Y
#pragma parameter DISPLAY_CUTOFF_ATTEN_C "Display C cutoff attenuation (dB)" 12.5 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_C config.DISPLAY_CUTOFF_ATTEN_C

#pragma parameter FEEDBACK_FILTER_MODE "Feedback filter (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define FEEDBACK_FILTER_MODE config.FEEDBACK_FILTER_MODE

#pragma parameter FEEDBACK_NOTCH_Y_CORRECT "Feedback Notch Y Correction" 0.86 0.0 10.0 0.01
#define FEEDBACK_NOTCH_Y_CORRECT config.FEEDBACK_NOTCH_Y_CORRECT

#pragma parameter FEEDBACK_RAW_Y_CORRECT "Feedback Raw Y Correction" 1.2 0.0 10.0 0.01
#define FEEDBACK_RAW_Y_CORRECT config.FEEDBACK_RAW_Y_CORRECT

#pragma parameter BW_MODE "Monitor mode (0=Off, 1=BW, 2=Y, 3=C, 4=Y+C)" 0 0 4 1
#define BW_MODE config.BW_MODE

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (1.0 / V_FREQ)

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
    if (BYPASS_COMPOSITE_DEMOD >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Use consolidated timebase helper
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Filter characteristics
    vec2 sigma = vec2(
        sigma_tb(tb, DISPLAY_BANDWIDTH_Y, DISPLAY_CUTOFF_ATTEN_Y),
        sigma_tb(tb, DISPLAY_BANDWIDTH_C, DISPLAY_CUTOFF_ATTEN_C));
    // Optimized symmetric lobed approach with early exit
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float UX = UV.x - 0.5;           // horizontal pixel edge shift
    float Ax = fract(UX);            // fractional horizontal position
    vec2 Tex = vec2((floor(UX) + 0.5) * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    vec3 color = vec3(0.0);
    vec3 wsum = vec3(0.0);

    // Process center sample
    float offset0 = Tex.x * config.OriginalSize.x;
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time;

    // R is Y, G is C
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0);

    float composite0 = pixel0.r;
    float chroma0 = pixel0.g;

    // Monitor mode: use center sample directly (bypass filter)
    float y_out = pixel0.r;
    float c_out = chroma0;
    
    vec3 demod0;

    demod0.r = composite0;
    demod0.g = 2.0 * chroma0 * carrier0.x;
    demod0.b = 2.0 * chroma0 * carrier0.y;
    
    // Center weights for all filter modes
    float w_y0 = gaussian(Ax, sigma.x);
    float w_c0 = gaussian(Ax, sigma.y);
    
    color += vec3(w_y0 * demod0.r, w_c0 * demod0.g, w_c0 * demod0.b);
    wsum += vec3(w_y0, w_c0, w_c0);

    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);
        float w_y_r = gaussian(nf + Ax, sigma.x);
        float w_y_l = gaussian(nf - Ax, sigma.x);
        float w_c_r = gaussian(nf + Ax, sigma.y);
        float w_c_l = gaussian(nf - Ax, sigma.y);
        if (w_y_r < THRESHOLD && w_y_l < THRESHOLD &&
            w_c_r < THRESHOLD && w_c_l < THRESHOLD)
            break;

        // Right sample
        float offsetR = (Tex.x + nf * dx.x) * config.OriginalSize.x;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time;
        vec3 pixelR = texture(Source, Tex + nf * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR);
        float compositeR = pixelR.r;
        float chromaR = pixelR.g;
        vec3 demodR = vec3(compositeR,
                           2.0 * chromaR * carrierR.x,
                           2.0 * chromaR * carrierR.y);

        // Left sample
        float offsetL = (Tex.x - nf * dx.x) * config.OriginalSize.x;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time;
        vec3 pixelL = texture(Source, Tex - nf * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL);
        float compositeL = pixelL.r;
        float chromaL = pixelL.g;
        vec3 demodL = vec3(compositeL,
                           2.0 * chromaL * carrierL.x,
                           2.0 * chromaL * carrierL.y);

        color.r += w_y_r * demodR.r + w_y_l * demodL.r;
        color.g += w_c_r * demodR.g + w_c_l * demodL.g;
        color.b += w_c_r * demodR.b + w_c_l * demodL.b;
        wsum.x += w_y_r + w_y_l;
        wsum.y += w_c_r + w_c_l;
        wsum.z += w_c_r + w_c_l;
    }

    // Normalize
    color /= max(wsum, vec3(EPS));

    if (FEEDBACK_FILTER_MODE >= 0.5) {
        float chroma = color.g * carrier0.x + color.b * carrier0.y;

        if (COLOR_FILTER_MODE < 0.5) {
            // Notch filter
            color.r = FEEDBACK_NOTCH_Y_CORRECT * y_out + c_out - chroma;
        } else if (COLOR_FILTER_MODE < 1.5) {
            // Comb filter
            color.r = y_out + c_out - chroma;
        } else if (COLOR_FILTER_MODE < 2.5) {
            // Notch + Comb
            float y_notch = FEEDBACK_NOTCH_Y_CORRECT * y_out + c_out - chroma;
            float y_comb = (y_out + c_out) - chroma;

            color.r = 0.5 * (y_notch + y_comb);
        } else {
            // No filter; use composite directly
            color.r = FEEDBACK_RAW_Y_CORRECT * color.r - chroma;
        }
    }

    if (BW_MODE < 0.5) {
        color = YPbPr_TO_RGB * color;
    } else if (BW_MODE < 1.5) {
        color = vec3(y_out + c_out);
    } else if (BW_MODE < 2.5) {
        color = vec3(y_out);
    } else if (BW_MODE < 3.5) {
        color = vec3(c_out);
    } else {
        color = vec3(c_out, y_out, c_out);
    }

    FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
