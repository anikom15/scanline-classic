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
// Output: IF-modulated composite signal

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

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// IF modulation and filtering constants
const float IF_CARRIER_MHZ = 44.0;
const float BANDPASS_CENTER_MHZ = 45.475;
const float STOPBAND_ATTEN_DB = 25.0; // Mid-range of 20-30 dB spec
const float OUTPUT_BANDWIDTH_MHZ = 5.45;

// Shared windowed-sinc helpers are now in window.inc

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float fc_upper_norm; // Upper cutoff (normalized to sample rate)
layout(location = 2) out float fc_lower_norm; // Lower cutoff (normalized to sample rate)
layout(location = 3) out float filter_taps;
layout(location = 4) out float kaiser_beta;
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

    // Compute normalized cutoff frequencies
    // Upper cutoff: BANDPASS_CENTER + OUTPUT_BANDWIDTH/2 = 45.475 + 2.725 = 48.2 MHz
    // Lower cutoff: BANDPASS_CENTER - OUTPUT_BANDWIDTH/2 = 45.475 - 2.725 = 42.75 MHz
    
    float upper_cutoff_mhz = BANDPASS_CENTER_MHZ + OUTPUT_BANDWIDTH_MHZ * 0.5;
    float lower_cutoff_mhz = BANDPASS_CENTER_MHZ - OUTPUT_BANDWIDTH_MHZ * 0.5;
    
    // Normalize to sample rate (cycles per pixel)
    float sample_rate_hz = 1.0 / tb.pixel_time_px;
    fc_upper_norm = (upper_cutoff_mhz * 1.0e6) / sample_rate_hz;
    fc_lower_norm = (lower_cutoff_mhz * 1.0e6) / sample_rate_hz;
    
    // Kaiser beta parameter for desired stopband attenuation
    // A ≈ -20 log10(δ) where δ is the ripple
    // For A = 25 dB: beta ≈ 0.1102 * (A - 8.7) = 0.1102 * 16.3 ≈ 1.8
    // Using slightly higher beta = 2.5 for better stopband rejection
    kaiser_beta = 2.5;
    
    // Estimate required filter length
    // N ≈ (A - 8) / (2.285 * Δf) where Δf is transition bandwidth
    // Using conservative transition bandwidth of 0.5 MHz
    float transition_bw_mhz = 0.5;
    float transition_bw_norm = (transition_bw_mhz * 1.0e6) / sample_rate_hz;
    filter_taps = ceil((STOPBAND_ATTEN_DB - 8.0) / (2.285 * transition_bw_norm));
    
    // Clamp to reasonable range
    filter_taps = clamp(filter_taps, 10.0, 30.0);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float fc_upper_norm;
layout(location = 2) in float fc_lower_norm;
layout(location = 3) in float filter_taps;
layout(location = 4) in float kaiser_beta;
layout(location = 5) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Helper: compute composite baseband signal from RGB pixel
float compute_composite_baseband(vec3 pixel, float t, vec2 pal_phase)
{
    float phase = compute_carrier_phase(t, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier = sincos_phase(phase + pal_phase);
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
    
    // Apply windowed sinc bandpass filter to IF-modulated signal
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
    vec2 sc_carrier0 = sincos_phase(sc_phase0 + pal_phase_base);
    float chroma0 = pixel0.g * sc_carrier0.x + pixel0.b * sc_carrier0.y;
    float y_gain = 1.0;
    float y_offset = 0.0;
    if (ENCODER_SETUP > 0.5) {
        y_gain = 0.925;
        y_offset = 0.075;
    }
    float composite0_direct = y_gain * (pixel0.r + y_offset) + chroma0;

    float if_signal0 = composite0_direct * cos(if_phase0);
    
    float coeff0 = sinc_bandpass_coeff(-Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
    bp_signal = coeff0 * if_signal0;
    
    // Convolve with neighboring pixels
    for (int n = 1; n <= 30; ++n) {
        float nf = float(n);
        
        // Right sample at position n - Ax
        vec2 tex_r = Tex + nf * dx;
        vec3 pixel_r = texture(Source, tex_r).rgb;

        // Use phase increments for both subcarrier and IF carrier for better precision
        float sc_phase_r = sc_phase0 + nf * sc_phase_inc_per_px;
        sc_phase_r = mod(sc_phase_r + PI, 2.0 * PI) - PI;
        vec2 sc_carrier_r = sincos_phase(sc_phase_r + pal_phase_base);
        float chroma_r = pixel_r.g * sc_carrier_r.x + pixel_r.b * sc_carrier_r.y;
        float composite_r = y_gain * (pixel_r.r + y_offset) + chroma_r;

        float if_phase_r = if_phase0 + nf * if_phase_inc_per_px;
        if_phase_r = mod(if_phase_r + PI, 2.0 * PI) - PI;
        float if_signal_r = composite_r * cos(if_phase_r);
        
        float coeff_r = sinc_bandpass_coeff(nf - Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
        
        // Left sample at position -n - Ax
        vec2 tex_l = Tex - nf * dx;
        vec3 pixel_l = texture(Source, tex_l).rgb;

        // Use phase increments for both subcarrier and IF carrier for better precision
        float sc_phase_l = sc_phase0 - nf * sc_phase_inc_per_px;
        sc_phase_l = mod(sc_phase_l + PI, 2.0 * PI) - PI;
        vec2 sc_carrier_l = sincos_phase(sc_phase_l + pal_phase_base);
        float chroma_l = pixel_l.g * sc_carrier_l.x + pixel_l.b * sc_carrier_l.y;
        float composite_l = y_gain * (pixel_l.r + y_offset) + chroma_l;

        float if_phase_l = if_phase0 - nf * if_phase_inc_per_px;
        if_phase_l = mod(if_phase_l + PI, 2.0 * PI) - PI;
        float if_signal_l = composite_l * cos(if_phase_l);
        
        float coeff_l = sinc_bandpass_coeff(-nf - Ax, fc_upper_norm, fc_lower_norm, kaiser_beta, filter_taps);
        
        bp_signal += coeff_r * if_signal_r + coeff_l * if_signal_l;
        if (n >= max_tap)
            break;
    }
    
    // Do not normalize by sum of bandpass coefficients (≈0 for BP FIR).
    // Output directly to preserve stable gain.
    
    FragColor = vec4(bp_signal, 0.0, 0.0, 1.0);
}
