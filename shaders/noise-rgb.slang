#version 450

// Filename: noise-rgb.slang
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
// RGB noise injection in the DSP sample domain
// --------------------------------------------
// Input: RGB voltage
// Output: RGB voltage
//
// Adds analog-like RGB noise and crosstalk to the framed 1D raster between
// `frameh.slang` and `framev.slang`. The pass keeps sampling and addressing
// contract-aware, preserves the alpha-carried `phase_rel_sample` state, and
// can be inserted into the working-rate DSP chain.
//
// Covered effects:
//  - broadband AWGN
//  - nearest-neighbor RG/BG crosstalk aligned to the wiring order
//  - pixel-clock feedthrough with odd-harmonic square-wave drive
//  - luminance/subcarrier contamination when a color subcarrier is present
//  - sample jitter / phase noise

#pragma name NoiseRGB
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "subframe.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/noise-rgb.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_RGB_NOISE_HEADER " —— Debug RGB Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter RGB_NOISE_BYPASS "Bypass RGB noise" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    uint CurrentSubFrame;
    uint TotalSubFrames;
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

    float RGB_NOISE_AWGN_DB;
    float RGB_NOISE_RG_XTALK_DB;
    float RGB_NOISE_BG_XTALK_DB;
    float RGB_NOISE_CLOCK_DB;
    float RGB_NOISE_YCROSSTALK_DB;
    float RGB_NOISE_JITTER_UI;

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
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define RGB_NOISE_AWGN_DB config.RGB_NOISE_AWGN_DB
#define RGB_NOISE_RG_XTALK_DB config.RGB_NOISE_RG_XTALK_DB
#define RGB_NOISE_BG_XTALK_DB config.RGB_NOISE_BG_XTALK_DB
#define RGB_NOISE_CLOCK_DB config.RGB_NOISE_CLOCK_DB
#define RGB_NOISE_YCROSSTALK_DB config.RGB_NOISE_YCROSSTALK_DB
#define RGB_NOISE_JITTER_UI config.RGB_NOISE_JITTER_UI

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float PHASE_ZERO;
    float RGB_NOISE_PRESET;
    float RGB_NOISE_CLOCK_HARMONICS;

#ifdef OPTION_DEBUG
    float RGB_NOISE_BYPASS;
#endif  // OPTION_DEBUG
} global;

#define PHASE_ZERO global.PHASE_ZERO
#define RGB_NOISE_PRESET global.RGB_NOISE_PRESET
#define RGB_NOISE_CLOCK_HARMONICS global.RGB_NOISE_CLOCK_HARMONICS

#ifdef OPTION_DEBUG
#define RGB_NOISE_BYPASS global.RGB_NOISE_BYPASS
#endif  // OPTION_DEBUG

struct NoiseRGBState {
    float frame_width;
    float frame_height;
    float data_length;
    float fs_current;
    float fs_original;
    float initial_phase_frac;
    float sc_freq_hz;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseRGBState vNoiseState;

// Reconstruct the packed 1D raster geometry and timing once per vertex from
// the contract API. The fragment stage then consumes only these precomputed,
// contract-consistent values when indexing the DSP signal.
NoiseRGBState compute_noise_state()
{
    NoiseRGBState state;

    float sc_freq_hz;
    int standard;
    compute_subcarrier_freq(SC_FREQ_MODE, SC_FREQ, config.OriginalFPS, sc_freq_hz, standard);

    state.frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    state.frame_height = contract_frame_height(
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
    state.data_length = max(contract_data_length(state.frame_width, state.frame_height), 1.0);
    state.fs_current = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    state.fs_original = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);
    state.initial_phase_frac = contract_subframe_aware_initial_field_phase_frac(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES,
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        PHASE_ZERO);
    state.sc_freq_hz = max(sc_freq_hz, 0.0);

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vNoiseState = compute_noise_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in NoiseRGBState vNoiseState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

struct NoiseGradeSettings {
    float awgn_db;
    float rg_xtalk_db;
    float bg_xtalk_db;
    float clock_db;
    float clock_harmonics;
    float ycrosstalk_db;
    float jitter_ui;
};

// Resolve the selected noise grade into one coherent parameter bundle.
// `Custom` preserves the menu sliders, while the graded presets override them
// with curated values that roughly track professional, consumer, and degraded
// analog RGB paths.
NoiseGradeSettings resolve_noise_grade_settings()
{
    if (RGB_NOISE_PRESET < 0.5) {
        return NoiseGradeSettings(
            RGB_NOISE_AWGN_DB,
            RGB_NOISE_RG_XTALK_DB,
            RGB_NOISE_BG_XTALK_DB,
            RGB_NOISE_CLOCK_DB,
            RGB_NOISE_CLOCK_HARMONICS,
            RGB_NOISE_YCROSSTALK_DB,
            RGB_NOISE_JITTER_UI);
    }

    if (RGB_NOISE_PRESET < 1.5) {
        return NoiseGradeSettings(-50.0, -50.0, -50.0, -50.0, 3.0, -50.0, 3.0);
    }

    if (RGB_NOISE_PRESET < 2.5) {
        return NoiseGradeSettings(-40.0, -40.0, -40.0, -40.0, 5.0, -40.0, 6.0);
    }

    return NoiseGradeSettings(-30.0, -30.0, -30.0, -30.0, 7.0, -30.0, 12.00);
}

// dB/linear conversions use the shared helpers from `common.inc`.

// Fetch one sample from the packed DSP raster using integer row/column
// decomposition. This keeps addressing aligned with the framed-signal
// contract instead of relying on presentation-space UV sampling.
vec4 fetch_signal_sample(float sample_index, NoiseRGBState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    int frame_width_i = max(int(state.frame_width + 0.5), 1);
    int data_limit_i = max(int(data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, data_limit))), 0, data_limit_i);
    int texel_y = clamped_index_i / frame_width_i;
    int texel_x = clamped_index_i - texel_y * frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(config.SourceSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SourceSize.y) - 1, 0));

    return texelFetch(Source, ivec2(texel_x, texel_y), 0);
}

// Sample between adjacent DSP samples with a simple linear blend. This is
// used for jitter/phase-noise perturbation so the pass can shift sample timing
// without breaking the underlying packed 1D addressing model.
vec4 sample_signal_linear(float sample_index, NoiseRGBState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float index0 = floor(clamped_index);
    float frac = clamped_index - index0;

    vec4 s0 = fetch_signal_sample(index0, state);
    vec4 s1 = fetch_signal_sample(min(index0 + 1.0, data_limit), state);
    return mix(s0, s1, frac);
}

// Build a band-limited square-wave drive from odd harmonics. This approximates
// digital clock feedthrough while letting the user choose how "sharp" the
// coupled pixel-clock contamination should appear.
float square_wave_drive(float cycles, float max_harmonic)
{
    float drive = 0.0;
    for (int h = 1; h <= 9; h += 2) {
        if (float(h) > max_harmonic + 0.5)
            break;

        drive += sin(2.0 * PI * float(h) * cycles) / float(h);
    }

    return clamp(drive * (4.0 / PI), -1.0, 1.0);
}

// Express timing jitter directly in sample-space units. A slower Gaussian,
// line-correlated component provides coarse phase wander, while a smaller
// blue-noise term adds fine-grained sample-to-sample motion.
float compute_jitter_samples(float sample_index, int output_y_i, uint frame, float jitter_ui)
{
    float jitter_amp = jitter_ui * 0.02;
    if (jitter_amp <= 0.0)
        return 0.0;

    float line_jitter = gaussian_noise3(
        uvec2(frame ^ 0x6D2B79F5u, uint(output_y_i)),
        frame,
        0x91E10DA5u).x * jitter_amp;
    float fine_jitter = tpdf_blue_noise_1x(vec2(sample_index, float(output_y_i)), frame) * jitter_amp;

    return line_jitter + 0.5 * fine_jitter;
}

// Model nearest-neighbor coupling for the physical bundle order
// Pixel Clock -> Red -> Green -> Blue -> YC. Red is therefore pulled mainly
// toward green, blue is pulled mainly toward green, and the center green trace
// sees a weaker bidirectional average of both neighbors.
vec3 apply_wired_crosstalk(vec3 color, float rg_xtalk_db, float bg_xtalk_db)
{
    float rg_amp = db_to_linear(rg_xtalk_db);
    float bg_amp = db_to_linear(bg_xtalk_db);

    vec3 coupled = color;
    coupled.r += rg_amp * (color.g - color.r);
    coupled.g += 0.35 * rg_amp * (color.r - color.g);
    coupled.g += 0.35 * bg_amp * (color.b - color.g);
    coupled.b += bg_amp * (color.g - color.b);

    return coupled;
}

// Inject pixel-clock feedthrough using the local horizontal edge energy and a
// square-wave phase drive locked to the reconstructed sample clock. The clock
// conductor sits closest to red in the assumed bundle, so red receives the
// strongest pickup, green a weaker adjacent imprint, and blue only a faint
// residual.
vec3 compute_clock_crosstalk(
    float sample_index,
    vec3 center,
    vec3 left,
    vec3 right,
    float clock_db,
    float clock_harmonics,
    NoiseRGBState state)
{
    float clock_amp = db_to_linear(clock_db);
    if (clock_amp <= EPS)
        return vec3(0.0);

    float clock_cycles = fract(state.initial_phase_frac + sample_index * state.fs_original / max(state.fs_current, EPS));
    float drive = square_wave_drive(clock_cycles, clock_harmonics);
    vec3 edge = 0.5 * (left + right) - center;
    vec3 wired_edge = vec3(
        edge.r + 0.35 * edge.g,
        0.30 * edge.r + 0.45 * edge.g,
        0.10 * edge.g + 0.05 * edge.b);

    return drive * clock_amp * wired_edge;
}

// Model luma-to-chroma leakage tied to the color subcarrier phase. With the
// YC line assumed to sit on the far side of blue in the bundle, blue receives
// the strongest phase-colored contamination, green a smaller correlated ripple,
// and red only a trace amount.
vec3 compute_y_subcarrier_crosstalk(float sample_index, vec3 color, float ycrosstalk_db, NoiseRGBState state)
{
    float sc_amp = db_to_linear(ycrosstalk_db);
    if (sc_amp <= EPS || state.sc_freq_hz <= EPS)
        return vec3(0.0);

    float carrier_cycles = fract(PHASE_ZERO / 360.0 + sample_index * state.sc_freq_hz / max(state.fs_current, EPS));
    float carrier_i = sin(2.0 * PI * carrier_cycles);
    float carrier_q = cos(2.0 * PI * carrier_cycles);
    float y = dot(color, vec3(0.299, 0.587, 0.114));

    return sc_amp * y * vec3(0.10 * carrier_i, -0.20 * carrier_q, 0.85 * carrier_q + 0.15 * carrier_i);
}

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= vNoiseState.frame_width || output_y >= vNoiseState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    float sample_index = output_y * vNoiseState.frame_width + output_x;
    vec4 center_sample = fetch_signal_sample(sample_index, vNoiseState);

#ifdef OPTION_DEBUG
    if (RGB_NOISE_BYPASS > 0.5) {
        FragColor = center_sample;
        return;
    }
#endif  // OPTION_DEBUG

    NoiseGradeSettings grade = resolve_noise_grade_settings();
    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    float jitter_samples = compute_jitter_samples(sample_index, output_y_i, frame, grade.jitter_ui);
    float jittered_index = sample_index + jitter_samples;

    vec4 jittered_sample = sample_signal_linear(jittered_index, vNoiseState);
    vec4 left_sample = sample_signal_linear(jittered_index - 1.0, vNoiseState);
    vec4 right_sample = sample_signal_linear(jittered_index + 1.0, vNoiseState);

    vec3 color = jittered_sample.rgb;
    color += compute_clock_crosstalk(
        jittered_index,
        color,
        left_sample.rgb,
        right_sample.rgb,
        grade.clock_db,
        grade.clock_harmonics,
        vNoiseState);
    color += compute_y_subcarrier_crosstalk(jittered_index, color, grade.ycrosstalk_db, vNoiseState);
    color = apply_wired_crosstalk(color, grade.rg_xtalk_db, grade.bg_xtalk_db);
    color += gaussian_noise3(uvec2(uint(output_x_i), uint(output_y_i)), frame, 0xD3ADB33Fu)
        * db_to_linear(grade.awgn_db);

    FragColor = vec4(color, jittered_sample.a);
}
