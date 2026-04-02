#version 450

// Filename: sharpen.slang
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
// Sharpness enhancement via dual bandpass filters
// ------------------------------------------------
// Input: Real RGB voltage
// Output: Real RGB voltage (sharpened)
//
// Applies user-controlled sharpness enhancement using two gaussian bandpass
// filters at complementary frequencies, with gains scaled logarithmically in dB.

#pragma name Sharpen
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/user-common.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter SHARPNENER_BYPASS "Bypass sharpener" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    // Timing and source geometry (for sharpness bandpass)
    vec4 OriginalSize;    // .xy size, .zw inv size
    vec4 OutputSize;
    vec4 FrameHSize;
    uint FrameCount;
    float OriginalFPS;    // Vertical frequency (Hz)
    float V_FREQ_MODE;
    float V_FREQ;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;        // Custom subcarrier frequency (MHz)
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;

    // User video adjustments
    float USER_SHARPNESS;
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define USER_SHARPNESS config.USER_SHARPNESS

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float H_FREQ;
    float H_BLANK_FUZZ;

#ifdef OPTION_DEBUG
    float SHARPNENER_BYPASS;
#endif  // OPTION_DEBUG
} global;

#define H_FREQ global.H_FREQ
#define H_BLANK_FUZZ global.H_BLANK_FUZZ

#ifdef OPTION_DEBUG
#define SHARPNENER_BYPASS global.SHARPNENER_BYPASS
#endif  // OPTION_DEBUG

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out flat vec4 sharpness_filters;
layout(location = 2) out flat float Fs;
layout(location = 3) out flat vec4 sharpness_params;  // (tap_count1, gain1, tap_count2, gain2)

// At Fs = 32 MHz, the wider (0.4 MHz) lobe yields about 37 taps at FILTER_THRESHOLD.
const float SHARPNESS_MAX_TAPS = 75.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Derive sample rate from original timing
    float f_sc;
    int standard;
    float pixel_time;
    float active_source_pixels;
    compute_subcarrier_freq(
        SC_FREQ_MODE, SC_FREQ,
        config.OriginalFPS,
        f_sc, standard);

    float pixel_clock_hz = compute_pixel_clock(
        PIXEL_CLOCK_MODE, PIXEL_CLOCK, f_sc
    );

    float h_freq_hz = compute_h_freq(
        H_FREQ_MODE, standard, H_FREQ, pixel_clock_hz,
        config.OriginalFPS);

    compute_h_timing(
        pixel_clock_hz, h_freq_hz, H_BLANK_FUZZ,
        config.OriginalSize.x, active_source_pixels, pixel_time);

    float Delta = config.OutputSize.x / active_source_pixels;
    float Fs_original = 1.0 / pixel_time;
    Fs = Fs_original * Delta * 2.0; // Effective sample rate at 2x scaling (32 MHz path)

#ifdef OPTION_CRISPY
    sharpness_filters = vec4(0.0);
    sharpness_params = vec4(0.0);
#else
#ifdef OPTION_DEBUG
    if (SHARPNENER_BYPASS < 0.5) {
#endif  // OPTION_DEBUG

    float emphasis_center_hz = 3.0e6;
    float emphasis2_center_hz = 8.0e6;
    float emphasis_sigma = gaussian_sigma(3.0e6 / Fs, 40.0);
    float emphasis2_sigma = gaussian_sigma(2.0e6 / Fs, 40.0);
    sharpness_filters = vec4(emphasis_center_hz, emphasis_sigma, emphasis2_center_hz, emphasis2_sigma);

    float tap_radius1 = gaussian_decay_time(emphasis_sigma, FILTER_THRESHOLD_ANALOG);
    float tap_count1 = min(2.0 * ceil(tap_radius1) + 1.0, SHARPNESS_MAX_TAPS);
    float tap_radius2 = gaussian_decay_time(emphasis2_sigma, FILTER_THRESHOLD_ANALOG);
    float tap_count2 = min(2.0 * ceil(tap_radius2) + 1.0, SHARPNESS_MAX_TAPS);

    float gain1 = 0.0;
    for (int k = 0; k < int(tap_count1); ++k) {
        float n = float(k) - (tap_count1 - 1.0) / 2.0;
        gain1 += gaussian(n, emphasis_sigma);
    }
    float gain2 = 0.0;
    for (int k = 0; k < int(tap_count2); ++k) {
        float n = float(k) - (tap_count2 - 1.0) / 2.0;
        gain2 += gaussian(n, emphasis2_sigma);
    }
    sharpness_params = vec4(tap_count1, gain1, tap_count2, gain2);

#ifdef OPTION_DEBUG
    } else {
        sharpness_filters = vec4(0.0);
        sharpness_params = vec4(0.0);
    }
#endif  // OPTION_DEBUG
#endif  // OPTION_CRISPY

}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec4 sharpness_filters;
layout(location = 2) flat in float Fs;
layout(location = 3) flat in vec4 sharpness_params;  // (tap_count1, gain1, tap_count2, gain2)
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Sharpness bandpass + harmonic (modulated Gaussian)
    float sharpness = USER_SHARPNESS / 100.0;
#ifdef OPTION_CRISPY
    vec3 color = texture(Source, vTexCoord).rgb;
    FragColor = vec4(color, 1.0);  // Sharpening circuit disabled under OPTION_CRISPY
    return;
#endif  // OPTION_CRISPY

    vec3 color = vec3(0.0);

#ifdef OPTION_DEBUG
    if (SHARPNENER_BYPASS < 0.5) {
#endif  // OPTION_DEBUG

    float emphasis_center_hz = sharpness_filters.x;
    float emphasis_sigma = sharpness_filters.y;
    float emphasis2_center_hz = sharpness_filters.z;
    float emphasis2_sigma = sharpness_filters.w;

    // Horizontal lattice setup
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float line = floor(UV.y);
    float baseCenter = floor(UV.x) + 0.5;
    vec2 TexCenter = vec2(
        baseCenter * config.OutputSize.z,
        (line + 0.5) * config.OutputSize.w);
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    // Zero-phase bandpass: cosine modulation baked into kernel weights.
    float emphasis_phase_step = 2.0 * PI * emphasis_center_hz / Fs;
    float emphasis2_phase_step = 2.0 * PI * emphasis2_center_hz / Fs;

    int n_taps1 = int(sharpness_params.x);
    float gain1 = sharpness_params.y;
    int center1 = (n_taps1 - 1) / 2;

    int n_taps2 = int(sharpness_params.z);
    float gain2 = sharpness_params.w;
    int center2 = (n_taps2 - 1) / 2;

    vec3 band_color = vec3(0.0);
    vec3 band2_color = vec3(0.0);

    // Sample each horizontal tap once and reuse it for both bandpass accumulators.
    int max_center = max(center1, center2);
    for (int n = -max_center; n <= max_center; ++n) {
        float tap_offset = float(n);
        vec3 rgb = texture(Source, TexCenter + tap_offset * dx).rgb;

        if (tap_offset == 0.0) {
            color = rgb; // Bypass path (for 0 dB target)
        }
        if (abs(n) <= center1) {
            float w1 = gaussian(tap_offset, emphasis_sigma) * cos(tap_offset * emphasis_phase_step);
            band_color += w1 * rgb;
        }
        if (abs(n) <= center2) {
            float w2 = gaussian(tap_offset, emphasis2_sigma) * cos(tap_offset * emphasis2_phase_step);
            band2_color += w2 * rgb;
        }
    }
    band_color /= gain1;
    band2_color /= gain2;

    // Piecewise-linear dB targets (final response at center frequencies):
    // Primary: 0% -> -6 dB, 50% -> 3 dB, 100% -> 8 dB
    // Secondary: 0% -> -2 dB, 50% -> 3 dB, 100% -> 5 dB
    float s = clamp(sharpness, 0.0, 1.0);
    float t_low = clamp(s / 0.5, 0.0, 1.0);
    float t_high = clamp((s - 0.5) / 0.5, 0.0, 1.0);

    float dB_primary = (s < 0.5) ? mix(-6.0, 3.0, t_low) : mix(3.0, 8.0, t_high);
    float dB_secondary = (s < 0.5) ? mix(-2.0, 3.0, t_low) : mix(3.0, 5.0, t_high);

    float total_primary_gain = pow(10.0, dB_primary / 20.0);
    float total_secondary_gain = pow(10.0, dB_secondary / 20.0);

    // Convert desired total gain to additive bandpass injection gain.
    float bp_primary_gain = total_primary_gain - 1.0;
    float bp_secondary_gain = total_secondary_gain - 1.0;

    color += bp_primary_gain * band_color;
    color += bp_secondary_gain * band2_color;

#ifdef OPTION_DEBUG
    } else {
        color = texture(Source, vTexCoord).rgb;
    }
#endif  // OPTION_DEBUG

    FragColor = vec4(color, 1.0);
}
