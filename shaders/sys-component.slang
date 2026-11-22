#version 450

// Filename: sys-component.slang
//
// Copyright (C) 2025-2026 W. M. Martinez
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
// System-level component amplifier and filter
// -------------------------------------------
// Input: Real RGB voltage with optional sync in alpha
// Output: Real YCC voltage with sync on luma
//
// Encodes RGB into YCC (Y, B-Y, R-Y) and filters each component
// YCC is not scaled; scaling factors depend on use case.

#pragma name SysComponent
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "lowpass.inc"
#include "filter-taps.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-component.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_COMPONENT_HEADER " —— Debug Sys Component —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_COMPONENT_BYPASS "Bypass system component stage" 0.0 0.0 1.0 1.0
#pragma parameter SYS_COMPONENT_FILTER_BYPASS "Bypass system component filter" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;

    // Per-component analog bandlimit (MHz/dB).
    float SYS_YC_FILTER_TYPE;
    float SYS_BANDWIDTH_Y;
    float SYS_BANDWIDTH_C;
    float SYS_CUTOFF_ATTEN_Y;
    float SYS_CUTOFF_ATTEN_C;
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ

#define SYS_YC_FILTER_TYPE config.SYS_YC_FILTER_TYPE
#define SYS_BANDWIDTH_Y config.SYS_BANDWIDTH_Y
#define SYS_BANDWIDTH_C config.SYS_BANDWIDTH_C
#define SYS_CUTOFF_ATTEN_Y config.SYS_CUTOFF_ATTEN_Y
#define SYS_CUTOFF_ATTEN_C config.SYS_CUTOFF_ATTEN_C

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float DSP_WORKING_FS;

#ifdef OPTION_DEBUG
    // Bypasses
    float SYS_COMPONENT_BYPASS;        // 0 or 1
    float SYS_COMPONENT_FILTER_BYPASS; // 0 or 1
#endif                                 // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define SYS_COMPONENT_BYPASS global.SYS_COMPONENT_BYPASS
#define SYS_COMPONENT_FILTER_BYPASS global.SYS_COMPONENT_FILTER_BYPASS
#endif  // OPTION_DEBUG

#define DSP_WORKING_FS global.DSP_WORKING_FS

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out vec3 sigma;
layout(location = 2) flat out vec3 kernelGain;
layout(location = 3) flat out float FrameWidth;
layout(location = 4) flat out float FrameHeight;
layout(location = 5) flat out float DataLength;
layout(location = 6) flat out float Taps;

const float MAX_TAPS = float(SYS_COMPONENT_MAX_TAPS);

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float fs_current = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);

    FrameWidth = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    FrameHeight = contract_frame_height(
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);

    // Filter design
    if (SYS_YC_FILTER_TYPE < 0.5) {
        // Normalize the analog Gaussian design into working-sample units before
        // evaluating the discrete kernel on the current DSP sample grid.
        vec3 sigma_seconds = vec3(
            gaussian_sigma(SYS_BANDWIDTH_Y * 1.0e6, SYS_CUTOFF_ATTEN_Y),
            gaussian_sigma(SYS_BANDWIDTH_C * 1.0e6, SYS_CUTOFF_ATTEN_C),
            gaussian_sigma(SYS_BANDWIDTH_C * 1.0e6, SYS_CUTOFF_ATTEN_C));

        float sigma_max_seconds = max(sigma_seconds.x, max(sigma_seconds.y, sigma_seconds.z));
        float t_support_seconds = gaussian_decay_time(sigma_max_seconds, FILTER_THRESHOLD_ANALOG);

        sigma = sigma_seconds * fs_current;
        Taps = max(1.0, min(2.0 * ceil(t_support_seconds * fs_current) + 1.0, MAX_TAPS));

        kernelGain = gaussian_lowpass_gain(sigma, Taps);
    } else {
        // First-order Butterworth filter
        vec2 gaussian_cutoff_freq = 1e6 * vec2(SYS_BANDWIDTH_Y, SYS_BANDWIDTH_C);
        vec2 sigma_seconds = vec2(
            gaussian_sigma(gaussian_cutoff_freq.x, SYS_CUTOFF_ATTEN_Y),
            gaussian_sigma(gaussian_cutoff_freq.y, SYS_CUTOFF_ATTEN_C));
        vec2 butterworth_cutoff_freq = vec2(
            butterworth_matched_cutoff(gaussian_cutoff_freq.x, SYS_CUTOFF_ATTEN_Y, sigma_seconds.x, EPS),
            butterworth_matched_cutoff(gaussian_cutoff_freq.y, SYS_CUTOFF_ATTEN_C, sigma_seconds.y, EPS));

        vec2 K = tan(PI * butterworth_cutoff_freq / fs_current);
        vec2 alpha = butterworth_alpha_from_prewarp(K);

        if (SYS_CUTOFF_ATTEN_Y == 0.0) {
            alpha.x = EPS; // No filtering (DC gain = 1)
        }

        if (SYS_CUTOFF_ATTEN_C == 0.0) {
            alpha.y = EPS; // No filtering (DC gain = 1)
        }

        sigma = vec3(alpha.x, alpha.y, alpha.y);
        Taps = min(ceil(log(FILTER_THRESHOLD_ANALOG) / log(max(max(alpha.x, alpha.y), EPS))), MAX_TAPS);

        // Calculate the centroid of the impulse response
        vec2 num = vec2(0.0);
        vec2 denom = vec2(0.0);

        for (int k = 0; k < int(Taps); ++k) {
            vec2 h = (1.0 - alpha) * pow(alpha, vec2(float(k)));
            num += float(k) * h;
            denom += h;
        }

        vec2 centroid_offset = num / vec2(max(denom.x, EPS), max(denom.y, EPS));

        kernelGain = vec3(max(max(centroid_offset.x, centroid_offset.y), centroid_offset.y));
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec3 sigma;
layout(location = 2) flat in vec3 kernelGain;
layout(location = 3) flat in float FrameWidth;
layout(location = 4) flat in float FrameHeight;
layout(location = 5) flat in float DataLength;
layout(location = 6) flat in float Taps;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
#ifdef OPTION_DEBUG
    if (SYS_COMPONENT_BYPASS >= 1.0) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    if (SYS_COMPONENT_FILTER_BYPASS >= 1.0) {
        vec4 source_sample = texture(Source, vTexCoord);
        vec3 yc = rgb_to_luma_chroma(source_sample.rgb);
        yc.r += source_sample.a;
        FragColor = vec4(yc, 0.0);
        return;
    }
#endif  // OPTION_DEBUG

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float output_x = floor(UV.x);
    float output_y = floor(UV.y);

    if (output_x >= FrameWidth || output_y >= FrameHeight) {
        FragColor = vec4(0.0);
        return;
    }

    float output_index = output_y * FrameWidth + output_x;
    if (output_index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    int n_taps = int(Taps);
    vec3 outycc = vec3(0.0);

    if (SYS_YC_FILTER_TYPE < 0.5) {
        vec3 accum = vec3(0.0);
        int center = (n_taps - 1) / 2;

        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = k - center;
            float dt = float(tap_offset);
            vec3 coeff = vec3(
                gaussian(dt, sigma.x),
                gaussian(dt, sigma.y),
                gaussian(dt, sigma.z));
            vec4 rgbs = fetch_input_sample(Source, config.SourceSize.xy, output_index + dt, FrameWidth, DataLength - 1.0);

            vec3 ycc = rgb_to_luma_chroma(rgbs.rgb);
            ycc.r += rgbs.a;

            accum += coeff * ycc;
        }
        outycc = accum / kernelGain;
    } else {
        vec3 filter_gain = vec3(0.0);
        vec3 accum = vec3(0.0);
        vec3 alpha = sigma;
        ivec3 centroid_offset = ivec3(int(kernelGain.x + 0.5), int(kernelGain.y + 0.5), int(kernelGain.z + 0.5));
        ivec3 output_indices = ivec3(int(output_index + 0.5), int(output_index + 0.5), int(output_index + 0.5));

        output_indices -= centroid_offset - (n_taps - 1) / 2;
        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = n_taps - 1 - k;
            float dt = float(tap_offset);
            vec3 coeff = (1.0 - alpha) * pow(alpha, vec3(dt));
            vec4 rgbs = vec4(
                fetch_input_sample(Source, config.SourceSize.xy, float(output_indices.x) - dt, FrameWidth, DataLength - 1.0).r,
                fetch_input_sample(Source, config.SourceSize.xy, float(output_indices.y) - dt, FrameWidth, DataLength - 1.0).g,
                fetch_input_sample(Source, config.SourceSize.xy, float(output_indices.z) - dt, FrameWidth, DataLength - 1.0).b,
                fetch_input_sample(Source, config.SourceSize.xy, float(output_indices.x) - dt, FrameWidth, DataLength - 1.0).a
                );

            vec3 ycc = rgb_to_luma_chroma(rgbs.rgb);
            ycc.r += rgbs.a;

            accum += coeff * ycc;
            filter_gain += coeff;
        }
        outycc = accum / vec3(max(filter_gain.x, EPS), max(filter_gain.y, EPS), max(filter_gain.z, EPS));
    }

    FragColor = vec4(outycc, 0.0);
}
