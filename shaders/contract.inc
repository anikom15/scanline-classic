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
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);

    // The stored raster width now matches the true line length in clocks.
    return max(1.0, round(total_cycles));
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
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    // In the clock-domain pipeline, `frameh.slang` emits one stored sample per
    // pixel clock. The native framed-signal sample rate is therefore the pixel
    // clock itself.
    return max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
}

float contract_snap_sample_rate(
    float requested_sample_rate,
    float fs_original,
    float base_frame_width)
{
    // Public contract: any stage that stores a 1D framed signal into a 2D
    // texture must keep the per-row stored width integral. Keep these values as
    // float across stage boundaries for portability, but treat them as
    // integral-valued and convert to int locally when exact integer arithmetic
    // is needed inside a shader stage.
    float safe_fs_original = max(fs_original, EPS);
    float safe_base_frame_width = max(base_frame_width, 1.0);
    float requested_safe = max(requested_sample_rate, EPS);
    float snapped_frame_width = max(1.0,
        round(safe_base_frame_width * requested_safe / safe_fs_original));

    return safe_fs_original * snapped_frame_width / safe_base_frame_width;
}

float contract_frame_width_at_sample_rate(
    float base_frame_width,
    float sample_rate,
    float fs_original)
{
    float safe_fs_original = max(fs_original, EPS);
    float safe_base_frame_width = max(base_frame_width, 1.0);

    return max(1.0,
        round(safe_base_frame_width * max(sample_rate, EPS) / safe_fs_original));
}

float contract_working_sample_rate(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz,
    float dsp_working_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float total_cycles = fs_original / max(h_freq_hz, EPS);
    float base_frame_width = max(1.0, round(total_cycles));
    float requested_sample_rate = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    float requested_safe = max(requested_sample_rate, EPS);
    float snapped_frame_width = max(1.0,
        round(base_frame_width * requested_safe / fs_original));

    return fs_original * snapped_frame_width / base_frame_width;
}

float contract_output_sample_rate(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz,
    float dsp_working_fs,
    float dsp_output_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float total_cycles = fs_original / max(h_freq_hz, EPS);
    float base_frame_width = max(1.0, round(total_cycles));

    float working_requested = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    float working_width = max(1.0,
        round(base_frame_width * max(working_requested, EPS) / fs_original));
    float working_sample_rate = fs_original * working_width / base_frame_width;

    float output_requested = (dsp_output_fs > 0.0)
        ? (dsp_output_fs * 1.0e6)
        : working_sample_rate;
    float output_width = max(1.0,
        round(base_frame_width * max(output_requested, EPS) / fs_original));

    return fs_original * output_width / base_frame_width;
}

float contract_working_frame_width(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz,
    float dsp_working_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float total_cycles = fs_original / max(h_freq_hz, EPS);
    float base_frame_width = max(1.0, round(total_cycles));
    float requested_sample_rate = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;

    return max(1.0,
        round(base_frame_width * max(requested_sample_rate, EPS) / fs_original));
}

float contract_output_frame_width(
    vec2 original_size,
    float original_fps,
    float sc_freq_mode,
    float sc_freq_custom_mhz,
    float pixel_clock_mode,
    float pixel_clock_mhz,
    float h_freq_mode,
    float h_freq_custom_khz,
    float h_blank_fuzz,
    float dsp_working_fs,
    float dsp_output_fs)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float fs_original = max(compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz), EPS);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float total_cycles = fs_original / max(h_freq_hz, EPS);
    float base_frame_width = max(1.0, round(total_cycles));

    float working_requested = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    float working_width = max(1.0,
        round(base_frame_width * max(working_requested, EPS) / fs_original));
    float working_sample_rate = fs_original * working_width / base_frame_width;

    float output_requested = (dsp_output_fs > 0.0)
        ? (dsp_output_fs * 1.0e6)
        : working_sample_rate;

    return max(1.0,
        round(base_frame_width * max(output_requested, EPS) / fs_original));
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
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);
    float clocks_per_line = max(1.0, round(total_cycles));
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

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
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);
    float total_cycles = pixel_clock_hz / max(h_freq_hz, EPS);
    float clocks_per_line = max(1.0, round(total_cycles));
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

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
    float field = float(frame_count);

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
