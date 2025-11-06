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