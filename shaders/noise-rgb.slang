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
//  - MagDeltaV-driven RG/BG capacitive crosstalk aligned to the wiring order
//  - H-rate ground-bounce striping / vertical-line crosstalk
//  - color-carrier contamination when a subcarrier is present
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
#pragma parameter RGB_NOISE_VIEW_MAG_DELTAV "View MagDeltaV" 0.0 0.0 1.0 1.0
#pragma parameter RGB_NOISE_MAG_DELTAV_MIP_LOD "MagDeltaV mip LOD" 0.0 0.0 12.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SysRGBBandlimitSize;
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
    float RGB_NOISE_CLOCK_HARMONIC;
    float SHORTEN_ODD_FIELD_TIME;

#ifdef OPTION_DEBUG
    float RGB_NOISE_BYPASS;
    float RGB_NOISE_VIEW_MAG_DELTAV;
    float RGB_NOISE_MAG_DELTAV_MIP_LOD;
#endif  // OPTION_DEBUG
} global;

#define PHASE_ZERO global.PHASE_ZERO
#define RGB_NOISE_PRESET global.RGB_NOISE_PRESET
#define SHORTEN_ODD_FIELD_TIME global.SHORTEN_ODD_FIELD_TIME
#define RGB_NOISE_CLOCK_HARMONIC global.RGB_NOISE_CLOCK_HARMONIC

#ifdef OPTION_DEBUG
#define RGB_NOISE_BYPASS global.RGB_NOISE_BYPASS
#define RGB_NOISE_VIEW_MAG_DELTAV global.RGB_NOISE_VIEW_MAG_DELTAV
#define RGB_NOISE_MAG_DELTAV_MIP_LOD global.RGB_NOISE_MAG_DELTAV_MIP_LOD
#endif  // OPTION_DEBUG

struct NoiseRGBState {
    float frame_width;
    float frame_height;
    float data_length;
    float fs_current;
    float fs_original;
    float h_freq_hz;
    float initial_field_phase_frac;
    float initial_subcarrier_phase_frac;
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
    state.h_freq_hz = compute_h_freq(
        H_FREQ_MODE,
        standard,
        H_FREQ,
        state.fs_original,
        config.OriginalFPS);
    state.initial_field_phase_frac = contract_initial_field_phase_frac(
        config.FrameCount,
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
        H_BLANK_FUZZ,
        SHORTEN_ODD_FIELD_TIME,
        PHASE_ZERO);
    state.initial_subcarrier_phase_frac = contract_initial_subcarrier_phase_frac(
        config.FrameCount,
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
        H_BLANK_FUZZ,
        SHORTEN_ODD_FIELD_TIME,
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
layout(set = 0, binding = 1) uniform sampler2D Source;  // Mip 11 (1-pixel terminal mip)
layout(set = 0, binding = 2) uniform sampler2D SysRGBBandlimit;
layout(set = 0, binding = 3) uniform sampler2D MagDeltaV;  // Mip 0
layout(set = 0, binding = 4) uniform sampler2D Mip1;
layout(set = 0, binding = 5) uniform sampler2D Mip2;
layout(set = 0, binding = 6) uniform sampler2D Mip3;
layout(set = 0, binding = 7) uniform sampler2D Mip4;
layout(set = 0, binding = 8) uniform sampler2D Mip5;
layout(set = 0, binding = 9) uniform sampler2D Mip6;
layout(set = 0, binding = 10) uniform sampler2D Mip7;
layout(set = 0, binding = 11) uniform sampler2D Mip8;
layout(set = 0, binding = 12) uniform sampler2D Mip9;
layout(set = 0, binding = 13) uniform sampler2D Mip10;

struct NoiseGradeSettings {
    float awgn_db;
    float rg_xtalk_db;
    float bg_xtalk_db;
    float clock_db;
    float ycrosstalk_db;
    float jitter_ui;
};

// Resolve the selected noise grade into one coherent parameter bundle.
// AWGN remains the dB-valued total noise budget, while the other `*_DB` fields
// are interpreted as dB-valued shares relative to AWGN: 0 dB means that the
// corresponding systematic term contributes at the same level as AWGN when its
// local shape term is 1. `Custom` preserves the menu sliders, while the graded
// presets override them with curated values that roughly track professional,
// consumer, and degraded analog RGB paths.
NoiseGradeSettings resolve_noise_grade_settings()
{
    if (RGB_NOISE_PRESET < 0.5) {
        return NoiseGradeSettings(
            RGB_NOISE_AWGN_DB,
            RGB_NOISE_RG_XTALK_DB,
            RGB_NOISE_BG_XTALK_DB,
            RGB_NOISE_CLOCK_DB,
            RGB_NOISE_YCROSSTALK_DB,
            RGB_NOISE_JITTER_UI);
    }

    // Professional: AWGN (external) dominated, low systematic error
    // Consumer: perceptual balance between AWGN and systematic error
    // Degraded: Systematic error (failures) dominate

    if (RGB_NOISE_PRESET < 1.5) {
        return NoiseGradeSettings(-60.0, 20.0, 20.0, -3.0, 0.0, 2.0);
    }

    if (RGB_NOISE_PRESET < 2.5) {
        return NoiseGradeSettings(-50.0, 30.0, 30.0, 3.0, 10.0, 6.0);
    }

    return NoiseGradeSettings(-40.0, 40.0, 40.0, 6.0, 20.0, 20.0);
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

    texel_x = clamp(texel_x, 0, max(int(config.SysRGBBandlimitSize.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(config.SysRGBBandlimitSize.y) - 1, 0));

    return texelFetch(SysRGBBandlimit, ivec2(texel_x, texel_y), 0);
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

// Reconstruct a carrier's fractional cycle at an arbitrary packed-sample index.
// Split the index into row/column components so the wrapped phase is formed from
// smaller terms; this preserves field-to-field offsets even when the total
// sample index grows large.
float reconstruct_carrier_cycles(
    float sample_index,
    float base_phase_cycles,
    float carrier_hz,
    NoiseRGBState state)
{
    float fs_safe = max(state.fs_current, EPS);
    float frame_width = max(state.frame_width, 1.0);
    float sample_y = floor(sample_index / frame_width);
    float sample_x = sample_index - sample_y * frame_width;
    float cycles_per_sample = carrier_hz / fs_safe;
    float cycles_per_line = frame_width * cycles_per_sample;

    return fract(base_phase_cycles + fract(sample_y * cycles_per_line) + sample_x * cycles_per_sample);
}

// Reconstruct a carrier phase that hard-resets at each line start so the tone
// stays H-sync aligned and lands at a fixed horizontal position every line.
float reconstruct_line_locked_cycles(
    float sample_index,
    float carrier_hz,
    NoiseRGBState state)
{
    float fs_safe = max(state.fs_current, EPS);
    float frame_width = max(state.frame_width, 1.0);
    float sample_y = floor(sample_index / frame_width);
    float sample_x = sample_index - sample_y * frame_width;

    return fract(sample_x * carrier_hz / fs_safe);
}

// Evaluate a finite cosine harmonic stack in closed form. Wrapping the phase
// to one cycle keeps the trigonometric arguments small, while the near-singular
// fallback handles the Dirichlet-kernel limit when the denominator collapses.
float sum_cosine_harmonics(float phase_cycles, int harmonic_count)
{
    if (harmonic_count <= 0)
        return 0.0;

    float theta = 2.0 * PI * fract(phase_cycles);
    float half_theta = 0.5 * theta;
    float denom = sin(half_theta);

    if (abs(denom) <= 16.0 * EPS)
        return float(harmonic_count);

    return sin(float(harmonic_count) * half_theta)
        * cos(0.5 * float(harmonic_count + 1) * theta) / denom;
}

// Closed-form odd-harmonic cosine stack used by the line-locked ground-bounce
// comb. The limit branch covers phase positions where every odd harmonic has
// the same sign (theta near integer multiples of pi).
float sum_cosine_odd_harmonics(float phase_cycles, int odd_harmonic_count)
{
    if (odd_harmonic_count <= 0)
        return 0.0;

    float theta = 2.0 * PI * fract(phase_cycles);
    float denom = sin(theta);

    if (abs(denom) <= 16.0 * EPS)
        return float(odd_harmonic_count) * cos(theta);

    return 0.5 * sin(2.0 * float(odd_harmonic_count) * theta) / denom;
}

// Evaluate an odd-harmonic range in closed form by differencing two prefix
// sums. This lets the ground-bounce comb start above the lowest H harmonics
// without falling back to an explicit loop.
float sum_cosine_odd_harmonics_range(
    float phase_cycles,
    int first_odd_harmonic,
    int odd_harmonic_count)
{
    if (odd_harmonic_count <= 0)
        return 0.0;

    int first_odd_index = max((first_odd_harmonic - 1) / 2, 0);
    return sum_cosine_odd_harmonics(phase_cycles, first_odd_index + odd_harmonic_count)
        - sum_cosine_odd_harmonics(phase_cycles, first_odd_index);
}

// Closed-form "saggy saw" / integrated-saw appearance kernel over one cycle:
//   f(x) = PI * x / 2 - x * x / 4,  for 0 <= x <= 2 PI.
// Normalize it to [0, 1] so it can drive a positive crosstalk injection.
float saggy_saw_wave(float phase_cycles)
{
    float x = 2.0 * PI * fract(phase_cycles);
    float sag = 0.5 * PI * x - 0.25 * x * x;

    return clamp(sag / max(0.25 * PI * PI, EPS), 0.0, 1.0);
}

// Treat ground bounce as a fixed H-sync-aligned tone comb, but use the
// integrated-harmonic "saggy saw" closed form for the visual envelope.
// The 9H fundamental stays line-locked and the effect is suppressed if the
// requested tone would exceed the pixel-clock limit.
float equal_energy_odd_harmonic_drive_hsync_locked(
    float fundamental_cycles,
    float fundamental_hz,
    float pixel_clock_hz)
{
    if (fundamental_hz <= EPS || pixel_clock_hz <= EPS)
        return 0.0;

    int max_harmonic = int(floor((pixel_clock_hz + EPS) / fundamental_hz));
    if (max_harmonic <= 0)
        return 0.0;

    return saggy_saw_wave(fundamental_cycles);
}

// Treat subcarrier crosstalk as a CW tone estimate built from all harmonics
// that fit under the working-rate Nyquist limit. The phase origin comes from
// the dedicated contract subcarrier helper, which is framecount-based and
// independent from any subframe notion. Each included tone contributes equal
// energy, and the closed-form sum avoids an explicit harmonic cap.
float equal_energy_subcarrier_drive(float sample_index, NoiseRGBState state)
{
    if (state.sc_freq_hz <= EPS || state.fs_current <= EPS)
        return 0.0;

    float nyquist_hz = 0.5 * state.fs_current;
    int harmonic_count = max(int(floor((nyquist_hz + EPS) / state.sc_freq_hz)), 0);

    if (harmonic_count == 0)
        return 0.0;

    float base_cycles = reconstruct_carrier_cycles(
        sample_index,
        state.initial_subcarrier_phase_frac,
        state.sc_freq_hz,
        state);
    float drive = sum_cosine_harmonics(base_cycles, harmonic_count);

    return clamp(drive / sqrt(float(harmonic_count)), -1.0, 1.0);
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

vec2 mag_delta_v_uv_from_index(float sample_index, NoiseRGBState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float sample_y = floor(clamped_index / max(state.frame_width, 1.0));
    float sample_x = clamped_index - sample_y * state.frame_width;
    vec2 mag_delta_size = max(vec2(textureSize(MagDeltaV, 0)), vec2(1.0));

    return (vec2(sample_x, sample_y) + vec2(0.5)) / mag_delta_size;
}

vec3 sample_mag_delta_v_level(vec2 mag_delta_uv, int lod_i)
{
    if (lod_i <= 0)
        return texture(MagDeltaV, mag_delta_uv).rgb;
    if (lod_i == 1)
        return texture(Mip1, mag_delta_uv).rgb;
    if (lod_i == 2)
        return texture(Mip2, mag_delta_uv).rgb;
    if (lod_i == 3)
        return texture(Mip3, mag_delta_uv).rgb;
    if (lod_i == 4)
        return texture(Mip4, mag_delta_uv).rgb;
    if (lod_i == 5)
        return texture(Mip5, mag_delta_uv).rgb;
    if (lod_i == 6)
        return texture(Mip6, mag_delta_uv).rgb;
    if (lod_i == 7)
        return texture(Mip7, mag_delta_uv).rgb;
    if (lod_i == 8)
        return texture(Mip8, mag_delta_uv).rgb;
    if (lod_i == 9)
        return texture(Mip9, mag_delta_uv).rgb;
    if (lod_i == 10)
        return texture(Mip10, mag_delta_uv).rgb;

    return texture(Source, mag_delta_uv).rgb;
}

vec3 sample_mag_delta_v_lod(float sample_index, float lod, NoiseRGBState state)
{
    vec2 mag_delta_uv = mag_delta_v_uv_from_index(sample_index, state);
    float lod_clamped = clamp(lod, 0.0, 11.0);
    int lod0_i = int(floor(lod_clamped));
    int lod1_i = min(lod0_i + 1, 11);
    float lod_frac = lod_clamped - float(lod0_i);

    vec3 sample0 = sample_mag_delta_v_level(mag_delta_uv, lod0_i);
    vec3 sample1 = sample_mag_delta_v_level(mag_delta_uv, lod1_i);
    return mix(sample0, sample1, lod_frac);
}

ivec2 mag_delta_v_level_size(int lod_i)
{
    if (lod_i <= 0)
        return max(textureSize(MagDeltaV, 0), ivec2(1));
    if (lod_i == 1)
        return max(textureSize(Mip1, 0), ivec2(1));
    if (lod_i == 2)
        return max(textureSize(Mip2, 0), ivec2(1));
    if (lod_i == 3)
        return max(textureSize(Mip3, 0), ivec2(1));
    if (lod_i == 4)
        return max(textureSize(Mip4, 0), ivec2(1));
    if (lod_i == 5)
        return max(textureSize(Mip5, 0), ivec2(1));
    if (lod_i == 6)
        return max(textureSize(Mip6, 0), ivec2(1));
    if (lod_i == 7)
        return max(textureSize(Mip7, 0), ivec2(1));
    if (lod_i == 8)
        return max(textureSize(Mip8, 0), ivec2(1));
    if (lod_i == 9)
        return max(textureSize(Mip9, 0), ivec2(1));
    if (lod_i == 10)
        return max(textureSize(Mip10, 0), ivec2(1));

    return max(textureSize(Source, 0), ivec2(1));
}

vec3 fetch_mag_delta_v_level_texel(int lod_i, ivec2 texel_coord)
{
    ivec2 level_size = mag_delta_v_level_size(lod_i);
    ivec2 clamped_coord = clamp(texel_coord, ivec2(0), max(level_size - ivec2(1), ivec2(0)));

    if (lod_i <= 0)
        return texelFetch(MagDeltaV, clamped_coord, 0).rgb;
    if (lod_i == 1)
        return texelFetch(Mip1, clamped_coord, 0).rgb;
    if (lod_i == 2)
        return texelFetch(Mip2, clamped_coord, 0).rgb;
    if (lod_i == 3)
        return texelFetch(Mip3, clamped_coord, 0).rgb;
    if (lod_i == 4)
        return texelFetch(Mip4, clamped_coord, 0).rgb;
    if (lod_i == 5)
        return texelFetch(Mip5, clamped_coord, 0).rgb;
    if (lod_i == 6)
        return texelFetch(Mip6, clamped_coord, 0).rgb;
    if (lod_i == 7)
        return texelFetch(Mip7, clamped_coord, 0).rgb;
    if (lod_i == 8)
        return texelFetch(Mip8, clamped_coord, 0).rgb;
    if (lod_i == 9)
        return texelFetch(Mip9, clamped_coord, 0).rgb;
    if (lod_i == 10)
        return texelFetch(Mip10, clamped_coord, 0).rgb;

    return texelFetch(Source, clamped_coord, 0).rgb;
}

float compute_mag_delta_v_level_frame_width(int lod_i, NoiseRGBState state)
{
    float base_storage_width = max(config.SysRGBBandlimitSize.x, 1.0);
    float level_storage_width = float(mag_delta_v_level_size(lod_i).x);

    return max(1.0,
        round(state.frame_width * max(level_storage_width / base_storage_width, 0.0)));
}

float compute_mag_delta_v_block_span(int lod_i, NoiseRGBState state)
{
    float level_frame_width = compute_mag_delta_v_level_frame_width(lod_i, state);
    float level_data_length = max(contract_data_length(level_frame_width, state.frame_height), 1.0);

    return max(state.data_length / level_data_length, 1.0);
}

vec3 sample_mag_delta_v_sliding_average_level(
    float sample_index,
    float window_sample_count,
    int lod_i,
    NoiseRGBState state)
{
    float level_frame_width = compute_mag_delta_v_level_frame_width(lod_i, state);
    float level_data_length = max(contract_data_length(level_frame_width, state.frame_height), 1.0);
    float block_span = max(state.data_length / level_data_length, 1.0);

    float window_center = clamp(sample_index + 0.5, 0.0, state.data_length);
    float window_start = max(window_center - 0.5 * window_sample_count, 0.0);
    float window_end = min(window_center + 0.5 * window_sample_count, state.data_length);
    float total_weight = max(window_end - window_start, EPS);

    int level_frame_width_i = max(int(level_frame_width + 0.5), 1);
    int last_level_index_i = max(int(level_data_length + 0.5) - 1, 0);
    int first_block_i = clamp(int(floor(window_start / block_span)), 0, last_level_index_i);
    int last_block_i = clamp(int(floor(max(window_end - EPS, 0.0) / block_span)), 0, last_level_index_i);
    vec3 weighted_sum = vec3(0.0);

    for (int tap = 0; tap < 4; tap++) {
        int block_i = first_block_i + tap;
        if (block_i > last_block_i)
            break;

        float block_start = float(block_i) * block_span;
        float block_end = min(block_start + block_span, state.data_length);
        float overlap = max(0.0, min(window_end, block_end) - max(window_start, block_start));

        if (overlap <= 0.0)
            continue;

        int texel_y = block_i / level_frame_width_i;
        int texel_x = block_i - texel_y * level_frame_width_i;
        weighted_sum += overlap * fetch_mag_delta_v_level_texel(lod_i, ivec2(texel_x, texel_y));
    }

    return weighted_sum / total_weight;
}

// Estimate the mean |ΔV| over the exact ideal support `N` by sliding a window
// across the packed 1D signal. The decimated MagDeltaV chain provides aligned
// power-of-two block averages; evaluate the nearest scales below and above the
// ideal support and blend them according to where `N` falls between their true
// block spans.
vec3 sample_mag_delta_v_sliding_average(float sample_index, float ideal_sample_count, NoiseRGBState state)
{
    float window_sample_count = max(ideal_sample_count, 1.0);
    float lod_f = clamp(log2(window_sample_count), 0.0, 11.0);
    int lod0_i = int(floor(lod_f));
    int lod1_i = min(lod0_i + 1, 11);
    vec3 avg0 = sample_mag_delta_v_sliding_average_level(
        sample_index,
        window_sample_count,
        lod0_i,
        state);

    if (lod1_i == lod0_i)
        return avg0;

    float span0 = compute_mag_delta_v_block_span(lod0_i, state);
    float span1 = compute_mag_delta_v_block_span(lod1_i, state);
    float blend = clamp((window_sample_count - span0) / max(span1 - span0, EPS), 0.0, 1.0);
    vec3 avg1 = sample_mag_delta_v_sliding_average_level(
        sample_index,
        window_sample_count,
        lod1_i,
        state);

    return mix(avg0, avg1, blend);
}

// Estimate the ideal mean sample count N implied by the AWGN noise budget.
// For amplitude-domain noise, RMS falls as 1/sqrt(N), so every 6 dB reduction
// in the target noise floor doubles the physically correct averaging support.
float compute_mag_delta_v_ideal_sample_count(float fs_current, float awgn_db)
{
    return exp2(1.0 - awgn_db / 6.0);
}

// Model ground bounce as an H-sync-aligned fixed-frequency injection: the
// phase restarts each line, the fundamental is selected as a harmonic of H,
// and only odd harmonics of that tone are included up to the pixel-clock
// limit.
vec3 compute_ground_bounce_shape(
    float sample_index,
    vec3 center,
    NoiseRGBState state)
{
    float ground_bounce_harmonic = max(round(RGB_NOISE_CLOCK_HARMONIC), 1.0);
    float fundamental_hz = ground_bounce_harmonic * state.h_freq_hz;
    float fundamental_cycles = reconstruct_line_locked_cycles(
        sample_index,
        fundamental_hz,
        state);
    float drive = equal_energy_odd_harmonic_drive_hsync_locked(
        fundamental_cycles,
        fundamental_hz,
        state.fs_original);
    float luma_level = clamp(
        dot(max(center, vec3(0.0)), vec3(0.299, 0.587, 0.114)) / max(VOLTAGE_100, EPS),
        0.0,
        1.0);
    float stripe = clamp(abs(drive) * luma_level, 0.0, 1.0);

    return vec3(stripe);
}

// Treat subcarrier crosstalk as a CW bleed with blue dominant, green at half
// strength, and red at quarter strength.
vec3 compute_subcarrier_crosstalk_shape(float sample_index, NoiseRGBState state)
{
    float carrier_tone = abs(equal_energy_subcarrier_drive(sample_index, state));
    return clamp(carrier_tone * vec3(0.25, 0.5, 1.0), vec3(0.0), vec3(1.0));
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

    if (RGB_NOISE_VIEW_MAG_DELTAV > 0.5) {
        vec3 debug_mag_delta_v = sample_mag_delta_v_lod(sample_index, RGB_NOISE_MAG_DELTAV_MIP_LOD, vNoiseState);
        FragColor = vec4(clamp(debug_mag_delta_v, 0.0, 1.0), 1.0);
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

    float awgn_sigma = db_to_linear(grade.awgn_db);
    float rg_share = db_to_linear(grade.rg_xtalk_db);
    float bg_share = db_to_linear(grade.bg_xtalk_db);
    float ground_bounce_share = db_to_linear(grade.clock_db);
    float yc_share = db_to_linear(grade.ycrosstalk_db);

    float mag_delta_v_ideal_sample_count = compute_mag_delta_v_ideal_sample_count(
        vNoiseState.fs_current,
        grade.awgn_db);
    vec3 mag_delta_v = clamp(sample_mag_delta_v_sliding_average(
        jittered_index,
        mag_delta_v_ideal_sample_count,
        vNoiseState), vec3(0.0), vec3(1.0));
    vec3 ground_bounce_shape = compute_ground_bounce_shape(
        jittered_index,
        jittered_sample.rgb,
        vNoiseState);
    vec3 yc_shape = compute_subcarrier_crosstalk_shape(jittered_index, vNoiseState);

    float red_rg_share = rg_share * mag_delta_v.g;
    float red_ground_bounce_share = ground_bounce_share * ground_bounce_shape.r;
    float red_yc_share = yc_share * yc_shape.r;
    float green_rg_share = rg_share * mag_delta_v.r;
    float green_bg_share = bg_share * mag_delta_v.b;
    float green_ground_bounce_share = ground_bounce_share * ground_bounce_shape.g;
    float green_yc_share = yc_share * yc_shape.g;
    float blue_bg_share = bg_share * mag_delta_v.g;
    float blue_ground_bounce_share = ground_bounce_share * ground_bounce_shape.b;
    float blue_yc_share = yc_share * yc_shape.b;

    uvec2 noise_seed = uvec2(uint(output_x_i), uint(output_y_i));
    vec3 awgn_noise = gaussian_noise3(noise_seed, frame, 0xD3ADB33Fu);

    vec3 color = jittered_sample.rgb;
    color += awgn_sigma * vec3(
        awgn_noise.r + red_rg_share + red_ground_bounce_share + red_yc_share,
        awgn_noise.g + green_rg_share + green_bg_share + green_ground_bounce_share + green_yc_share,
        awgn_noise.b + blue_bg_share + blue_ground_bounce_share + blue_yc_share);

    FragColor = vec4(color, jittered_sample.a);
}
