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

#pragma name IFDemod
#pragma format R16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_IF_DEMOD;
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

// IF/demodulation parameters (must match if-mod.slang)
const float IF_CARRIER_MHZ = 8.0;          // Practical IF carrier (NTSC VSB)
const float VSB_VESTIGE_MHZ = 0.75;        // Lower sideband vestige width
const float VSB_FULL_SIDEBAND_MHZ = 4.2;   // Upper sideband full width (NTSC)

// Kaiser windowed-sinc lowpass for demod (matches if-mod.slang design)
// Target stopband adapts with resolution: 20 dB → 24 dB
const float TARGET_STOPBAND_DB = 20.0;     // Base; actual used value adapts per width
const float MIN_TRANSITION_BW_MHZ = 1.0;   // Tighter transition at high res
const float MAX_TRANSITION_BW_MHZ = 2.0;   // Wider transition at low res
const int MIN_TAPS = 16;                   // Match if-mod.slang
const int MAX_TAPS = 40;                   // Match if-mod.slang

// Shared windowed-sinc helpers are now in window.inc

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_lp_norm;     // normalized lowpass cutoff
layout(location = 2) out float filter_taps;    // adaptive tap count
layout(location = 3) out float kaiser_beta;    // Kaiser window parameter
layout(location = 4) out float aliased_carrier_norm; // aliased IF carrier frequency
layout(location = 5) out TimebaseConfig tb;

// Zone-aware alias helper: correctly handles even/odd Nyquist zones
// Odd zones (1,3,5...): frequency aliases normally
// Even zones (2,4,6...): frequency inverts (spectral mirroring)
float alias_freq(float f_hz, float sample_rate_hz, out int zone)
{
    float nyquist = 0.5 * sample_rate_hz;
    zone = int(floor(f_hz / nyquist));
    float aliased = f_hz - float(zone) * nyquist;
    
    // Even zones invert the spectrum
    if (zone % 2 == 0) {
        aliased = nyquist - aliased;
    }
    
    return aliased;
}

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

    // Compute output texture sample rate
    // The IF signal is stored in the output texture at OutputSize.x resolution
    // Sample rate = pixels per line × line frequency
    float sample_rate_hz = config.OutputSize.x * tb.h_freq_hz;
    float sample_rate_mhz = sample_rate_hz * 1.0e-6;
    
    // Compute aliased IF carrier frequency (bandpass sampling)
    // The 8 MHz carrier may alias depending on sample rate
    // Zone 0 (fs > 16 MHz): no aliasing, carrier stays at 8 MHz
    // Zone 1 (fs < 16 MHz): aliases to lower frequency
    float if_carrier_hz = IF_CARRIER_MHZ * 1.0e6;
    int carrier_zone;
    float aliased_carrier_hz = alias_freq(if_carrier_hz, sample_rate_hz, carrier_zone);
    aliased_carrier_norm = aliased_carrier_hz / sample_rate_hz;
    
    // Compute VSB bandwidth for lowpass cutoff
    float vsb_bandwidth_mhz = VSB_VESTIGE_MHZ + VSB_FULL_SIDEBAND_MHZ;
    float lpf_cutoff_hz = vsb_bandwidth_mhz * 1.0e6 * 0.5; // Half-bandwidth for lowpass
    fc_lp_norm = clamp(lpf_cutoff_hz / sample_rate_hz, 1e-5, 0.49);
    
    // Adaptive transition bandwidth based on OutputSize.x (match if-mod.slang)
    float output_width = config.OutputSize.x;
    float width_factor = clamp((output_width - 720.0) / (1920.0 - 720.0), 0.0, 1.0);
    
    float transition_bw_mhz = mix(MAX_TRANSITION_BW_MHZ, MIN_TRANSITION_BW_MHZ, width_factor);
    float transition_bw_norm = (transition_bw_mhz * 1.0e6) / sample_rate_hz;
    transition_bw_norm = max(transition_bw_norm, 1.2 / sample_rate_hz); // avoid pathological narrow transitions
    
    // Adaptive stopband: 20 dB → 24 dB to reduce residual aliasing at higher widths
    float target_stop_db = mix(20.0, 24.0, width_factor);
    kaiser_beta = 0.1102 * (target_stop_db - 8.7);
    
    // Compute required taps using Kaiser formula
    float required_taps = (target_stop_db - 8.0) / (2.285 * max(transition_bw_norm, 0.01));
    
    // Adaptive tap budget (mirror if-mod.slang)
    float adaptive_max_taps = mix(18.0, float(MAX_TAPS), width_factor);
    filter_taps = clamp(required_taps, float(MIN_TAPS), adaptive_max_taps);
    filter_taps = floor(filter_taps * 0.5) * 2.0; // Round to even
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_lp_norm;
layout(location = 2) in float filter_taps;
layout(location = 3) in float kaiser_beta;
layout(location = 4) in float aliased_carrier_norm;
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

    vec2 Tex = vec2(
        baseCenter * config.OutputSize.z,
        (line + 0.5) * config.OutputSize.w);

    float t0 = line / tb.h_freq_hz + baseCenter * tb.pixel_time_px;
    float if_hz = IF_CARRIER_MHZ * 1.0e6;
    
    // Derive IF field phase (match if-mod.slang)
    float if_field_phase = 0.0;
    {
        float denom = max(tb.sc_freq_hz, EPS);
        float freq_ratio = if_hz / denom;
        float normalized_field_phase = fract(tb.field_phase / (2.0 * PI));
        if_field_phase = normalized_field_phase * freq_ratio * 2.0 * PI;
        if_field_phase = mod(if_field_phase, 2.0 * PI);
    }

    // Precompute phase increment per pixel for precision
    float if_phase_inc_per_px = 2.0 * PI * if_hz * tb.pixel_time_px;

    // For bandpass-sampled signals, demodulate at the ALIASED carrier frequency
    // This correctly recovers the baseband without needing the actual 44 MHz
    float aliased_carrier_hz = aliased_carrier_norm * (1.0 / tb.pixel_time_px);
    float aliased_phase_inc_per_px = 2.0 * PI * aliased_carrier_hz * tb.pixel_time_px;

    // Complex demodulation at aliased carrier
    float lo_phase0 = compute_carrier_phase(t0, aliased_carrier_hz, if_field_phase);
    vec2 lo0 = sincos_phase_raw(lo_phase0);
    float lo_c0 = lo0.y;  // cos
    float lo_s0 = -lo0.x; // -sin for e^{-jωt}

    // IF input (R channel)
    float if0 = texture(Source, Tex).r;

    float i0 = if0 * lo_c0;
    float q0 = if0 * lo_s0;

    // Convolve I & Q with lowpass windowed-sinc
    float i_acc = 0.0;
    float q_acc = 0.0;
    float wsum = 0.0;
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    float c0 = sinc_lowpass_coeff(-Ax, fc_lp_norm, kaiser_beta, filter_taps);
    i_acc += c0 * i0;
    q_acc += c0 * q0;
    wsum  += c0;

    int max_tap = int(filter_taps);
    // Loop limit matches if-mod.slang MAX_TAPS
    for (int n = 1; n <= 40; ++n) {
        if (n > max_tap) break;
        
        float nf = float(n);

        // Right sample - use aliased carrier phase increment
        vec2 Tex_r = Tex + nf * dx;
        float lo_phase_r = lo_phase0 + nf * aliased_phase_inc_per_px;
        lo_phase_r = mod(lo_phase_r + PI, 2.0 * PI) - PI;
        vec2 lor = sincos_phase_raw(lo_phase_r);
        float lo_cr = lor.y;
        float lo_sr = -lor.x;
        float if_r = texture(Source, Tex_r).r;
        float ir = if_r * lo_cr;
        float qr = if_r * lo_sr;
        float cr = sinc_lowpass_coeff(nf - Ax, fc_lp_norm, kaiser_beta, filter_taps);

        // Left sample - use aliased carrier phase increment
        vec2 Tex_l = Tex - nf * dx;
        float lo_phase_l = lo_phase0 - nf * aliased_phase_inc_per_px;
        lo_phase_l = mod(lo_phase_l + PI, 2.0 * PI) - PI;
        vec2 lol = sincos_phase_raw(lo_phase_l);
        float lo_cl = lol.y;
        float lo_sl = -lol.x;
        float if_l = texture(Source, Tex_l).r;
        float il = if_l * lo_cl;
        float ql = if_l * lo_sl;
        float cl = sinc_lowpass_coeff(-nf - Ax, fc_lp_norm, kaiser_beta, filter_taps);

        i_acc += cr * ir + cl * il;
        q_acc += cr * qr + cl * ql;
        wsum  += cr + cl;
    }

    // Normalize LPF gain
    float I = i_acc / max(wsum, EPS);
    float Q = q_acc / max(wsum, EPS);

    // No additional gain: modulator already applied 2× compensation for cos mixer
    // This maintains unity gain through the IF mod→demod chain
    // Simplified single mode: linear I/Q mix tuned for VSB asymmetry, preserves chroma
    float composite = I + K_VSB * Q;

    FragColor = vec4(composite, 0.0, 0.0, 1.0);
}
