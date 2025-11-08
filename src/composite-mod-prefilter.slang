#version 450

/* Filename: composite-mod-prefilter.slang

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

#pragma name CompositeMod
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float BYPASS_COMPOSITE_MOD;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float COLOR_FILTER_MODE;
    float NOTCH_WIDTH; // Band-stop width in MHz (symmetric)
    float BANDPASS_WIDTH; // Chroma band-pass width in MHz (symmetric)
    float COMB_FILTER_TAPS;
    float NOTCH_COMB_W;
    float BW_MODE;
    // New: notch design controls
    float NOTCH_CENTER_ATTEN_DB;
    float NOTCH_EDGE_ATTEN_DB;
} config;

#pragma parameter COMPOSITE_HEADER " ==== Composite Video Mod. Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass Composite modulation (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD

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

#pragma parameter NOTCH_WIDTH "Notch band-stop width (MHz, symmetric)" 2.6 0.01 10.0 0.01
#define NOTCH_WIDTH config.NOTCH_WIDTH

// Notch design parameters
#pragma parameter NOTCH_CENTER_ATTEN_DB "Notch center attenuation (dB)" 48.0 0.0 120.0 0.5
#define NOTCH_CENTER_ATTEN_DB config.NOTCH_CENTER_ATTEN_DB
#pragma parameter NOTCH_EDGE_ATTEN_DB "Notch edge attenuation at ±offset (dB)" 3.0 0.0 20.0 0.1
#define NOTCH_EDGE_ATTEN_DB config.NOTCH_EDGE_ATTEN_DB

// Performance note: very wide/narrow BANDPASS_WIDTH values increase tap count and cost.
// For best performance, keep BANDPASS_WIDTH moderate (e.g. 1–4 MHz).

#pragma parameter BANDPASS_WIDTH "Chroma band-pass width (MHz, symmetric)" 2.6 0.01 10.0 0.01
#define BANDPASS_WIDTH config.BANDPASS_WIDTH

#pragma parameter COMB_FILTER_TAPS "Comb Filter Taps" 1 1 3 1
#define COMB_FILTER_TAPS config.COMB_FILTER_TAPS

#pragma parameter NOTCH_COMB_W "Notch-Comb Mixing Weight" 0.5 0.0 1.0 0.1
#define NOTCH_COMB_W config.NOTCH_COMB_W

#pragma parameter BW_MODE "Monitor mode (0=Off, 1=BW, 2=Y, 3=C, 4=Y+C)" 0 0 4 1
#define BW_MODE config.BW_MODE

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (1.0 / V_FREQ)

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float USER_PICTURE;
    float USER_BRIGHTNESS;
    float USER_COLOR;
    float USER_TINT;
    float USER_SHARPNESS;
    float NOTCH_Y_CORRECT;
} global;

#pragma parameter USER_PICTURE "User Settings: Picture" 0.5 0.0 1.0 0.01
#define USER_PICTURE global.USER_PICTURE
#pragma parameter USER_BRIGHTNESS "User Settings: Brightness" 0.5 0.0 1.0 0.01
#define USER_BRIGHTNESS global.USER_BRIGHTNESS
#pragma parameter USER_COLOR "User Settings: Color" 0.5 0.0 1.0 0.01
#define USER_COLOR global.USER_COLOR
#pragma parameter USER_TINT "User Settings: Tint" 0.5 0.0 1.0 0.01
#define USER_TINT global.USER_TINT
#pragma parameter USER_SHARPNESS "User Settings: Sharpness" 0.0 0.0 1.0 0.01
#define USER_SHARPNESS global.USER_SHARPNESS

#pragma parameter NOTCH_Y_CORRECT "Notch Y Correction" 1.18 0.0 10.0 0.01
#define NOTCH_Y_CORRECT global.NOTCH_Y_CORRECT

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
    if (BYPASS_COMPOSITE_MOD >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Use consolidated timebase helper
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        config.OriginalSize.x,
        config.OutputSize.x,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // User settings
    float y_gain = 2.0 * USER_PICTURE;
    float y_bias = 0.2 * USER_BRIGHTNESS - 0.1;
    float c_gain = 2.0 * USER_COLOR;

    // Notch design targets
    float pixel_time_px = tb.pixel_time_px;

    float A_center_dB = NOTCH_CENTER_ATTEN_DB; // center notch depth
    float A_edge_dB = NOTCH_EDGE_ATTEN_DB;     // attenuation at f0 ± Δ

    float a_center = pow(10.0, -A_center_dB / 20.0); // linear
    float a_edge = pow(10.0, -A_edge_dB / 20.0);     // linear
    float alpha = clamp(2.0 * (1.0 - a_center), 0.0, 2.0);

    // Sigma derivations via sigma_tb(): interpret NOTCH_WIDTH and BANDPASS_WIDTH as full
    // symmetric widths, mapping to cutoff = width/2 with attenuation = NOTCH_EDGE_ATTEN_DB.
    // This approach aligns with system-level usage and centralizes derivation logic.
    float sigma_bs = sigma_tb(tb, max(NOTCH_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);
    float sigma_bp = sigma_tb(tb, max(BANDPASS_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);

    // Subcarrier cycles per pixel for modulation
    float f_sc_px = tb.sc_freq_hz * pixel_time_px; // subcarrier cycles per pixel

    // Optimized symmetric lobed approach with early exit
    // Horizontal coordinate handling: align with bandlimit.inc (no Y shift)
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float UX = UV.x - 0.5;
    float Ax = fract(UX);
    vec2 Tex = vec2((floor(UX) + 0.5) * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    // Accumulators: band-stop notch for luma, modulated band-pass for chroma
    float conv_gcos = 0.0; // Luma notch: Σ g(n)*cos(2π f_sc_px n)*x(n)
    float sum_g    = 0.0;  // Luma notch: Σ g(n)

    float c_bp_accum = 0.0; // Chroma band-pass: Σ g_bp(n)*cos(2π f_sc_px n)*x(n)
    float sum_bp = 0.0;     // Chroma envelope sum: Σ g_bp(n)

    // Process center sample
    float offset0 = Tex.x * config.OriginalSize.x;
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time;
    
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0);
    
    float chroma0 = pixel0.g * carrier0.x + pixel0.b * carrier0.y;
    float composite0 = pixel0.r + chroma0;
    
    // Center weights for luma band-stop notch
    float g_env0 = gaussian(Ax, sigma_bs);
    sum_g += g_env0;
    float w_cos0 = g_env0 * cos(2.0 * PI * f_sc_px * Ax);

    // Center weights for chroma band-pass: modulated Gaussian envelope
    float g_bp0 = gaussian(Ax, sigma_bp);
    float w_bp0 = g_bp0 * cos(2.0 * PI * f_sc_px * Ax);

    // Accumulate center sample
    conv_gcos += w_cos0 * composite0;
    c_bp_accum += w_bp0 * composite0;
    sum_bp += g_bp0;
    
    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);

        // Luma band-stop: separate left/right weights at proper offsets
        float g_env_r = gaussian(nf + Ax, sigma_bs);
        float g_env_l = gaussian(nf - Ax, sigma_bs);
        // Chroma band-pass: separate left/right
        float g_bp_r  = gaussian(nf + Ax, sigma_bp);
        float g_bp_l  = gaussian(nf - Ax, sigma_bp);

        // Early exit if both envelopes negligible on both sides
        if (g_env_r < THRESHOLD && g_env_l < THRESHOLD &&
            g_bp_r  < THRESHOLD && g_bp_l  < THRESHOLD)
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
        
        // Accumulate luma band-stop components (modulated weights per side)
        float w_notch_r = g_env_r * cos(2.0 * PI * f_sc_px * (nf + Ax));
        float w_notch_l = g_env_l * cos(2.0 * PI * f_sc_px * (nf - Ax));
        conv_gcos += w_notch_r * compositeR + w_notch_l * compositeL;
        sum_g     += g_env_r + g_env_l;

        // Accumulate chroma band-pass (modulated at f_sc)
        float w_bp_r = g_bp_r * cos(2.0 * PI * f_sc_px * (nf + Ax));
        float w_bp_l = g_bp_l * cos(2.0 * PI * f_sc_px * (nf - Ax));
        c_bp_accum += w_bp_r * compositeR + w_bp_l * compositeL;
        sum_bp += g_bp_r + g_bp_l;
    }

    // Normalize luma band-stop notch
    // Scale to balance white-level (determined empirically)
    float notch_response = conv_gcos / max(sum_g, EPS);
    float y_out = NOTCH_Y_CORRECT * (composite0 - alpha * notch_response);

    // Reconstruct chroma with modulated Gaussian band-pass (centered at f_sc)
    // Scale to compensate for modulation gain loss (cos^2 average = 0.5; determined empirically)
    float c_bp = 2.0 * c_bp_accum / max(sum_bp, EPS);
    // Comb filter path (compute only when needed)
    vec2 color_comb = vec2(0.0);
    if (COLOR_FILTER_MODE >= 0.5 && COLOR_FILTER_MODE < 3.5) {
        // Phase accumulated per line (in radians)
        float phase_per_line = 2.0 * PI * tb.sc_freq_hz * LINE_TIME;
        
        // Calculate phase corrections to reach target phase shifts (π, 2π, 3π)
        // after moving vertically by N lines
        float phase_correction_1 = PI - phase_per_line;
        float phase_correction_2 = 2.0 * PI - 2.0 * phase_per_line;
        float phase_correction_3 = 3.0 * PI - 3.0 * phase_per_line;
        
        // Convert phase corrections to time offsets
        float phase_to_time = 1.0 / (2.0 * PI * tb.sc_freq_hz);
        float time_correction_1 = phase_correction_1 * phase_to_time;
        float time_correction_2 = phase_correction_2 * phase_to_time;
        float time_correction_3 = phase_correction_3 * phase_to_time;
        
        // Texture coordinate offsets: purely vertical (no horizontal offset)
        vec2 comb_dy_1 = vec2(0.0, -1.0 * config.OutputSize.w);
        vec2 comb_dy_2 = vec2(0.0, -2.0 * config.OutputSize.w);
        vec2 comb_dy_3 = vec2(0.0, -3.0 * config.OutputSize.w);

        // Total time offsets: line time + phase correction
        float t_offset_1 = LINE_TIME + time_correction_1;
        float t_offset_2 = 2.0 * LINE_TIME + time_correction_2;
        float t_offset_3 = 3.0 * LINE_TIME + time_correction_3;

        // Sample comb filter taps
        mat3 comb_taps_yuv = mat3(
            texture(Source, Tex + comb_dy_1).rgb,
            texture(Source, Tex + comb_dy_2).rgb,
            texture(Source, Tex + comb_dy_3).rgb);

        // Calculate carrier phases with time corrections
        vec2 carrier_1 = sincos_phase(compute_carrier_phase(t0 - t_offset_1, tb.sc_freq_hz, tb.field_phase));
        vec2 carrier_2 = sincos_phase(compute_carrier_phase(t0 - t_offset_2, tb.sc_freq_hz, tb.field_phase));
        vec2 carrier_3 = sincos_phase(compute_carrier_phase(t0 - t_offset_3, tb.sc_freq_hz, tb.field_phase));

        // Reconstruct composite signals from taps
        vec3 comb_taps_composite = vec3(
            dot(comb_taps_yuv[0], vec3(1.0, carrier_1)),
            dot(comb_taps_yuv[1], vec3(1.0, carrier_2)),
            dot(comb_taps_yuv[2], vec3(1.0, carrier_3)));

        // Apply comb filter combinations
        if (COMB_FILTER_TAPS < 2) {
            // 1-tap comb
            color_comb = 0.5 * vec2(composite0 + comb_taps_composite.x,
                                     composite0 - comb_taps_composite.x);
        } else if (COMB_FILTER_TAPS < 3) {
            // 2-tap comb
            float y = 0.5 * (0.5 * composite0 + comb_taps_composite.x + 0.5 * comb_taps_composite.y);
            float c = 0.5 * (0.5 * composite0 - comb_taps_composite.x + 0.5 * comb_taps_composite.y);
            color_comb = vec2(y, c);
        } else {
            // 3-tap comb
            float y = (0.5 * composite0 + comb_taps_composite.x + comb_taps_composite.y + 0.5 * comb_taps_composite.z) / 3.0;
            float c = (0.5 * composite0 - comb_taps_composite.x + comb_taps_composite.y - 0.5 * comb_taps_composite.z) / 3.0;
            color_comb = vec2(y, c);
        }
    }

    // Select color filter mode
    vec3 color;
    if (COLOR_FILTER_MODE < 0.5) {
        // Notch: use band-stop luma and band-pass chroma (now centered at f_sc)
        color = vec3(y_out, c_bp, 0.0);
    } else if (COLOR_FILTER_MODE < 1.5) {
        color = vec3(color_comb, 0.0);
        y_out = color_comb.r;
    } else if (COLOR_FILTER_MODE < 2.5) {
        // Mix between the notch and comb outputs
        vec2 mixed = mix(vec2(y_out, c_bp), color_comb, NOTCH_COMB_W);
        color = vec3(mixed, 0.0);
    } else if (COLOR_FILTER_MODE < 3.5) {
        color = vec3(composite0, composite0, 0.0);
    }

    // BW monitor modes: route either luma-only or chroma-only to all channels
    float c_out = color.g;
    if (BW_MODE < 0.5) {
        color.r = color.r * y_gain + y_bias;
        color.g = color.g * c_gain;
    } else if (BW_MODE < 1.5) {
        color = vec3(composite0, 0.0, 0.0);
    } else if (BW_MODE < 2.5) {
        color = vec3(y_out, 0.0, 0.0);
    } else if (BW_MODE < 3.5) {
        color = vec3(0.0, c_out, 0.0);
    } else if (BW_MODE < 4.5) {
        color = vec3(y_out, c_out, 0.0);
    }

    FragColor = vec4(color, 1.0);
}
