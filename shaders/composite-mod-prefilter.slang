#version 450

// Filename: composite-mod-prefilter.slang
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
// Composite modulation with separation filter pre-processing
// ----------------------------------------------------------------
// Input: Component voltage signal
// Output: Separated Y and C signals

#include "common.inc"
#include "color.inc"
#include "bandlimit.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/composite.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass Composite modulation (off, on)" 0.0 0.0 1.0 1.0

#pragma name CompositeMod
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_COMPOSITE_MOD;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float COLOR_FILTER_MODE;
    float NOTCH_WIDTH;
    float BANDPASS_WIDTH;
    float COMB_FILTER_TAPS;
    float NOTCH_COMB_W;
    float BW_MODE;
    float NOTCH_CENTER_ATTEN_DB;
    float NOTCH_EDGE_ATTEN_DB;
    float NOTCH_Y_CORRECT;
    float RAW_Y_CORRECT;
    float RAW_C_CORRECT;
    float ENCODER_SETUP;
    float PAL;
} config;

#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#define NOTCH_WIDTH config.NOTCH_WIDTH
#define NOTCH_CENTER_ATTEN_DB config.NOTCH_CENTER_ATTEN_DB
#define NOTCH_EDGE_ATTEN_DB config.NOTCH_EDGE_ATTEN_DB

#define BANDPASS_WIDTH config.BANDPASS_WIDTH

#define COMB_FILTER_TAPS config.COMB_FILTER_TAPS

#define NOTCH_COMB_W config.NOTCH_COMB_W

#define BW_MODE config.BW_MODE

#define NOTCH_Y_CORRECT config.NOTCH_Y_CORRECT
    
#define RAW_Y_CORRECT config.RAW_Y_CORRECT
#define RAW_C_CORRECT config.RAW_C_CORRECT

#define ENCODER_SETUP config.ENCODER_SETUP
#define PAL config.PAL

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 sigma;
layout(location = 2) out TimebaseConfig tb;

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
    sigma.x = sigma_tb(tb, max(NOTCH_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);
    sigma.y = sigma_tb(tb, max(BANDPASS_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 sigma;
layout(location = 2) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_COMPOSITE_MOD > 0.5) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Notch design targets
    float pixel_time_px = tb.pixel_time_px;

    float A_center_dB = NOTCH_CENTER_ATTEN_DB; // center notch depth
    float A_edge_dB = NOTCH_EDGE_ATTEN_DB;     // attenuation at f0 ± Δ

    float a_center = pow(10.0, -A_center_dB / 20.0); // linear
    float a_edge = pow(10.0, -A_edge_dB / 20.0);     // linear
    float alpha = clamp(2.0 * (1.0 - a_center), 0.0, 2.0);

    // Subcarrier cycles per pixel for modulation
    float f_sc_px = tb.sc_freq_hz * pixel_time_px; // subcarrier cycles per pixel

    // Optimized symmetric lobed approach with early exit
    // Horizontal coordinate handling: nearest pixel center (no Y shift)
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float baseIndex = floor(UV.x);  // nearest pixel index
    float baseCenter = baseIndex + 0.5;   // center in pixel units
    float Ax = UV.x - baseCenter;         // offset from center in [-0.5, 0.5]
    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 255.0;
    
    // Accumulators: band-stop notch for luma, modulated band-pass for chroma
    float conv_gcos = 0.0; // Luma notch: Σ g(n)*cos(2π f_sc_px n)*x(n)
    float sum_g    = 0.0;  // Luma notch: Σ g(n)

    float c_bp_accum = 0.0; // Chroma band-pass: Σ g_bp(n)*cos(2π f_sc_px n)*x(n)
    float sum_bp = 0.0;     // Chroma envelope sum: Σ g_bp(n)

    // Process center sample
    // Coordinate system fix: use output pixel lattice directly.
    // Previously: offset0 = Tex.x * OriginalSize.x; t0 used tb.pixel_time (original-pixel time),
    // which caused horizontal misalignment at scale factors (e.g., 2x). Now we anchor on
    // baseCenter (already an output pixel index + 0.5) and use tb.pixel_time_px (time per output pixel).
    float offset0 = baseCenter; // output pixel index (center)
    float line = floor(vTexCoord.y * config.OriginalSize.y);
    vec2 pal_phase = vec2(0.0, floor(mod(line, 2.0)) * PI * PAL); // PAL phase alternates every line

    float t0 = line / tb.h_freq_hz + offset0 * tb.pixel_time_px;
    
    // Precompute phase increment per pixel for precision in filter loops
    float sc_phase_inc_per_px = 2.0 * PI * tb.sc_freq_hz * tb.pixel_time_px;
    
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0 + pal_phase);
    
    float chroma0 = pixel0.g * carrier0.x + pixel0.b * carrier0.y;

    float y_gain = 1.0;
    float y_offset = 0.0;

    if (ENCODER_SETUP > 0.5) {
        // NTSC setup
        y_gain = 0.925;
        y_offset = 0.075;
    }

    float composite0 = y_gain * (pixel0.r + y_offset) + chroma0;
    
    // Center weights for luma band-stop notch
    float g_env0 = gaussian(Ax, sigma.x);
    sum_g += g_env0;
    float w_cos0 = g_env0 * cos(2.0 * PI * f_sc_px * Ax);

    // Center weights for chroma band-pass: modulated Gaussian envelope
    float g_bp0 = gaussian(Ax, sigma.y);
    float w_bp0 = g_bp0 * cos(2.0 * PI * f_sc_px * Ax);

    // Accumulate center sample
    conv_gcos += w_cos0 * composite0;
    c_bp_accum += w_bp0 * composite0;
    sum_bp += g_bp0;
    
    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 20; ++n) {
        float nf = float(n);

        // Symmetric distances from kernel center: right = n - Ax, left = n + Ax
        float g_env_r = gaussian(nf - Ax, sigma.x);
        float g_env_l = gaussian(nf + Ax, sigma.x);
        float g_bp_r  = gaussian(nf - Ax, sigma.y);
        float g_bp_l  = gaussian(nf + Ax, sigma.y);

        // Early exit if both envelopes negligible on both sides
        if (g_env_r < THRESHOLD && g_env_l < THRESHOLD &&
            g_bp_r  < THRESHOLD && g_bp_l  < THRESHOLD)
            break;
        
        // Right sample (output pixel lattice)
        vec3 pixelR = texture(Source, Tex + float(n) * dx).rgb;
        // Use phase increment for better precision
        float phaseR = phase0 + nf * sc_phase_inc_per_px;
        phaseR = mod(phaseR + PI, 2.0 * PI) - PI;
        vec2 carrierR = sincos_phase(phaseR + pal_phase);
        
        float chromaR = pixelR.g * carrierR.x + pixelR.b * carrierR.y;
        float compositeR = y_gain * (pixelR.r + y_offset) + chromaR;
        
        // Left sample (output pixel lattice)
        vec3 pixelL = texture(Source, Tex - float(n) * dx).rgb;
        // Use phase increment for better precision
        float phaseL = phase0 - nf * sc_phase_inc_per_px;
        phaseL = mod(phaseL + PI, 2.0 * PI) - PI;
        vec2 carrierL = sincos_phase(phaseL + pal_phase);
        
        float chromaL = pixelL.g * carrierL.x + pixelL.b * carrierL.y;
        float compositeL = y_gain * (pixelL.r + y_offset) + chromaL;
        
        // Accumulate luma band-stop components (modulated weights per side)
        float w_notch_r = g_env_r * cos(2.0 * PI * f_sc_px * (nf - Ax));
        float w_notch_l = g_env_l * cos(2.0 * PI * f_sc_px * (nf + Ax));
        conv_gcos += w_notch_r * compositeR + w_notch_l * compositeL;
        sum_g     += g_env_r + g_env_l;

        // Accumulate chroma band-pass (modulated at f_sc)
        float w_bp_r = g_bp_r * cos(2.0 * PI * f_sc_px * (nf - Ax));
        float w_bp_l = g_bp_l * cos(2.0 * PI * f_sc_px * (nf + Ax));
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
        float phase_per_line = 2.0 * PI * tb.sc_freq_hz / tb.h_freq_hz;
        
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
        float t_offset_1 = 1.0 / tb.h_freq_hz + time_correction_1;
        float t_offset_2 = 2.0 / tb.h_freq_hz + time_correction_2;
        float t_offset_3 = 3.0 / tb.h_freq_hz + time_correction_3;

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
    vec2 color;
    if (COLOR_FILTER_MODE < 0.5) {
        // Notch: use band-stop luma and band-pass chroma (now centered at f_sc)
        color = vec2(y_out, c_bp);
    } else if (COLOR_FILTER_MODE < 1.5) {
        color = vec2(color_comb);
        y_out = color_comb.r;
    } else if (COLOR_FILTER_MODE < 2.5) {
        // Mix between the notch and comb outputs
        color = mix(vec2(y_out, c_bp), color_comb, NOTCH_COMB_W / 100.0);
    } else if (COLOR_FILTER_MODE < 3.5) {
        color = vec2(RAW_Y_CORRECT * composite0, RAW_C_CORRECT * composite0);
    }

    // BW monitor modes: route either luma-only or chroma-only to all channels
    float c_out = color.g;
    if (BW_MODE < 0.5) {
        // Normal output (no user scaling applied here)
    } else if (BW_MODE < 1.5) {
        color = vec2(y_out, 0.0);
    } else if (BW_MODE < 2.5) {
        color = vec2(0.0, c_out);
    } else if (BW_MODE < 3.5) {
        color = vec2(y_out, c_out);
    }

    FragColor = vec4(color, vec2(0.0, 1.0));
}
