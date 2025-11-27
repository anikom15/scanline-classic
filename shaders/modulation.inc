/* Filename: modulation.inc

   Copyright (C) 2025 W. M. Martinez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

// Shared modulation and demodulation functions for composite and S-Video processing

const float NTSC_FSC = 3.579545e6;
const float PAL_FSC = 4.4336187e6;

// Timebase and subcarrier configuration
struct TimebaseConfig {
    float field;
    float field_phase;
    float h_freq_hz;
    float sc_freq_hz;
    float pixel_time;
    float pixel_time_px;
};

// Phase normalization helper. Keeps phase bounded in [-PI, PI].
// Prefer calling this at the call site right before trig for best optimizer behavior.
float normalize_phase(float phase) {
    return mod(phase + PI, 2.0 * PI) - PI;
}

// Optimized sincos helper - computes both sin and cos in one call
// Returns vec2(sin(phase), cos(phase))
// NOTE: During migration, call sites should pre-normalize using normalize_phase()
// and use sincos_phase_raw(). This function is kept for backward compatibility
// and will be simplified to the raw form after all call sites are updated.
vec2 sincos_phase(float phase) {
    return vec2(sin(phase), cos(phase));
}

// Raw variant without internal normalization. Caller must ensure phase is bounded.
vec2 sincos_phase_raw(float phase) {
    return vec2(sin(phase), cos(phase));
}

// Vec2 overloads. The convention in this codebase uses phase.x for sin and phase.y for cos.
vec2 sincos_phase(vec2 phase) {
    return vec2(sin(phase.x), cos(phase.y));
}

vec2 sincos_phase_raw(vec2 phase) {
    return vec2(sin(phase.x), cos(phase.y));
}

// Compute carrier phase with precision-preserving normalization
// Uses fract() to keep phase bounded and prevent floating-point drift
// over long runtimes or high line numbers
float compute_carrier_phase(float t, float sc_freq_hz, float field_phase) {
    // Use fract to keep phase bounded and preserve precision
    // Normalize by extracting only fractional cycles to keep values small
    float cycles = sc_freq_hz * t;
    float fractional_cycles = fract(cycles);
    float phase = 2.0 * PI * fractional_cycles + field_phase;
    // Ensure phase is in [-PI, PI] so downstream callers may safely use raw trig
    return normalize_phase(phase);
}

// Compute complete timebase configuration for composite/S-Video processing
// Assumptions:
//   - Vertical line index derived from v_lines_per_field (includes blanking as needed).
//   - tex_coord.y ∈ [0,1] spans the field; floor(tex_coord.y * v_lines_per_field) gives line number.
// If you need active-only line indexing, reintroduce an original_height parameter or scale.
TimebaseConfig compute_timebase(
    uint frame_count,
    vec2 tex_coord,
    vec2 original_size,
    float output_width,
    float v_freq_mode,
    float auto_v_freq,
    float custom_v_freq,
    float v_lines_per_field,
    float shorten_odd_field_time,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float h_blank_inactive_len,
    float h_blank_inactive_unit)
{
    TimebaseConfig config;

    // Field number cycling (retain existing modulus behavior)
    config.field = float(frame_count % 12u);

    float line = floor(tex_coord.y * original_size.y);

    // Vertical frequency selection
    float v_freq;
    if (v_freq_mode < 0.5)
        v_freq = auto_v_freq;
    else if (v_freq_mode < 1.5)
        v_freq = 59.94; // NTSC standard
    else if (v_freq_mode < 2.5)
        v_freq = 50.0; // PAL standard
    else
        v_freq = custom_v_freq;

    // Horizontal timing
    config.h_freq_hz = v_freq * v_lines_per_field;
    float line_time = 1.0 / config.h_freq_hz;

    // Inactive (blank) pixel span computation (horizontal)
    float inactive_pixels;
    if (h_blank_inactive_unit < 0.5)
        inactive_pixels = h_blank_inactive_len;
    else if (h_blank_inactive_unit < 1.5)
        inactive_pixels = h_blank_inactive_len * 1.0e-6 * config.h_freq_hz * original_size.x;
    else
        inactive_pixels = h_blank_inactive_len / 100.0 * original_size.x;

    float total_pixels = original_size.x + inactive_pixels;
    config.pixel_time = line_time / total_pixels;

    // Subcarrier frequency derivation (preserves previous rounding scheme)
    float fsc = v_lines_per_field < 288.0 ? NTSC_FSC : PAL_FSC;

    float subcarrier_div = round(config.h_freq_hz * total_pixels / fsc * 100.0) / 100.0;
    if (sc_freq_mode < 0.5)
        config.sc_freq_hz = config.h_freq_hz * total_pixels / subcarrier_div;
    else if (sc_freq_mode < 1.5)
        config.sc_freq_hz = NTSC_FSC;
    else if (sc_freq_mode < 2.5)
        config.sc_freq_hz = PAL_FSC;
    else
        config.sc_freq_hz = sc_freq_custom_mhz * 1.0e6;

    // Field phase (odd-field timing tweak retained)
    float field_time = 1.0 / v_freq;
    config.field_phase = field_time * config.field * 2.0 * PI * config.sc_freq_hz;

    float odd_time_adjust = original_size.x / 256.0 * config.pixel_time;
    config.field_phase -= ceil(config.field / 2.0) * odd_time_adjust
        * shorten_odd_field_time * 2.0 * PI * config.sc_freq_hz;
    config.field_phase = mod(config.field_phase, 2.0 * PI) - PI;

    // Per-output-pixel time (cycles-per-pixel scaling)
    config.pixel_time_px = config.pixel_time * (original_size.x / output_width);

    return config;
}

// Compute Gaussian low-pass sigma (in texels) from timebase and cutoff spec.
// Inputs:
//   tb                 - TimebaseConfig with pixel_time_px set
//   cutoff_freq_mhz    - Desired cutoff frequency in MHz (analog domain)
//   cutoff_atten_db    - Target attenuation at cutoff in dB (e.g., 3 dB)
// Derivation:
//   Time-domain Gaussian kernel: w(x) = exp(-x²/(2σ²))
//   Frequency response magnitude:  |H(f)| = exp(-2π²σ²f²)
//   Design constraint: |H(f_c)| = a = 10^(-A/20), where A = cutoff_atten_db
//   Solving for σ:
//     a = exp(-2π²σ²f_c²)
//     ln a = -2π²σ²f_c²
//     σ² = -ln a / (2π²f_c²)
//     σ = sqrt(-ln a) / (√2 π f_c) = sqrt(-2 ln a) / (2π f_c)
//   Equivalent forms:
//     Original:   σ = sqrt(-2 ln(10^(-A/20))) / (2π f_c)
//     Simplified: σ = sqrt((A/10) ln 10) / (2π f_c)
//   where f_c is in cycles per pixel: f_c = cutoff_freq_hz * pixel_time_px
float sigma_tb(TimebaseConfig tb, float cutoff_freq_mhz, float cutoff_atten_db)
{
    // Convert cutoff to cycles-per-pixel
    float f_c_px = cutoff_freq_mhz * 1.0e6 * tb.pixel_time_px;

    // Guard: require positive frequency scale and attenuation
    if (f_c_px <= 0.0 || cutoff_atten_db <= 0.0)
        return 0.0;

    // Simplified stable form avoids pow/log on tiny values
    const float LN10 = 2.3025850929940459; // ln(10) high-precision constant
    float factor = (cutoff_atten_db * LN10) * 0.1; // (A/10)·ln(10) = -2·ln(a)

    // σ in texels
    float sigma = sqrt(factor) / (2.0 * PI * f_c_px);
    return sigma;
}