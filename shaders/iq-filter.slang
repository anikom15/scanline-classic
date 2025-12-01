#version 450

// Filename: iq-mod.slang
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
// IQ baseband modulation shader for VSB
// -----------------------------------------------------------------
// Input: Component voltage signal (RGB)
// Output: Complex IQ baseband representation (R16G16_SFLOAT)
// 
// This shader models VSB modulation in complex baseband (I/Q) form:
// - Consumes analytic baseband (R=I, G=Q) from composite-iq.slang
// - Applies asymmetric lowpass filtering (I: 4.2 MHz, Q: 0.75 MHz)
// - Per-channel bypass: I filter, Q filter
// - Optional overall I/Q bypass for quick debugging
// - Operates entirely at baseband (no RF carrier)

// Includes trimmed to what is needed for timebase and windowed sinc
#include "common.inc"
#include "window.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"

// Bypass & control parameters
#pragma parameter BYPASS_IQ_MOD "Bypass I/Q filtering (off,on)" 0.0 0.0 1.0 1.0
#pragma parameter BYPASS_I_FILTER "Bypass I lowpass (off,on)" 0.0 0.0 1.0 1.0
#pragma parameter BYPASS_Q_FILTER "Bypass Q lowpass (off,on)" 0.0 0.0 1.0 1.0

#pragma name IQMod
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_IQ_MOD;
    float BYPASS_I_FILTER;
    float BYPASS_Q_FILTER;
    float UNUSED0;
    float UNUSED1;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
} config;

#define BYPASS_IQ_MOD      config.BYPASS_IQ_MOD
#define BYPASS_I_FILTER    config.BYPASS_I_FILTER
#define BYPASS_Q_FILTER    config.BYPASS_Q_FILTER
#define V_FREQ_MODE        config.V_FREQ_MODE
#define V_FREQ             config.V_FREQ
#define V_LINES_PER_FIELD  config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE       config.SC_FREQ_MODE
#define SC_FREQ            config.SC_FREQ
#define H_BLANK_INACTIVE_LEN  config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// VSB baseband parameters (NTSC)
const float VSB_I_CUTOFF_MHZ = 4.2;        // I channel lowpass cutoff (positive frequencies)
const float VSB_Q_CUTOFF_MHZ = 0.75;       // Q channel lowpass cutoff (negative frequencies)

// Blackman-Harris 4-term windowed-sinc filter design (asymmetric per channel)
// We allow more taps for the narrower Q-channel cutoff to keep a clean transition.
const int MIN_TAPS_I = 16;                 // I channel min taps
const int MAX_TAPS_I = 40;                 // I channel max taps
const int MIN_TAPS_Q = 24;                 // Q channel min taps
const int MAX_TAPS_Q = 56;                 // Q channel max taps

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_i_norm;          // I channel cutoff (normalized)
layout(location = 2) out float fc_q_norm;          // Q channel cutoff (normalized)
layout(location = 3) out float taps_i;             // I channel tap count (even)
layout(location = 4) out float taps_q;             // Q channel tap count (even)
layout(location = 5) out TimebaseConfig tb;

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

    // Compute output texture sample rate
    // Sample rate = pixels per line × line frequency
    float sample_rate_hz = config.OutputSize.x * tb.h_freq_hz;
    
    // Normalize cutoff frequencies to sample rate (cycles per sample)
    fc_i_norm = (VSB_I_CUTOFF_MHZ * 1.0e6) / sample_rate_hz;
    fc_q_norm = (VSB_Q_CUTOFF_MHZ * 1.0e6) / sample_rate_hz;

    // Validation & clamp inside Nyquist
    fc_i_norm = clamp(fc_i_norm, 0.0, 0.49);
    fc_q_norm = clamp(fc_q_norm, 0.0, 0.49);

    // Adaptive design based on OutputSize.x ∈ [720, 1440]
    // Blackman-Harris 4-term: stopband ~92 dB, mainlobe width = 8π/N
    float output_width = config.OutputSize.x;
    float width_factor = clamp((output_width - 720.0) / (1440.0 - 720.0), 0.0, 1.0);

    // Adaptive tap counts per channel
    float adaptive_i = mix(float(MIN_TAPS_I), float(MAX_TAPS_I), width_factor);
    float adaptive_q = mix(float(MIN_TAPS_Q), float(MAX_TAPS_Q), width_factor);
    taps_i = floor(adaptive_i * 0.5) * 2.0; // even for symmetry
    taps_q = floor(adaptive_q * 0.5) * 2.0; // even for symmetry
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_i_norm;
layout(location = 2) in float fc_q_norm;
layout(location = 3) in float taps_i;
layout(location = 4) in float taps_q;
layout(location = 5) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
// Source is the analytic signal produced by composite-iq.slang: R=I, G=Q
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Input here is already composite→analytic

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float line = floor(UV.y);
    float baseIndex = floor(UV.x);
    float baseCenter = baseIndex + 0.5;
    float Ax = UV.x - baseCenter;
    
    vec2 Tex = vec2(
        baseCenter * config.OutputSize.z,
        (line + 0.5) * config.OutputSize.w);

    float offset0 = baseCenter;
    vec2 dx = vec2(config.OutputSize.z, 0.0);
    int max_tap_i = int(taps_i);
    int max_tap_q = int(taps_q);
    int max_tap = max(max_tap_i, max_tap_q);
    
    // Central sample from analytic input
    vec2 iq0 = texture(Source, Tex).rg;

    if (BYPASS_IQ_MOD > 0.5) {
        FragColor = vec4(iq0.r, iq0.g, 0.0, 1.0); // pass-through analytic
        return;
    }
    // Apply asymmetric lowpass filtering for VSB to the analytic input
    float i_signal = 0.0;
    float i_wsum = 0.0;
    if (BYPASS_I_FILTER > 0.5) {
        i_signal = iq0.r;
        i_wsum = 1.0;
        max_tap_i = 0; // skip loop accumulation
    } else {
        float coeff0_i = sinc_lowpass_bh4(-Ax, fc_i_norm, taps_i);
        i_signal = coeff0_i * iq0.r;
        i_wsum = coeff0_i;
    }
    
    float q_signal = 0.0;
    float q_wsum = 0.0;
    if (BYPASS_Q_FILTER > 0.5) {
        q_signal = iq0.g;
        q_wsum = 1.0;
        max_tap_q = 0;
    } else {
        float coeff0_q = sinc_lowpass_bh4(-Ax, fc_q_norm, taps_q);
        q_signal = coeff0_q * iq0.g;
        q_wsum = coeff0_q;
    }
    
    // Convolve both channels with neighboring samples (single texture fetch per offset)
    for (int n = 1; n <= 56; ++n) {
        if (n > max_tap)
            break;
        
        float nf = float(n);
        
        // Neighbor analytic samples
        vec2 tex_r = Tex + nf * dx;
        vec2 tex_l = Tex - nf * dx;
        vec2 iq_r = texture(Source, tex_r).rg;
        vec2 iq_l = texture(Source, tex_l).rg;

        // Apply lowpass filter coefficients
        if (n <= max_tap_i) {
            float coeff_r_i = sinc_lowpass_bh4(nf - Ax, fc_i_norm, taps_i);
            float coeff_l_i = sinc_lowpass_bh4(-nf - Ax, fc_i_norm, taps_i);
            i_signal += coeff_r_i * iq_r.r + coeff_l_i * iq_l.r;
            i_wsum += coeff_r_i + coeff_l_i;
        }

        // Q channel (may use fewer/more taps); skip when beyond taps_q
        if (n <= max_tap_q) {
            float coeff_r_q = sinc_lowpass_bh4(nf - Ax, fc_q_norm, taps_q);
            float coeff_l_q = sinc_lowpass_bh4(-nf - Ax, fc_q_norm, taps_q);
            q_signal += coeff_r_q * iq_r.g + coeff_l_q * iq_l.g;
            q_wsum += coeff_r_q + coeff_l_q;
        }
    }
    
    // Normalize filters to maintain unity gain
    i_signal /= max(i_wsum, EPS);
    q_signal /= max(q_wsum, EPS);
    
    // Noise processing moved to separate pass: iq-noise.slang
    
    // Output complex IQ: (I, Q) in RG channels
    FragColor = vec4(i_signal, q_signal, 0.0, 1.0);
}
