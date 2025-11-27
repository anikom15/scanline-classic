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
// - Composite baseband signal is generated from component input
// - VSB asymmetry implemented via Hilbert transform approximation
// - I channel: composite signal filtered by VSB bandpass
// - Q channel: Hilbert transform of I, scaled by K_VSB for asymmetry
// - No RF carrier—operates entirely at baseband for numerical stability

#include "common.inc"
#include "modulation.inc"
#include "window.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass composite modulation (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter BYPASS_IQ_MOD "Bypass IQ modulation (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter IQ_RF_NOISE_DB "RF noise floor (dB)" -30.0 -96.0 96.0 1.0

#pragma name IQMod
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_IQ_MOD;
    float BYPASS_COMPOSITE_MOD;
    float IQ_RF_NOISE_DB;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float ENCODER_SETUP;
    float PAL;
    float K_VSB;
    float IQ_ZERO_PHASE_METHOD2;
} config;

#define BYPASS_IQ_MOD config.BYPASS_IQ_MOD
#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD
#define IQ_RF_NOISE_DB config.IQ_RF_NOISE_DB
#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define ENCODER_SETUP config.ENCODER_SETUP
#define PAL config.PAL
#define K_VSB config.K_VSB
#define IQ_ZERO_PHASE_METHOD2 config.IQ_ZERO_PHASE_METHOD2

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// VSB baseband parameters (NTSC)
const float VSB_VESTIGE_MHZ = 0.75;        // Lower sideband vestige width
const float VSB_FULL_SIDEBAND_MHZ = 4.2;   // Upper sideband full width (NTSC)

// Blackman-Harris 4-term windowed-sinc filter design
// Stopband: ~92 dB (far exceeds requirements for clean VSB)
// OutputSize.x constrained to [720, 1440] for practical GPU performance
const int MIN_TAPS = 20;                   // Minimum taps at 720px
const int MAX_TAPS = 48;                   // Maximum taps at 1440px

// Hilbert transform approximation taps (fixed, optimized for VSB bandwidth)
const int HILBERT_TAPS = 15;               // Odd number for Type III FIR

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_upper_norm;      // Upper cutoff (normalized)
layout(location = 2) out float fc_lower_norm;      // Lower cutoff (normalized)
layout(location = 3) out float fc_bandwidth_norm;  // Passband width (normalized)
layout(location = 4) out float filter_taps;        // Adaptive tap count
layout(location = 6) out TimebaseConfig tb;

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

    // VSB baseband band edges (relative to DC)
    // Lower edge: -vestige = -0.75 MHz
    // Upper edge: +full_sideband = +4.2 MHz
    // Total bandwidth: 4.95 MHz
    
    float vsb_lower_edge_mhz = -VSB_VESTIGE_MHZ;
    float vsb_upper_edge_mhz = VSB_FULL_SIDEBAND_MHZ;
    
    // Compute output texture sample rate
    // Sample rate = pixels per line × line frequency
    float sample_rate_hz = config.OutputSize.x * tb.h_freq_hz;
    float sample_rate_mhz = sample_rate_hz * 1.0e-6;
    
    // Baseband VSB band (no aliasing concerns, DC-centered)
    float vsb_lower_hz = vsb_lower_edge_mhz * 1.0e6;
    float vsb_upper_hz = vsb_upper_edge_mhz * 1.0e6;
    
    // Normalize to sample rate (cycles per sample)
    fc_upper_norm = vsb_upper_hz / sample_rate_hz;
    fc_lower_norm = vsb_lower_hz / sample_rate_hz;
    fc_bandwidth_norm = fc_upper_norm - fc_lower_norm;

    // Validation & clamp inside Nyquist
    fc_upper_norm = clamp(fc_upper_norm, -0.49, 0.49);
    fc_lower_norm = clamp(fc_lower_norm, -0.49, 0.49);
    fc_bandwidth_norm = max(fc_upper_norm - fc_lower_norm, 0.0);

    // Adaptive design based on OutputSize.x ∈ [720, 1440]
    // Blackman-Harris 4-term: stopband ~92 dB, mainlobe width = 8π/N
    float output_width = config.OutputSize.x;
    float width_factor = clamp((output_width - 720.0) / (1440.0 - 720.0), 0.0, 1.0);

    // Adaptive tap count: 20-48 taps scaled by resolution
    float adaptive_taps = mix(float(MIN_TAPS), float(MAX_TAPS), width_factor);
    filter_taps = floor(adaptive_taps * 0.5) * 2.0; // even for symmetry
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_upper_norm;
layout(location = 2) in float fc_lower_norm;
layout(location = 3) in float fc_bandwidth_norm;
layout(location = 4) in float filter_taps;
layout(location = 6) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Helper: compute composite baseband signal from RGB pixel
float compute_composite_baseband(vec3 pixel, float t, vec2 pal_phase)
{
    float phase = compute_carrier_phase(t, tb.sc_freq_hz, tb.field_phase);
    vec2 phase2 = vec2(phase) + pal_phase;
    phase2 = vec2(normalize_phase(phase2.x), normalize_phase(phase2.y));
    vec2 carrier = sincos_phase_raw(phase2);
    float chroma = pixel.g * carrier.x + pixel.b * carrier.y;
    
    float y_gain = 1.0;
    float y_offset = 0.0;
    if (ENCODER_SETUP > 0.5) {
        y_gain = 0.925;
        y_offset = 0.075;
    }
    
    return y_gain * (pixel.r + y_offset) + chroma;
}

void main()
{
    if (BYPASS_COMPOSITE_MOD > 0.5) {
        // Pass through RGB as (R, 0) for debugging
        vec3 rgb = texture(Source, vTexCoord).rgb;
        FragColor = vec4(rgb.r, 0.0, 0.0, 1.0);
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

    float offset0 = baseCenter;
    vec2 pal_phase_base = vec2(0.0, floor(mod(line, 2.0)) * PI * PAL);

    float t0 = line / tb.h_freq_hz + offset0 * tb.pixel_time_px;
    
    vec2 dx = vec2(config.OutputSize.z, 0.0);
    int max_tap = int(filter_taps);
    
    // Central pixel (n = 0, adjusted by Ax offset)
    vec3 pixel0 = texture(Source, Tex).rgb;
    float composite0 = compute_composite_baseband(pixel0, t0, pal_phase_base);

    if (BYPASS_IQ_MOD > 0.5) {
        // Output composite baseband in I channel for debugging
        FragColor = vec4(composite0, 0.0, 0.0, 1.0);
        return;
    }

    // I channel: VSB-shaped composite via asymmetric bandpass
    // Blackman-Harris 4-term window for ~92 dB stopband rejection
    float i_signal = 0.0;
    float i_wsum = 0.0;  // Track coefficient sum for normalization
    float coeff0_bp = sinc_bandpass_bh4(-Ax, fc_upper_norm, fc_lower_norm, filter_taps);
    i_signal = coeff0_bp * composite0;
    i_wsum = coeff0_bp;
    
    // Q channel: Hilbert transform approximation for VSB asymmetry
    // Type III FIR: h[n] = (2/π) · sin²(πn/2) / n for odd n, h[0] = 0
    float q_signal = 0.0;
    float q_wsum = 0.0;
    
    // Convolve with neighboring pixels
    // Loop limit set to MAX_TAPS (48) for potential unrolling
    for (int n = 1; n <= 48; ++n) {
        if (n > max_tap)
            break;
        
        float nf = float(n);
        
        // Right sample
        vec2 tex_r = Tex + nf * dx;
        vec3 pixel_r = texture(Source, tex_r).rgb;
        float t_r = t0 + nf * tb.pixel_time_px;
        float composite_r = compute_composite_baseband(pixel_r, t_r, pal_phase_base);
        
        float coeff_r_bp = sinc_bandpass_bh4(nf - Ax, fc_upper_norm, fc_lower_norm, filter_taps);
        
        // Hilbert coefficient (Type III FIR) - EVALUATE AT SAME OFFSET POSITION
        float hilbert_r = 0.0;
        float pos_r = nf - Ax;  // Same fractional position as bandpass
        int ni = int(nf);
        if (ni % 2 == 1) { // Odd samples only for integer part
            // Continuous extension: h(x) = (2/π) · sin²(πx/2) / x
            float sin_val = sin(PI * pos_r * 0.5);
            hilbert_r = (2.0 / PI) * (sin_val * sin_val) / pos_r;
        }
        
        // Left sample
        vec2 tex_l = Tex - nf * dx;
        vec3 pixel_l = texture(Source, tex_l).rgb;
        float t_l = t0 - nf * tb.pixel_time_px;
        float composite_l = compute_composite_baseband(pixel_l, t_l, pal_phase_base);
        
        float coeff_l_bp = sinc_bandpass_bh4(-nf - Ax, fc_upper_norm, fc_lower_norm, filter_taps);
        
        // Hilbert at left position - evaluate at fractional offset
        float pos_l = -nf - Ax;
        float hilbert_l = 0.0;
        if (ni % 2 == 1) {
            float sin_val = sin(PI * pos_l * 0.5);
            hilbert_l = (2.0 / PI) * (sin_val * sin_val) / pos_l;
        }
        
        i_signal += coeff_r_bp * composite_r + coeff_l_bp * composite_l;
        i_wsum += coeff_r_bp + coeff_l_bp;
        // Shape Q with same bandpass to match I bandwidth and group delay
        q_signal += hilbert_r * coeff_r_bp * composite_r + hilbert_l * coeff_l_bp * composite_l;
        // Accumulate magnitude-based weights for normalization (odd-only taps contribute)
        q_wsum += abs(hilbert_r) * abs(coeff_r_bp) + abs(hilbert_l) * abs(coeff_l_bp);
    }
    
    // Normalize bandpass filter to maintain unity gain through mod→demod chain
    i_signal /= max(i_wsum, EPS);
    // Normalize Q to the same shaped bandwidth
    q_signal = q_signal / max(q_wsum, EPS);
    
    // Scale Q by K_VSB to model vestigial sideband asymmetry
    // K_VSB ≈ 0.27 for NTSC VSB (vestige is ~27% of full sideband)
    q_signal *= K_VSB;
    
    // Add RF noise dithering if enabled (simulates thermal/shot noise in RF path)
    // Convert dB to linear amplitude: noise_amp = 10^(-dB/20)
    float noise_amplitude = exp(IQ_RF_NOISE_DB * 0.1151292546); // ln(10)/20 ≈ 0.1151
    
    // Simple hash-based PRNG for per-pixel noise
    vec2 seed = vTexCoord * config.OutputSize.xy + vec2(config.FrameCount * 0.12345, line * 0.67890);
    float hash_i = fract(sin(dot(seed, vec2(12.9898, 78.233))) * 43758.5453);
    float hash_q = fract(sin(dot(seed + vec2(0.314, 0.271), vec2(12.9898, 78.233))) * 43758.5453);
    
    // Box-Muller transform for Gaussian noise (approximate)
    float noise_i = (hash_i - 0.5) * noise_amplitude;
    float noise_q = (hash_q - 0.5) * noise_amplitude;
    
    i_signal += noise_i;
    q_signal += noise_q;
    
    // Output complex IQ: (I, Q) in RG channels
    FragColor = vec4(i_signal, q_signal, 0.0, 1.0);
}
