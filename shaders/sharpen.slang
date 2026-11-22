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
// Input and output: luma in R, modulated chroma in G.
//
// Applies two zero-phase Gaussian bandpass filters to luma. Chroma remains
// aligned with the center luma sample.

#pragma name Sharpen
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "bandpass.inc"
#include "filter-taps.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/user-common.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SHARPEN_HEADER " —— Debug Sharpen —— " 0.0 0.0 0.0 0.0
#pragma parameter DEBUG_SHARPEN_BYPASS "Bypass sharpener" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float DSP_WORKING_FS;
    float USER_SHARPNESS;
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define USER_SHARPNESS config.USER_SHARPNESS
#define H_FREQ config.H_FREQ
#define DSP_WORKING_FS config.DSP_WORKING_FS

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;

#ifdef OPTION_DEBUG
    float DEBUG_SHARPEN_BYPASS;
#endif  // OPTION_DEBUG
} global;


#ifdef OPTION_DEBUG
#define DEBUG_SHARPEN_BYPASS global.DEBUG_SHARPEN_BYPASS
#endif  // OPTION_DEBUG

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out flat vec4 sharpness_filters;
layout(location = 2) out flat float Fs;
layout(location = 3) out flat vec4 sharpness_params;  // (tap_count1, gain1, tap_count2, gain2)
layout(location = 4) out flat float FrameWidth;
layout(location = 5) out flat float FrameHeight;
layout(location = 6) out flat float DataLength;

const float SHARPNESS_MAX_TAPS = float(SHARPEN_MAX_TAPS);
const float SHARPNESS_PRIMARY_BANDWIDTH_HZ = 3.0e6;
const float SHARPNESS_SECONDARY_BANDWIDTH_HZ = 2.0e6;
const float SHARPNESS_ATTEN_DB = 40.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    Fs = contract_working_sample_rate(
        config.OriginalFPS, SC_FREQ_MODE, SC_FREQ, PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ, DSP_WORKING_FS);
    FrameWidth = contract_working_frame_width(
        config.OriginalFPS, SC_FREQ_MODE, SC_FREQ, PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ, DSP_WORKING_FS);
    FrameHeight = contract_frame_height(
        config.OriginalSize.xy, config.OriginalFPS, V_FREQ_MODE, V_FREQ,
        SC_FREQ_MODE, SC_FREQ, PIXEL_CLOCK_MODE, PIXEL_CLOCK, H_FREQ_MODE, H_FREQ);
    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);

#ifdef OPTION_CRISPY
    sharpness_filters = vec4(0.0);
    sharpness_params = vec4(0.0);
#else
#ifdef OPTION_DEBUG
    if (DEBUG_SHARPEN_BYPASS < 0.5) {
#endif  // OPTION_DEBUG

    float emphasis_center_hz = 3.0e6;
    float emphasis2_center_hz = 8.0e6;
    float emphasis_sigma = gaussian_sigma(SHARPNESS_PRIMARY_BANDWIDTH_HZ / Fs, SHARPNESS_ATTEN_DB);
    float emphasis2_sigma = gaussian_sigma(SHARPNESS_SECONDARY_BANDWIDTH_HZ / Fs, SHARPNESS_ATTEN_DB);
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
layout(location = 4) flat in float FrameWidth;
layout(location = 5) flat in float FrameHeight;
layout(location = 6) flat in float DataLength;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    vec2 pixel = floor(vTexCoord * config.OutputSize.xy);
    float sample_index = pixel.y * FrameWidth + pixel.x;
    if (pixel.x >= FrameWidth || pixel.y >= FrameHeight || sample_index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    float data_limit = DataLength - 1.0;
    vec4 center_sample = fetch_input_sample(Source, config.SourceSize.xy, sample_index, FrameWidth, data_limit);

#ifdef OPTION_CRISPY
    FragColor = center_sample;
    return;
#endif  // OPTION_CRISPY

#ifdef OPTION_DEBUG
    if (DEBUG_SHARPEN_BYPASS >= 0.5) {
        FragColor = center_sample;
        return;
    }
#endif  // OPTION_DEBUG

    float sharpness = USER_SHARPNESS / 100.0;
    float luma = center_sample.r;
    float emphasis_center_hz = sharpness_filters.x;
    float emphasis_sigma = sharpness_filters.y;
    float emphasis2_center_hz = sharpness_filters.z;
    float emphasis2_sigma = sharpness_filters.w;

    // Zero-phase bandpass: cosine modulation baked into kernel weights.
    float emphasis_phase_step = 2.0 * PI * emphasis_center_hz / Fs;
    float emphasis2_phase_step = 2.0 * PI * emphasis2_center_hz / Fs;

    int n_taps1 = int(sharpness_params.x);
    float gain1 = sharpness_params.y;
    int center1 = (n_taps1 - 1) / 2;

    int n_taps2 = int(sharpness_params.z);
    float gain2 = sharpness_params.w;
    int center2 = (n_taps2 - 1) / 2;

    float band_luma = 0.0;
    float band2_luma = 0.0;

    // Sample each horizontal tap once and reuse it for both bandpass accumulators.
    int max_center = max(center1, center2);
    for (int n = -max_center; n <= max_center; ++n) {
        float tap_offset = float(n);
        float sample_luma = (n == 0) ? center_sample.r : fetch_input_sample(
            Source, config.SourceSize.xy, sample_index + tap_offset, FrameWidth, data_limit).r;
        if (abs(n) <= center1) {
            float w1 = gaussian_carrier_kernel(tap_offset, emphasis_sigma, emphasis_phase_step);
            band_luma += w1 * sample_luma;
        }
        if (abs(n) <= center2) {
            float w2 = gaussian_carrier_kernel(tap_offset, emphasis2_sigma, emphasis2_phase_step);
            band2_luma += w2 * sample_luma;
        }
    }
    band_luma /= gain1;
    band2_luma /= gain2;

    // Piecewise-linear dB targets (final response at center frequencies):
    // Primary: 0% -> -6 dB, 50% -> 3 dB, 100% -> 8 dB
    // Secondary: 0% -> -2 dB, 50% -> 3 dB, 100% -> 5 dB
    float s = clamp(sharpness, 0.0, 1.0);
    float t_low = clamp(s / 0.5, 0.0, 1.0);
    float t_high = clamp((s - 0.5) / 0.5, 0.0, 1.0);

    float dB_primary = (s < 0.5) ? mix(-6.0, 3.0, t_low) : mix(3.0, 8.0, t_high);
    float dB_secondary = (s < 0.5) ? mix(-2.0, 3.0, t_low) : mix(3.0, 5.0, t_high);

    float total_primary_gain = db_to_linear(dB_primary);
    float total_secondary_gain = db_to_linear(dB_secondary);

    // Convert desired total gain to additive bandpass injection gain.
    float bp_primary_gain = total_primary_gain - 1.0;
    float bp_secondary_gain = total_secondary_gain - 1.0;

    luma += bp_primary_gain * band_luma;
    luma += bp_secondary_gain * band2_luma;

    FragColor = vec4(luma, center_sample.gba);
}
