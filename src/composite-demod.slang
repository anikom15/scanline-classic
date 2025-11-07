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
#pragma format R16G16B16A16_SFLOAT

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
    float DISPLAY_BANDWIDTH_Y;
    float DISPLAY_BANDWIDTH_C;
    float DISPLAY_CUTOFF_ATTEN_Y;
    float DISPLAY_CUTOFF_ATTEN_C;
    float FEEDBACK_FILTER_MODE;
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

#pragma parameter SC_FREQ "Custom Subcarrier Frequency (MHz)" 3.579545 0.0 10.0 0.000001
#define SC_FREQ config.SC_FREQ

#define H_FREQ_HZ (V_FREQ * V_LINES_PER_FIELD)

#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter DISPLAY_BANDWIDTH_Y "Display Luma (Y) bandwidth (MHz)" 6.75 0.0 75.0 0.01
#define DISPLAY_BANDWIDTH_Y config.DISPLAY_BANDWIDTH_Y
#pragma parameter DISPLAY_BANDWIDTH_C "Display Chroma (C) bandwidth (MHz)" 1.79 0.0 6.75 0.01
#define DISPLAY_BANDWIDTH_C config.DISPLAY_BANDWIDTH_C

#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display Y cutoff attenuation (dB)" 3.0 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_Y config.DISPLAY_CUTOFF_ATTEN_Y
#pragma parameter DISPLAY_CUTOFF_ATTEN_C "Display C cutoff attenuation (dB)" 3.0 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_C config.DISPLAY_CUTOFF_ATTEN_C

#pragma parameter FEEDBACK_FILTER_MODE "Enable feedback filter (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define FEEDBACK_FILTER_MODE config.FEEDBACK_FILTER_MODE

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
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Filter characteristics
    vec3 sigma = sigma601(
        vec3(DISPLAY_BANDWIDTH_Y, DISPLAY_BANDWIDTH_C, DISPLAY_BANDWIDTH_C),
        vec3(DISPLAY_CUTOFF_ATTEN_Y, DISPLAY_CUTOFF_ATTEN_C, DISPLAY_CUTOFF_ATTEN_C),
        config.OutputSize.x);

    // Optimized symmetric lobed approach with early exit
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 A = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * config.OutputSize.zw;
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
    float w_y0 = gaussian(A.x, sigma.x);
    float w_c0 = gaussian(A.x, sigma.y);

    if (FEEDBACK_FILTER_MODE > 0.5) {
        float remod = w_c0 * (demod0.g * carrier0.x + demod0.b * carrier0.y);

        demod0.r = composite0 - remod;
    }
    
    color += vec3(w_y0 * demod0.r, w_c0 * demod0.g, w_c0 * demod0.b);
    wsum += vec3(w_y0, w_c0, w_c0);

    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n) + A.x;
        
        // Compute weights for all filter modes
        float w_y = gaussian(nf, sigma.x);
        float w_c = gaussian(nf, sigma.y);
         
        // Early exit if all weights negligible
        if (w_y < THRESHOLD && w_c < THRESHOLD)
            break;
        
        // Right sample
        float offsetR = (Tex.x + float(n) * dx.x) * config.OriginalSize.x;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time;
        
        vec3 pixelR = texture(Source, Tex + float(n) * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR);

        float compositeR = pixelR.r;
        float chromaR = pixelR.g;
        
        vec3 demodR;
        demodR.r = compositeR;
        demodR.g = 2.0 * chromaR * carrierR.x;
        demodR.b = 2.0 * chromaR * carrierR.y;

        if (FEEDBACK_FILTER_MODE > 0.5) {
            float remod = w_c * (demodR.g * carrierR.x + demodR.b * carrierR.y);

            demodR.r = compositeR - remod;
        }
        
        // Left sample
        float offsetL = (Tex.x - float(n) * dx.x) * config.OriginalSize.x;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time;
        
        vec3 pixelL = texture(Source, Tex - float(n) * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL);
        
        float compositeL = pixelL.r;
        float chromaL = pixelL.g;
        
        vec3 demodL;
        demodL.r = compositeL;
        demodL.g = 2.0 * chromaL * carrierL.x;
        demodL.b = 2.0 * chromaL * carrierL.y;

        if (FEEDBACK_FILTER_MODE > 0.5) {
            float remod = w_c * (demodL.g * carrierL.x + demodL.b * carrierL.y);

            demodL.r = compositeL - remod;
        }
        
        // Accumulate raw filter
        color.r += w_y * (demodR.r + demodL.r);
        color.g += w_c * (demodR.g + demodL.g);
        color.b += w_c * (demodR.b + demodL.b);
        wsum.x += 2.0 * w_y;
        wsum.y += 2.0 * w_c;
        wsum.z += 2.0 * w_c;
    }

    // Normalize
    color /= max(wsum, vec3(EPS));

    if (BW_MODE < 0.5) {
        ;
    } else if (BW_MODE < 1.5) {
        color = vec3(y_out + c_out, 0.0, 0.0);
    } else if (BW_MODE < 2.5) {
        color = vec3(y_out, 0.0, 0.0);
    } else if (BW_MODE < 3.5) {
        color = vec3(c_out, 0.0, 0.0);
    } else {
        color = vec3(y_out, 0.0, c_out);
    }

    FragColor = vec4(color, 1.0);
}
