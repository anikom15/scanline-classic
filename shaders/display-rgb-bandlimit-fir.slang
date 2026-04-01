#version 450

// Filename: display-rgb-bandlimit-fir.slang
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
// When the filter is bypassed for debugging, a simple triangle
// convolution is used instead of the FIR, which has a fixed 3-tap
// kernel but is continuous for fractional pixel offsets. This is
// required to prevent aliasing on the output.

#pragma name DisplayRGBBandlimitFIR
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "modulation.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/user-uncommon.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/display-rgb-fir.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_RGB_BANDLIMIT_HEADER " —— Debug Display RGB Bandlimit —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_RGB_AMP_BYPASS "Bypass display RGB amplifier" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_RGB_FILTER_BYPASS "Bypass display RGB filter" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    vec4 FrameHSize;
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

    float DISPLAY_CUTOFF;
    float DISPLAY_STOPBAND;
    float USER_BLUE_ONLY;
} config;

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

#define DISPLAY_CUTOFF config.DISPLAY_CUTOFF
#define DISPLAY_STOPBAND config.DISPLAY_STOPBAND

#define USER_BLUE_ONLY config.USER_BLUE_ONLY

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float DISPLAY_GAIN_R;
    float DISPLAY_GAIN_G;
    float DISPLAY_GAIN_B;
    float DISPLAY_BIAS_R;
    float DISPLAY_BIAS_G;
    float DISPLAY_BIAS_B;

#ifdef OPTION_DEBUG
    float DISPLAY_RGB_FILTER_BYPASS;
    float DISPLAY_RGB_AMP_BYPASS;
#endif  // OPTION_DEBUG

} global;

#ifdef OPTION_DEBUG
#define DISPLAY_RGB_FILTER_BYPASS global.DISPLAY_RGB_FILTER_BYPASS
#define DISPLAY_RGB_AMP_BYPASS global.DISPLAY_RGB_AMP_BYPASS
#endif  // OPTION_DEBUG

#define DISPLAY_GAIN_R global.DISPLAY_GAIN_R
#define DISPLAY_GAIN_G global.DISPLAY_GAIN_G
#define DISPLAY_GAIN_B global.DISPLAY_GAIN_B

#define DISPLAY_BIAS_R global.DISPLAY_BIAS_R
#define DISPLAY_BIAS_G global.DISPLAY_BIAS_G
#define DISPLAY_BIAS_B global.DISPLAY_BIAS_B

struct KaiserFilter {
    float fc_norm; // Normalized cutoff frequency (0..0.5)
    float taps; // Number of filter taps (should be odd)
    float beta; // Kaiser window beta parameter
    float gain; // Precomputed gain factor for normalization
};

struct PolyphaseFilter {
    float Delta;  // Resampling ratio (output / input)
    float taps;
};
#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float Tin;
layout(location = 2) out flat KaiserFilter kfilt;
layout(location = 6) out flat PolyphaseFilter pfilt;
layout(location = 9) out flat vec3 gain;
layout(location = 10) out flat vec3 bias;

const int MAX_TAPS = 37;
const float KAISER_ATTEN_DB = 40.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float f_sc;
    int standard;
    float pixel_time;
    float active_source_pixels;

    compute_subcarrier_freq(
        SC_FREQ_MODE, SC_FREQ,
        config.OriginalFPS,
        f_sc, standard);

    float pixel_clock_hz = compute_pixel_clock(
        PIXEL_CLOCK_MODE, PIXEL_CLOCK, f_sc
    );

    float h_freq_hz = compute_h_freq(
        H_FREQ_MODE, standard, H_FREQ, pixel_clock_hz,
        config.OriginalFPS);

    compute_h_timing(
        pixel_clock_hz, h_freq_hz, H_BLANK_FUZZ,
        config.OriginalSize.x, active_source_pixels, pixel_time);

    // Polyphase resampler factors
    float Delta_in = config.SourceSize.x / active_source_pixels;
    float Delta = config.OutputSize.x / config.SourceSize.x;

    // This restores the proper upscaled sampling rate of source
    float fs_original = 1.0 / pixel_time;
    float fs_in = fs_original * Delta_in;
    float fs_out = fs_in * Delta;

    Tin = 1.0 / fs_in;

    pfilt.Delta = Delta;

    // Kaiser window design from cutoff and stopband
    // Don't allow stopband to be less than cutoff
    float cutoff = DISPLAY_CUTOFF * 1.0e6;  // MHz
    float stopband = max(DISPLAY_CUTOFF, DISPLAY_STOPBAND) * 1.0e6;  // MHz

    // FIR cutoff is the user cutoff
    kfilt.fc_norm = cutoff / fs_out;

    float trans_width = max(stopband - cutoff, EPS); // MHz, avoid div0
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

    // Amplifier
    gain = vec3(
        pow(10.0, DISPLAY_GAIN_R / 20.0),
        pow(10.0, DISPLAY_GAIN_G / 20.0),
        pow(10.0, DISPLAY_GAIN_B / 20.0));
    bias = vec3(
        DISPLAY_BIAS_R * 10e-3,
        DISPLAY_BIAS_G * 10e-3,
        DISPLAY_BIAS_B * 10e-3);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in flat float Tin;
layout(location = 2) in flat KaiserFilter kfilt;
layout(location = 6) in flat PolyphaseFilter pfilt;
layout(location = 9) in flat vec3 gain;
layout(location = 10) in flat vec3 bias;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 Tex = vec2(
        (floor(UV.x) + 0.5) * config.OutputSize.z,
        (floor(UV.y) + 0.5) * config.OutputSize.w
    );

    // Filter
    float Delta = pfilt.Delta;
    int n_taps = int(pfilt.taps);

    float output_index = Tex.x * config.OutputSize.x;
    float phase = output_index / Delta;
    float input_index = floor(phase);
    int center = (n_taps - 1) / 2;
    float frac_offset = phase - floor(phase);

    vec3 color = vec3(0.0);

#ifdef OPTION_DEBUG
    if (DISPLAY_RGB_FILTER_BYPASS > 0.5) {
        // Area average
        const int MAX_TAPS = 16;

        float Tout = Tin / Delta;
        n_taps = min(int(1.0 + ceil(Tout / Tin)), 16);
        center = (n_taps - 1) / 2;

        for (int k = 0; k < n_taps; ++k) {
            int tap_offset = k - center;

            // Continuous time offset between input sample and output sample
            float dt = (float(tap_offset) - frac_offset) * Tin;
            float coeff = zoh_area(dt, Tin, Tout);

            vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
            vec3 rgb = texture(Source, input_tex).rgb;

            color += coeff * rgb;
        }
    } else {
#endif  // OPTION_DEBUG

#ifdef OPTION_CRISPY
    // Linear
    float coeff_sum = 0.0;
    for (int k = 0; k < 3; ++k) {
        int tap_offset = k - 1;

        // Continuous time offset between input sample and output sample
        float dt = (float(tap_offset) - frac_offset) * Tin;
        float coeff = zoh_triangle(dt, Tin, 1.5 * Tin);

        vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
        vec3 rgb = texture(Source, input_tex).rgb;

        color += coeff * rgb;
        coeff_sum += coeff;
    }
    color /= max(coeff_sum, EPS);
#else
    // Standard FIR convolution (Kaiser)
    for (int k = 0; k < n_taps; ++k) {
        int tap_offset = k - center;
        float w = kaiser(float(tap_offset), kfilt.taps, kfilt.beta);
        float coeff = sinc(float(tap_offset - frac_offset), kfilt.fc_norm) * w;
        vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
        vec3 rgb = texture(Source, input_tex).rgb;

        color += coeff * rgb / kfilt.gain;
    }
#endif  // OPTION_CRISPY

#ifdef OPTION_DEBUG
    }  // end filter bypass
#endif  // OPTION_DEBUG

#ifdef OPTION_DEBUG
    // RGB amplifier
    if (DISPLAY_RGB_AMP_BYPASS < 0.5) {
        color = gain * (color + bias);
    }
#else
    color = gain * (color + bias);
#endif  // OPTION_DEBUG

    // Apply blue-only filter
    color.r *= 1.0 - USER_BLUE_ONLY;
    color.g *= 1.0 - USER_BLUE_ONLY;

    FragColor = vec4(color, 1.0);
}
