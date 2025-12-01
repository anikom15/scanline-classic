#version 450

// Filename: composite-prefilter.slang
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
// Composite separation filter (without initial modulation)
// ----------------------------------------------------------------
// Input: Composite baseband signal (from iq-demod.slang)
// Output: Separated Y and C signals

#include "common.inc"
#include "modulation.inc"
#include "bandlimit.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"
#include "menus/parameters/composite.inc"

#pragma parameter BYPASS_PREFILTER "Bypass prefilter (off, on)" 0.0 0.0 1.0 1.0

#pragma name CompositePreFilter
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_PREFILTER;
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
} config;

#define BYPASS_PREFILTER config.BYPASS_PREFILTER

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
    if (BYPASS_PREFILTER > 0.5) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Input composite baseband from previous stage
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float line = floor(UV.y);
    float baseIndex = floor(UV.x);
    float baseCenter = baseIndex + 0.5;
    float Ax = UV.x - baseCenter;

    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (line + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    float A_center_dB = NOTCH_CENTER_ATTEN_DB;
    float a_center = pow(10.0, -A_center_dB / 20.0);
    float alpha = clamp(2.0 * (1.0 - a_center), 0.0, 2.0);

    const float THRESHOLD = 1.0 / 255.0;

    // Center sample - input is already composite baseband from iq-demod.slang
    float composite0 = texture(Source, Tex).r;

    // Luma notch accumulators
    float conv_gcos = 0.0;
    float sum_g = 0.0;

    // Chroma accumulators
    float c_accum = 0.0;
    float sum_c = 0.0;

    // Subcarrier cycles per pixel for modulation (cycles/pixel)
    float f_sc_px = tb.sc_freq_hz * tb.pixel_time_px;

    // Center weights (include fractional horizontal offset Ax)
    float g_env0 = gaussian(Ax, sigma.x);
    sum_g += g_env0;
    float w_cos0 = g_env0 * cos(2.0 * PI * f_sc_px * Ax);

    float g_bp0 = gaussian(Ax, sigma.y);
    float w_bp0 = g_bp0 * cos(2.0 * PI * f_sc_px * Ax);

    conv_gcos += w_cos0 * composite0;
    c_accum += w_bp0 * composite0;
    sum_c += g_bp0;

    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 20; ++n) {
        float nf = float(n);

        float g_env_r = gaussian(nf - Ax, sigma.x);
        float g_env_l = gaussian(nf + Ax, sigma.x);
        float g_bp_r  = gaussian(nf - Ax, sigma.y);
        float g_bp_l  = gaussian(nf + Ax, sigma.y);

        if (g_env_r < THRESHOLD && g_env_l < THRESHOLD &&
            g_bp_r  < THRESHOLD && g_bp_l  < THRESHOLD)
            break;

        // Right
        vec2 Tex_r = Tex + nf * dx;
        float comp_r = texture(Source, Tex_r).r;
        float w_notch_r = g_env_r * cos(2.0 * PI * f_sc_px * (nf - Ax));
        float w_bp_r = g_bp_r  * cos(2.0 * PI * f_sc_px * (nf - Ax));

        // Left
        vec2 Tex_l = Tex - nf * dx;
        float comp_l = texture(Source, Tex_l).r;
        float w_notch_l = g_env_l * cos(2.0 * PI * f_sc_px * (nf + Ax));
        float w_bp_l = g_bp_l  * cos(2.0 * PI * f_sc_px * (nf + Ax));

        conv_gcos += w_notch_r * comp_r + w_notch_l * comp_l;
        sum_g += g_env_r + g_env_l;

        c_accum += w_bp_r * comp_r + w_bp_l * comp_l;
        sum_c += g_bp_r + g_bp_l;
    }

    // Normalize luma band-stop notch
    // Scale to balance white-level (determined empirically)
    float notch_response = conv_gcos / max(sum_g, EPS);
    float y_out = NOTCH_Y_CORRECT * (composite0 - alpha * notch_response);

    // Reconstruct chroma with modulated Gaussian band-pass (centered at f_sc)
    // Scale to compensate for modulation gain loss (cos^2 average = 0.5; determined empirically)
    float c_bp = 2.0 * c_accum / max(sum_c, EPS);

    // Comb filter path (compute only when needed)
    vec2 color_comb = vec2(0.0);

    if (COLOR_FILTER_MODE >= 0.5 && COLOR_FILTER_MODE < 3.5) {
        // Current line phase at this texel
        float t0 = line / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
        float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);

        // Subcarrier phase increment per horizontal pixel (radians/pixel)
        float sc_phase_inc_per_px = 2.0 * PI * tb.sc_freq_hz * tb.pixel_time_px;
        // Subcarrier spatial period in pixels
        float period_px = 2.0 * PI / sc_phase_inc_per_px;

        // Vertical offsets for line taps
        vec2 comb_dy_1 = vec2(0.0, -1.0 * config.OutputSize.w);
        vec2 comb_dy_2 = vec2(0.0, -2.0 * config.OutputSize.w);
        vec2 comb_dy_3 = vec2(0.0, -3.0 * config.OutputSize.w);

        // Compute phase-aligned horizontal shifts for each tap line
        // Tap 1 (line -1): target phase difference = π (180°)
        float t1_same = (line - 1.0) / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
        float phase1_same = compute_carrier_phase(t1_same, tb.sc_freq_hz, tb.field_phase);
        float dphi1 = normalize_phase(phase1_same - phase0);
        float dphi_needed1 = dphi1 - PI;
        float dx1_px = dphi_needed1 / sc_phase_inc_per_px;
        dx1_px -= round(dx1_px / period_px) * period_px;

        // Tap 2 (line -2): target phase difference = 0 (in-phase)
        float t2_same = (line - 2.0) / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
        float phase2_same = compute_carrier_phase(t2_same, tb.sc_freq_hz, tb.field_phase);
        float dphi2 = normalize_phase(phase2_same - phase0);
        float dphi_needed2 = dphi2 - 0.0;
        float dx2_px = dphi_needed2 / sc_phase_inc_per_px;
        dx2_px -= round(dx2_px / period_px) * period_px;

        // Tap 3 (line -3): target phase difference = π (180°)
        float t3_same = (line - 3.0) / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
        float phase3_same = compute_carrier_phase(t3_same, tb.sc_freq_hz, tb.field_phase);
        float dphi3 = normalize_phase(phase3_same - phase0);
        float dphi_needed3 = dphi3 - PI;
        float dx3_px = dphi_needed3 / sc_phase_inc_per_px;
        dx3_px -= round(dx3_px / period_px) * period_px;

        vec2 dx_norm = vec2(config.OutputSize.z, 0.0);

        // Sample phase-aligned taps
        vec3 comb_taps_composite = vec3(
            texture(Source, Tex + comb_dy_1 - dx1_px * dx_norm).r,
            texture(Source, Tex + comb_dy_2 - dx2_px * dx_norm).r,
            texture(Source, Tex + comb_dy_3 - dx3_px * dx_norm).r
        );

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
