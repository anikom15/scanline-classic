// Filename: sys-bandlimit.slang
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
// System-side general filter
// ----------------------
// Input: Real voltage
// Output: Real voltage
//
// Implements a polyphase FIR resampler with a direct Gaussian kernel
// over the canonical 1D framed signal emitted by `frameh.slang`.
//
// The vertex shader computes the filter parameters and polyphase
// factors based on the input and output sizes and timing, while the
// fragment shader applies the filter to produce the final output color.
//
// The filter is designed to limit the bandwidth proportionally to the
// system clock, ensuring a smooth output.  It operates on all four
// channels of the input signal.  The fourth channel can be used for
// sync or any other passband metadata.

#pragma name SysRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "lowpass.inc"
#include "filter-taps.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-rgb.inc"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timingProfileMode

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float PHASE_ZERO;
    float SYS_FILTER_DECIMATION;
    float SYS_FILTER_ATTEN;
    float COMPENSATE_SINC_ROLLOFF;
    float SYS_FILTER_TYPE;

#ifdef OPTION_DEBUG
    float SYS_RGB_BANDLIMIT_BYPASS;
#endif

} config;

#ifdef OPTION_DEBUG
#define SYS_RGB_BANDLIMIT_BYPASS config.SYS_RGB_BANDLIMIT_BYPASS
#else
const float SYS_RGB_BANDLIMIT_BYPASS = 0.0;
#endif  // OPTION_DEBUG

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SHORTEN_ODD_FIELD_TIME timing_profile_field_adjustment(TIMING_PROFILE_MODE, config.SHORTEN_ODD_FIELD_TIME)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, global.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, global.PIXEL_CLOCK_FRAC6, global.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define PHASE_ZERO (config.PHASE_ZERO + timing_profile_initial_phase(TIMING_PROFILE_MODE, 0.0))
#define SYS_FILTER_DECIMATION config.SYS_FILTER_DECIMATION
#define SYS_FILTER_ATTEN config.SYS_FILTER_ATTEN
#define COMPENSATE_SINC_ROLLOFF config.COMPENSATE_SINC_ROLLOFF
#ifdef VGA_RATE_DOMAIN
#define DSP_WORKING_FS 0.0
#else
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)
#endif
#define SYS_FILTER_TYPE config.SYS_FILTER_TYPE

layout(std140, set = 0, binding = 0) uniform UBO
{
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
    float SC_FREQ_FRAC6;
    float SC_FREQ_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float PIXEL_CLOCK_FRAC11;
} global;

struct GaussianFilter {
    float sigma;    // sigma in working-sample units
    float t_limit;  // support radius in working-sample units
    float gain;     // Precomputed gain factor for normalization
};

struct PolyphaseFilter {
    float taps;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 2) flat out float InputPackedWidth;
layout(location = 3) flat out GaussianFilter gfilt;
layout(location = 6) flat out PolyphaseFilter pfilt;
layout(location = 9) flat out float InputDataLength;
layout(location = 10) flat out float OutputDataLength;
layout(location = 11) flat out double OutputFrameWidth;
layout(location = 12) flat out float InputTextureFits;
layout(location = 13) flat out float OutputPackedWidth;
layout(location = 14) flat out double InputFrameWidth;

const float MAX_TAPS = float(SYS_BANDLIMIT_MAX_TAPS);

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    int timingProfileMode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);

    float PixelClock = contract_pixel_clock(
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        SC_FREQ_MODE,
        SC_FREQ,
        config.OriginalFPS
    );


    float BaseFrameWidth = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    InputFrameWidth = BaseFrameWidth;

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
    float WorkingSampleRate = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);

    float fs_out = WorkingSampleRate;

    OutputFrameWidth = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_frame_width_at_sample_rate(
        BaseFrameWidth,
        fs_out,
        fs_original), DSP_WORKING_FS);
    InputDataLength = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, global.FIELD_ODD, BaseFrameWidth,
        contract_data_length(BaseFrameWidth, InputFrameHeight)), 1.0);
    OutputDataLength = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, global.FIELD_ODD, OutputFrameWidth,
        contract_data_length(OutputFrameWidth, InputFrameHeight)), 1.0);
    InputPackedWidth = contract_pixel_packed_width(InputDataLength);
    OutputPackedWidth = contract_pixel_packed_width(OutputDataLength);
    InputTextureFits = contract_pixel_texture_fits(config.SourceSize.xy, InputDataLength, InputPackedWidth) &&
        contract_pixel_texture_fits(config.OutputSize.xy, OutputDataLength, OutputPackedWidth) ? 1.0 : 0.0;

    // The upstream framed signal is already ZOH-held. Normalize the analog
    // Gaussian design into pixel clocks, while still compensating for
    // the source ZOH sinc rolloff in the target frequency response.

    float cutoff_freq = 0.5 * PixelClock / SYS_FILTER_DECIMATION;

    float zoh_ratio = clamp(cutoff_freq / max(PixelClock, EPS), 0.0, 0.5);
    float zoh_mag = (zoh_ratio < EPS)
        ? 1.0
        : abs(sin(PI * zoh_ratio) / (PI * zoh_ratio));
    float zoh_gain = linear_to_db(zoh_mag);
    float cutoff_atten = SYS_FILTER_ATTEN + zoh_gain * COMPENSATE_SINC_ROLLOFF;

    // Filter design
    if (SYS_FILTER_TYPE < 0.5) {
        // Gaussian filter design
        float sigma_seconds = gaussian_sigma(cutoff_freq, cutoff_atten);
        float t_limit_seconds = gaussian_decay_time(sigma_seconds, FILTER_THRESHOLD_ANALOG);

        gfilt.sigma = sigma_seconds * fs_original;
        gfilt.t_limit = t_limit_seconds * fs_original;

        pfilt.taps = min(2.0 * ceil(gfilt.t_limit) + 1.0, MAX_TAPS);

        gfilt.gain = gaussian_lowpass_gain(gfilt.sigma, pfilt.taps);
    } else {
        // First-order Butterworth filter design
        // Determine -3 dB frequency of Gaussian design
        // Set as the cutoff frequency for the Butterworth design to match the -3 dB point
        float butterworth_cutoff_freq;

        if (cutoff_atten <= 3.0) {
            butterworth_cutoff_freq = cutoff_freq;
        } else {
            float sigma_seconds = gaussian_sigma(cutoff_freq, cutoff_atten);
            butterworth_cutoff_freq = butterworth_matched_cutoff(
                cutoff_freq, cutoff_atten, sigma_seconds, 0.0);
        }
        float K = tan(PI * butterworth_cutoff_freq / fs_original);
        float alpha = butterworth_alpha_from_prewarp(K);

        gfilt.sigma = alpha; // Reuse sigma field for alpha
        pfilt.taps = min(ceil(log(FILTER_THRESHOLD_ANALOG) / log(max(alpha, EPS))), MAX_TAPS);

        // Calculate the centroid of the impulse response for phase compensation
        float num = 0.0;
        float denom = 0.0;

        for (int k = 0; k < int(pfilt.taps); ++k) {
            float h = (1.0 - alpha) * pow(alpha, float(k));
            num += float(k) * h;
            denom += h;
        }

        float centroid_offset = num / max(denom, EPS);

        gfilt.t_limit = centroid_offset;  // Reuse t_limit field for centroid-based phase compensation
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 2) flat in float InputPackedWidth;
layout(location = 3) flat in GaussianFilter gfilt;
layout(location = 6) flat in PolyphaseFilter pfilt;
layout(location = 9) flat in float InputDataLength;
layout(location = 10) flat in float OutputDataLength;
layout(location = 11) flat in double OutputFrameWidth;
layout(location = 12) flat in float InputTextureFits;
layout(location = 13) flat in float OutputPackedWidth;
layout(location = 14) flat in double InputFrameWidth;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec4 fetch_input_sample(float sample_index, float input_frame_width, float input_data_limit)
{
    // The packed stride is integral-valued by contract.
    int input_frame_width_i = max(int(input_frame_width + 0.5), 1);
    int input_data_limit_i = max(int(input_data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, input_data_limit))),
        0, input_data_limit_i);
    int texel_y = clamped_index_i / input_frame_width_i;
    int texel_x = clamped_index_i - texel_y * input_frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(config.SourceSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SourceSize.y) - 1, 0));

    return texelFetch(Source, ivec2(texel_x, texel_y), 0);
}

void main()
{
    if (InputTextureFits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    // Single-pass lobe-based horizontal Gaussian convolution
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= OutputPackedWidth) {
        FragColor = vec4(0.0);
        return;
    }

    int n_taps = int(pfilt.taps);
    int center = (n_taps - 1) / 2;

    float field_output_index = output_y * OutputPackedWidth + output_x;
    if (field_output_index >= OutputDataLength) {
        FragColor = vec4(0.0);
        return;
    }

    double input_sample_pos = double(field_output_index) * double(InputFrameWidth) / double(OutputFrameWidth);
    double input_pos_floor = floor(input_sample_pos);
    int input_index_int = int(input_pos_floor);
    float frac_offset = float(input_sample_pos - input_pos_floor);
    float input_data_limit = max(ceil(InputDataLength) - 1.0, 0.0);

    vec4 color = vec4(0.0);

#ifdef OPTION_DEBUG
    if (SYS_RGB_BANDLIMIT_BYPASS > 0.5) {
        float sample_index = clamp(float(floor(input_sample_pos + 0.5)), 0.0, input_data_limit);
        FragColor = fetch_input_sample(sample_index, InputPackedWidth, input_data_limit);
        return;
    }
#endif  // OPTION_DEBUG

#ifdef OPTION_CRISPY
    float sample_index = clamp(float(floor(input_sample_pos + 0.5)), 0.0, input_data_limit);
    FragColor = fetch_input_sample(sample_index, InputPackedWidth, input_data_limit);
    return;
#endif  // OPTION_CRISPY

    if (SYS_FILTER_TYPE < 0.5) {
        // Standard polyphase FIR convolution with a direct Gaussian kernel.
        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = k - center;
            float dt = float(tap_offset) - frac_offset;
            float coeff = gaussian(dt, gfilt.sigma);

            float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
            vec4 sample_value = fetch_input_sample(sample_index, InputPackedWidth, input_data_limit);

            color += coeff * sample_value;
        }
        color /= gfilt.gain;
    } else {
        // First-order Butterworth truncated IIR implementation
        float gain = 0.0;
        int centroid_offset = int(gfilt.t_limit + 0.5); // Round centroid to nearest integer tap index
        float alpha = gfilt.sigma;

        input_index_int -= centroid_offset - (n_taps - 1) / 2; // Phase compensation by shifting the center tap by the centroid
        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = n_taps - 1 - k; // Reverse order for causal IIR
            float dt = float(tap_offset) + frac_offset;
            float coeff = (1.0 - alpha) * pow(alpha, dt);

            float sample_index = clamp(float(input_index_int - tap_offset), 0.0, input_data_limit);
            vec4 sample_value = fetch_input_sample(sample_index, InputPackedWidth, input_data_limit);

            color += coeff * sample_value;
            gain += coeff;
        }
        color /= max(gain, EPS);
    }

    FragColor = color;
}
