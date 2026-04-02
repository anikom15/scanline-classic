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
#include "modulation.inc"
#include "zoh.inc"

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
    float SYS_FILTER_DECIMATION;
    float SYS_FILTER_ATTEN;
    float COMPENSATE_SINC_ROLLOFF;

#ifdef OPTION_DEBUG
    float SYS_RGB_BANDLIMIT_BYPASS;
#endif

} config;

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

#define SYS_FILTER_DECIMATION config.SYS_FILTER_DECIMATION
#define SYS_FILTER_ATTEN config.SYS_FILTER_ATTEN
#define COMPENSATE_SINC_ROLLOFF config.COMPENSATE_SINC_ROLLOFF

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
    float Delta;  // Resampling factor
    float taps;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float Tin;
layout(location = 2) flat out float active_source_pixels;
layout(location = 3) flat out GaussianFilter gfilt;
layout(location = 6) flat out PolyphaseFilter pfilt;

const float MAX_TAPS = 71.0;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    float f_sc;
    int standard;
    float pixel_time;

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

    Tin = pixel_time;

    // Polyphase resampler factors
    // active_source_pixels - actual signal pixels without padding
    float Delta = config.OutputSize.x / active_source_pixels;

    float fs_in = 1.0 / Tin;
    float fs_out = fs_in * Delta;

    pfilt.Delta = Delta;

    // Gaussian filter design
    float cutoff_freq = 0.5 * pixel_clock_hz / SYS_FILTER_DECIMATION;

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
layout(location = 2) flat in float active_source_pixels;
layout(location = 3) flat in GaussianFilter gfilt;
layout(location = 6) flat in PolyphaseFilter pfilt;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Single-pass lobe-based horizontal Gaussian convolution
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 Tex = vec2(
        (floor(UV.x) + 0.5) * config.OutputSize.z,
        (floor(UV.y) + 0.5) * config.OutputSize.w
    );

    float Delta = pfilt.Delta;
    int n_taps = int(pfilt.taps);
    int center = (n_taps - 1) / 2;
    float padding = floor(config.SourceSize.x - active_source_pixels);

    float output_index = Tex.x * config.OutputSize.x;
    float phase = output_index / Delta;
    float input_index = floor(phase) + floor(padding / 2.0);
    float frac_offset = phase - floor(phase);

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

            vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
            vec3 rgb = texture(Source, input_tex).rgb;

            color += coeff * rgb;
        }
        FragColor = vec4(color, 1.0);
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

        vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
        vec3 rgb = texture(Source, input_tex).rgb;

        color += coeff * rgb;
    }
    FragColor = vec4(color, 1.0);
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

        vec2 input_tex = vec2(((input_index + tap_offset) + 0.5) * config.SourceSize.z, Tex.y);
        vec3 rgb = texture(Source, input_tex).rgb;

        color += coeff * rgb;
    }
    color /= gfilt.gain;

    FragColor = vec4(color, 1.0);
}
