#version 450

// Filename: display-component.slang
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
// Display-side component decoder
// ------------------------------
// Input: Real YPbPr voltage
// Output: Real RGB voltage
//
// Implements a polyphase decimator with Kaiser-windowed sinc low-pass prototypes,
// following the same sample-domain resampling model as `display-rgb.slang`.
// Separate filter designs are used for luma (Y) and chroma (Pb/Pr), based on the
// corresponding cutoff and stopband parameters in `display-component.inc`.
//
// After resampling/filtering in the YPbPr domain, component gain/bias are
// applied, the signal is decoded to RGB, and the final RGB amplifier plus
// blue-only toggle are applied.

#pragma name DisplayComponent
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/display-component.inc"
#include "menus/parameters/display-rgb-amp.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/user-uncommon.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_COMPONENT_HEADER " —— Debug Display Component —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPONENT_BYPASS "Bypass display component stage" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_COMPONENT_FILTER_BYPASS "Bypass display component filter" 0.0 0.0 1.0 1.0
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
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;

    float DISPLAY_CUTOFF_Y;
    float DISPLAY_CUTOFF_C;
    float DISPLAY_STOPBAND_Y;
    float USER_BLUE_ONLY;

    float BW_MODE;
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
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define DSP_OUTPUT_FS config.DSP_OUTPUT_FS

#define DISPLAY_CUTOFF_Y config.DISPLAY_CUTOFF_Y
#define DISPLAY_CUTOFF_C config.DISPLAY_CUTOFF_C
#define DISPLAY_STOPBAND_Y config.DISPLAY_STOPBAND_Y
#define USER_BLUE_ONLY config.USER_BLUE_ONLY

#define BW_MODE config.BW_MODE

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float DISPLAY_STOPBAND_C;

    float DISPLAY_GAIN_Y;
    float DISPLAY_GAIN_C;
    float DISPLAY_BIAS_Y;
    float DISPLAY_BIAS_C;
    float DISPLAY_GAIN_R;
    float DISPLAY_GAIN_G;
    float DISPLAY_GAIN_B;
    float DISPLAY_BIAS_R;
    float DISPLAY_BIAS_G;
    float DISPLAY_BIAS_B;

#ifdef OPTION_DEBUG
    float DISPLAY_COMPONENT_FILTER_BYPASS;
    float DISPLAY_COMPONENT_BYPASS;
#endif  // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define DISPLAY_COMPONENT_FILTER_BYPASS global.DISPLAY_COMPONENT_FILTER_BYPASS
#define DISPLAY_COMPONENT_BYPASS global.DISPLAY_COMPONENT_BYPASS
#endif  // OPTION_DEBUG

#define DISPLAY_STOPBAND_C global.DISPLAY_STOPBAND_C

#define DISPLAY_GAIN_Y global.DISPLAY_GAIN_Y
#define DISPLAY_GAIN_C global.DISPLAY_GAIN_C
#define DISPLAY_BIAS_Y global.DISPLAY_BIAS_Y
#define DISPLAY_BIAS_C global.DISPLAY_BIAS_C
#define DISPLAY_GAIN_R global.DISPLAY_GAIN_R
#define DISPLAY_GAIN_G global.DISPLAY_GAIN_G
#define DISPLAY_GAIN_B global.DISPLAY_GAIN_B
#define DISPLAY_BIAS_R global.DISPLAY_BIAS_R
#define DISPLAY_BIAS_G global.DISPLAY_BIAS_G
#define DISPLAY_BIAS_B global.DISPLAY_BIAS_B

struct KaiserFilter {
    float fc_norm;
    float taps;
    float beta;
    float gain;
};

struct PolyphaseFilter {
    float Delta;
};

const int MAX_TAPS = 37;
const float KAISER_ATTEN_DB = 40.0;

float compute_kaiser_gain(KaiserFilter filt)
{
    float sum = 0.0;
    int center = int((filt.taps - 1.0) / 2.0);

    for (int k = 0; k < int(filt.taps); ++k) {
        int tap_offset = k - center;
        float w = kaiser(float(tap_offset), filt.taps, filt.beta);
        float coeff = sinc(float(tap_offset), filt.fc_norm) * w;
        sum += coeff;
    }

    return max(sum, EPS);
}

KaiserFilter design_kaiser_filter(float cutoff_mhz, float stopband_mhz, float fs_out)
{
    KaiserFilter filt;

    float cutoff = cutoff_mhz * 1.0e6;
    float stopband = max(cutoff_mhz, stopband_mhz) * 1.0e6;
    float trans_width = max(stopband - cutoff, EPS);
    float delta_omega = 2.0 * PI * trans_width / max(fs_out, EPS);

    filt.fc_norm = min(cutoff / max(fs_out, EPS), 0.5 - EPS);
    filt.beta = kaiser_beta_from_atten(KAISER_ATTEN_DB);

    float taps_calc = min(
        (KAISER_ATTEN_DB - 8.0) / (2.285 * max(delta_omega, EPS)),
        float(MAX_TAPS));
    filt.taps = float(int(ceil(taps_calc)) | 1);
    filt.gain = compute_kaiser_gain(filt);

    return filt;
}

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 2) flat out KaiserFilter yfilt;
layout(location = 6) flat out KaiserFilter cfilt;
layout(location = 10) flat out PolyphaseFilter pfilt;
layout(location = 11) flat out vec3 gain;
layout(location = 12) flat out vec3 bias;
layout(location = 13) flat out float OutputFrameHeight;
layout(location = 14) flat out float InputDataLength;
layout(location = 15) flat out float OutputDataLength;
layout(location = 16) flat out float InputFrameWidth;
layout(location = 17) flat out float OutputFrameWidth;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    OutputFrameHeight = contract_frame_height(
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

    InputFrameWidth = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    OutputFrameWidth = contract_output_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    InputDataLength = max(contract_data_length(InputFrameWidth, OutputFrameHeight), 1.0);
    OutputDataLength = max(contract_data_length(OutputFrameWidth, OutputFrameHeight), 1.0);
    pfilt.Delta = OutputDataLength / max(InputDataLength, 1.0);

    float OutputSampleRate = contract_output_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    yfilt = design_kaiser_filter(DISPLAY_CUTOFF_Y, DISPLAY_STOPBAND_Y, OutputSampleRate);
    cfilt = design_kaiser_filter(DISPLAY_CUTOFF_C, DISPLAY_STOPBAND_C, OutputSampleRate);

    gain = vec3(
        db_to_linear(DISPLAY_GAIN_Y),
        db_to_linear(DISPLAY_GAIN_C),
        db_to_linear(DISPLAY_GAIN_C));
    bias = vec3(
        DISPLAY_BIAS_Y * 10e-3,
        DISPLAY_BIAS_C * 10e-3,
        DISPLAY_BIAS_C * 10e-3);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 2) flat in KaiserFilter yfilt;
layout(location = 6) flat in KaiserFilter cfilt;
layout(location = 10) flat in PolyphaseFilter pfilt;
layout(location = 11) flat in vec3 gain;
layout(location = 12) flat in vec3 bias;
layout(location = 13) flat in float OutputFrameHeight;
layout(location = 14) flat in float InputDataLength;
layout(location = 15) flat in float OutputDataLength;
layout(location = 16) flat in float InputFrameWidth;
layout(location = 17) flat in float OutputFrameWidth;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= OutputFrameWidth || output_y >= OutputFrameHeight) {
        FragColor = vec4(0.0);
        return;
    }

    float field_output_index = output_y * OutputFrameWidth + output_x;
    if (field_output_index < 0.0 || field_output_index >= OutputDataLength) {
        FragColor = vec4(0.0);
        return;
    }

    float Delta = pfilt.Delta;
    float invDelta = 1.0 / max(Delta, EPS);
    float input_sample_pos = field_output_index * invDelta;
    float input_pos_floor = floor(input_sample_pos);
    int input_index_int = int(input_pos_floor);
    float frac_offset = input_sample_pos - input_pos_floor;
    float input_data_limit = max(InputDataLength - 1.0, 0.0);
    float nearest_sample_index = clamp(floor(input_sample_pos + 0.5), 0.0, input_data_limit);
    vec4 center_sample = fetch_input_sample(Source, config.SourceSize.xy, nearest_sample_index, InputFrameWidth, input_data_limit);

    vec3 rgb_gain = vec3(
        db_to_linear(DISPLAY_GAIN_R),
        db_to_linear(DISPLAY_GAIN_G),
        db_to_linear(DISPLAY_GAIN_B));
    vec3 rgb_bias = vec3(
        DISPLAY_BIAS_R * 10e-3,
        DISPLAY_BIAS_G * 10e-3,
        DISPLAY_BIAS_B * 10e-3);

#ifdef OPTION_DEBUG
    if (DISPLAY_COMPONENT_BYPASS > 0.5) {
        FragColor = center_sample;
        return;
    }

    if (DISPLAY_COMPONENT_FILTER_BYPASS > 0.5) {
        vec3 ypbpr = gain * (center_sample.rgb + bias);
        vec3 color = rgb_gain * (YPbPr_TO_RGB * ypbpr + rgb_bias);
        color.r *= 1.0 - USER_BLUE_ONLY;
        color.g *= 1.0 - USER_BLUE_ONLY;
        FragColor = vec4(color, 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    vec3 filtered_ypbpr;
#ifdef OPTION_CRISPY
    float Tout = max(invDelta, EPS);
    float zoh_sum = 0.0;
    filtered_ypbpr = vec3(0.0);
    int zoh_taps = max(int(ceil(Tout)) + 1, 1);
    for (int k = 0; k < zoh_taps; ++k) {
        float coeff = zoh_area(float(k) - frac_offset, 1.0, Tout);
        float sample_index = clamp(float(input_index_int + k), 0.0, input_data_limit);
        filtered_ypbpr += coeff * fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).rgb;
        zoh_sum += coeff;
    }
    filtered_ypbpr /= max(zoh_sum, EPS);
#else
    float y_out = 0.0;
    int n_taps_y = int(yfilt.taps);
    int center_y = (n_taps_y - 1) / 2;
    for (int k = 0; k < n_taps_y; ++k) {
        int tap_offset = k - center_y;
        float w = kaiser(float(tap_offset), yfilt.taps, yfilt.beta);
        float coeff = sinc(float(tap_offset) - frac_offset, yfilt.fc_norm) * w;
        float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
        y_out += coeff * fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).r;
    }
    y_out /= yfilt.gain;

    vec2 c_out = vec2(0.0);
    int n_taps_c = int(cfilt.taps);
    int center_c = (n_taps_c - 1) / 2;
    for (int k = 0; k < n_taps_c; ++k) {
        int tap_offset = k - center_c;
        float w = kaiser(float(tap_offset), cfilt.taps, cfilt.beta);
        float coeff = sinc(float(tap_offset) - frac_offset, cfilt.fc_norm) * w;
        float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
        c_out += coeff * fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).gb;
    }
    c_out /= cfilt.gain;

    filtered_ypbpr = vec3(y_out, c_out);
#endif  // OPTION_CRISPY

    vec3 ypbpr = gain * (filtered_ypbpr + bias);

    if (BW_MODE < 0.5) {
        // YPbPr (full color)
    } else if (BW_MODE < 1.5) {
        // Y only
        ypbpr.gb = vec2(0.0);
    } else if (BW_MODE < 2.5) {
        // Pb only
        ypbpr.rb = vec2(0.0);
    } else if (BW_MODE < 3.5) {
        // Pr only
        ypbpr.rg = vec2(0.0);
    } else if (BW_MODE < 4.5) {
        // Y + Pb
        ypbpr.b = 0.0;
    } else if (BW_MODE < 5.5) {
        // Y + Pr
        ypbpr.g = 0.0;
    } else {
        // Pb + Pr
        ypbpr.r = 0.0;
    }

    vec3 color = rgb_gain * (YPbPr_TO_RGB * ypbpr + rgb_bias);
    color.r *= 1.0 - USER_BLUE_ONLY;
    color.g *= 1.0 - USER_BLUE_ONLY;

    FragColor = vec4(color, 1.0);
}
