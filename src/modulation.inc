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

// Optimized sincos helper - computes both sin and cos in one call
// Returns vec2(sin(phase), cos(phase))
// This is more efficient than calling sin() and cos() separately
vec2 sincos_phase(float phase) {
    // Normalize phase to [-PI, PI] once before trig calls
    // This improves accuracy and ensures consistent results
    phase = mod(phase + PI, 2.0 * PI) - PI;
    return vec2(sin(phase), cos(phase));
}

// Compute carrier phase with precision-preserving normalization
// Uses fract() to keep phase bounded and prevent floating-point drift
// over long runtimes or high line numbers
float compute_carrier_phase(float t, float sc_freq_hz, float field_phase) {
    // Use fract to keep phase bounded and preserve precision
    // Normalize by extracting only fractional cycles to keep values small
    float cycles = sc_freq_hz * t;
    float fractional_cycles = fract(cycles);
    return 2.0 * PI * fractional_cycles + field_phase;
}

// Timebase and subcarrier configuration
struct TimebaseConfig {
    float field;
    float line;
    float field_phase;
    float sc_freq_hz;
    float pixel_time;
};

// Compute complete timebase configuration for composite/S-Video processing
// This consolidates the timing calculations used across multiple shaders
TimebaseConfig compute_timebase(
    float frame_count,
    vec2 tex_coord,
    vec2 original_size,
    float v_freq,
    float v_lines_per_field,
    float shorten_odd_field_time,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float h_blank_inactive_len,
    float h_blank_inactive_unit)
{
    TimebaseConfig config;
    
    // Field and line computation
    config.field = float(uint(frame_count) % 12u);
    config.line = floor(tex_coord.y * original_size.y);
    
    // Horizontal timing
    float h_freq_hz = v_freq * v_lines_per_field;
    float line_time = 1.0 / h_freq_hz;
    
    // Calculate inactive pixels based on unit
    float inactive_pixels;
    if (h_blank_inactive_unit < 0.5)
        inactive_pixels = h_blank_inactive_len;
    else if (h_blank_inactive_unit < 1.5)
        inactive_pixels = h_blank_inactive_len * 1.0e-6
            * h_freq_hz * original_size.x;
    else
        inactive_pixels = h_blank_inactive_len / 100.0
            * original_size.x;
    
    float total_pixels = original_size.x + inactive_pixels;
    config.pixel_time = line_time / total_pixels;
    
    // Subcarrier frequency derivation
    float subcarrier_div = round(h_freq_hz * total_pixels / NTSC_FSC * 100.0) / 100.0;
    if (sc_freq_mode < 0.5)
        config.sc_freq_hz = h_freq_hz * total_pixels / subcarrier_div;
    else if (sc_freq_mode < 1.5)
        config.sc_freq_hz = NTSC_FSC;
    else if (sc_freq_mode < 2.5)
        config.sc_freq_hz = PAL_FSC;
    else
        config.sc_freq_hz = sc_freq_custom_mhz * 1.0e6;
    
    // Field phase computation with odd-field timing adjustment
    float field_time = 1.0 / v_freq;
    config.field_phase = field_time * config.field * 2.0 * PI * config.sc_freq_hz;
    
    float odd_time_adjust = original_size.x / 256.0 * config.pixel_time;
    config.field_phase -= ceil(config.field / 2.0) * odd_time_adjust 
        * shorten_odd_field_time * 2.0 * PI * config.sc_freq_hz;
    config.field_phase = mod(config.field_phase, 2.0 * PI) - PI;
    
    return config;
}