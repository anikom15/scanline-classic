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

#pragma name DisplayRGBBandlimitFIR
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "window.inc"
#include "modulation.inc"

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
};

struct PolyphaseFilter {
    float L; // Upsampling factor
    float M; // Downsampling factor
    float n_poly; // Number of polyphase components (ceil(taps / L))
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out KaiserFilter kfilt;
layout(location = 4) out PolyphaseFilter pfilt;
layout(location = 7) out vec3 gain;
layout(location = 8) out vec3 bias;
layout(location = 9) out TimebaseConfig tb;

// Maximum filter transition width is limited to 1.0 MHz
// A = 40
// MAX_TAPS = (A - 8) / (2.285 * (2 * PI * 1.0e6 / fs_out))
// fs_out is approximately 16 MHz
const int MAX_TAPS = 37;

// Greatest common divisor
int gcd(int a, int b) {
    // Euclidean algorithm
    while (b != 0) {
        int t = b;
        b = a % b;
        a = t;
    }
    return a;
}

// Kaiser windowed-sinc filter design (precise method only)
// - Transition width in radians/sample
// - Beta from attenuation
const float KAISER_ATTEN_DB = 40.0; // Desired attenuation (dB)

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.SourceSize.xy,
        config.FrameHSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK,
        PIXEL_CLOCK_MODE,
        H_FREQ_MODE,
        H_FREQ,
        V_FREQ_MODE,
        V_FREQ,
        H_BLANK_FUZZ,
        SHORTEN_ODD_FIELD_TIME);

    // Polyphase resampler factors
    int N_in = int(round(tb.h_pixels));
    int N_out = int(round(config.OutputSize.x));
    int g = gcd(N_in, N_out);
    int L = N_out / g;
    int M = N_in / g;
    float fs_in = 1.0 / tb.pixel_time_px;
    float fs_out = fs_in * float(L) / float(M); // Effective output sample rate after polyphase resampling

    // Kaiser window design from cutoff and stopband
    // Don't allow stopband to be less than cutoff
    float cutoff = DISPLAY_CUTOFF * 1.0e6;  // MHz
    float stopband = max(DISPLAY_CUTOFF, DISPLAY_STOPBAND) * 1.0e6;  // MHz

    // FIR cutoff is the user cutoff
    kfilt.fc_norm = cutoff / fs_out;

    float trans_width = max(stopband - cutoff, EPS); // MHz, avoid div0
    const float atten_db = KAISER_ATTEN_DB;
    float delta_omega = 2.0 * PI * trans_width / fs_out; // radians/sample
    float beta_precise = kaiser_beta_from_atten(atten_db);
    float taps_calc = min((atten_db - 8.0) / (2.285 * max(delta_omega, EPS)), MAX_TAPS);

    kfilt.taps = float(int(ceil(taps_calc)) | 1); // force odd
    kfilt.beta = beta_precise;

    pfilt.L = float(L);
    pfilt.M = float(M);
    pfilt.n_poly = kfilt.taps;

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
layout(location = 1) in KaiserFilter kfilt;
layout(location = 4) in PolyphaseFilter pfilt;
layout(location = 7) in vec3 gain;
layout(location = 8) in vec3 bias;
layout(location = 9) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Polyphase resampler using struct parameters and L/M factors
vec3 apply_polyphase_resampler(sampler2D source, vec2 tex)
{
    // tex.x is the output pixel center in normalized coordinates (0..1)
    int L = int(pfilt.L);
    int M = int(pfilt.M);
    int n_taps = int(pfilt.n_poly);
    int padding = int(round(config.SourceSize.x - tb.h_pixels));

    int output_index = int(tex.x * config.OutputSize.x);
    int phase = (output_index * M) % L;
    int input_index = (output_index * M) / L + padding / 2;
    int center = (n_taps - 1) / 2;
    float frac_offset = float(phase) / float(L);

    vec3 color = vec3(0.0);

    for (int k = 0; k < n_taps; ++k) {
        int tap_offset = k - center;
        float coeff = sinc_lowpass_kaiser(tap_offset - frac_offset, kfilt.fc_norm, kfilt.taps, kfilt.beta);
        vec2 input_tex = vec2((input_index + tap_offset) * config.SourceSize.z, tex.y);
        vec3 rgb = texture(source, input_tex).rgb;

        color += coeff * rgb;
    }

    return color;
}

void main()
{
    // Use original Tex and Ax for output pixel sample coordinate and fractional component
    vec2 UV = vTexCoord * config.OutputSize.xy;
    float baseCenter = floor(UV.x) + 0.5;
    float Ax = UV.x - baseCenter;

    vec2 Tex = vec2(
        baseCenter * config.OutputSize.z,
        (floor(UV.y) + 0.5) * config.OutputSize.w);

    vec2 dx = vec2(config.OutputSize.z, 0.0);

    // Filter
#ifdef OPTION_CRISPY
    vec3 color = texture(Source, Tex).rgb;
#else
    vec3 color;
#ifdef OPTION_DEBUG
    if (DISPLAY_RGB_FILTER_BYPASS > 0.5) {
        color = texture(Source, Tex).rgb;
    } else {
        color = apply_polyphase_resampler(Source, Tex);
    }
#else
    color = apply_polyphase_resampler(Source, Tex);
#endif  // OPTION_DEBUG
#endif // OPTION_CRISPY

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
