/* Filename: contract.inc

   Copyright (C) 2026 W. M. Martinez

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

// Contract-oriented timing getters.
// Public API rule: each getter is independent and can be called directly.
// `contract_*` helpers must not call other `contract_*` helpers; derive from
// first principles or `modulation.inc` only.
// `contract_field()` intentionally returns the unbounded frame count as float.
// The `contract_initial_*_phase_frac()` helpers describe the field-dependent
// timebase / carrier phase for downstream reconstruction only; they must not be
// used to shift the packed storage grid in `frameh.slang`, which should remain
// anchored to geometry and integer line carry.
// A preset may explicitly disable the color subcarrier; in that case the
// underlying timing helpers return `sc_freq_hz == 0.0`, and callers must either
// tolerate that directly or clamp only to a minimum safe value when a positive
// frequency is mathematically required.

#include "modulation.inc"

// Returns the output sample rate and width needed for an HD anti-aliasing filter.
// The estimated output depends on the display type:
//   - EDTV: up to 1262 samples per line, 19.71 MHz output rate
//   - Hi-Vision: up to 3212 samples per line, 108.405 MHz output rate
//   - Standard HDTV: up to 3212 samples per line, 108.405 MHz output rate
//   - Progressive-only HDTV: up to 3212 samples per line, 216.81 MHz output rate
//   - Full HDTV: up to 3212 samples per line, 216.81 MHz output rate
//
dvec2 contract_auto_hd_aa_fs_spl(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float v_freq_mode,
    float v_freq_custom_hz,
    float hd_display_type)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;

    compute_v_lines_per_field(
        v_freq_mode, standard, v_freq_custom_hz, original_fps, original_size.y,
        v_lines_per_field, v_lines_per_frame, is_interlaced
    );

    float v_freq_hz = compute_v_freq(v_freq_mode, h_freq_hz, v_lines_per_field, v_freq_custom_hz);
    float target_sample_rate;

    if (hd_display_type < 0.5)
        target_sample_rate = 19.71e6;  // EDTV
    else if (hd_display_type < 2.5)
        target_sample_rate = 108.405e6;  // Hi-Vision and Standard HDTV
    else
        target_sample_rate = 216.81e6;  // Progressive-only and Full HDTV

    float base_frame_width = compute_stored_line_width(
        h_freq_mode, h_freq_custom_khz, pixel_clock_hz / max(h_freq_hz, EPS));
    double width = double(base_frame_width) * double(target_sample_rate) / double(max(pixel_clock_hz, EPS));
    return dvec2(double(target_sample_rate), width);
}

// Returns the number of stored clock samples that represent one active source pixel.
float contract_clock_factor(
    float original_width,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);
    float fuzz_frac = h_blank_fuzz / 100.0;

    return max(1.0, round(total_cycles * fuzz_frac / max(original_width, 1.0)));
}

// Returns the total number of stored clock samples in one line.
float contract_clocks_per_line(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);

    return compute_stored_line_width(h_freq_mode, h_freq_custom_khz, total_cycles);
}

// Returns the total number of stored samples in a framed 2D raster.
float contract_data_length(double frame_width, float frame_height)
{
    return float(ceil(double(frame_width) * double(frame_height)));
}

// Pack the field in either pixel or working samples into a nearly square
// power-of-two grid, independently of allocation size.
float contract_pixel_packed_width(float data_length)
{
    return exp2(ceil(log2(sqrt(max(ceil(data_length), 1.0)))));
}

bool contract_pixel_texture_fits(vec2 texture_size, float data_length, float width)
{
    return texture_size.x >= width && texture_size.y >= ceil(ceil(data_length) / width);
}

// Returns the presentation-space width used for output geometry calculations.
float contract_display_frame_width(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);
    float clocks_per_line = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, total_cycles);
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

    return clocks_per_line / max(clock_factor, 1.0);
}

// Returns the current field index as an unbounded float.
float contract_field(uint frame_count)
{
    return float(frame_count);
}

// Field zero follows the profile or legacy video standard; FIELD_ODD reverses it.
float contract_field_parity(
    uint frame_count, float field_odd,
    float original_fps, float sc_freq_mode, float sc_freq_custom_mhz,
    float profile_first_odd)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    if (!(profile_first_odd == -1.0 || profile_first_odd == 0.0 || profile_first_odd == 1.0))
        return uintBitsToFloat(0x7fc00000u);
    bool first_is_odd = profile_first_odd < 0.0
        ? standard == 1 || (standard >= 3 && original_fps <= 55.0)
        : profile_first_odd > 0.5;
    uint first_odd = first_is_odd ? 1u : 0u;
    uint reversed = (field_odd > 0.5) ? 1u : 0u;
    return float((frame_count % 2u + first_odd + reversed) % 2u);
}

// Returns the current field's storage height in lines.
float contract_frame_height(
    vec2 original_size,
    float original_fps,
    float v_freq_mode,
    float custom_v_freq,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;
    compute_v_lines_per_field(
        v_freq_mode,
        h_freq_hz,
        original_fps,
        custom_v_freq,
        original_size.y,
        v_lines_per_field,
        v_lines_per_frame,
        is_interlaced);

    return v_lines_per_field;
}

// Returns the stored clock-domain line width in samples.
float contract_frame_width(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    return compute_stored_line_width(h_freq_mode, h_freq_custom_khz, pixel_clock_hz / max(h_freq_hz, EPS));
}

// Returns the stored line width that corresponds to a given sample rate.
double contract_frame_width_at_sample_rate(
    float base_frame_width,
    float sample_rate,
    float fs_original)
{
    float safe_fs_original = max(fs_original, EPS);
    float safe_base_frame_width = max(base_frame_width, 1.0);

    return max(1.0lf, double(safe_base_frame_width) * double(max(sample_rate, EPS)) / double(safe_fs_original));
}

// Offset from the first stored sample to the exact physical line boundary.
float contract_hsync_sample_offset(
    float clock_line_start, float base_width, double output_width, float stored_line_start)
{
    return float(double(clock_line_start) * double(output_width) / double(base_width)
        - double(stored_line_start));
}

// Returns the framed-signal sample rate emitted by `frameh.slang`.
float contract_fs_original(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    return max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
}

// Returns the full frame height, including both fields when interlaced.
float contract_full_frame_height(
    vec2 original_size,
    float original_fps,
    float v_freq_mode,
    float custom_v_freq,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;
    compute_v_lines_per_field(
        v_freq_mode,
        h_freq_hz,
        original_fps,
        custom_v_freq,
        original_size.y,
        v_lines_per_field,
        v_lines_per_frame,
        is_interlaced);

    return is_interlaced ? v_lines_per_frame : v_lines_per_field;
}

// Returns the horizontal line frequency in Hz.
float contract_h_frequency(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    return compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
}

// Returns the starting pixel-clock/sample-time phase offset for the current
// field, including any odd-field timing adjustment used by the legacy
// modulation path. This is a timebase reference for downstream reconstruction,
// not a command to move the packed data grid in `frameh.slang`.
float contract_initial_field_phase_frac(
    vec2 original_size, float original_fps, uint frame_count,
    float pixel_clock_mode, float pixel_clock_mhz,
    float sc_freq_mode, float sc_freq_custom_mhz,
    float h_freq_mode, float h_freq_custom_khz,
    float v_freq_mode, float custom_v_freq,
    float phase_zero)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float frame_width = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, pixel_clock_hz / max(h_freq_hz, EPS));

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;
    compute_v_lines_per_field(
        v_freq_mode,
        h_freq_hz,
        original_fps,
        custom_v_freq,
        original_size.y,
        v_lines_per_field,
        v_lines_per_frame,
        is_interlaced);

    double data_length_fract = fract(frame_width * v_lines_per_field);

    return float(fract(double(frame_count) * data_length_fract + double(phase_zero) / 360.0lf));
}

// The components encode an exact decimal value with eleven fractional digits.
bool timing_valid_parts(vec3 parts, float max_whole)
{
    return parts.x >= 0.0 && parts.x <= max_whole && parts.x == floor(parts.x)
        && parts.y >= 0.0 && parts.y <= 999999.0 && parts.y == floor(parts.y)
        && parts.z >= 0.0 && parts.z <= 99999.0 && parts.z == floor(parts.z);
}

double timing_decimal_ticks(vec3 parts)
{
    return double(parts.x) * 100000000000.0lf
        + double(parts.y) * 100000.0lf + double(parts.z);
}

double timing_add_mod(double a, double b, double modulus)
{
    return a >= modulus - b ? a - (modulus - b) : a + b;
}

double timing_remainder(double value, double modulus)
{
    double remainder = value - floor(value / modulus) * modulus;
    if (remainder < 0.0lf)
        remainder += modulus;
    if (remainder >= modulus)
        remainder -= modulus;
    return remainder;
}

// All operands are integers below 2^53. Avoid an overflowing product.
double timing_multiply_mod(double a, double b, double modulus)
{
    a = timing_remainder(a, modulus);
    double result = 0.0lf;
    for (int bit = 0; bit < 53 && b > 0.0lf; ++bit) {
        if (timing_remainder(b, 2.0lf) != 0.0lf)
            result = timing_add_mod(result, a, modulus);
        b = floor(b * 0.5lf);
        a = timing_add_mod(a, a, modulus);
    }
    return result;
}

// Compute the phase of a rational fraction of one clock without large products.
double timing_rational_clock_phase(double fraction, double scale, double numerator, double denominator)
{
    if (fraction == 0.0lf)
        return 0.0lf;

    double carrier_remainder = timing_remainder(numerator, denominator);
    double carrier_integer = (numerator - carrier_remainder) / denominator;
    double remaining = fraction;
    double quotient = 0.0lf;
    double remainder = 0.0lf;
    double term_quotient = 0.0lf;
    double term_remainder = carrier_remainder;
    for (int bit = 0; bit < 53 && remaining > 0.0lf; ++bit) {
        if (timing_remainder(remaining, 2.0lf) != 0.0lf) {
            if (remainder >= denominator - term_remainder)
                quotient += 1.0lf;
            quotient += term_quotient;
            remainder = timing_add_mod(remainder, term_remainder, denominator);
        }
        remaining = floor(remaining * 0.5lf);
        if (remaining > 0.0lf) {
            term_quotient *= 2.0lf;
            if (term_remainder >= denominator - term_remainder)
                term_quotient += 1.0lf;
            term_remainder = timing_add_mod(term_remainder, term_remainder, denominator);
        }
    }
    double whole = timing_multiply_mod(fraction, carrier_integer, scale);
    whole = timing_add_mod(whole, timing_remainder(quotient, scale), scale);
    return (whole + remainder / denominator) / scale;
}

// Reduce a binary fractional clock before applying the field count.
double timing_fractional_clock_phase(double fraction, double numerator, double denominator)
{
    if (fraction == 0.0lf)
        return 0.0lf;
    double scale = 1.0lf;
    for (int bit = 0; bit < 53 && fract(fraction) != 0.0lf; ++bit) {
        fraction *= 2.0lf;
        scale *= 2.0lf;
    }
    if (fract(fraction) != 0.0lf)
        return double(uintBitsToFloat(0x7fc00000u));
    return timing_rational_clock_phase(fraction, scale, numerator, denominator);
}

// Returns the starting color-subcarrier phase offset for the current field.
// Physical field durations are independent of the stored raster geometry.
// FIELD_ODD reverses the standard's initial field order.
float contract_initial_subcarrier_phase_frac(
    vec2 original_size, float original_fps, uint frame_count,
    float pixel_clock_mode, float pixel_clock_mhz,
    float sc_freq_mode, float sc_freq_custom_mhz,
    float h_freq_mode, float h_freq_custom_khz,
    float v_freq_mode, float custom_v_freq,
    float shorten_odd_field_time,
    float field_odd, vec3 pixel_clock_parts, vec3 sc_freq_parts, dvec2 profile_pixel_ratio,
    float phase_zero, dvec4 profile_clock_numerators, dvec4 profile_clock_denominators,
    float profile_first_odd)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float frame_width = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, pixel_clock_hz / max(h_freq_hz, EPS));

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;
    compute_v_lines_per_field(
        v_freq_mode,
        h_freq_hz,
        original_fps,
        custom_v_freq,
        original_size.y,
        v_lines_per_field,
        v_lines_per_frame,
        is_interlaced);

    bool legacy = profile_clock_numerators.x == -1.0lf;
    double even_length;
    double odd_length;
    double even_remainder = 0.0lf;
    double odd_remainder = 0.0lf;
    double even_scale = 1.0lf;
    double odd_scale = 1.0lf;
    if (legacy) {
        even_length = double(frame_width) * double(is_interlaced ? ceil(v_lines_per_field) : v_lines_per_field);
        odd_length = double(frame_width) * double(is_interlaced ? floor(v_lines_per_field) : v_lines_per_field);
        if (shorten_odd_field_time > 0.5 && (standard == 0 || standard == 2) && !is_interlaced)
            odd_length -= 4.0lf;
        if (shorten_odd_field_time > 0.5 && standard == 1 && is_interlaced)
            odd_length += 4.0lf;
    } else {
        double even_numerator = is_interlaced ? profile_clock_numerators.z : profile_clock_numerators.x;
        double odd_numerator = is_interlaced ? profile_clock_numerators.w : profile_clock_numerators.y;
        even_scale = is_interlaced ? profile_clock_denominators.z : profile_clock_denominators.x;
        odd_scale = is_interlaced ? profile_clock_denominators.w : profile_clock_denominators.y;
        if (!(even_numerator > 0.0lf && even_numerator < 4503599627370496.0lf
              && odd_numerator > 0.0lf && odd_numerator < 4503599627370496.0lf
              && even_scale >= 1.0lf && even_scale <= 1048576.0lf
              && odd_scale >= 1.0lf && odd_scale <= 1048576.0lf
              && even_numerator == floor(even_numerator) && odd_numerator == floor(odd_numerator)
              && even_scale == floor(even_scale) && odd_scale == floor(odd_scale)))
            return uintBitsToFloat(0x7fc00000u);
        even_length = floor(even_numerator / even_scale);
        odd_length = floor(odd_numerator / odd_scale);
        even_remainder = timing_remainder(even_numerator, even_scale);
        odd_remainder = timing_remainder(odd_numerator, odd_scale);
    }

    if (!(profile_first_odd == -1.0 || profile_first_odd == 0.0 || profile_first_odd == 1.0))
        return uintBitsToFloat(0x7fc00000u);
    bool standard_first_odd = standard == 1 || (standard >= 3 && original_fps <= 55.0);
    bool first_odd = (profile_first_odd < 0.0 ? standard_first_odd : profile_first_odd > 0.5)
        != (field_odd > 0.5);
    if (!(even_length >= 0.0lf && even_length < 9007199254740992.0lf)
        || !(odd_length >= 0.0lf && odd_length < 9007199254740992.0lf))
        return uintBitsToFloat(0x7fc00000u);

    double numerator;
    double denominator;
    if (legacy) {
        if (!(profile_pixel_ratio.x == -1.0lf && profile_pixel_ratio.y == 1.0lf)
            || !timing_valid_parts(pixel_clock_parts, 500.0))
            return uintBitsToFloat(0x7fc00000u);
        denominator = timing_decimal_ticks(pixel_clock_parts);
        if (denominator <= 0.0lf)
            return uintBitsToFloat(0x7fc00000u);
    } else {
        if (!(pixel_clock_mode >= 0.5
              && profile_pixel_ratio.x > 0.0lf && profile_pixel_ratio.x <= 16777216.0lf
              && profile_pixel_ratio.y > 0.0lf && profile_pixel_ratio.y <= 16777216.0lf
              && profile_pixel_ratio.x == floor(profile_pixel_ratio.x)
              && profile_pixel_ratio.y == floor(profile_pixel_ratio.y)
              && profile_pixel_ratio.x <= 500.0lf * profile_pixel_ratio.y))
            return uintBitsToFloat(0x7fc00000u);
        numerator = profile_pixel_ratio.y;
        denominator = profile_pixel_ratio.x;
    }
    if (standard == 4)
        return float(fract(double(phase_zero) / 360.0lf));

    double carrier_ticks;
    if (standard == 0)
        carrier_ticks = 357954500000.0lf;
    else if (standard == 1)
        carrier_ticks = 443361875000.0lf;
    else if (standard == 2)
        carrier_ticks = 357561100000.0lf;
    else if (timing_valid_parts(sc_freq_parts, 10.0))
        carrier_ticks = timing_decimal_ticks(sc_freq_parts);
    else
        return uintBitsToFloat(0x7fc00000u);

    if (carrier_ticks <= 0.0lf)
        return uintBitsToFloat(0x7fc00000u);
    if (legacy)
        numerator = pixel_clock_mode >= 0.5 ? 100000000000.0lf : carrier_ticks;

    double even_integer = floor(even_length);
    double odd_integer = floor(odd_length);
    double even_ticks = timing_multiply_mod(even_integer, numerator, denominator);
    double odd_ticks = timing_multiply_mod(odd_integer, numerator, denominator);
    double first_ticks = first_odd ? odd_ticks : even_ticks;
    double pair_ticks = timing_add_mod(even_ticks, odd_ticks, denominator);
    double result_ticks = timing_multiply_mod(pair_ticks, double(frame_count / 2u), denominator);
    if (frame_count % 2u != 0u)
        result_ticks = timing_add_mod(result_ticks, first_ticks, denominator);

    double even_fraction = legacy
        ? timing_fractional_clock_phase(even_length - even_integer, numerator, denominator)
        : timing_rational_clock_phase(even_remainder, even_scale, numerator, denominator);
    double odd_fraction = legacy
        ? timing_fractional_clock_phase(odd_length - odd_integer, numerator, denominator)
        : timing_rational_clock_phase(odd_remainder, odd_scale, numerator, denominator);
    double fractional_phase = fract(double(frame_count / 2u) * fract(even_fraction + odd_fraction));
    if (frame_count % 2u != 0u)
        fractional_phase += first_odd ? odd_fraction : even_fraction;
    return float(fract(result_ticks / denominator + fractional_phase + double(phase_zero) / 360.0lf));
}

// Returns 1.0 for interlaced timings and 0.0 otherwise.
float contract_is_interlaced(
    vec2 original_size,
    float original_fps,
    float v_freq_mode,
    float custom_v_freq,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float v_lines_per_field;
    float v_lines_per_frame;
    bool is_interlaced;
    compute_v_lines_per_field(
        v_freq_mode,
        h_freq_hz,
        original_fps,
        custom_v_freq,
        original_size.y,
        v_lines_per_field,
        v_lines_per_frame,
        is_interlaced);

    return is_interlaced ? 1.0 : 0.0;
}

// Returns the per-line carry, measured in clocks, caused by width quantization.
float contract_line_carry_clocks(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);
    float clocks_per_line = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, total_cycles);
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

    return mod(clocks_per_line, max(clock_factor, 1.0));
}

// Returns the nominal output-stage line duration in samples.
double contract_output_frame_width(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float dsp_working_fs,
    float dsp_output_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float base_frame_width = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, fs_original / max(h_freq_hz, EPS));

    float working_requested = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    float output_requested = (dsp_output_fs > 0.0)
        ? (dsp_output_fs * 1.0e6)
        : working_requested;

    return max(1.0lf, double(base_frame_width) * double(max(output_requested, EPS)) / double(fs_original));
}

// Returns the output-stage sample rate in Hz.
float contract_output_sample_rate(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float dsp_working_fs,
    float dsp_output_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float working_requested = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    return (dsp_output_fs > 0.0)
        ? (dsp_output_fs * 1.0e6)
        : working_requested;
}

// Returns the pixel clock in Hz for the selected timing configuration.
// If the pixel clock is defined as a multiple of a disabled subcarrier, the
// modulation helpers return the smallest safe positive fallback rather than
// silently substituting a standard NTSC/PAL carrier.
float contract_pixel_clock(
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float original_fps)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    return compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
}

// Returns the subcarrier frequency in Hz or 0.0 if the subcarrier is disabled.
float contract_subcarrier_freq_hz(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    return max(sc_freq_hz, 0.0);
}

// Returns the nominal working-stage line duration in samples.
double contract_working_frame_width(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float dsp_working_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float base_frame_width = compute_stored_line_width(h_freq_mode, h_freq_custom_khz, fs_original / max(h_freq_hz, EPS));
    float requested_sample_rate = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;

    return max(1.0lf, double(base_frame_width) * double(max(requested_sample_rate, EPS)) / double(fs_original));
}

// Returns the working-stage sample rate in Hz.
float contract_working_sample_rate(
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float dsp_working_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    return (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
}
