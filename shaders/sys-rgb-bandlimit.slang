#version 450

// Filename: sys-rgb-bandlimit.slang
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
// System-side RGB filter
// ----------------------
// Input: Real RGB voltage
// Output: Real RGB voltage
//
// Implements a polyphase FIR resampler with a Gaussian kernel
// convoluted with a ZOH kernel to reframe the input data as a real RGB
// signal from a DAC.
//
// The vertex shader computes the filter parameters and polyphase
// factors based on the input and output sizes and timing, while the
// fragment shader applies the filter to produce the final output color.

#pragma name SysRGBBandlimit
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"
#include "zoh.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-rgb.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter SYS_RGB_BANDLIMIT_BYPASS "System RGB bandlimit bypass" 0.0 0.0 1.0 1.0
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
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float PHASE_ZERO;
    float SYS_FILTER_DECIMATION;
    float SYS_FILTER_ATTEN;
    float COMPENSATE_SINC_ROLLOFF;
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;

#ifdef OPTION_DEBUG
    float SYS_RGB_BANDLIMIT_BYPASS;
#endif

} config;

#define FieldCount config.FrameCount

#ifdef OPTION_DEBUG
#define SYS_RGB_BANDLIMIT_BYPASS config.SYS_RGB_BANDLIMIT_BYPASS
#else
const float SYS_RGB_BANDLIMIT_BYPASS = 0.0;
#endif  // OPTION_DEBUG

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define PHASE_ZERO config.PHASE_ZERO
#define SYS_FILTER_DECIMATION config.SYS_FILTER_DECIMATION
#define SYS_FILTER_ATTEN config.SYS_FILTER_ATTEN
#define COMPENSATE_SINC_ROLLOFF config.COMPENSATE_SINC_ROLLOFF
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define DSP_OUTPUT_FS config.DSP_OUTPUT_FS

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

struct GaussianFilter {
    float sigma;    // sigma in seconds
    float t_limit;  // time for filter response to decay below threshold
    float gain;     // Precomputed gain factor for normalization
};

struct PolyphaseFilter {
    float Delta;          // Resampling factor
    float taps;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float Tin;
layout(location = 2) flat out float InputFrameWidth;
layout(location = 3) flat out GaussianFilter gfilt;
layout(location = 6) flat out PolyphaseFilter pfilt;
layout(location = 8) flat out float OutputFrameHeight;
layout(location = 9) flat out float InputDataLength;
layout(location = 10) flat out float OutputDataLength;
layout(location = 11) flat out float OutputFrameWidth;

const float MAX_TAPS = 71.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

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

    // Keep widths as float varyings for cross-driver safety, but the contract
    // guarantees they are integral-valued.
    float fs_in = fs_original;
    float fs_out = WorkingSampleRate;

    OutputFrameHeight = InputFrameHeight;
    OutputFrameWidth = contract_frame_width_at_sample_rate(
        BaseFrameWidth,
        fs_out,
        fs_original);
    InputDataLength = max(contract_data_length(InputFrameWidth, OutputFrameHeight), 1.0);
    OutputDataLength = max(contract_data_length(OutputFrameWidth, OutputFrameHeight), 1.0);

    Tin = 1.0 / fs_in;

    // Polyphase resampler ratio is data-length driven rather than texture-size driven.
    float Delta = OutputDataLength / max(InputDataLength, 1.0);

    pfilt.Delta = Delta;

    // Gaussian filter design
    float cutoff_freq = 0.5 * PixelClock / SYS_FILTER_DECIMATION;

    // Compensate for sinc(x) rolloff by adjusting attenuation
    // gain = 20.0 * log10(abs(sinc(0.5))) ≈ -3.92 dB at Nyquist (x=0.5)
    const float zoh_gain = -3.92;
    float cutoff_atten = SYS_FILTER_ATTEN + zoh_gain * COMPENSATE_SINC_ROLLOFF;

    gfilt.sigma = gaussian_sigma(cutoff_freq, cutoff_atten);
    gfilt.t_limit = gaussian_decay_time(gfilt.sigma, FILTER_THRESHOLD_ANALOG);

    float t_support = gfilt.t_limit + Tin / 2.0;

    pfilt.taps = min(2.0 * ceil(t_support * fs_out) + 1.0, MAX_TAPS);

    // Compute gain for normalization
    float gain = 0.0;
    for (int k = 0; k < int(pfilt.taps); ++k) {
        float t = (float(k) - (pfilt.taps - 1.0) / 2.0) * Tin;
        float a = t / (sqrt(2.0) * gfilt.sigma);
        float b = (t - Tin) / (sqrt(2.0) * gfilt.sigma);
        gain += gfilt.sigma * sqrt(PI / 2.0) * (erf(a) - erf(b));
    }
    gfilt.gain = gain;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float Tin;
layout(location = 2) flat in float InputFrameWidth;
layout(location = 3) flat in GaussianFilter gfilt;
layout(location = 6) flat in PolyphaseFilter pfilt;
layout(location = 8) flat in float OutputFrameHeight;
layout(location = 9) flat in float InputDataLength;
layout(location = 10) flat in float OutputDataLength;
layout(location = 11) flat in float OutputFrameWidth;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec3 fetch_input_sample(float sample_index, float input_frame_width, float input_data_limit)
{
    // `input_frame_width` is passed as float for portability, but it is
    // integral-valued by contract, so the row/column decomposition can be
    // performed exactly in integer arithmetic here.
    int input_frame_width_i = max(int(input_frame_width + 0.5), 1);
    int input_data_limit_i = max(int(input_data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, input_data_limit))),
        0, input_data_limit_i);
    int texel_y = clamped_index_i / input_frame_width_i;
    int texel_x = clamped_index_i - texel_y * input_frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(config.SourceSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SourceSize.y) - 1, 0));

    return texelFetch(Source, ivec2(texel_x, texel_y), 0).rgb;
}

void main()
{
    // Single-pass lobe-based horizontal Gaussian convolution
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

    float field_output_index = output_y * OutputFrameWidth + output_x;
    if (field_output_index >= OutputDataLength) {
        FragColor = vec4(0.0);
        return;
    }

    float input_sample_pos = field_output_index * invDelta;
    float input_pos_floor = floor(input_sample_pos);
    int input_index_int = int(input_pos_floor);
    float frac_offset = input_sample_pos - input_pos_floor;
    float input_data_limit = max(InputDataLength - 1.0, 0.0);

    float phase_rel_sample = contract_phase_rel_sample(output_x, output_y, OutputFrameWidth);

    vec3 color = vec3(0.0);

#ifdef OPTION_DEBUG
    if (SYS_RGB_BANDLIMIT_BYPASS > 0.5) {
        float Tout = Tin / Delta;
        n_taps = min(int(1.0 + ceil(Tout / Tin)), 16);
        center = (n_taps - 1) / 2;

        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = k - center;

            // Continuous time offset between input sample and output sample
            float dt = (float(tap_offset) - frac_offset) * Tin;
            float coeff = zoh_area(dt, Tin, Tout);

            float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
            vec3 rgb = fetch_input_sample(sample_index, InputFrameWidth, input_data_limit);

            color += coeff * rgb;
        }
        FragColor = vec4(color, phase_rel_sample);
        return;
    }
#endif  // OPTION_DEBUG

#ifdef OPTION_CRISPY
    float Tout = Tin / Delta;
    n_taps = min(int(1.0 + ceil(Tout / Tin)), 16);
    center = (n_taps - 1) / 2;

    for (int k = 0; k < n_taps; ++k) {
        int tap_offset = k - center;

        // Continuous time offset between input sample and output sample
        float dt = (float(tap_offset) - frac_offset) * Tin;
        float coeff = zoh_area(dt, Tin, Tout);

        float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
        vec3 rgb = fetch_input_sample(sample_index, InputFrameWidth, input_data_limit);

        color += coeff * rgb;
    }
    FragColor = vec4(color, phase_rel_sample);
    return;
#endif  // OPTION_CRISPY

    // Standard polyphase FIR convolution
    for (int k = 0; k < n_taps; ++k) {
        int tap_offset = k - center;

        // Continuous time offset between input sample and output sample
        float dt = (float(tap_offset) - frac_offset) * Tin;

        // ZOH ∗ Gaussian coefficient (closed form)
        float a = dt / (sqrt(2.0) * gfilt.sigma);
        float b = (dt - Tin) / (sqrt(2.0) * gfilt.sigma);

        float coeff = gfilt.sigma * sqrt(PI / 2.0) * (erf(a) - erf(b));

        float sample_index = clamp(float(input_index_int + tap_offset), 0.0, input_data_limit);
        vec3 rgb = fetch_input_sample(sample_index, InputFrameWidth, input_data_limit);

        color += coeff * rgb;
    }
    color /= gfilt.gain;

    FragColor = vec4(color, phase_rel_sample);
}
