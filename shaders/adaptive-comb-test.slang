#version 450

/* Filename: adaptive-comb-test.slang

   Adaptive Comb Filter Test Shader
   
   This shader implements an adaptive comb filter that uses correlation analysis
   to determine when vertical comb filtering is appropriate. It blends between
   notch filtering (for motion/detail) and comb filtering (for static content).

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

#pragma name AdaptiveCombTest
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_ADAPTIVE_COMB;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float NOTCH_WIDTH;
    float BANDPASS_WIDTH;
    float COMB_FILTER_TAPS;
    float NOTCH_CENTER_ATTEN_DB;
    float NOTCH_EDGE_ATTEN_DB;
} config;

#pragma parameter ADAPTIVE_COMB_HEADER " ==== Adaptive Comb Filter Test ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_ADAPTIVE_COMB "Bypass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define BYPASS_ADAPTIVE_COMB config.BYPASS_ADAPTIVE_COMB

//#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
//#define V_FREQ config.V_FREQ

#define V_FREQ config.OriginalFPS

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

#pragma parameter NOTCH_WIDTH "Notch band-stop width (MHz)" 2.6 0.01 10.0 0.01
#define NOTCH_WIDTH config.NOTCH_WIDTH

#pragma parameter NOTCH_CENTER_ATTEN_DB "Notch center attenuation (dB)" 60.0 0.0 120.0 0.5
#define NOTCH_CENTER_ATTEN_DB config.NOTCH_CENTER_ATTEN_DB
#pragma parameter NOTCH_EDGE_ATTEN_DB "Notch edge attenuation (dB)" 2.0 0.0 20.0 0.1
#define NOTCH_EDGE_ATTEN_DB config.NOTCH_EDGE_ATTEN_DB

#pragma parameter BANDPASS_WIDTH "Chroma band-pass width (MHz)" 2.6 0.01 10.0 0.01
#define BANDPASS_WIDTH config.BANDPASS_WIDTH

#pragma parameter COMB_FILTER_TAPS "Comb Filter Taps" 3 1 3 1
#define COMB_FILTER_TAPS config.COMB_FILTER_TAPS

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (1.0 / V_FREQ)

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float ADAPTIVE_MODE;
    float ADAPTIVE_SENSITIVITY;
    float ADAPTIVE_THRESHOLD_LOW;
    float ADAPTIVE_THRESHOLD_HIGH;
    float LUMA_WEIGHT;
    float COMPOSITE_WEIGHT;
    float CHROMA_WEIGHT;
    float GRADIENT_WEIGHT;
    float DEBUG_MODE;
} global;

#pragma parameter ADAPTIVE_HEADER " === Adaptive Parameters === " 0.0 0.0 0.0 0.0

#pragma parameter ADAPTIVE_MODE "Adaptive mode (0=Off/Notch, 1=Off/Comb, 2=Adaptive)" 2.0 0.0 2.0 1.0
#define ADAPTIVE_MODE global.ADAPTIVE_MODE

#pragma parameter ADAPTIVE_SENSITIVITY "Sensitivity (higher=more aggressive comb)" 4.0 1.0 10.0 0.5
#define ADAPTIVE_SENSITIVITY global.ADAPTIVE_SENSITIVITY

#pragma parameter ADAPTIVE_THRESHOLD_LOW "Threshold low (prefer notch below)" 0.3 0.0 1.0 0.05
#define ADAPTIVE_THRESHOLD_LOW global.ADAPTIVE_THRESHOLD_LOW

#pragma parameter ADAPTIVE_THRESHOLD_HIGH "Threshold high (prefer comb above)" 0.7 0.0 1.0 0.05
#define ADAPTIVE_THRESHOLD_HIGH global.ADAPTIVE_THRESHOLD_HIGH

#pragma parameter CORRELATION_HEADER " === Correlation Weights === " 0.0 0.0 0.0 0.0

#pragma parameter LUMA_WEIGHT "Luma correlation weight" 0.3 0.0 1.0 0.05
#define LUMA_WEIGHT global.LUMA_WEIGHT

#pragma parameter COMPOSITE_WEIGHT "Composite correlation weight" 0.3 0.0 1.0 0.05
#define COMPOSITE_WEIGHT global.COMPOSITE_WEIGHT

#pragma parameter CHROMA_WEIGHT "Chroma phase correlation weight" 0.2 0.0 1.0 0.05
#define CHROMA_WEIGHT global.CHROMA_WEIGHT

#pragma parameter GRADIENT_WEIGHT "Vertical gradient weight" 0.2 0.0 1.0 0.05
#define GRADIENT_WEIGHT global.GRADIENT_WEIGHT

#pragma parameter DEBUG_HEADER " === Debug Visualization === " 0.0 0.0 0.0 0.0

#pragma parameter DEBUG_MODE "Debug (0=Off, 1=Confidence, 2=Luma, 3=Comp, 4=Chroma, 5=Grad)" 0.0 0.0 5.0 1.0
#define DEBUG_MODE global.DEBUG_MODE

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
    if (BYPASS_ADAPTIVE_COMB >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Use consolidated timebase helper
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        // Updated: pass original_width and output_width explicitly
        config.OriginalSize.x,
        config.OutputSize.x,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Notch filter setup
    float pixel_time_px = tb.pixel_time * (config.OriginalSize.x * config.OutputSize.z);
    float A_center_dB = NOTCH_CENTER_ATTEN_DB;
    float A_edge_dB = NOTCH_EDGE_ATTEN_DB;
    float a_center = pow(10.0, -A_center_dB / 20.0);
    float a_edge = pow(10.0, -A_edge_dB / 20.0);
    float alpha = clamp(2.0 * (1.0 - a_center), 0.0, 2.0);
    float d_px = max(NOTCH_WIDTH * 1.0e6 * pixel_time_px, 1e-6);
    float arg = clamp(2.0 * (1.0 - a_edge) / max(alpha, 1e-6), EPS, 1.0);
    float sigma_bs = sqrt(-log(arg)) / (sqrt(2.0) * PI * d_px);

    // Chroma band-pass setup
    float f_sc_px = tb.sc_freq_hz * pixel_time_px;
    float bw_px = max(BANDPASS_WIDTH * 1.0e6 * pixel_time_px, 1e-6);
    float a_bp = pow(10.0, -NOTCH_EDGE_ATTEN_DB / 20.0);
    float sigma_bp = sqrt(-log(a_bp)) / (sqrt(2.0) * PI * (bw_px * 0.5));

    // Get current pixel coordinates
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float UX = UV.x - 0.5;
    float Ax = fract(UX);
    vec2 Tex = vec2((floor(UX) + 0.5) * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    // Compute current pixel composite signal
    float offset0 = Tex.x * config.OriginalSize.x;
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time;
    
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0);
    
    float chroma0 = pixel0.g * carrier0.x + pixel0.b * carrier0.y;
    float composite0 = pixel0.r + chroma0;
    
    // === NOTCH FILTER (Luma extraction) ===
    float conv_gcos = 0.0;
    float sum_g = 0.0;
    float c_bp_accum = 0.0;
    float sum_bp = 0.0;

    // Center sample
    float g_env0 = gaussian(Ax, sigma_bs);
    sum_g += g_env0;
    float w_cos0 = g_env0 * cos(2.0 * PI * f_sc_px * Ax);
    float g_bp0 = gaussian(Ax, sigma_bp);
    float w_bp0 = g_bp0 * cos(2.0 * PI * f_sc_px * Ax);
    conv_gcos += w_cos0 * composite0;
    c_bp_accum += w_bp0 * composite0;
    sum_bp += g_bp0;
    
    // Symmetric lobes
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);
        float g_env_r = gaussian(nf + Ax, sigma_bs);
        float g_env_l = gaussian(nf - Ax, sigma_bs);
        float g_bp_r  = gaussian(nf + Ax, sigma_bp);
        float g_bp_l  = gaussian(nf - Ax, sigma_bp);

        if (g_env_r < THRESHOLD && g_env_l < THRESHOLD && g_bp_r < THRESHOLD && g_bp_l < THRESHOLD)
            break;
        
        // Right sample
        float offsetR = (Tex.x + float(n) * dx.x) * config.OriginalSize.x;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time;
        vec3 pixelR = texture(Source, Tex + float(n) * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR);
        float chromaR = pixelR.g * carrierR.x + pixelR.b * carrierR.y;
        float compositeR = pixelR.r + chromaR;
        
        // Left sample
        float offsetL = (Tex.x - float(n) * dx.x) * config.OriginalSize.x;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time;
        vec3 pixelL = texture(Source, Tex - float(n) * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL);
        float chromaL = pixelL.g * carrierL.x + pixelL.b * carrierL.y;
        float compositeL = pixelL.r + chromaL;
        
        float w_notch_r = g_env_r * cos(2.0 * PI * f_sc_px * (nf + Ax));
        float w_notch_l = g_env_l * cos(2.0 * PI * f_sc_px * (nf - Ax));
        conv_gcos += w_notch_r * compositeR + w_notch_l * compositeL;
        sum_g += g_env_r + g_env_l;
        float w_bp_r = g_bp_r * cos(2.0 * PI * f_sc_px * (nf + Ax));
        float w_bp_l = g_bp_l * cos(2.0 * PI * f_sc_px * (nf - Ax));
        c_bp_accum += w_bp_r * compositeR + w_bp_l * compositeL;
        sum_bp += g_bp_r + g_bp_l;
    }

    float notch_response = conv_gcos / max(sum_g, EPS);
    float y_notch = 0.8 * (composite0 - alpha * notch_response);
    float c_notch = 1.2 * 2.0 * c_bp_accum / max(sum_bp, EPS);

    // === COMB FILTER ===
    float phase_per_line = 2.0 * PI * tb.sc_freq_hz * LINE_TIME;
    
    // Phase corrections for π, 2π, 3π shifts
    float phase_correction_1 = PI - phase_per_line;
    float phase_correction_2 = 2.0 * PI - 2.0 * phase_per_line;
    float phase_correction_3 = 3.0 * PI - 3.0 * phase_per_line;
    
    float phase_to_time = 1.0 / (2.0 * PI * tb.sc_freq_hz);
    float time_correction_1 = phase_correction_1 * phase_to_time;
    float time_correction_2 = phase_correction_2 * phase_to_time;
    float time_correction_3 = phase_correction_3 * phase_to_time;
    
    // Purely vertical texture offsets
    vec2 comb_dy_1 = vec2(0.0, -1.0 * config.OutputSize.w);
    vec2 comb_dy_2 = vec2(0.0, -2.0 * config.OutputSize.w);
    vec2 comb_dy_3 = vec2(0.0, -3.0 * config.OutputSize.w);

    float t_offset_1 = LINE_TIME + time_correction_1;
    float t_offset_2 = 2.0 * LINE_TIME + time_correction_2;
    float t_offset_3 = 3.0 * LINE_TIME + time_correction_3;

    // Sample previous scanlines
    mat3 comb_taps_yuv = mat3(
        texture(Source, Tex + comb_dy_1).rgb,
        texture(Source, Tex + comb_dy_2).rgb,
        texture(Source, Tex + comb_dy_3).rgb);

    // Calculate carrier phases with time corrections
    vec2 carrier_1 = sincos_phase(compute_carrier_phase(t0 - t_offset_1, tb.sc_freq_hz, tb.field_phase));
    vec2 carrier_2 = sincos_phase(compute_carrier_phase(t0 - t_offset_2, tb.sc_freq_hz, tb.field_phase));
    vec2 carrier_3 = sincos_phase(compute_carrier_phase(t0 - t_offset_3, tb.sc_freq_hz, tb.field_phase));

    // Reconstruct composite signals
    vec3 comb_taps_composite = vec3(
        dot(comb_taps_yuv[0], vec3(1.0, carrier_1)),
        dot(comb_taps_yuv[1], vec3(1.0, carrier_2)),
        dot(comb_taps_yuv[2], vec3(1.0, carrier_3)));

    // === ADAPTIVE CORRELATION ANALYSIS ===
    
    // Method 1: Luma correlation (vertical change detection)
    float luma_current = pixel0.r;
    float luma_prev1 = comb_taps_yuv[0].r;
    float luma_prev2 = comb_taps_yuv[1].r;
    float luma_prev3 = comb_taps_yuv[2].r;
    
    float luma_diff_1 = abs(luma_current - luma_prev1);
    float luma_diff_2 = abs(luma_current - luma_prev2);
    float luma_diff_3 = abs(luma_current - luma_prev3);
    float avg_luma_diff = (luma_diff_1 + luma_diff_2 + luma_diff_3) / 3.0;
    
    // Method 2: Composite signal correlation
    float comp_diff_1 = abs(composite0 - comb_taps_composite.x);
    float comp_diff_2 = abs(composite0 - comb_taps_composite.y);
    float comp_diff_3 = abs(composite0 - comb_taps_composite.z);
    float avg_comp_diff = (comp_diff_1 + comp_diff_2 + comp_diff_3) / 3.0;
    
    // Method 3: Chroma phase correlation
    // Extract chroma from previous lines
    float chroma_prev1 = comb_taps_yuv[0].g * carrier_1.x + comb_taps_yuv[0].b * carrier_1.y;
    float chroma_prev2 = comb_taps_yuv[1].g * carrier_2.x + comb_taps_yuv[1].b * carrier_2.y;
    float chroma_prev3 = comb_taps_yuv[2].g * carrier_3.x + comb_taps_yuv[2].b * carrier_3.y;
    
    // Phase-inverted chroma should be similar in magnitude but opposite sign
    // Low value = good phase inversion, high value = not inverted
    float chroma_correlation_1 = abs(chroma0 + chroma_prev1) / max(abs(chroma0) + abs(chroma_prev1), 0.01);
    float chroma_correlation_3 = abs(chroma0 + chroma_prev3) / max(abs(chroma0) + abs(chroma_prev3), 0.01);
    float chroma_correlation = (chroma_correlation_1 + chroma_correlation_3) * 0.5;
    
    // Method 4: Vertical gradient (real detail vs interlaced artifacts)
    float vertical_gradient = abs(luma_current - luma_prev1);
    
    // === CONFIDENCE CALCULATION ===
    
    // Normalize differences to confidence values [0,1]
    // Lower difference = higher confidence in comb filter
    float luma_confidence = 1.0 - clamp(avg_luma_diff * ADAPTIVE_SENSITIVITY, 0.0, 1.0);
    float comp_confidence = 1.0 - clamp(avg_comp_diff * ADAPTIVE_SENSITIVITY, 0.0, 1.0);
    float chroma_confidence = 1.0 - clamp(chroma_correlation, 0.0, 1.0);
    float gradient_confidence = 1.0 - clamp(vertical_gradient * ADAPTIVE_SENSITIVITY * 2.0, 0.0, 1.0);
    
    // Weighted combination
    float weight_sum = LUMA_WEIGHT + COMPOSITE_WEIGHT + CHROMA_WEIGHT + GRADIENT_WEIGHT;
    float comb_confidence = (LUMA_WEIGHT * luma_confidence + 
                            COMPOSITE_WEIGHT * comp_confidence + 
                            CHROMA_WEIGHT * chroma_confidence +
                            GRADIENT_WEIGHT * gradient_confidence) / max(weight_sum, 0.01);
    
    // Apply smooth transition using thresholds
    comb_confidence = smoothstep(ADAPTIVE_THRESHOLD_LOW, ADAPTIVE_THRESHOLD_HIGH, comb_confidence);
    
    // === COMB FILTER OUTPUT ===
    vec2 color_comb;
    if (COMB_FILTER_TAPS < 2) {
        color_comb = 0.5 * vec2(composite0 + comb_taps_composite.x,
                                 composite0 - comb_taps_composite.x);
    } else if (COMB_FILTER_TAPS < 3) {
        float y = 0.5 * (0.5 * composite0 + comb_taps_composite.x + 0.5 * comb_taps_composite.y);
        float c = 0.5 * (0.5 * composite0 - comb_taps_composite.x + 0.5 * comb_taps_composite.y);
        color_comb = vec2(y, c);
    } else {
        float y = (0.5 * composite0 + comb_taps_composite.x + comb_taps_composite.y + 0.5 * comb_taps_composite.z) / 3.0;
        float c = (0.5 * composite0 - comb_taps_composite.x + comb_taps_composite.y - 0.5 * comb_taps_composite.z) / 3.0;
        color_comb = vec2(y, c);
    }

    // === OUTPUT SELECTION ===
    vec3 color;
    
    if (ADAPTIVE_MODE < 0.5) {
        // Mode 0: Notch only
        color = vec3(y_notch, c_notch, 0.0);
    } else if (ADAPTIVE_MODE < 1.5) {
        // Mode 1: Comb only
        color = vec3(color_comb, 0.0);
    } else {
        // Mode 2: Adaptive blend
        vec2 mixed = mix(vec2(y_notch, c_notch), color_comb, comb_confidence);
        color = vec3(mixed, 0.0);
    }
    
    // === DEBUG VISUALIZATION ===
    if (DEBUG_MODE > 0.5) {
        if (DEBUG_MODE < 1.5) {
            // Debug 1: Show confidence map (grayscale)
            color = vec3(comb_confidence);
        } else if (DEBUG_MODE < 2.5) {
            // Debug 2: Luma confidence (red = low, green = high)
            color = vec3(1.0 - luma_confidence, luma_confidence, 0.0);
        } else if (DEBUG_MODE < 3.5) {
            // Debug 3: Composite confidence
            color = vec3(1.0 - comp_confidence, comp_confidence, 0.0);
        } else if (DEBUG_MODE < 4.5) {
            // Debug 4: Chroma correlation (green = good phase inv)
            color = vec3(chroma_correlation, chroma_confidence, 0.0);
        } else {
            // Debug 5: Vertical gradient
            color = vec3(1.0 - gradient_confidence, gradient_confidence, 0.0);
        }
    }

    FragColor = vec4(color, 1.0);
}
