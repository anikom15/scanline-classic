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
// `contract_field()` intentionally returns the unbounded frame count as float.

#include "modulation.inc"

float contract_field(uint frame_count)
{
    return float(frame_count);
}

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

    return max(1.0, round(total_cycles));
}

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

float contract_fs_original(
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
    // In the clock-domain pipeline, `frameh.slang` emits one stored sample per
    // pixel clock. The native framed-signal sample rate is therefore the pixel
    // clock itself.
    return max(contract_pixel_clock(
        pixel_clock_mode,
        pixel_clock_mhz,
        sc_freq_mode,
        sc_freq_custom_mhz,
        original_fps), EPS);
}

float contract_frame_width(
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
    // The stored raster width now matches the true line length in clocks.
    return max(contract_clocks_per_line(
        original_fps,
        sc_freq_mode,
        sc_freq_custom_mhz,
        pixel_clock_mode,
        pixel_clock_mhz,
        h_freq_mode,
        h_freq_custom_khz), 1.0);
}

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
    // Presentation-space width for stages that reason about the intended
    // displayed raster geometry rather than the stored clock-domain texture.
    float clocks_per_line = contract_clocks_per_line(
        original_fps,
        sc_freq_mode,
        sc_freq_custom_mhz,
        pixel_clock_mode,
        pixel_clock_mhz,
        h_freq_mode,
        h_freq_custom_khz);
    float clock_factor = contract_clock_factor(
        original_size.x,
        original_fps,
        sc_freq_mode,
        sc_freq_custom_mhz,
        pixel_clock_mode,
        pixel_clock_mhz,
        h_freq_mode,
        h_freq_custom_khz,
        h_blank_fuzz);

    return clocks_per_line / max(clock_factor, 1.0);
}

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
    float clocks_per_line = contract_clocks_per_line(
        original_fps,
        sc_freq_mode,
        sc_freq_custom_mhz,
        pixel_clock_mode,
        pixel_clock_mhz,
        h_freq_mode,
        h_freq_custom_khz);
    float clock_factor = contract_clock_factor(
        original_size.x,
        original_fps,
        sc_freq_mode,
        sc_freq_custom_mhz,
        pixel_clock_mode,
        pixel_clock_mhz,
        h_freq_mode,
        h_freq_custom_khz,
        h_blank_fuzz);

    return mod(clocks_per_line, max(clock_factor, 1.0));
}

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

float contract_initial_field_phase_frac(
    uint frame_count,
    vec2 original_size,
    float original_fps,
    float v_freq_mode,
    float custom_v_freq,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz,
    float phase_zero)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float frame_width;
    float pixel_time;
    compute_h_timing(pixel_clock_hz, h_freq_hz, h_blank_fuzz, original_size.x, frame_width, pixel_time);

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

    float t_field = v_lines_per_field / h_freq_hz;
    float fs_original = 1.0 / pixel_time;
    float field = contract_field(frame_count);

    return fract(phase_zero / 360.0 + fract(field * t_field * fs_original));
}

float contract_data_length(float frame_width, float frame_height)
{
    return frame_width * frame_height;
}

float contract_phase_rel_sample(float sample_x, float sample_y, float frame_width)
{
    float output_index = sample_x;
    float field_output_index = sample_y * frame_width + output_index;
    return fract(field_output_index);
}
