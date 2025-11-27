#version 450

// Filename: composite-demod-postfilter.slang
//
// Post-filter after IF demodulation:
// - Applies Gaussian notch (luma) and Gaussian chroma filtering like composite-mod-prefilter.slang
// - Two chroma modes:
//   1) True chroma demodulation: modulated Gaussian band-pass around subcarrier to restore suppressed sideband
//   2) Simple demodulation: Gaussian low-pass at 0.6 MHz with ~6 dB attenuation at cutoff
//
// Input: R channel = composite baseband (output of if-demod.slang)
// Output: R = filtered luma, G = filtered chroma
//
// Copyright (C) 2025 W. M. Martinez
// Licensed under GPLv3 or later.

#include "common.inc"
#include "modulation.inc"
#include "bandlimit.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"
#include "menus/parameters/composite.inc"

#pragma parameter BYPASS_PREFILTER "Bypass prefilter (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter CHROMA_DEMOD_MODE "Chroma mode (true, simple)" 0.0 0.0 1.0 1.0
#pragma parameter VSB_CHROMA_AWARE "VSB chroma correction (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter IQ_CUTOFF_MHZ "IQ lowpass cutoff (MHz)" 4.2 2.0 8.0 0.1
#pragma parameter CHROMA_I_BW_MHZ "Chroma I bandwidth (MHz)" 1.3 0.4 2.0 0.1
#pragma parameter CHROMA_Q_BW_MHZ "Chroma Q bandwidth (MHz)" 0.4 0.2 1.3 0.1

#pragma name CompositePreFilter
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_PREFILTER;
    float CHROMA_DEMOD_MODE;
    float VSB_CHROMA_AWARE;
    float IQ_CUTOFF_MHZ;
    float CHROMA_I_BW_MHZ;
    float CHROMA_Q_BW_MHZ;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float NOTCH_WIDTH;
    float BANDPASS_WIDTH;
    float NOTCH_CENTER_ATTEN_DB;
    float NOTCH_EDGE_ATTEN_DB;
    float NOTCH_Y_CORRECT;
    float RAW_Y_CORRECT;
    float RAW_C_CORRECT;
    float PAL;
} config;

#define BYPASS_PREFILTER config.BYPASS_PREFILTER
#define CHROMA_DEMOD_MODE config.CHROMA_DEMOD_MODE
#define VSB_CHROMA_AWARE config.VSB_CHROMA_AWARE
#define IQ_CUTOFF_MHZ config.IQ_CUTOFF_MHZ
#define CHROMA_I_BW_MHZ config.CHROMA_I_BW_MHZ
#define CHROMA_Q_BW_MHZ config.CHROMA_Q_BW_MHZ

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#define NOTCH_WIDTH config.NOTCH_WIDTH
#define NOTCH_CENTER_ATTEN_DB config.NOTCH_CENTER_ATTEN_DB
#define NOTCH_EDGE_ATTEN_DB config.NOTCH_EDGE_ATTEN_DB
#define BANDPASS_WIDTH config.BANDPASS_WIDTH

#define NOTCH_Y_CORRECT config.NOTCH_Y_CORRECT
#define RAW_Y_CORRECT config.RAW_Y_CORRECT
#define RAW_C_CORRECT config.RAW_C_CORRECT

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
layout(location = 2) out vec2 vsb_chroma_gain;
layout(location = 3) out TimebaseConfig tb;

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

    // Precompute Gaussian sigmas, matching composite-mod-prefilter approach
    sigma.x = sigma_tb(tb, max(NOTCH_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);
    sigma.y = sigma_tb(tb, max(BANDPASS_WIDTH * 0.5, 1e-6), NOTCH_EDGE_ATTEN_DB);

    // Compute VSB chroma gain factors for adaptive correction
    // NTSC: I = ±1.3 MHz (default), Q = ±0.4 MHz (default)
    // PAL/SECAM: typically narrower symmetric chroma
    // Adapts to arbitrary subcarrier frequency and IQ lowpass cutoff
    vsb_chroma_gain = compute_vsb_chroma_gain(tb.sc_freq_hz, IQ_CUTOFF_MHZ,
                                              CHROMA_I_BW_MHZ, CHROMA_Q_BW_MHZ);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 sigma;
layout(location = 2) in vec2 vsb_chroma_gain;
layout(location = 3) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_PREFILTER > 0.5) {
        vec4 s = texture(Source, vTexCoord);
        FragColor = vec4(s.rg, 0.0, 1.0);
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
    float A_edge_dB = NOTCH_EDGE_ATTEN_DB;
    float a_center = pow(10.0, -A_center_dB / 20.0);
    float alpha = clamp(2.0 * (1.0 - a_center), 0.0, 2.0);

    const float THRESHOLD = 1.0 / 255.0;

    // Center sample (match composite-mod-prefilter behavior: phase from offset only, not fractional center time)
    float t0 = line / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
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

    // Symmetric lobes
    for (int n = 1; n <= 24; ++n) {
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

    // Luma notch output
    float notch_response = conv_gcos / max(sum_g, EPS);
    float y_out = NOTCH_Y_CORRECT * (composite0 - alpha * notch_response);

    // Chroma filtering modes with VSB-aware correction
    float c_out;
    if (CHROMA_DEMOD_MODE < 0.5) {
        // True chroma demodulation: VSB-aware I/Q recovery
        // NTSC uses quadrature modulation with asymmetric bandwidths:
        // - I (in-phase): ±1.3 MHz relative to subcarrier (default)
        // - Q (quadrature): ±0.4 MHz relative to subcarrier (default)
        // After IQ mod/demod (4.2 MHz lowpass), sidebands become asymmetric (VSB-shaped)
        
        float c_bp_raw = c_accum / max(sum_c, EPS);
        
        if (VSB_CHROMA_AWARE > 0.5) {
            // VSB-aware correction: compensate for sideband asymmetry
            // The bandpass filter extracts composite chroma containing both I and Q
            // modulated at 90° phase difference. Effective gain depends on sideband preservation.
            //
            // I channel: wider bandwidth (±1.3 MHz) → more affected by IQ cutoff
            // Q channel: narrow bandwidth (±0.4 MHz) → less affected
            //
            // Composite chroma gain: weighted average based on energy contribution
            const float I_WEIGHT = 0.7;  // I carries most luma-chroma cross-energy
            const float Q_WEIGHT = 0.3;  // Q carries pure color difference
            float composite_vsb_gain = I_WEIGHT * vsb_chroma_gain.x + Q_WEIGHT * vsb_chroma_gain.y;
            
            // Normalize by VSB gain and modulation loss (cos² average = 0.5)
            c_out = 2.0 * c_bp_raw / composite_vsb_gain;
        } else {
            // Legacy DSB assumption: both sidebands fully preserved
            // Standard modulation loss compensation only
            c_out = 2.0 * c_bp_raw;
        }
    } else {
        // Simple demodulation: lowpass at Q bandwidth (0.4 MHz default)
        // Extracts narrow-band chroma without attempting I/Q separation
        // Less affected by VSB asymmetry since it doesn't rely on wide I bandwidth
        float c_lp = c_accum / max(sum_c, EPS);
        
        if (VSB_CHROMA_AWARE > 0.5) {
            // Simple mode uses Q-channel VSB correction
            // Q bandwidth is narrow, typically less affected by IQ cutoff
            c_out = 2.0 * c_lp / vsb_chroma_gain.y;
        } else {
            // Legacy: assume no sideband loss
            c_out = 2.0 * c_lp;
        }
    }

    FragColor = vec4(vec2(y_out, c_out), vec2(0.0, 1.0));
}
