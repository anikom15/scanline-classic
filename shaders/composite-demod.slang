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

#include "common.inc"
#include "color.inc"
#include "bandlimit.inc"
#include "modulation.inc"

#include "menus/parameters/user-video.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/composite.inc"

#pragma name CompositeDemod
#pragma format R16G16B16A16_SFLOAT

#pragma parameter BYPASS_COMPOSITE_DEMOD "Bypass composite demodulation (off, on)" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_COMPOSITE_DEMOD;
    float V_FREQ_MODE;
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
    float FEEDBACK_FILTER;
    float FEEDBACK_NOTCH_Y_CORRECT;
    float FEEDBACK_RAW_Y_CORRECT;
    float BW_MODE;
    float USER_COLOR;   // Color (%)
    float USER_TINT;    // Tint (degrees)
    float DECODER_SETUP;
} config;

#define USER_COLOR config.USER_COLOR
#define USER_TINT config.USER_TINT

#define BYPASS_COMPOSITE_DEMOD config.BYPASS_COMPOSITE_DEMOD

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#define DISPLAY_BANDWIDTH_Y config.DISPLAY_BANDWIDTH_Y
#define DISPLAY_BANDWIDTH_C config.DISPLAY_BANDWIDTH_C

#define DISPLAY_CUTOFF_ATTEN_Y config.DISPLAY_CUTOFF_ATTEN_Y
#define DISPLAY_CUTOFF_ATTEN_C config.DISPLAY_CUTOFF_ATTEN_C

#define FEEDBACK_FILTER config.FEEDBACK_FILTER

#define FEEDBACK_NOTCH_Y_CORRECT config.FEEDBACK_NOTCH_Y_CORRECT
#define FEEDBACK_RAW_Y_CORRECT config.FEEDBACK_RAW_Y_CORRECT

#define BW_MODE config.BW_MODE

#define DECODER_SETUP config.DECODER_SETUP

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 sigma;
layout(location = 2) out float c_gain;
layout(location = 3) out float c_phase;
layout(location = 4) out TimebaseConfig tb;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Precompute timebase config for fragment stage
    tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        V_FREQ_MODE,
        config.OriginalFPS,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Precompute per-component sigmas for fragment stage
    sigma.x = sigma_tb(tb, DISPLAY_BANDWIDTH_Y, DISPLAY_CUTOFF_ATTEN_Y);
    sigma.y = sigma_tb(tb, DISPLAY_BANDWIDTH_C, DISPLAY_CUTOFF_ATTEN_C);

    // Precompute user color gain/phase
    c_gain = 2.0 * USER_COLOR / 100.0;
    c_phase = PI * USER_TINT / 180.0;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(location = 1) in vec2 sigma;
layout(location = 2) in float c_gain;
layout(location = 3) in float c_phase;
layout(location = 4) in TimebaseConfig tb;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_COMPOSITE_DEMOD >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }
    
    // Optimized symmetric lobed approach with early exit
    // Horizontal coordinate handling: nearest pixel center (no Y shift)
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float baseIndex = floor(UV.x); // nearest pixel index
    float baseCenter = baseIndex + 0.5;  // pixel center coordinate
    float Ax = UV.x - baseCenter;        // offset in [-0.5, 0.5]
    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 255.0;
    
    vec3 color = vec3(0.0);
    vec3 wsum = vec3(0.0);
    
    // Process center sample
    // Coordinate system fix: use output pixel lattice with tb.pixel_time_px to avoid scale-induced shifts
    float offset0 = baseCenter; // output pixel center index
    float t0 = tb.line / tb.h_freq_hz + offset0 * tb.pixel_time_px;

    // R is Y, G is C
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0 + c_phase);

    float composite0 = pixel0.r;
    float chroma0 = pixel0.g;

    // Monitor mode: use center sample directly (bypass filter)
    float y_out = composite0;
    float c_out = chroma0;
    
    vec3 demod0;

    demod0.r = composite0;
    demod0.g = c_gain * 2.0 * chroma0 * carrier0.x;
    demod0.b = c_gain * 2.0 * chroma0 * carrier0.y;
    
    // Center weights for all filter modes
    float w_y0 = gaussian(Ax, sigma.x);
    float w_c0 = gaussian(Ax, sigma.y);
    
    color += vec3(w_y0 * demod0.r, w_c0 * demod0.g, w_c0 * demod0.b);
    wsum += vec3(w_y0, w_c0, w_c0);
    
    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 20; ++n) {
        float nf = float(n);
        // Symmetric distances: right = n - Ax, left = n + Ax
        float w_y_r = gaussian(nf - Ax, sigma.x);
        float w_y_l = gaussian(nf + Ax, sigma.x);
        float w_c_r = gaussian(nf - Ax, sigma.y);
        float w_c_l = gaussian(nf + Ax, sigma.y);
        if (w_y_r < THRESHOLD && w_y_l < THRESHOLD &&
            w_c_r < THRESHOLD && w_c_l < THRESHOLD)
            break;

        // Right sample (output pixel lattice)
        float offsetR = baseCenter + nf;
        float tR = tb.line / tb.h_freq_hz + offsetR * tb.pixel_time_px;
        vec3 pixelR = texture(Source, Tex + nf * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR + c_phase);
        float compositeR = pixelR.r;
        float chromaR = pixelR.g;
        vec3 demodR = vec3(compositeR,
                   c_gain * 2.0 * chromaR * carrierR.x,
                   c_gain * 2.0 * chromaR * carrierR.y);
        

        // Left sample (output pixel lattice)
        float offsetL = baseCenter - nf;
        float tL = tb.line / tb.h_freq_hz + offsetL * tb.pixel_time_px;
        vec3 pixelL = texture(Source, Tex - nf * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL + c_phase);
        float compositeL = pixelL.r;
        float chromaL = pixelL.g;
        vec3 demodL = vec3(compositeL,
                   c_gain * 2.0 * chromaL * carrierL.x,
                   c_gain * 2.0 * chromaL * carrierL.y);
        

        color.r += w_y_r * demodR.r + w_y_l * demodL.r;
        color.g += w_c_r * demodR.g + w_c_l * demodL.g;
        color.b += w_c_r * demodR.b + w_c_l * demodL.b;
        wsum.x += w_y_r + w_y_l;
        wsum.y += w_c_r + w_c_l;
        wsum.z += w_c_r + w_c_l;
        
    }

    // Normalize
    color /= max(wsum, vec3(EPS));

    if (FEEDBACK_FILTER >= 0.5) {
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

    // Correct for setup if necessary
    if (DECODER_SETUP > 0.5) {
        color.r = (color.r - 0.075) / 0.925;
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
        color = vec3(y_out, c_out, c_out);
    }

    FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
