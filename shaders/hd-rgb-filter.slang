#version 450

// Filename: hd-rgb-filter.slang
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
// High Definition RGB Filter
// ---------------------------
// Input: Real RGB voltage
// Output: Real RGB voltage
//
// Implements a polyphase FIR resampler with a Kaiser windowed sinc
// prototype filter to downsample or upsample working sample rate
// to output sample rate, maintaining the original frame rate and
// horizontal timing.
//
// The display type can be selected to limit output formats.  The
// following types are supported:
//   - EDTV: 480p, 576p
//   - Hi-Vision: 480p, 576p, 1080i (most consumer HDTV CRTs)
//   - Standard HDTV: 480p, 576p, 720p, 1080i (most PVMs and BVMs)
//   - Progressive-only HDTV: 480p, 576p, 720p, 1080p (LCD, most plasmas)
//   - Full HDTV: 480p, 576p, 720p, 1080i, 1080p (some CRTs, high-end plasmas)
//
// The following output modes are used:
//   - EDTV: up to 1262 samples per line, 19.71 MHz output rate
//   - Hi-Vision: up to 3212 samples per line, 108.405 MHz output rate
//   - Standard HDTV: up to 3212 samples per line, 108.405 MHz output rate
//   - Progressive-only HDTV: up to 3212 samples per line, 216.81 MHz output rate
//   - Full HDTV: up to 3212 samples per line, 216.81 MHz output rate

#pragma name HDRGBFilter
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/user-uncommon.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/display-rgb-amp.inc"
#include "menus/parameters/display-hd.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#include "raster-mapping.inc"
#define TIMING_PROFILE_MODE timingProfileMode

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
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float HD_DISPLAY_TYPE;

    float BW_MODE;

    float DISPLAY_CUTOFF;
    float DISPLAY_STOPBAND;
    float PIXEL_CLOCK_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float SC_FREQ_FRAC11;
    float SC_FREQ_FRAC6;
} config;

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, global.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, config.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)
#define HD_DISPLAY_TYPE config.HD_DISPLAY_TYPE

#define BW_MODE config.BW_MODE

#define DISPLAY_CUTOFF config.DISPLAY_CUTOFF
#define DISPLAY_STOPBAND config.DISPLAY_STOPBAND

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
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
layout(location = 11) flat out double InputFrameWidth;
layout(location = 12) flat out double OutputFrameWidth;
layout(location = 16) flat out float InputPackedWidth;
layout(location = 17) flat out float InputTextureFits;
layout(location = 18) flat out float BaseFrameWidthOut;
layout(location = 13) flat out float DeskewSampleRatio;
layout(location = 14) flat out float LineCarryClocksOut;
layout(location = 15) flat out float ClockFactorOut;
layout(location = 19) flat out vec4 vRasterPattern;
layout(location = 20) flat out ivec2 vRasterExceptions;

const int MAX_TAPS = 37;
const float KAISER_ATTEN_DB = 50.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    int timingProfileMode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);
    timing_profile_raster_descriptor(TIMING_PROFILE_MODE, config.OriginalSize.y, global.FrameCount,
        global.FIELD_ODD, vRasterPattern, vRasterExceptions);

    float InputFrameHeight = contract_frame_height(
        config.OriginalSize.xy, config.OriginalFPS,
        V_FREQ_MODE, V_FREQ,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ
    );
    float OriginalFs = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK
    );
    float LineCarryClocks = contract_line_carry_clocks(
        config.OriginalSize.xy, config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ, H_BLANK_FUZZ
    );
    float ClockFactor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ, H_BLANK_FUZZ
    );
    if (TIMING_PROFILE_MODE > 0)
        LineCarryClocks = 0.0;
    BaseFrameWidthOut = contract_frame_width(
        config.OriginalFPS, SC_FREQ_MODE, SC_FREQ, PIXEL_CLOCK_MODE, PIXEL_CLOCK, H_FREQ_MODE, H_FREQ);
    dvec2 OutputFsSPL = contract_auto_hd_aa_fs_spl(
        config.OriginalSize.xy, config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ,
        V_FREQ_MODE, V_FREQ,
        HD_DISPLAY_TYPE
    );

    float OutputFs = float(OutputFsSPL.x);

    OutputFrameHeight = InputFrameHeight;
    InputFrameWidth = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ,
        DSP_WORKING_FS
    ), DSP_WORKING_FS);
    OutputFrameWidth = timing_profile_rate_width(TIMING_PROFILE_MODE, OutputFsSPL.y, OutputFs / 1.0e6);
    InputDataLength = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, InputFrameWidth,
        contract_data_length(InputFrameWidth, OutputFrameHeight)), 1.0);
    InputPackedWidth = contract_pixel_packed_width(InputDataLength);
    InputTextureFits = contract_pixel_texture_fits(config.SourceSize.xy, InputDataLength, InputPackedWidth) ? 1.0 : 0.0;
    OutputDataLength = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, OutputFrameWidth,
        contract_data_length(OutputFrameWidth, OutputFrameHeight)), 1.0);

    DeskewSampleRatio = OutputFs / max(OriginalFs, EPS);
    LineCarryClocksOut = LineCarryClocks;
    ClockFactorOut = ClockFactor;

    float Delta = float(OutputFrameWidth / max(InputFrameWidth, 1.0lf));

    pfilt.Delta = Delta;

    // Kaiser window design from cutoff and stopband
    const float cutoff = 0.45; // Normalized
    const float stopband = 0.5;

    kfilt.fc_norm = cutoff;

    float trans_width = max(stopband - cutoff, EPS); // MHz, avoid div0
    float delta_omega = 2.0 * PI * trans_width; // radians/sample
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
layout(location = 11) flat in double InputFrameWidth;
layout(location = 12) flat in double OutputFrameWidth;
layout(location = 16) flat in float InputPackedWidth;
layout(location = 17) flat in float InputTextureFits;
layout(location = 18) flat in float BaseFrameWidthOut;
layout(location = 13) flat in float DeskewSampleRatio;
layout(location = 14) flat in float LineCarryClocksOut;
layout(location = 15) flat in float ClockFactorOut;
layout(location = 19) flat in vec4 vRasterPattern;
layout(location = 20) flat in ivec2 vRasterExceptions;
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
    float input_storage_width = InputPackedWidth;
    if (InputTextureFits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    vec2 line_range = raster_line_range(vRasterPattern, vRasterExceptions, output_y, OutputFrameWidth);
    vec2 clock_range = raster_line_range(vRasterPattern, vRasterExceptions, output_y, double(BaseFrameWidthOut));
    double line_width = double(clock_range.y) * OutputFrameWidth / double(BaseFrameWidthOut);
    if (double(output_x) >= ceil(line_width) || output_y >= OutputFrameHeight) {
        FragColor = vec4(0.0);
        return;
    }

    float Delta = pfilt.Delta;
    float invDelta = 1.0 / max(Delta, EPS);
    int n_taps = int(pfilt.taps);
    int center = (n_taps - 1) / 2;

    float row_shift_output = compute_row_shift_output_samples(output_y_i);
    {
        float sync_shift = contract_hsync_sample_offset(clock_range.x, BaseFrameWidthOut, OutputFrameWidth, line_range.x);
#ifdef OPTION_DEBUG
        sync_shift = mix(sync_shift, 0.0, DESKEW_BYPASS);
#endif
        row_shift_output += sync_shift;
    }
    double field_output_index = double(line_range.x) + double(output_x) + double(row_shift_output);
    if (field_output_index < 0.0 || field_output_index >= OutputDataLength) {
        FragColor = vec4(0.0);
        return;
    }

    double input_sample_pos = field_output_index * double(InputFrameWidth) / double(OutputFrameWidth);
    double input_pos_floor = floor(input_sample_pos);
    int input_index_int = int(input_pos_floor);
    float frac_offset = float(input_sample_pos - input_pos_floor);
    float input_data_limit = max(ceil(InputDataLength) - 1.0, 0.0);

    vec3 color = vec3(0.0);

#ifdef OPTION_DEBUG
    if (DISPLAY_RGB_FILTER_BYPASS > 0.5) {
        float sample_index = clamp(float(floor(input_sample_pos + 0.5)), 0.0, input_data_limit);
        color = fetch_input_sample(Source, config.SourceSize.xy, sample_index, input_storage_width, input_data_limit).rgb;
    } else {
#endif  // OPTION_DEBUG

#ifdef OPTION_CRISPY
    float Tout = max(invDelta, EPS);
    float zoh_sum = 0.0;
    int zoh_taps = max(int(ceil(Tout)) + 1, 1);
    for (int k = 0; k < zoh_taps; ++k) {
        float coeff = zoh_area(float(k) - frac_offset, 1.0, Tout);
        float sample_index = clamp(float(input_index_int + k), 0.0, input_data_limit);
        vec3 rgb = fetch_input_sample(Source, config.SourceSize.xy, sample_index, input_storage_width, input_data_limit).rgb;

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
        vec3 rgb = fetch_input_sample(Source, config.SourceSize.xy, sample_index, input_storage_width, input_data_limit).rgb;

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
