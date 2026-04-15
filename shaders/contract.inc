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

    return max(1.0, round(total_cycles));
}

// Returns the total number of stored samples in a framed 2D raster.
float contract_data_length(float frame_width, float frame_height)
{
    return frame_width * frame_height;
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
    float clocks_per_line = max(1.0, round(total_cycles));
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

    return clocks_per_line / max(clock_factor, 1.0);
}

// Returns the current field index as an unbounded float.
float contract_field(uint frame_count)
{
    return float(frame_count);
}

// Returns the visible field height in lines.
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

    return max(1.0, round(pixel_clock_hz / max(h_freq_hz, EPS)));
}

// Returns the stored line width that corresponds to a given sample rate.
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

    float frame_width = round(pixel_clock_hz / max(h_freq_hz, EPS));

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

// Returns the starting color-subcarrier phase offset for the current field.
// This mirrors the legacy modulation path, including odd-field timing
// adjustment and its 12-step phase stabilization. Like the field-phase helper
// above, this value is for downstream carrier reconstruction rather than
// storage-grid placement.
float contract_initial_subcarrier_phase_frac(
    vec2 original_size, float original_fps, uint frame_count,
    float pixel_clock_mode, float pixel_clock_mhz,
    float sc_freq_mode, float sc_freq_custom_mhz,
    float h_freq_mode, float h_freq_custom_khz,
    float v_freq_mode, float custom_v_freq,
    float shorten_odd_field_time,
    float phase_zero)
{
    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(sc_freq_mode, sc_freq_custom_mhz, original_fps, sc_freq_hz, standard);

    float pixel_clock_hz = compute_pixel_clock(pixel_clock_mode, pixel_clock_mhz, sc_freq_hz);
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, pixel_clock_hz, original_fps);

    float frame_width = round(pixel_clock_hz / max(h_freq_hz, EPS));

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

    double data_length = frame_width * v_lines_per_field;

    if (shorten_odd_field_time > 0.5) {
        // With odd-field timing adjustment, the field length alternates between two integer values.
        if (standard == 0) {
            if (!is_interlaced) {
                double sc_cycles_per_frame_fract = fract((2.0lf * data_length - 4.0lf) * (double(sc_freq_hz) / double(pixel_clock_hz)));
                double sc_cycles_per_even_field_fract = fract(data_length * (double(sc_freq_hz) / double(pixel_clock_hz)));

                return float(fract(fract(double(frame_count / 2u) * sc_cycles_per_frame_fract)
                    + double(frame_count % 2u) * sc_cycles_per_even_field_fract
                    + double(phase_zero) / 360.0lf));
            }
        } else {
            if (is_interlaced) {
                double sc_cycles_per_frame_fract = fract((2.0lf * data_length + 4.0lf) * (double(sc_freq_hz) / double(pixel_clock_hz)));
                double sc_cycles_per_even_field_fract = fract(data_length * (double(sc_freq_hz) / double(pixel_clock_hz)));

                return float(fract(fract(double(frame_count / 2u) * sc_cycles_per_frame_fract)
                    + double(frame_count % 2u) * sc_cycles_per_even_field_fract
                    + double(phase_zero) / 360.0lf));
            }
        }
    }

    double sc_cycles_per_field_fract = fract(data_length * (double(sc_freq_hz) / double(pixel_clock_hz)));
    return float(fract(double(frame_count) * sc_cycles_per_field_fract + double(phase_zero) / 360.0lf));
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
    float clocks_per_line = max(1.0, round(total_cycles));
    float fuzz_frac = h_blank_fuzz / 100.0;
    float clock_factor = max(1.0, round(total_cycles * fuzz_frac / max(original_size.x, 1.0)));

    return mod(clocks_per_line, max(clock_factor, 1.0));
}

// Returns the snapped output-stage stored line width in samples.
float contract_output_frame_width(
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
    float base_frame_width = max(1.0, round(fs_original / max(h_freq_hz, EPS)));

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

// Returns the snapped output-stage sample rate in Hz.
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
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float base_frame_width = max(1.0, round(fs_original / max(h_freq_hz, EPS)));

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

// Snaps a requested sample rate so the stored row width remains integral.
float contract_snap_sample_rate(
    float requested_sample_rate,
    float fs_original,
    float base_frame_width)
{
    float safe_fs_original = max(fs_original, EPS);
    float safe_base_frame_width = max(base_frame_width, 1.0);
    float snapped_frame_width = max(1.0,
        round(safe_base_frame_width * max(requested_sample_rate, EPS) / safe_fs_original));

    return safe_fs_original * snapped_frame_width / safe_base_frame_width;
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

// Returns the snapped working-stage stored line width in samples.
float contract_working_frame_width(
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
    float base_frame_width = max(1.0, round(fs_original / max(h_freq_hz, EPS)));
    float requested_sample_rate = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;

    return max(1.0,
        round(base_frame_width * max(requested_sample_rate, EPS) / fs_original));
}

// Returns the snapped working-stage sample rate in Hz.
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
    float h_freq_hz = compute_h_freq(h_freq_mode, standard, h_freq_custom_khz, fs_original, original_fps);
    float base_frame_width = max(1.0, round(fs_original / max(h_freq_hz, EPS)));
    float requested_sample_rate = (dsp_working_fs > 0.0)
        ? (dsp_working_fs * 1.0e6)
        : fs_original;
    float snapped_frame_width = max(1.0,
        round(base_frame_width * max(requested_sample_rate, EPS) / fs_original));

    return fs_original * snapped_frame_width / base_frame_width;
}
