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
        return NoiseGradeSettings(-50.0, 20.0, 20.0, 30.0, 0.0, 2.0);
    }

    if (RGB_NOISE_PRESET < 2.5) {
        return NoiseGradeSettings(-40.0, 30.0, 30.0, 40.0, 5.0, 6.0);
    }

    return NoiseGradeSettings(-30.0, 40.0, 40.0, 50.0, 10.0, 30.0);
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

// Build a sample-rate-limited odd-harmonic clock drive from a cosine-aligned
// carrier. The working sample rate decides how many odd harmonics fit under
// Nyquist, capped at 9, and each included harmonic contributes equal crosstalk
// energy.
float equal_energy_odd_harmonic_drive(float fundamental_cycles, float fundamental_hz, float fs_current)
{
    float nyquist_hz = 0.5 * fs_current;
    float drive = 0.0;
    int harmonic_count = 0;

    for (int h = 1; h <= 9; h += 2) {
        if (float(h) * fundamental_hz > nyquist_hz + EPS)
            break;

        drive += cos(2.0 * PI * float(h) * fundamental_cycles);
        harmonic_count += 1;
    }

    if (harmonic_count == 0)
        return 0.0;

    return clamp(drive / sqrt(float(harmonic_count)), -1.0, 1.0);
}

// Treat subcarrier crosstalk as a CW tone estimate built from as many
// harmonics as fit under the working-rate Nyquist limit, capped at 9. The
// phase origin comes from the dedicated contract subcarrier helper, which is
// framecount-based and independent from any subframe notion. Each included
// tone contributes equal energy.
float equal_energy_subcarrier_drive(float sample_index, NoiseRGBState state)
{
    if (state.sc_freq_hz <= EPS)
        return 0.0;

    float nyquist_hz = 0.5 * state.fs_current;
    int max_harmonic = min(9, int(floor((nyquist_hz + EPS) / max(state.sc_freq_hz, EPS))));
    float base_cycles = reconstruct_carrier_cycles(
        sample_index,
        state.initial_subcarrier_phase_frac,
        state.sc_freq_hz,
        state);
    float drive = 0.0;
    int tone_count = 0;

    for (int n = 1; n <= 9; n++) {
        if (n > max_harmonic)
            break;

        drive += cos(2.0 * PI * float(n) * base_cycles);
        tone_count += 1;
    }

    if (tone_count == 0)
        return 0.0;

    return clamp(drive / sqrt(float(tone_count)), -1.0, 1.0);
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

// AWGN sets the total RMS random noise budget. The other controls are dB-valued
// systematic shares relative to AWGN that modulate deterministic MagDeltaV /
// clock / YC shapes:
//   set 1 (red):   Clock + RG + AWGN
//   set 2 (green): RG + BG + AWGN
//   set 3 (blue):  BG + YC + AWGN
float compute_noise_budget_sigma(float awgn_db)
{
    return db_to_linear(awgn_db);
}

float compute_systematic_share(float share_db)
{
    return db_to_linear(share_db);
}

// Estimate the ideal mean sample count N implied by the AWGN noise budget,
// then quantize it to the coarsest available MagDeltaV mip block that still
// covers at least that many source texels.
float compute_mag_delta_v_ideal_sample_count(float fs_current, float awgn_db)
{
    float f_min = 0.5 * fs_current * exp2(awgn_db / 6.0);
    return fs_current / max(f_min, EPS);
}

float compute_mag_delta_v_lod(float ideal_sample_count)
{
    vec2 mag_delta_size = max(vec2(textureSize(MagDeltaV, 0)), vec2(1.0));
    float max_lod = floor(log2(max(max(mag_delta_size.x, mag_delta_size.y), 1.0)));
    float lod = ceil(0.5 * log2(max(ideal_sample_count, 1.0)));

    return clamp(lod, 0.0, max_lod);
}

// Inject pixel-clock feedthrough using the local red-channel edge energy and a
// sample-rate-limited odd-harmonic drive locked to the reconstructed sample
// clock. Clock crosstalk is restricted to red only.
vec3 compute_clock_crosstalk_shape(
    float sample_index,
    vec3 center,
    vec3 left,
    vec3 right,
    NoiseRGBState state)
{
    float clock_cycles = reconstruct_carrier_cycles(
        sample_index,
        state.initial_field_phase_frac,
        state.fs_original,
        state);
    float drive = equal_energy_odd_harmonic_drive(clock_cycles, state.fs_original, state.fs_current);
    float red_edge = abs(0.5 * (left.r + right.r) - center.r);

    return vec3(clamp(abs(drive) * red_edge, 0.0, 1.0), 0.0, 0.0);
}

// Treat subcarrier crosstalk as a blue-only CW bleed tied to the subcarrier
// phase itself rather than an explicit Y/C reconstruction.
vec3 compute_subcarrier_crosstalk_shape(float sample_index, NoiseRGBState state)
{
    float blue_tone = abs(equal_energy_subcarrier_drive(sample_index, state));
    return vec3(0.0, 0.0, clamp(blue_tone, 0.0, 1.0));
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
    vec4 left_sample = sample_signal_linear(jittered_index - 1.0, vNoiseState);
    vec4 right_sample = sample_signal_linear(jittered_index + 1.0, vNoiseState);

    float awgn_sigma = compute_noise_budget_sigma(grade.awgn_db);
    float rg_share = compute_systematic_share(grade.rg_xtalk_db);
    float bg_share = compute_systematic_share(grade.bg_xtalk_db);
    float clock_share = compute_systematic_share(grade.clock_db);
    float yc_share = compute_systematic_share(grade.ycrosstalk_db);

    float mag_delta_v_lod = compute_mag_delta_v_lod(
        compute_mag_delta_v_ideal_sample_count(vNoiseState.fs_current, grade.awgn_db));
    vec3 mag_delta_v = clamp(sample_mag_delta_v_lod(jittered_index, mag_delta_v_lod, vNoiseState), vec3(0.0), vec3(1.0));
    vec3 clock_shape = compute_clock_crosstalk_shape(
        jittered_index,
        jittered_sample.rgb,
        left_sample.rgb,
        right_sample.rgb,
        vNoiseState);
    vec3 yc_shape = compute_subcarrier_crosstalk_shape(jittered_index, vNoiseState);

    float red_rg_share = rg_share * mag_delta_v.g;
    float red_clock_share = clock_share * clock_shape.r;
    float green_rg_share = rg_share * mag_delta_v.r;
    float green_bg_share = bg_share * mag_delta_v.b;
    float blue_bg_share = bg_share * mag_delta_v.g;
    float blue_yc_share = yc_share * yc_shape.b;

    uvec2 noise_seed = uvec2(uint(output_x_i), uint(output_y_i));
    vec3 awgn_noise = gaussian_noise3(noise_seed, frame, 0xD3ADB33Fu);

    vec3 color = jittered_sample.rgb;
    color += awgn_sigma * vec3(
        awgn_noise.r + red_rg_share + red_clock_share,
        awgn_noise.g + green_rg_share + green_bg_share,
        awgn_noise.b + blue_bg_share + blue_yc_share);

    FragColor = vec4(color, jittered_sample.a);
}
