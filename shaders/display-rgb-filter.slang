#version 450

// Filename: display-rgb.slang
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
// Display-side RGB filter
// -----------------------
// Input: Real RGB voltage
// Output: Real RGB voltage
//
// Implements a polyphase FIR resampler with a Kaiser windowed-sinc
// prototype filter, designed from user cutoff and stopband parameters.
// The vertex shader computes the filter parameters and polyphase
// factors based on the input and output sizes, while the fragment
// shader applies the filter to produce the final output color.
//
// When the filter is bypassed for debugging, nearest-sample Dirac evaluation
// is used. Under crispy mode, a ZOH area-average resample path is used.

#pragma name DisplayRGBBandlimitFIR
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "filter-taps.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/user-uncommon.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/display-rgb-amp.inc"
#include "menus/parameters/display-rgb-filter.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_RGB_BANDLIMIT_HEADER " —— Debug Display RGB Bandlimit —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_RGB_FILTER_BYPASS "Bypass display RGB filter" 0.0 0.0 1.0 1.0
#pragma parameter DESKEW_BYPASS "Bypass integrated deskew" 0.0 0.0 1.0 1.0
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
    float H_BLANK_FUZZ;
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;

    float BW_MODE;

    float DISPLAY_CUTOFF;
    float DISPLAY_STOPBAND;
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

#define BW_MODE config.BW_MODE

#define DISPLAY_CUTOFF config.DISPLAY_CUTOFF
#define DISPLAY_STOPBAND config.DISPLAY_STOPBAND

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;

#ifdef OPTION_DEBUG
    float DISPLAY_RGB_FILTER_BYPASS;
    float DESKEW_BYPASS;
#endif  // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define DISPLAY_RGB_FILTER_BYPASS global.DISPLAY_RGB_FILTER_BYPASS
#define DESKEW_BYPASS global.DESKEW_BYPASS
#endif  // OPTION_DEBUG

struct KaiserFilter {
    float fc_norm;  // Normalized cutoff frequency (0..0.5)
    float taps;     // Number of filter taps (should be odd)
    float beta;     // Kaiser window beta parameter
    float gain;     // Precomputed gain factor for normalization
};

struct PolyphaseFilter {
    float Delta;  // Resampling ratio (output / input)
    float taps;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 2) flat out KaiserFilter kfilt;
layout(location = 6) flat out PolyphaseFilter pfilt;
layout(location = 8) flat out float OutputFrameHeight;
layout(location = 9) flat out float InputDataLength;
layout(location = 10) flat out float OutputDataLength;
layout(location = 11) flat out float InputFrameWidth;
layout(location = 12) flat out float OutputFrameWidth;
layout(location = 13) flat out float DeskewSampleRatio;
layout(location = 14) flat out float LineCarryClocksOut;
layout(location = 15) flat out float ClockFactorOut;

const int MAX_TAPS = DISPLAY_RGB_FILTER_MAX_TAPS;
const float KAISER_ATTEN_DB = 40.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float BaseFrameWidth = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    float InputFrameHeight = contract_frame_height(
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
    float fs_original = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);
    float LineCarryClocks = contract_line_carry_clocks(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    float ClockFactor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    float WorkingSampleRate = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
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

    // Keep widths as float varyings for cross-driver safety, but the contract
    // guarantees they are integral-valued.
    float fs_out = OutputSampleRate;

    OutputFrameHeight = InputFrameHeight;
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

    DeskewSampleRatio = fs_out / max(fs_original, EPS);
    LineCarryClocksOut = LineCarryClocks;
    ClockFactorOut = ClockFactor;

    // Polyphase resampler ratio is data-length driven rather than texture-size driven.
    float Delta = OutputDataLength / max(InputDataLength, 1.0);

    pfilt.Delta = Delta;

    // Kaiser window design from cutoff and stopband
    float cutoff = DISPLAY_CUTOFF * 1.0e6;
    float stopband = DISPLAY_STOPBAND * 1.0e6;

    // FIR cutoff is the user cutoff
    kfilt.fc_norm = cutoff / fs_out;

    float trans_width = display_transition_width_hz(cutoff, stopband);
    float delta_omega = 2.0 * PI * trans_width / fs_out; // radians/sample
    float beta_precise = kaiser_beta_from_atten(KAISER_ATTEN_DB);
    float taps_calc = min((KAISER_ATTEN_DB - 8.0) / (2.285 * max(delta_omega, EPS)), MAX_TAPS);
    kfilt.taps = float(int(ceil(taps_calc)) | 1); // force odd
    kfilt.beta = beta_precise;

    // Precompute gain for normalization
    float sum = 0.0;
    int center = int((kfilt.taps - 1.0) / 2.0);
    for (int k = 0; k < int(kfilt.taps); ++k) {
        int tap_offset = k - center;
        float w = kaiser(float(tap_offset), kfilt.taps, kfilt.beta);
        float coeff = sinc(float(tap_offset), kfilt.fc_norm) * w;
        sum += coeff;
    }
    kfilt.gain = sum;

    pfilt.taps = kfilt.taps;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 2) flat in KaiserFilter kfilt;
layout(location = 6) flat in PolyphaseFilter pfilt;
layout(location = 8) flat in float OutputFrameHeight;
layout(location = 9) flat in float InputDataLength;
layout(location = 10) flat in float OutputDataLength;
layout(location = 11) flat in float InputFrameWidth;
layout(location = 12) flat in float OutputFrameWidth;
layout(location = 13) flat in float DeskewSampleRatio;
layout(location = 14) flat in float LineCarryClocksOut;
layout(location = 15) flat in float ClockFactorOut;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

float compute_row_shift_output_samples(int output_y_i)
{
    int carry_clocks = int(LineCarryClocksOut);
    int clock_factor = int(ClockFactorOut);
    int row_carry_clocks = (clock_factor > 0)
        ? (output_y_i * carry_clocks) % clock_factor
        : 0;

#ifdef OPTION_DEBUG
    return mix(float(row_carry_clocks) * DeskewSampleRatio, 0.0, DESKEW_BYPASS);
#else
    return float(row_carry_clocks) * DeskewSampleRatio;
#endif  // OPTION_DEBUG
}

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

    float Delta = pfilt.Delta;
    float invDelta = 1.0 / max(Delta, EPS);
    int n_taps = int(pfilt.taps);
    int center = (n_taps - 1) / 2;

    float row_shift_output = compute_row_shift_output_samples(output_y_i);
    float deskewed_output_x = output_x + row_shift_output;

    float field_output_index = output_y * OutputFrameWidth + deskewed_output_x;
    if (field_output_index < 0.0 || field_output_index >= OutputDataLength) {
        FragColor = vec4(0.0);
        return;
    }

    float input_sample_pos = field_output_index * invDelta;
    float input_pos_floor = floor(input_sample_pos);
    int input_index_int = int(input_pos_floor);
    float frac_offset = input_sample_pos - input_pos_floor;
    float input_data_limit = max(InputDataLength - 1.0, 0.0);

    vec3 color = vec3(0.0);

#ifdef OPTION_DEBUG
    if (DISPLAY_RGB_FILTER_BYPASS > 0.5) {
        float sample_index = clamp(floor(input_sample_pos + 0.5), 0.0, input_data_limit);
        color = fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).rgb;
    } else {
#endif  // OPTION_DEBUG

#ifdef OPTION_CRISPY
    float Tout = max(invDelta, EPS);
    float zoh_sum = 0.0;
    int zoh_taps = max(int(ceil(Tout)) + 1, 1);
    for (int k = 0; k < zoh_taps; ++k) {
        float coeff = zoh_area(float(k) - frac_offset, 1.0, Tout);
        float sample_index = clamp(float(input_index_int + k), 0.0, input_data_limit);
        vec3 rgb = fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).rgb;

        color += coeff * rgb;
        zoh_sum += coeff;
    }
    color /= max(zoh_sum, EPS);
#else
    // Standard FIR convolution (Kaiser)
    for (int k = 0; k < n_taps; ++k) {
        int tap_offset = k - center;
        float w = kaiser(float(tap_offset), kfilt.taps, kfilt.beta);
        float coeff = sinc(float(tap_offset - frac_offset), kfilt.fc_norm) * w;
        float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
        vec3 rgb = fetch_input_sample(Source, config.SourceSize.xy, sample_index, InputFrameWidth, input_data_limit).rgb;

        color += coeff * rgb;
    }
    color /= kfilt.gain;
#endif  // OPTION_CRISPY

#ifdef OPTION_DEBUG
    }  // end filter bypass
#endif  // OPTION_DEBUG

    if (BW_MODE < 0.5) {
        // RGB
    } else if (BW_MODE < 1.5) {
        // R only
        color.gb = vec2(0.0);
    } else if (BW_MODE < 2.5) {
        // G only
        color.rb = vec2(0.0);
    } else if (BW_MODE < 3.5) {
        // B only
         color.rg = vec2(0.0);
    } else if (BW_MODE < 4.5) {
        // R+G
        color.b = 0.0;
    } else if (BW_MODE < 5.5) {
        // R+B
        color.g = 0.0;
    } else {
        // G+B
        color.r = 0.0;
    }

    FragColor = vec4(color, 1.0);
}
