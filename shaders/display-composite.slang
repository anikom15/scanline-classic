#version 450

// Filename: display-composite.slang
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
// Display-side composite separation in the packed working-rate stream.
// Input: composite baseband in R. Output: luma in R, modulated chroma in G.
// Both widths specify the full bandwidth around the subcarrier.

#pragma name DisplayCompositePrefilter
#pragma format R16G16_SFLOAT

#include "common.inc"
#include "bandpass.inc"
#include "filter-taps.inc"
#include "contract.inc"
#include "dsp.inc"
#include "comb.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/display-composite.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_COMPOSITE_PREFILTER_HEADER " —— Debug Display Composite Prefilter —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPOSITE_PREFILTER_BYPASS "Bypass display composite prefilter" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_NOTCH_BYPASS "Bypass display luma notch" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_BANDPASS_BYPASS "Bypass display chroma bandpass" 0.0 0.0 1.0 1.0
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
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float DSP_WORKING_FS;
    float DISPLAY_BANDPASS_WIDTH;
    float DISPLAY_BANDPASS_ATTEN_DB;
    float COLOR_FILTER_MODE;
    float COMB_FILTER_LUMA_ADAPT;

#ifdef OPTION_DEBUG
    float DISPLAY_COMPOSITE_PREFILTER_BYPASS;
    float DISPLAY_NOTCH_BYPASS;
    float DISPLAY_BANDPASS_BYPASS;
#endif  // OPTION_DEBUG
    float PIXEL_CLOCK_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float SC_FREQ_FRAC11;
} config;

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float SC_FREQ_FRAC6;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out vec2 FilterSigma;
layout(location = 2) flat out vec2 FilterGain;
layout(location = 3) flat out float ChromaFrequency;
layout(location = 4) flat out float FrameWidth;
layout(location = 5) flat out float FrameHeight;
layout(location = 6) flat out float DataLength;
layout(location = 7) flat out float Taps;
layout(location = 8) flat out float HorizontalFrequency;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float fs = contract_working_sample_rate(
        config.OriginalFPS, config.SC_FREQ_MODE, timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11)),
        config.PIXEL_CLOCK_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)),
        config.H_FREQ_MODE, config.H_FREQ, config.DSP_WORKING_FS);
    FrameWidth = contract_working_frame_width(
        config.OriginalFPS, config.SC_FREQ_MODE, timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11)),
        config.PIXEL_CLOCK_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)),
        config.H_FREQ_MODE, config.H_FREQ, config.DSP_WORKING_FS);
    FrameHeight = contract_frame_height(
        config.OriginalSize.xy, config.OriginalFPS,
        config.V_FREQ_MODE, config.V_FREQ, config.SC_FREQ_MODE, timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11)),
        config.PIXEL_CLOCK_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)), config.H_FREQ_MODE, config.H_FREQ);
    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);
    ChromaFrequency = 2.0 * PI * contract_subcarrier_freq_hz(
        config.OriginalFPS, config.SC_FREQ_MODE, timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11))) / max(fs, EPS);
    HorizontalFrequency = contract_h_frequency(
        config.OriginalFPS, config.SC_FREQ_MODE, timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11)),
        config.PIXEL_CLOCK_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)),
        config.H_FREQ_MODE, config.H_FREQ);

    vec2 bandwidth = 0.5e6 * vec2(config.DISPLAY_BANDPASS_WIDTH, config.DISPLAY_BANDPASS_WIDTH);
    FilterSigma = fs * vec2(
        gaussian_sigma(bandwidth.x, config.DISPLAY_BANDPASS_ATTEN_DB),
        gaussian_sigma(bandwidth.y, config.DISPLAY_BANDPASS_ATTEN_DB));
    float support = gaussian_decay_time(max(FilterSigma.x, FilterSigma.y), FILTER_THRESHOLD_ANALOG);
    Taps = min(2.0 * ceil(support) + 1.0, float(DISPLAY_COMPOSITE_MAX_TAPS));

    float gain_x = gaussian_inphase_bandpass_gain(FilterSigma.x, ChromaFrequency, Taps);
    float gain_y = gaussian_inphase_bandpass_gain(FilterSigma.y, ChromaFrequency, Taps);
    FilterGain = max(vec2(gain_x, gain_y), vec2(EPS));
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec2 FilterSigma;
layout(location = 2) flat in vec2 FilterGain;
layout(location = 3) flat in float ChromaFrequency;
layout(location = 4) flat in float FrameWidth;
layout(location = 5) flat in float FrameHeight;
layout(location = 6) flat in float DataLength;
layout(location = 7) flat in float Taps;
layout(location = 8) flat in float HorizontalFrequency;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

vec2 filter_notch_bandpass(float index, float composite)
{
#ifdef OPTION_DEBUG
    if (config.DISPLAY_BANDPASS_BYPASS > 0.5) {
        return vec2(composite, 0.0);
    }
#endif

    vec2 accum = vec2(0.0);
    float weight = 0.0;
    float carrier_cos = 0.0;
    float carrier_square = 0.0;
    float dc_accum = 0.0;
    for (int k = 0; k < int(Taps); ++k) {
        float t = float(k) - (Taps - 1.0) / 2.0;
        float sample_cv = fetch_input_sample(
            Source, config.SourceSize.xy, index + t, FrameWidth, DataLength - 1.0).r;
        vec2 h = vec2(gaussian(t, FilterSigma.x), gaussian(t, FilterSigma.y));
        accum.x += gaussian_carrier_kernel(t, FilterSigma.x, ChromaFrequency) * sample_cv;
        accum.y += gaussian_carrier_kernel(t, FilterSigma.y, ChromaFrequency) * sample_cv;
        float carrier = cos(ChromaFrequency * t);
        weight += h.x;
        carrier_cos += h.x * carrier;
        carrier_square += h.x * carrier * carrier;
        dc_accum += h.x * sample_cv;
    }

    vec2 band = accum / FilterGain;
    float notch_component = gaussian_dc_orthogonal_notch(
        accum.x, dc_accum, weight, carrier_cos, carrier_square);
    float y = config.DISPLAY_BANDPASS_ATTEN_DB > 0.0
#ifdef OPTION_DEBUG
        && config.DISPLAY_NOTCH_BYPASS < 0.5
#endif
        ? composite - notch_component : composite;
    float c = config.DISPLAY_BANDPASS_ATTEN_DB > 0.0
        ? band.y : composite;
    return vec2(y, c);
}

void main()
{
    vec2 pixel = floor(vTexCoord * config.OutputSize.xy);
    float index = pixel.y * FrameWidth + pixel.x;
    if (pixel.x >= FrameWidth || pixel.y >= FrameHeight || index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    float composite = fetch_input_sample(
        Source, config.SourceSize.xy, index, FrameWidth, DataLength - 1.0).r;

#ifdef OPTION_DEBUG
    if (config.DISPLAY_COMPOSITE_PREFILTER_BYPASS > 0.5) {
        FragColor = vec4(composite, 0.0, 0.0, 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    vec2 notch = ChromaFrequency > 0.0
        ? filter_notch_bandpass(index, composite) : vec2(composite, 0.0);
    vec2 yc = notch;

    bool use_comb = config.COLOR_FILTER_MODE >= 1.0;
    bool adaptive_comb = config.COLOR_FILTER_MODE >= 1.5;

    if (use_comb && ChromaFrequency > 0.0 && HorizontalFrequency > 0.0) {
        float subcarrier_frequency = ChromaFrequency / (2.0 * PI);
        float system_phase_shift = comb_system_phase_shift(
            subcarrier_frequency, HorizontalFrequency);
        float phase_offset = comb_phase_offset(PI, system_phase_shift, ChromaFrequency);

        float previous_line = fetch_comb_line_sample(
            Source, config.SourceSize.xy, pixel.x - phase_offset, pixel.y - 1.0,
            FrameWidth, DataLength, 0);
        float y_comb = 0.5 * (composite + previous_line);
        float c_comb = 0.5 * (composite - previous_line);

        if (adaptive_comb) {
            float correlation = comb_point_correlation(
                abs(composite), abs(previous_line));
            float luma_weight = smoothstep(
                config.COMB_FILTER_LUMA_ADAPT - 0.05,
                config.COMB_FILTER_LUMA_ADAPT + 0.05,
                correlation);
            yc = vec2(mix(notch.x, y_comb, luma_weight), c_comb);
        } else {
            yc = vec2(y_comb, c_comb);
        }
    }

    FragColor = vec4(yc, 0.0, 1.0);
}
