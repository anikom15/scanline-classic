#version 450

// Filename: if-demod.slang
//
// Demodulates the IF-modulated composite signal back to baseband
// using a cosine mixer at the IF carrier and a Kaiser 4.2
// windowed-sinc lowpass filter. Outputs the restored composite
// signal in the R channel.
//
// Copyright (C) 2025 W. M. Martinez
// Licensed under GPLv3 or later.

#include "common.inc"
#include "modulation.inc"
#include "window.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_IF_DEMOD "Bypass IF demod (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter IF_DEMOD_USE_NYQUIST "Use Nyquist VSB filter (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter IF_DEMOD_MODE "IF Demod Mode (I, Magnitude, Mix)" 0.0 0.0 2.0 1.0

#pragma name IFDemod
#pragma format R16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_IF_DEMOD;
    float IF_DEMOD_USE_NYQUIST;
    float IF_DEMOD_MODE;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float K_VSB;
} config;

#define BYPASS_IF_DEMOD config.BYPASS_IF_DEMOD
#define IF_DEMOD_USE_NYQUIST config.IF_DEMOD_USE_NYQUIST
#define IF_DEMOD_MODE config.IF_DEMOD_MODE
#define K_VSB config.K_VSB

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// IF/demodulation parameters (must match encoder)
const float IF_CARRIER_MHZ = 44.0;         // must match if-mod
const float LPF_CUTOFF_MHZ = 4.2;          // baseband LPF cutoff (MHz)
const float KAISER_BETA = 2.5;             // Kaiser window beta (~25 dB stopband)

// Nyquist VSB filter constants (must match if-mod bandpass asymmetry)
const float VSB_CENTER_MHZ = 45.475;       // match if-mod BANDPASS_CENTER_MHZ
const float VSB_BANDWIDTH_MHZ = 5.45;      // match if-mod OUTPUT_BANDWIDTH_MHZ
const float NYQUIST_TAPS = 16.0;           // VSB correction filter half-length

// Shared windowed-sinc helpers are now in window.inc

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_lp_norm;    // normalized lowpass cutoff
layout(location = 2) out float filter_taps;   // half-length taps
layout(location = 3) out float vsb_fc_upper_norm; // Nyquist VSB upper cutoff
layout(location = 4) out float vsb_fc_lower_norm; // Nyquist VSB lower cutoff
layout(location = 5) out TimebaseConfig tb;

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

    // Lowpass cutoff at 4.2 MHz in baseband per system spec
    float cutoff_hz = LPF_CUTOFF_MHZ * 1.0e6;
    float sample_rate_hz = 1.0 / tb.pixel_time_px;
    fc_lp_norm = clamp(cutoff_hz / sample_rate_hz, 1e-5, 0.49);

    // Estimate taps from transition BW ~ 0.5 MHz, clamp for practicality
    float transition_bw_hz = 0.5e6;
    float transition_bw_norm = clamp(transition_bw_hz / sample_rate_hz, 1e-5, 0.25);
    // Kaiser empirical length: N ≈ (A - 8) / (2.285 * Δf); A ~ maps from beta
    // For beta=4.2, use A≈50 dB → N around this value. Keep runtime safe.
    float A = 50.0;
    float N_est = (A - 8.0) / (2.285 * transition_bw_norm);
    filter_taps = clamp(ceil(N_est), 12.0, 32.0);

    // Nyquist VSB filter cutoffs (inverse of if-mod bandpass asymmetry)
    // Upper edge: VSB_CENTER + VSB_BANDWIDTH/2
    // Lower edge: VSB_CENTER - VSB_BANDWIDTH/2
    float vsb_upper_hz = (VSB_CENTER_MHZ + VSB_BANDWIDTH_MHZ * 0.5) * 1.0e6;
    float vsb_lower_hz = (VSB_CENTER_MHZ - VSB_BANDWIDTH_MHZ * 0.5) * 1.0e6;
    vsb_fc_upper_norm = clamp(vsb_upper_hz / sample_rate_hz, 1e-5, 0.49);
    vsb_fc_lower_norm = clamp(vsb_lower_hz / sample_rate_hz, 1e-5, 0.49);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_lp_norm;
layout(location = 2) in float filter_taps;
layout(location = 3) in float vsb_fc_upper_norm;
layout(location = 4) in float vsb_fc_lower_norm;
layout(location = 5) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_IF_DEMOD > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float line = floor(UV.y);
    float baseIndex = floor(UV.x);
    float baseCenter = baseIndex + 0.5;
    float Ax = UV.x - baseCenter;

    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (line + 0.5) * config.OutputSize.w);

    float t0 = line / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
    float if_hz = IF_CARRIER_MHZ * 1.0e6;
    // Derive IF field phase from subcarrier field phase scaled by frequency ratio
    // Normalize to [0,1) before scaling to prevent precision loss from large phase values
    float if_field_phase = 0.0;
    {
        float denom = max(tb.sc_freq_hz, EPS);
        float freq_ratio = if_hz / denom;
        float normalized_field_phase = fract(tb.field_phase / (2.0 * PI));
        if_field_phase = normalized_field_phase * freq_ratio * 2.0 * PI;
        if_field_phase = mod(if_field_phase, 2.0 * PI);
    }

    // Precompute phase increment per pixel for precision in filter loops
    float if_phase_inc_per_px = 2.0 * PI * if_hz * tb.pixel_time_px;

    // Branch: Nyquist VSB filter path or I/Q demod path
    if (IF_DEMOD_USE_NYQUIST > 0.5) {
        // === Nyquist VSB Filter Mode ===
        // 1. Apply asymmetric VSB correction filter at IF to balance sidebands
        // 2. Real demod with single cos mixer
        // 3. Single LPF to remove 2*f_IF image
        
        float if0 = texture(Source, Tex).r;
        vec2 dx = vec2(config.OutputSize.z, 0.0);
        
        // Nyquist VSB equalization: inverse bandpass (boost lower sideband, attenuate upper)
        // Design: bandpass centered at IF with inverse gain profile
        // For simplicity, use windowed-sinc bandpass inverted (lower gain = higher boost)
        float vsb_corrected = 0.0;
        float vsb_wsum = 0.0;
        int nyquist_max = int(NYQUIST_TAPS);
        
        // Center tap
        float nyq_c0 = sinc_bandpass_coeff(-Ax, vsb_fc_upper_norm, vsb_fc_lower_norm, KAISER_BETA, NYQUIST_TAPS);
        // Invert gain for correction (boost vestigial sideband)
        float correction_scale = 1.5;  // empirical tuning factor
        float vsb_coeff0 = 1.0 - correction_scale * nyq_c0;
        vsb_corrected += vsb_coeff0 * if0;
        vsb_wsum += vsb_coeff0;
        
        for (int n = 1; n <= 16; ++n) {
            float nf = float(n);
            
            vec2 Tex_r = Tex + nf * dx;
            float if_r = texture(Source, Tex_r).r;
            float nyq_cr = sinc_bandpass_coeff(nf - Ax, vsb_fc_upper_norm, vsb_fc_lower_norm, KAISER_BETA, NYQUIST_TAPS);
            float vsb_coeff_r = 1.0 - correction_scale * nyq_cr;
            
            vec2 Tex_l = Tex - nf * dx;
            float if_l = texture(Source, Tex_l).r;
            float nyq_cl = sinc_bandpass_coeff(-nf - Ax, vsb_fc_upper_norm, vsb_fc_lower_norm, KAISER_BETA, NYQUIST_TAPS);
            float vsb_coeff_l = 1.0 - correction_scale * nyq_cl;
            
            vsb_corrected += vsb_coeff_r * if_r + vsb_coeff_l * if_l;
            vsb_wsum += vsb_coeff_r + vsb_coeff_l;
            
            if (n >= nyquist_max)
                break;
        }
        
        // Normalize VSB correction (optional, depends on sum behavior)
        float if_vsb = vsb_corrected / max(abs(vsb_wsum), EPS);
        
        // Real demodulation: mix down with cos(ωt)
        float lo_phase0 = compute_carrier_phase(t0, if_hz, if_field_phase);
        float lo_c0 = sincos_phase(lo_phase0).y;
        float demod0 = if_vsb * lo_c0;
        
        // Lowpass filter to remove 2*f_IF image
        float composite_acc = 0.0;
        float lp_wsum = 0.0;
        
        float lp_c0 = sinc_lowpass_coeff(-Ax, fc_lp_norm, KAISER_BETA, filter_taps);
        composite_acc += lp_c0 * demod0;
        lp_wsum += lp_c0;
        
        int max_tap = int(filter_taps);
        for (int n = 1; n <= 30; ++n) {
            float nf = float(n);
            
            vec2 Tex_r = Tex + nf * dx;
            float if_r_vsb = texture(Source, Tex_r).r;  // assume VSB-corrected in practice
            // Use phase increment for better precision
            float lo_phase_r = lo_phase0 + nf * if_phase_inc_per_px;
            lo_phase_r = mod(lo_phase_r + PI, 2.0 * PI) - PI;
            float lo_cr = cos(lo_phase_r);
            float demod_r = if_r_vsb * lo_cr;
            float lp_cr = sinc_lowpass_coeff(nf - Ax, fc_lp_norm, KAISER_BETA, filter_taps);
            
            vec2 Tex_l = Tex - nf * dx;
            float if_l_vsb = texture(Source, Tex_l).r;
            // Use phase increment for better precision
            float lo_phase_l = lo_phase0 - nf * if_phase_inc_per_px;
            lo_phase_l = mod(lo_phase_l + PI, 2.0 * PI) - PI;
            float lo_cl = cos(lo_phase_l);
            float demod_l = if_l_vsb * lo_cl;
            float lp_cl = sinc_lowpass_coeff(-nf - Ax, fc_lp_norm, KAISER_BETA, filter_taps);
            
            composite_acc += lp_cr * demod_r + lp_cl * demod_l;
            lp_wsum += lp_cr + lp_cl;
            
            if (n >= max_tap)
                break;
        }
        
        float composite = (composite_acc / max(lp_wsum, EPS)) * 2.0;  // compensate mixer loss
        FragColor = vec4(composite, 0.0, 0.0, 1.0);
        return;
    }

    // Local oscillators for complex demod (analytic baseband)
    float lo_phase0 = compute_carrier_phase(t0, if_hz, if_field_phase);
    vec2 lo0 = sincos_phase(lo_phase0);
    float lo_c0 = lo0.y;                 // cos
    float lo_s0 = -lo0.x;                // -sin (for e^{-jωt})

    // IF input (R channel)
    float if0 = texture(Source, Tex).r;

    float i0 = if0 * lo_c0;
    float q0 = if0 * lo_s0;

    // Convolve I & Q with lowpass windowed-sinc
    float i_acc = 0.0;
    float q_acc = 0.0;
    float wsum = 0.0;
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    float c0 = sinc_lowpass_coeff(-Ax, fc_lp_norm, KAISER_BETA, filter_taps);
    i_acc += c0 * i0;
    q_acc += c0 * q0;
    wsum  += c0;

    int max_tap = int(filter_taps);
    for (int n = 1; n <= 30; ++n) {
        float nf = float(n);

        // Right sample - use phase increment for better precision
        vec2 Tex_r = Tex + nf * dx;
        float t_r = t0 + nf * tb.pixel_time_px;
        float lo_phase_r = lo_phase0 + nf * if_phase_inc_per_px;
        lo_phase_r = mod(lo_phase_r + PI, 2.0 * PI) - PI;
        vec2 lor = sincos_phase(lo_phase_r);
        float lo_cr = lor.y;
        float lo_sr = -lor.x;
        float if_r = texture(Source, Tex_r).r;
        float ir = if_r * lo_cr;
        float qr = if_r * lo_sr;
        float cr = sinc_lowpass_coeff(nf - Ax, fc_lp_norm, KAISER_BETA, filter_taps);

        // Left sample - use phase increment for better precision
        vec2 Tex_l = Tex - nf * dx;
        float t_l = t0 - nf * tb.pixel_time_px;
        float lo_phase_l = lo_phase0 - nf * if_phase_inc_per_px;
        lo_phase_l = mod(lo_phase_l + PI, 2.0 * PI) - PI;
        vec2 lol = sincos_phase(lo_phase_l);
        float lo_cl = lol.y;
        float lo_sl = -lol.x;
        float if_l = texture(Source, Tex_l).r;
        float il = if_l * lo_cl;
        float ql = if_l * lo_sl;
        float cl = sinc_lowpass_coeff(-nf - Ax, fc_lp_norm, KAISER_BETA, filter_taps);

        i_acc += cr * ir + cl * il;
        q_acc += cr * qr + cl * ql;
        wsum  += cr + cl;
        if (n >= max_tap)
            break;
    }

    // Normalize LPF gain
    float I = i_acc / max(wsum, EPS);
    float Q = q_acc / max(wsum, EPS);

    // Compensate mixer 0.5 amplitude loss (real part of cos * signal)
    I *= 2.0;
    Q *= 2.0;

    float composite;
    if (IF_DEMOD_MODE < 0.5) {
        // Mode 0: I only
        composite = I;
    } else if (IF_DEMOD_MODE < 1.5) {
        // Mode 1: magnitude (image & phase artifact suppression)
        composite = length(vec2(I, Q));
    } else {
        // Mode 2: linear mix tuned for VSB imbalance
        composite = I + K_VSB * Q;
    }

    FragColor = vec4(composite, 0.0, 0.0, 1.0);
}
