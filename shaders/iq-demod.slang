#version 450

// Filename: iq-demod.slang
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
// IQ baseband demodulation shader for VSB
// -----------------------------------------------------------------
// Input: Complex IQ baseband (R16G16_SFLOAT, RG channels)
// Output: Recovered composite baseband (R16_SFLOAT)
//
// This shader recovers the composite signal from complex IQ:
// - Applies matched lowpass filtering to I and Q channels
// - Combines using envelope detection: sqrt(I² + Q²) or linear mix
// - Kaiser windowed-sinc lowpass for matched filtering
// - Maintains unity gain through the IQ mod→demod chain

#include "common.inc"
#include "modulation.inc"
#include "window.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_IQ_DEMOD "Bypass IQ demod (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter IQ_DEMOD_METHOD "IQ Demod (0=I only, 1=Envelope, 2=Linear)" 2.0 0.0 2.0 1.0

#pragma name IQDemod
#pragma format R16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_IQ_DEMOD;
    float IQ_DEMOD_METHOD;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float K_VSB;
    // No extra positional parameters needed
} config;

#define BYPASS_IQ_DEMOD config.BYPASS_IQ_DEMOD
#define IQ_DEMOD_METHOD config.IQ_DEMOD_METHOD
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

// VSB baseband parameters (must match iq-mod.slang)
const float VSB_VESTIGE_MHZ = 0.75;        // Lower sideband vestige width
const float VSB_FULL_SIDEBAND_MHZ = 4.2;   // Upper sideband full width (NTSC)

// Blackman-Harris 4-term windowed-sinc lowpass for matched filtering
// Stopband: ~92 dB (matches modulator)
const int MIN_TAPS = 20;                   // Match iq-mod.slang
const int MAX_TAPS = 48;                   // Match iq-mod.slang

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_lp_norm;     // normalized lowpass cutoff
layout(location = 2) out float filter_taps;    // adaptive tap count
layout(location = 4) out TimebaseConfig tb;

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
    float sample_rate_hz = config.OutputSize.x * tb.h_freq_hz;
    float sample_rate_mhz = sample_rate_hz * 1.0e-6;
    
    // Compute VSB bandwidth for lowpass cutoff
    float vsb_bandwidth_mhz = VSB_VESTIGE_MHZ + VSB_FULL_SIDEBAND_MHZ;
    float lpf_cutoff_hz = vsb_bandwidth_mhz * 1.0e6 * 0.5; // Half-bandwidth for lowpass
    fc_lp_norm = clamp(lpf_cutoff_hz / sample_rate_hz, 1e-5, 0.49);
    
    // Adaptive design based on OutputSize.x (match iq-mod.slang)
    // Blackman-Harris 4-term: stopband ~92 dB, mainlobe width = 8π/N
    float output_width = config.OutputSize.x;
    float width_factor = clamp((output_width - 720.0) / (1440.0 - 720.0), 0.0, 1.0);
    
    // Adaptive tap count: 20-48 taps scaled by resolution (mirror modulator)
    float adaptive_taps = mix(float(MIN_TAPS), float(MAX_TAPS), width_factor);
    filter_taps = floor(adaptive_taps * 0.5) * 2.0; // even for symmetry
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_lp_norm;
layout(location = 2) in float filter_taps;
layout(location = 4) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_IQ_DEMOD > 0.5) {
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

    // IQ input (RG channels)
    vec2 iq0 = texture(Source, Tex).rg;

    // Convolve I & Q with lowpass windowed-sinc (matched filter)
    vec2 iq_acc = vec2(0.0);  // Combined I/Q accumulator
    float wsum = 0.0;          // Single weight sum (filters are identical)
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    // Central coefficient
    float c0 = sinc_lowpass_bh4(-Ax, fc_lp_norm, filter_taps);
    iq_acc += c0 * iq0;
    wsum += c0;

    int max_tap = int(filter_taps);
    for (int n = 1; n <= 48; ++n) {
        if (n > max_tap) break;
        
        float nf = float(n);

        // Right sample
        vec2 iq_r = texture(Source, Tex + nf * dx).rg;
        float cr = sinc_lowpass_bh4(nf - Ax, fc_lp_norm, filter_taps);

        // Left sample
        vec2 iq_l = texture(Source, Tex - nf * dx).rg;
        float cl = sinc_lowpass_bh4(-nf - Ax, fc_lp_norm, filter_taps);

        iq_acc += cr * iq_r + cl * iq_l;
        wsum += cr + cl;
    }

    // Normalize both I and Q with the same weight sum
    vec2 IQ = iq_acc / max(wsum, EPS);
    float I = IQ.r;
    float Q = IQ.g;

    // Demodulation method selection (unchanged)
    float composite;
    if (IQ_DEMOD_METHOD < 0.5) {
        composite = I;
    } else if (IQ_DEMOD_METHOD < 1.5) {
        composite = length(IQ);
    } else {
        composite = I + Q;
    }

    FragColor = vec4(composite, 0.0, 0.0, 1.0);
}
