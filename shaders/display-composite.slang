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
#include "filter-taps.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/display-composite.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_COMPOSITE_PREFILTER_HEADER " —— Debug Display Composite Prefilter —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPOSITE_PREFILTER_BYPASS "Bypass display composite prefilter" 0.0 0.0 1.0 1.0
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
    float DISPLAY_BANDPASS_WIDTH;
    float DISPLAY_BANDPASS_ATTEN_DB;

#ifdef OPTION_DEBUG
    float DISPLAY_COMPOSITE_PREFILTER_BYPASS;
#endif  // OPTION_DEBUG
} config;

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
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

    vec2 bandwidth = 0.5e6 * vec2(config.DISPLAY_BANDPASS_WIDTH, config.DISPLAY_BANDPASS_WIDTH);
    FilterSigma = fs * vec2(
        gaussian_sigma(bandwidth.x, config.DISPLAY_BANDPASS_ATTEN_DB),
        gaussian_sigma(bandwidth.y, config.DISPLAY_BANDPASS_ATTEN_DB));
    float support = gaussian_decay_time(max(FilterSigma.x, FilterSigma.y), FILTER_THRESHOLD_ANALOG);
    Taps = min(2.0 * ceil(support) + 1.0, float(DISPLAY_COMPOSITE_MAX_TAPS));

    vec2 carrier_response = vec2(0.0);
    for (int k = 0; k < int(Taps); ++k) {
        float t = float(k) - (Taps - 1.0) / 2.0;
        vec2 h = vec2(gaussian(t, FilterSigma.x), gaussian(t, FilterSigma.y));
        carrier_response += h * cos(ChromaFrequency * t) * cos(ChromaFrequency * t);
    }
    FilterGain = max(carrier_response, vec2(EPS));
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
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

vec2 filter_notch_bandpass(float index, float composite)
{
    vec2 accum = vec2(0.0);
    for (int k = 0; k < int(Taps); ++k) {
        float t = float(k) - (Taps - 1.0) / 2.0;
        float sample_cv = fetch_input_sample(
            Source, config.SourceSize.xy, index + t, FrameWidth, DataLength - 1.0).r;
        vec2 h = vec2(gaussian(t, FilterSigma.x), gaussian(t, FilterSigma.y));
        accum += h * cos(ChromaFrequency * t) * sample_cv;
    }

    vec2 band = accum / FilterGain;
    float y = config.DISPLAY_BANDPASS_ATTEN_DB > 0.0 ? composite - band.x : composite;
    float c = config.DISPLAY_BANDPASS_ATTEN_DB > 0.0 ? band.y : composite;
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

    // Comb modes will select their own separation here; until implemented,
    // every mode uses the notch/bandpass fallback.
    vec2 yc = ChromaFrequency > 0.0
        ? filter_notch_bandpass(index, composite) : vec2(composite, 0.0);
    FragColor = vec4(yc, 0.0, 1.0);
}
