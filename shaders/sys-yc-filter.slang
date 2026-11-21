#version 450

// Filename: sys-yc-filter.slang
//
// Copyright (C) 2026 W. M. Martinez
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
// System Y/C filter for the packed DSP sample stream.
// Input and output: luma in R, modulated chroma in G.
// C bandwidth is the baseband prototype bandwidth, i.e. half the bandpass width.
// The sampled sidebands can overlap near DC or Nyquist; kernel support is
// limited by the generated tap cap, including at automatic working rates.

#pragma name SysYCFilter
#pragma format R16G16_SFLOAT

#include "common.inc"
#include "filter-taps.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-component.inc"
#include "menus/parameters/sys-encode.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_YC_FILTER_HEADER " —— Debug Sys YC Filter —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_YC_FILTER_BYPASS "Bypass system YC filter" 0.0 0.0 1.0 1.0
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
    float SYS_YC_FILTER_TYPE;
    float SYS_BANDWIDTH_Y;
    float SYS_BANDWIDTH_C;
    float SYS_CUTOFF_ATTEN_Y;
    float SYS_CUTOFF_ATTEN_C;
    float SVIDEO;

#ifdef OPTION_DEBUG
    float SYS_YC_FILTER_BYPASS;
#endif
} config;

#define SVIDEO config.SVIDEO

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out vec2 FilterParam;
layout(location = 2) flat out vec2 FilterGain;
layout(location = 3) flat out float ChromaFrequency;
layout(location = 4) flat out float LumaDelay;
layout(location = 5) flat out float FrameWidth;
layout(location = 6) flat out float FrameHeight;
layout(location = 7) flat out float DataLength;
layout(location = 8) flat out float Taps;

const float MAX_TAPS = float(SYS_YC_FILTER_MAX_TAPS);

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float fs = contract_working_sample_rate(
        config.OriginalFPS, config.SC_FREQ_MODE, config.SC_FREQ,
        config.PIXEL_CLOCK_MODE, config.PIXEL_CLOCK,
        config.H_FREQ_MODE, config.H_FREQ, config.DSP_WORKING_FS);
    FrameWidth = contract_working_frame_width(
        config.OriginalFPS, config.SC_FREQ_MODE, config.SC_FREQ,
        config.PIXEL_CLOCK_MODE, config.PIXEL_CLOCK,
        config.H_FREQ_MODE, config.H_FREQ, config.DSP_WORKING_FS);
    FrameHeight = contract_frame_height(
        config.OriginalSize.xy, config.OriginalFPS,
        config.V_FREQ_MODE, config.V_FREQ, config.SC_FREQ_MODE, config.SC_FREQ,
        config.PIXEL_CLOCK_MODE, config.PIXEL_CLOCK, config.H_FREQ_MODE, config.H_FREQ);
    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);
    ChromaFrequency = 2.0 * PI * contract_subcarrier_freq_hz(
        config.OriginalFPS, config.SC_FREQ_MODE, config.SC_FREQ) / max(fs, EPS);

    vec2 bandwidth = 1.0e6 * vec2(config.SYS_BANDWIDTH_Y, config.SYS_BANDWIDTH_C);
    vec2 attenuation = vec2(config.SYS_CUTOFF_ATTEN_Y, config.SYS_CUTOFF_ATTEN_C);
    vec2 sigma_seconds = vec2(
        gaussian_sigma(bandwidth.x, attenuation.x),
        gaussian_sigma(bandwidth.y, attenuation.y));

    if (config.SYS_YC_FILTER_TYPE < 0.5) {
        FilterParam = sigma_seconds * fs;
        float support = gaussian_decay_time(max(sigma_seconds.x, sigma_seconds.y), FILTER_THRESHOLD_ANALOG) * fs;
        Taps = min(2.0 * ceil(support) + 1.0, MAX_TAPS);
    } else {
        vec2 cutoff = bandwidth;
        if (attenuation.x > 3.0) {
            cutoff.x = sqrt(log(2.0)) / max(2.0 * PI * sigma_seconds.x, EPS);
        }
        if (attenuation.y > 3.0) {
            cutoff.y = sqrt(log(2.0)) / max(2.0 * PI * sigma_seconds.y, EPS);
        }
        vec2 K = tan(PI * clamp(cutoff / max(fs, EPS), vec2(0.0), vec2(0.25)));
        FilterParam = clamp((1.0 - K) / (1.0 + K), vec2(0.0), vec2(1.0 - EPS));
        if (attenuation.x <= 0.0) {
            FilterParam.x = 0.0;
        }
        if (attenuation.y <= 0.0) {
            FilterParam.y = 0.0;
        }
        float alpha_max = max(FilterParam.x, FilterParam.y);
        Taps = clamp(ceil(log(FILTER_THRESHOLD_ANALOG) / log(max(alpha_max, EPS))), 1.0, MAX_TAPS);
    }

    vec2 gain = vec2(0.0);
    vec2 moment = vec2(0.0);
    vec2 image = vec2(0.0);
    vec2 image_moment = vec2(0.0);
    for (int k = 0; k < int(Taps); ++k) {
        float t = config.SYS_YC_FILTER_TYPE < 0.5 ? float(k) - (Taps - 1.0) / 2.0 : float(k);
        vec2 h;
        if (config.SYS_YC_FILTER_TYPE < 0.5) {
            h = vec2(gaussian(t, FilterParam.x), gaussian(t, FilterParam.y));
        } else {
            h = pow(max(FilterParam, vec2(EPS)), vec2(t));
        }
        gain += h;
        moment += t * h;
        vec2 image_tap = h.y * vec2(cos(2.0 * ChromaFrequency * t), sin(2.0 * ChromaFrequency * t));
        image += image_tap;
        image_moment += t * image_tap;
    }

    // Normalize the actual real bandpass response at the carrier, including
    // the negative-frequency image of the modulated prototype.
    vec2 carrier_response = vec2(gain.y + image.x, image.y);
    FilterGain = vec2(max(gain.x, EPS), max(length(carrier_response) * 0.5, EPS));
    float chroma_delay = dot(vec2(moment.y + image_moment.x, image_moment.y), carrier_response)
        / max(dot(carrier_response, carrier_response), EPS);
    if (attenuation.y <= 0.0) {
        chroma_delay = 0.0;
    }
    LumaDelay = config.SYS_YC_FILTER_TYPE < 0.5 ? 0.0 : chroma_delay - moment.x / max(gain.x, EPS);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec2 FilterParam;
layout(location = 2) flat in vec2 FilterGain;
layout(location = 3) flat in float ChromaFrequency;
layout(location = 4) flat in float LumaDelay;
layout(location = 5) flat in float FrameWidth;
layout(location = 6) flat in float FrameHeight;
layout(location = 7) flat in float DataLength;
layout(location = 8) flat in float Taps;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
#ifdef OPTION_DEBUG
    if (config.SYS_YC_FILTER_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
#endif

    vec2 pixel = floor(vTexCoord * config.OutputSize.xy);
    float index = pixel.y * FrameWidth + pixel.x;
    if (pixel.x >= FrameWidth || pixel.y >= FrameHeight || index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    vec2 accum = vec2(0.0);
    for (int k = 0; k < int(Taps); ++k) {
        float t = config.SYS_YC_FILTER_TYPE < 0.5 ? float(k) - (Taps - 1.0) / 2.0 : float(k);
        vec2 h;
        float sample_index;
        if (config.SYS_YC_FILTER_TYPE < 0.5) {
            h = vec2(gaussian(t, FilterParam.x), gaussian(t, FilterParam.y));
            sample_index = index + t;
        } else {
            h = pow(max(FilterParam, vec2(EPS)), vec2(t));
            sample_index = index - t;
        }

        vec2 sample_yc = fetch_input_sample(Source, config.SourceSize.xy, sample_index, FrameWidth, DataLength - 1.0).rg;
        float y = sample_yc.x;
        if (LumaDelay != 0.0) {
            float y_index = sample_index - LumaDelay;
            float y_floor = floor(y_index);
            float y0 = fetch_input_sample(Source, config.SourceSize.xy, y_floor, FrameWidth, DataLength - 1.0).r;
            float y1 = fetch_input_sample(Source, config.SourceSize.xy, y_floor + 1.0, FrameWidth, DataLength - 1.0).r;
            y = mix(y0, y1, fract(y_index));
        }
        accum.x += h.x * y;
        accum.y += h.y * cos(ChromaFrequency * t) * sample_yc.y;
    }

    vec2 yc = accum / FilterGain;
    if (config.SYS_CUTOFF_ATTEN_C <= 0.0) {
        yc.y = fetch_input_sample(Source, config.SourceSize.xy, index, FrameWidth, DataLength - 1.0).g;
    }
    vec2 cv = vec2(yc.r + yc.g, 0.0);
    yc = mix(cv, yc, SVIDEO);
    FragColor = vec4(yc, 0.0, 0.0);
}
