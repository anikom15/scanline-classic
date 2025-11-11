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
    float OriginalFPS;
    float BYPASS_COMPOSITE_DEMOD;
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
    float USER_TINT;
    float USER_SHARPNESS;
} config;

#pragma parameter COMPOSITE_DEMOD_HEADER2 "==== User Settings ====" 0.0 0.0 0.0 0.0

#pragma parameter USER_PICTURE "User: Picture" 0.5 0.0 1.0 0.01
#pragma parameter USER_BRIGHTNESS "User: Brightness" 0.5 0.0 1.0 0.01
#pragma parameter USER_COLOR "User: Color" 0.5 0.0 1.0 0.01
#pragma parameter USER_TINT "User: Tint" 0.5 0.0 1.0 0.01
#pragma parameter USER_SHARPNESS "User: Sharpness" 0.5 0.0 1.0 0.01
#pragma parameter USER_SHARPNESS_HARMONIC "User: Sharpness Harmonic (0=Off, 1=On)" 1.0 0.0 1.0 1.0

#define USER_TINT config.USER_TINT
#define USER_SHARPNESS config.USER_SHARPNESS

#pragma parameter COMPOSITE_DEMOD_HEADER " ==== Composite Video Demod. Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_COMPOSITE_DEMOD "Bypass Composite demodulation (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define BYPASS_COMPOSITE_DEMOD config.BYPASS_COMPOSITE_DEMOD

//#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
//#define V_FREQ config.V_FREQ

#define V_FREQ config.OriginalFPS

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
    float USER_SHARPNESS_HARMONIC;
} global;

#define USER_SHARPNESS_HARMONIC global.USER_SHARPNESS_HARMONIC

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

    // User settings
    float c_phase = 2.0 * PI * (USER_TINT - 0.5);

    // Filter characteristics
    vec2 sigma = vec2(
        sigma_tb(tb, DISPLAY_BANDWIDTH_Y, DISPLAY_CUTOFF_ATTEN_Y),
        sigma_tb(tb, DISPLAY_BANDWIDTH_C, DISPLAY_CUTOFF_ATTEN_C));
    
    // High frequency emphasis filter for sharpness
    // Center frequency: 190 * H_FREQ_HZ with 1 MHz -3dB bandwidth
    // Using Gaussian bandpass for smooth, artifact-free peaking
    float emphasis_center_hz = 190.0 * H_FREQ_HZ;
    float emphasis_bw_mhz = 1.0; // 1 MHz -3dB bandwidth
    float emphasis_sigma = sigma_tb(tb, emphasis_bw_mhz, 3.0);
    
    // Second harmonic emphasis filter at 3x frequency (570 * H_FREQ_HZ)
    // with 2 MHz -3dB bandwidth
    float emphasis2_center_hz = 3.0 * emphasis_center_hz; // 570 * H_FREQ_HZ
    float emphasis2_bw_mhz = 2.0; // 2 MHz -3dB bandwidth
    float emphasis2_sigma = sigma_tb(tb, emphasis2_bw_mhz, 3.0);
    
    // Optimized symmetric lobed approach with early exit
    // Horizontal coordinate handling: nearest pixel center (no Y shift)
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float baseIndex = floor(UV.x); // nearest pixel index
    float baseCenter = baseIndex + 0.5;  // pixel center coordinate
    float Ax = UV.x - baseCenter;        // offset in [-0.5, 0.5]
    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    vec3 color = vec3(0.0);
    vec3 wsum = vec3(0.0);
    
    // For emphasis filter (narrow bandpass around center frequency)
    vec3 emphasis_color = vec3(0.0);
    vec3 emphasis_wsum = vec3(0.0);
    
    // For second harmonic emphasis filter
    vec3 emphasis2_color = vec3(0.0);
    vec3 emphasis2_wsum = vec3(0.0);

    // Process center sample
    // Coordinate system fix: use output pixel lattice with tb.pixel_time_px to avoid scale-induced shifts
    float offset0 = baseCenter; // output pixel center index
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time_px;

    // R is Y, G is C
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0 + c_phase);

    float composite0 = pixel0.r;
    float chroma0 = pixel0.g;

    // Monitor mode: use center sample directly (bypass filter)
    float y_out = pixel0.r;
    float c_out = chroma0;
    
    vec3 demod0;

    demod0.r = composite0;
    demod0.g = 2.0 * chroma0 * carrier0.x;
    demod0.b = 2.0 * chroma0 * carrier0.y;
    
    // Modulate by emphasis center frequency for bandpass effect
    float emphasis_phase0 = 2.0 * PI * emphasis_center_hz * t0;
    float emphasis_mod0 = cos(emphasis_phase0);
    
    // Second harmonic modulation
    float emphasis2_phase0 = 2.0 * PI * emphasis2_center_hz * t0;
    float emphasis2_mod0 = cos(emphasis2_phase0);
    
    // Center weights for all filter modes
    float w_y0 = gaussian(Ax, sigma.x);
    float w_c0 = gaussian(Ax, sigma.y);
    float w_emphasis0 = gaussian(Ax, emphasis_sigma);
    float w_emphasis2_0 = gaussian(Ax, emphasis2_sigma);
    
    color += vec3(w_y0 * demod0.r, w_c0 * demod0.g, w_c0 * demod0.b);
    wsum += vec3(w_y0, w_c0, w_c0);
    
    // Modulated accumulation for bandpass
    emphasis_color += w_emphasis0 * demod0 * emphasis_mod0;
    emphasis_wsum += vec3(w_emphasis0);
    
    // Second harmonic modulated accumulation
    emphasis2_color += w_emphasis2_0 * demod0 * emphasis2_mod0;
    emphasis2_wsum += vec3(w_emphasis2_0);

    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);
        // Symmetric distances: right = n - Ax, left = n + Ax
        float w_y_r = gaussian(nf - Ax, sigma.x);
        float w_y_l = gaussian(nf + Ax, sigma.x);
        float w_c_r = gaussian(nf - Ax, sigma.y);
        float w_c_l = gaussian(nf + Ax, sigma.y);
        float w_emphasis_r = gaussian(nf - Ax, emphasis_sigma);
        float w_emphasis_l = gaussian(nf + Ax, emphasis_sigma);
        float w_emphasis2_r = gaussian(nf - Ax, emphasis2_sigma);
        float w_emphasis2_l = gaussian(nf + Ax, emphasis2_sigma);
        
        if (w_y_r < THRESHOLD && w_y_l < THRESHOLD &&
            w_c_r < THRESHOLD && w_c_l < THRESHOLD &&
            w_emphasis_r < THRESHOLD && w_emphasis_l < THRESHOLD &&
            w_emphasis2_r < THRESHOLD && w_emphasis2_l < THRESHOLD)
            break;

        // Right sample (output pixel lattice)
        float offsetR = baseCenter + nf;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time_px;
        vec3 pixelR = texture(Source, Tex + nf * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR + c_phase);
        float compositeR = pixelR.r;
        float chromaR = pixelR.g;
        vec3 demodR = vec3(compositeR,
                           2.0 * chromaR * carrierR.x,
                           2.0 * chromaR * carrierR.y);
        
        float emphasis_phaseR = 2.0 * PI * emphasis_center_hz * tR;
        float emphasis_modR = cos(emphasis_phaseR);
        
        float emphasis2_phaseR = 2.0 * PI * emphasis2_center_hz * tR;
        float emphasis2_modR = cos(emphasis2_phaseR);

        // Left sample (output pixel lattice)
        float offsetL = baseCenter - nf;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time_px;
        vec3 pixelL = texture(Source, Tex - nf * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL + c_phase);
        float compositeL = pixelL.r;
        float chromaL = pixelL.g;
        vec3 demodL = vec3(compositeL,
                           2.0 * chromaL * carrierL.x,
                           2.0 * chromaL * carrierL.y);
        
        float emphasis_phaseL = 2.0 * PI * emphasis_center_hz * tL;
        float emphasis_modL = cos(emphasis_phaseL);
        
        float emphasis2_phaseL = 2.0 * PI * emphasis2_center_hz * tL;
        float emphasis2_modL = cos(emphasis2_phaseL);

        color.r += w_y_r * demodR.r + w_y_l * demodL.r;
        color.g += w_c_r * demodR.g + w_c_l * demodL.g;
        color.b += w_c_r * demodR.b + w_c_l * demodL.b;
        wsum.x += w_y_r + w_y_l;
        wsum.y += w_c_r + w_c_l;
        wsum.z += w_c_r + w_c_l;
        
        // Modulated accumulation for bandpass
        emphasis_color += w_emphasis_r * demodR * emphasis_modR + w_emphasis_l * demodL * emphasis_modL;
        emphasis_wsum += vec3(w_emphasis_r + w_emphasis_l);
        
        // Second harmonic modulated accumulation
        emphasis2_color += w_emphasis2_r * demodR * emphasis2_modR + w_emphasis2_l * demodL * emphasis2_modL;
        emphasis2_wsum += vec3(w_emphasis2_r + w_emphasis2_l);
    }

    // Normalize
    color /= max(wsum, vec3(EPS));
    emphasis_color /= max(emphasis_wsum, vec3(EPS));
    emphasis2_color /= max(emphasis2_wsum, vec3(EPS));
    
    // Apply frequency emphasis when USER_SHARPNESS > 0
    // Demodulate back to baseband by multiplying again
    if (USER_SHARPNESS > 0.0) {
        // Demodulate the bandpass output
        float demod_mod = 2.0 * cos(emphasis_phase0);
        vec3 emphasis_component = emphasis_color * demod_mod;
        // Add scaled emphasis back to signal
        color += USER_SHARPNESS * emphasis_component;
        
        // Apply second harmonic emphasis if enabled
        if (USER_SHARPNESS_HARMONIC >= 0.5) {
            float demod_mod2 = 2.0 * cos(emphasis2_phase0);
            vec3 emphasis2_component = emphasis2_color * demod_mod2;
            // Add scaled second harmonic emphasis
            // The second harmonic is typically less pronounced, so use half the scaling
            color += USER_SHARPNESS * 0.5 * emphasis2_component;
        }
    }

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
        color = vec3(y_out, c_out, c_out);
    }

    FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
