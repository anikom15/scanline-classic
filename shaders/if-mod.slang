#version 450

// Filename: if-mod.slang
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
// Composite modulation, IF modulation, and bandpass filtering shader
// -----------------------------------------------------------------
// Input: Component voltage signal
// Output: IF-modulated composite signal (single modulation path)
// Notes:
// - Composite encoder and color subcarrier generation remain unchanged; chroma is preserved.
// - Demodulation behavior/modes are implemented in `if-demod.slang` (not here).
// - Undersampled IF is bandpass-filtered with adaptive Kaiser FIR (20→24 dB).

#include "common.inc"
#include "modulation.inc"
#include "window.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass Composite modulation (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter BYPASS_IF_MOD "Bypass IF modulation (off, on)" 0.0 0.0 1.0 1.0

#pragma name CompositeMod
#pragma format R16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_COMPOSITE_MOD;
    float BYPASS_IF_MOD;
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
} config;

#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD
#define BYPASS_IF_MOD config.BYPASS_IF_MOD

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

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// IF modulation and filtering constants for VSB
const float IF_CARRIER_MHZ = 8.0;   // Practical IF carrier (NTSC VSB)
const float VSB_VESTIGE_MHZ = 0.75;  // Lower sideband vestige width
const float VSB_FULL_SIDEBAND_MHZ = 4.2; // Upper sideband full width (NTSC)

// FIR Kaiser windowed-sinc bandpass filter design
// Target: 20 dB stopband rejection with minimum taps
// OutputSize.x constrained to [720, 1920] for clean bandpass sampling at 8 MHz IF
const float TARGET_STOPBAND_DB = 20.0; // Practical target for VSB
const float MIN_TRANSITION_BW_MHZ = 1.0; // Tighter transition at high res
const float MAX_TRANSITION_BW_MHZ = 2.0; // Wider transition at low res
const int MIN_TAPS = 16; // Minimum for quality bandpass at 720px
const int MAX_TAPS = 40; // Allow more taps at higher resolutions

// Shared windowed-sinc helpers are in window.inc

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

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_upper_norm;      // Upper cutoff (normalized)
layout(location = 2) out float fc_lower_norm;      // Lower cutoff (normalized)
layout(location = 3) out float fc_bandwidth_norm;  // Passband width (normalized)
layout(location = 4) out float filter_taps;        // Adaptive tap count
layout(location = 5) out float kaiser_beta;        // Kaiser beta (adaptive)
layout(location = 6) out float aliasing_warning;   // 1.0 if sample rate too low
layout(location = 7) out TimebaseConfig tb;

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

    // Compute VSB asymmetric band edges for 8 MHz IF
    // VSB lower edge: carrier - vestige = 8.0 - 0.75 = 7.25 MHz
    // VSB upper edge: carrier + full_sideband = 8.0 + 4.2 = 12.2 MHz
    // Total bandwidth: 4.95 MHz (NTSC)
    // K_VSB controls asymmetry: -1 = LSB only, 0 = DSB, +1 = USB only
    // For NTSC VSB, K_VSB ≈ 0.27 (vestige is ~27% of full sideband)
    
    float vsb_lower_edge_mhz = IF_CARRIER_MHZ - VSB_VESTIGE_MHZ;
    float vsb_upper_edge_mhz = IF_CARRIER_MHZ + VSB_FULL_SIDEBAND_MHZ;
    
    // Compute output texture sample rate
    // The IF signal is stored in the output texture at OutputSize.x resolution
    // Sample rate = pixels per line × line frequency
    float sample_rate_hz = config.OutputSize.x * tb.h_freq_hz;
    float sample_rate_mhz = sample_rate_hz * 1.0e-6;
    
    // Validate minimum sample rate for clean bandpass sampling at 8 MHz IF
    // Minimum safe rate: 11.0 MHz (NTSC 720px ≈ 11.3 MHz, fits in zone 0)
    // Below this, VSB band [7.25, 12.2] MHz cannot fit in first Nyquist zone
    const float MIN_SAFE_SAMPLE_RATE_MHZ = 11.0;
    
    // For bandpass sampling with 8 MHz IF carrier:
    // The VSB band [7.25, 12.2] MHz requires sample rate > 24.4 MHz for zone 0 (no aliasing)
    // Or operates in zone 1 at lower sample rates (with aliasing to baseband)
    // Compute aliased frequencies using zone-aware algorithm
    float vsb_lower_hz = vsb_lower_edge_mhz * 1.0e6;
    float vsb_upper_hz = vsb_upper_edge_mhz * 1.0e6;
    
    // Zone-aware aliased band computation
    // VSB band [7.25, 12.2] MHz spans 4.95 MHz
    int zone_lower, zone_upper;
    float aliased_lower_hz = alias_freq(vsb_lower_hz, sample_rate_hz, zone_lower);
    float aliased_upper_hz = alias_freq(vsb_upper_hz, sample_rate_hz, zone_upper);
    
    // If band crosses zone boundary or inverts, swap edges to maintain positive bandwidth
    if (zone_lower != zone_upper || aliased_upper_hz < aliased_lower_hz) {
        float temp = aliased_lower_hz;
        aliased_lower_hz = aliased_upper_hz;
        aliased_upper_hz = temp;
    }
    
    // Validate minimum bandwidth (band shouldn't collapse)
    float aliased_bw_hz = aliased_upper_hz - aliased_lower_hz;
    if (aliased_bw_hz < 1.0e6) {
        // Band collapsed or invalid aliasing - trigger warning and bypass
        aliasing_warning = 1.0;
    }
    
    // Normalize to sample rate (cycles per sample)
    fc_upper_norm = aliased_upper_hz / sample_rate_hz;
    fc_lower_norm = aliased_lower_hz / sample_rate_hz;
    fc_bandwidth_norm = max(fc_upper_norm - fc_lower_norm, 0.0);

    // Validation & clamp inside Nyquist
    if (fc_upper_norm > 0.5 || fc_lower_norm > 0.5) {
        fc_upper_norm = min(fc_upper_norm, 0.49);
        fc_lower_norm = min(fc_lower_norm, 0.49);
        fc_bandwidth_norm = max(fc_upper_norm - fc_lower_norm, 0.0);
    }

    // Adaptive design based on OutputSize.x ∈ [720,1920]
    float output_width = config.OutputSize.x;
    float width_factor = clamp((output_width - 720.0) / (1920.0 - 720.0), 0.0, 1.0);

    // Transition bandwidth: 2.0 MHz → 1.0 MHz (wider early to reduce taps & ripples)
    float transition_bw_mhz = mix(MAX_TRANSITION_BW_MHZ, MIN_TRANSITION_BW_MHZ, width_factor);
    float transition_bw_norm = (transition_bw_mhz * 1.0e6) / sample_rate_hz;
    transition_bw_norm = max(transition_bw_norm, 1.2 / sample_rate_hz); // avoid pathological narrow transitions

    // Target stopband: 20 dB → 24 dB as resolution increases
    float target_stop_db = mix(20.0, 24.0, width_factor);
    kaiser_beta = 0.1102 * (target_stop_db - 8.7); // empirical Kaiser relation

    // Required taps (Kaiser): N ≈ (A - 8) / (2.285 * Δf)
    float required_taps = (target_stop_db - 8.0) / (2.285 * max(transition_bw_norm, 0.01));

    // Adaptive tap ceiling: 720px ≈ 18 taps, 1920px ≈ 40 taps
    float adaptive_max_taps = mix(18.0, float(MAX_TAPS), width_factor);
    filter_taps = clamp(required_taps, float(MIN_TAPS), adaptive_max_taps);
    filter_taps = floor(filter_taps * 0.5) * 2.0; // even for symmetry

    // Aliasing warning: unsafe sample rate OR band collapse
    if (sample_rate_mhz < MIN_SAFE_SAMPLE_RATE_MHZ || aliased_bw_hz < 1.0e6) {
        aliasing_warning = 1.0;
    } else {
        aliasing_warning = 0.0;
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_upper_norm;
layout(location = 2) in float fc_lower_norm;
layout(location = 3) in float fc_bandwidth_norm;
layout(location = 4) in float filter_taps;
layout(location = 5) in float kaiser_beta;
layout(location = 6) in float aliasing_warning;
layout(location = 7) in TimebaseConfig tb;
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

    float offset0 = baseCenter;
    vec2 pal_phase_base = vec2(0.0, floor(mod(line, 2.0)) * PI * PAL);

    float t0 = line / tb.h_freq_hz + offset0 * tb.pixel_time_px;
    
    float bp_signal = 0.0;
    vec2 dx = vec2(config.OutputSize.z, 0.0);
    int max_tap = int(filter_taps);
    
    // Central pixel (n = 0, adjusted by Ax offset)
    vec3 pixel0 = texture(Source, Tex).rgb;
    float composite0 = compute_composite_baseband(pixel0, t0, pal_phase_base);

    if (BYPASS_IF_MOD > 0.5) {
        FragColor = vec4(composite0, 0.0, 0.0, 1.0);
        return;
    }

    float if_carrier_hz = IF_CARRIER_MHZ * 1.0e6;

    // Derive IF field phase from subcarrier field phase scaled by frequency ratio
    // Normalize to [0,1) before scaling to prevent precision loss from large phase values
    float if_field_phase = 0.0;
    {
        float denom = max(tb.sc_freq_hz, EPS);
        float freq_ratio = if_carrier_hz / denom;
        float normalized_field_phase = fract(tb.field_phase / (2.0 * PI));
        if_field_phase = normalized_field_phase * freq_ratio * 2.0 * PI;
        if_field_phase = mod(if_field_phase, 2.0 * PI);
    }

    // Precompute phase increments per pixel for precision in filter loop
    float if_phase_inc_per_px = 2.0 * PI * if_carrier_hz * tb.pixel_time_px;
    float sc_phase_inc_per_px = 2.0 * PI * tb.sc_freq_hz * tb.pixel_time_px;

    // Compute base phases for center pixel
    float if_phase0 = compute_carrier_phase(t0, if_carrier_hz, if_field_phase);
    float sc_phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);

    // Compute center composite using direct phase calculation
    vec2 sc_phase2_0 = vec2(sc_phase0) + pal_phase_base;
    sc_phase2_0 = vec2(normalize_phase(sc_phase2_0.x), normalize_phase(sc_phase2_0.y));
    vec2 sc_carrier0 = sincos_phase_raw(sc_phase2_0);
    float chroma0 = pixel0.g * sc_carrier0.x + pixel0.b * sc_carrier0.y;
    float y_gain = 1.0;
    float y_offset = 0.0;
    if (ENCODER_SETUP > 0.5) {
        y_gain = 0.925;
        y_offset = 0.075;
    }
    float composite0_direct = y_gain * (pixel0.r + y_offset) + chroma0;

    float if_signal0 = composite0_direct * cos(if_phase0);
    
    // Apply Kaiser windowed-sinc bandpass FIR filter
    // Center tap (n = 0)
    float coeff0 = sinc_bandpass_coeff(-Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
    bp_signal = coeff0 * if_signal0;
    float sum_abs_coeff = abs(coeff0);
    
    // Convolve with neighboring pixels (optimized loop)
    // Loop limit set to MAX_TAPS (40) to allow unrolling
    for (int n = 1; n <= 40; ++n) {
        if (n > max_tap) break;
        
        float nf = float(n);
        
        // Right sample at position n - Ax
        vec2 tex_r = Tex + nf * dx;
        vec3 pixel_r = texture(Source, tex_r).rgb;
        float sc_phase_r = sc_phase0 + nf * sc_phase_inc_per_px;
        sc_phase_r = mod(sc_phase_r + PI, 2.0 * PI) - PI;
        vec2 sc_phase2_r = vec2(sc_phase_r) + pal_phase_base;
        sc_phase2_r = vec2(normalize_phase(sc_phase2_r.x), normalize_phase(sc_phase2_r.y));
        vec2 sc_carrier_r = sincos_phase_raw(sc_phase2_r);
        float chroma_r = pixel_r.g * sc_carrier_r.x + pixel_r.b * sc_carrier_r.y;
        float composite_r = y_gain * (pixel_r.r + y_offset) + chroma_r;
        float if_phase_r = if_phase0 + nf * if_phase_inc_per_px;
        if_phase_r = mod(if_phase_r + PI, 2.0 * PI) - PI;
        float if_signal_r = composite_r * cos(if_phase_r);
        
        float coeff_r = sinc_bandpass_coeff(nf - Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
        
        // Left sample at position -n - Ax
        vec2 tex_l = Tex - nf * dx;
        vec3 pixel_l = texture(Source, tex_l).rgb;
        float sc_phase_l = sc_phase0 - nf * sc_phase_inc_per_px;
        sc_phase_l = mod(sc_phase_l + PI, 2.0 * PI) - PI;
        vec2 sc_phase2_l = vec2(sc_phase_l) + pal_phase_base;
        sc_phase2_l = vec2(normalize_phase(sc_phase2_l.x), normalize_phase(sc_phase2_l.y));
        vec2 sc_carrier_l = sincos_phase_raw(sc_phase2_l);
        float chroma_l = pixel_l.g * sc_carrier_l.x + pixel_l.b * sc_carrier_l.y;
        float composite_l = y_gain * (pixel_l.r + y_offset) + chroma_l;
        float if_phase_l = if_phase0 - nf * if_phase_inc_per_px;
        if_phase_l = mod(if_phase_l + PI, 2.0 * PI) - PI;
        float if_signal_l = composite_l * cos(if_phase_l);
        
        float coeff_l = sinc_bandpass_coeff(-nf - Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
        
        bp_signal += coeff_r * if_signal_r + coeff_l * if_signal_l;
        sum_abs_coeff += abs(coeff_r) + abs(coeff_l);
    }
    
    // Bandpass FIR maintains unity passband gain by design
    // Apply 2× gain to compensate for cos(ωt) mixer reducing amplitude by 0.5
    const float MIXER_GAIN_COMPENSATION = 2.0;
    bp_signal *= MIXER_GAIN_COMPENSATION;
    
    // Small-sum fallback check (if filter collapsed due to numerical issues)
    if (sum_abs_coeff < 0.01) {
        // Return unfiltered composite with same gain compensation
        bp_signal = composite0_direct * MIXER_GAIN_COMPENSATION;
    }
    
    // Apply magenta warning tint if sample rate is insufficient (unchanged behavior)
    // Magenta = (1, 0, 1) multiplied with signal
    vec3 warning_tint = mix(vec3(1.0), vec3(1.0, 0.0, 1.0), aliasing_warning);
    
    FragColor = vec4(bp_signal * warning_tint.r, 0.0, 0.0, 1.0);
}
