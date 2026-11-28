#version 450

// Filename: noise-composite.slang
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
// Composite video noise injection in the DSP sample domain
// --------------------------------------------
// Input: Composite video voltage
// Output: Composite video voltage
//
// Adds analog-like composite video noise to the framed 1D raster between
// `frameh.slang` and `framev.slang`. The pass keeps sampling and addressing
// contract-aware, preserves the alpha-carried `phase_rel_sample` state, and
// can be inserted into the working-rate DSP chain.
//
// Covered effects:
//  - broadband AWGN
//  - H-rate ground-bounce striping / vertical-line interference
//  - sample jitter / phase noise

#pragma name NoiseComposite
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "subframe.inc"

#include "menus/parameters/noise-composite.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS)

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_COMPOSITE_NOISE_HEADER " —— Debug Composite Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter COMPOSITE_NOISE_BYPASS "Bypass Composite noise" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 CompositeOutSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    uint CurrentSubFrame;
    uint TotalSubFrames;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;

    float COMPOSITE_NOISE_AWGN_DB;
    float COMPOSITE_NOISE_CLOCK_DB;
    float COMPOSITE_NOISE_JITTER_UI;
    float COMPOSITE_NOISE_PRESET;
    float COMPOSITE_NOISE_CLOCK_HARMONIC;
    float PIXEL_CLOCK_FRAC11;
} config;

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, global.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, global.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define COMPOSITE_NOISE_AWGN_DB config.COMPOSITE_NOISE_AWGN_DB
#define COMPOSITE_NOISE_CLOCK_DB config.COMPOSITE_NOISE_CLOCK_DB
#define COMPOSITE_NOISE_JITTER_UI config.COMPOSITE_NOISE_JITTER_UI
#define COMPOSITE_NOISE_PRESET config.COMPOSITE_NOISE_PRESET
#define COMPOSITE_NOISE_CLOCK_HARMONIC config.COMPOSITE_NOISE_CLOCK_HARMONIC

layout(std140, set = 0, binding = 0) uniform UBO
{
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
    float SC_FREQ_FRAC6;
    float SC_FREQ_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float PHASE_ZERO;
    float SHORTEN_ODD_FIELD_TIME;

#ifdef OPTION_DEBUG
    float COMPOSITE_NOISE_BYPASS;
#endif  // OPTION_DEBUG
} global;

#define PHASE_ZERO (global.PHASE_ZERO + timing_profile_initial_phase(TIMING_PROFILE_MODE, 0.0))
#define SHORTEN_ODD_FIELD_TIME timing_profile_field_adjustment(TIMING_PROFILE_MODE, global.SHORTEN_ODD_FIELD_TIME)

#ifdef OPTION_DEBUG
#define COMPOSITE_NOISE_BYPASS global.COMPOSITE_NOISE_BYPASS
#endif  // OPTION_DEBUG

struct NoiseCompositeState {
    double frame_width;
    float data_length;
    float fs_current;
    float fs_original;
    float h_freq_hz;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseCompositeState vNoiseState;

// Reconstruct the packed 1D raster geometry and timing once per vertex from
// the contract API. The fragment stage then consumes only these precomputed,
// contract-consistent values when indexing the DSP signal.
NoiseCompositeState compute_noise_state()
{
    NoiseCompositeState state;

    state.frame_width = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS), DSP_WORKING_FS);
    float frame_height = contract_frame_height(
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
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, global.FIELD_ODD, state.frame_width,
        contract_data_length(state.frame_width, frame_height)), 1.0);
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
    state.h_freq_hz = contract_h_frequency(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ
    );

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
layout(location = 1) flat in NoiseCompositeState vNoiseState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;
layout(set = 0, binding = 2) uniform sampler2D CompositeOut;

struct NoiseGradeSettings {
    float awgn_db;
    float clock_db;
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
    if (COMPOSITE_NOISE_PRESET < 0.5) {
        return NoiseGradeSettings(
            COMPOSITE_NOISE_AWGN_DB,
            COMPOSITE_NOISE_CLOCK_DB,
            COMPOSITE_NOISE_JITTER_UI);
    }

    // Professional: AWGN (external) dominated, low systematic error
    // Consumer: perceptual balance between AWGN and systematic error
    // Degraded: Systematic error (failures) dominate
    if (COMPOSITE_NOISE_PRESET < 1.5)
        return NoiseGradeSettings(-60.0, 20.0, 1.0);
    if (COMPOSITE_NOISE_PRESET < 2.5)
        return NoiseGradeSettings(-50.0, 30.0, 2.0);
    return NoiseGradeSettings(-40.0, 40.0, 9.0);
}

// Fetch one sample from the packed DSP raster using integer row/column
// decomposition. This keeps addressing aligned with the framed-signal
// contract instead of relying on presentation-space UV sampling.
vec4 fetch_signal_sample(float sample_index, NoiseCompositeState state)
{
    return fetch_input_sample(CompositeOut, config.CompositeOutSize.xy, sample_index, float(state.frame_width), state.data_length);
}

// Sample between adjacent DSP samples with a simple linear blend. This is
// used for jitter/phase-noise perturbation so the pass can shift sample timing
// without breaking the underlying packed 1D addressing model.
vec4 sample_signal_linear(float sample_index, NoiseCompositeState state)
{
    float data_limit = max(state.data_length - 1.0, 0.0);
    float clamped_index = clamp(sample_index, 0.0, data_limit);
    float index0 = floor(clamped_index);
    float frac = clamped_index - index0;

    vec4 s0 = fetch_signal_sample(index0, state);
    vec4 s1 = fetch_signal_sample(min(index0 + 1.0, data_limit), state);
    return mix(s0, s1, frac);
}

// Closed-form "saggy saw" / integrated-saw appearance kernel over one cycle:
//   f(x) = PI * x / 2 - x * x / 4,  for 0 <= x <= 2 PI.
// Normalize it to [0, 1] so it can drive a positive interference envelope.
float saggy_saw_wave(float phase_cycles)
{
    float x = 2.0 * PI * fract(phase_cycles);
    float sag = 0.5 * PI * x - 0.25 * x * x;

    return clamp(sag / max(0.25 * PI * PI, EPS), 0.0, 1.0);
}

// Treat ground bounce as an H-sync-aligned stripe generator. The user chooses
// the stripe spacing as a multiple of H, and this helper suppresses the effect
// if that requested tone would exceed the available pixel-clock bandwidth. The
// visible profile is the positive integrated-saw envelope rather than a literal
// alternating cosine waveform.
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

// Model ground bounce as a line-locked vertical stripe artifact. The phase is
// intentionally reset at each H line so the interference stays anchored to a
// fixed horizontal position while its strength still follows local signal level.
float compute_ground_bounce_shape(
    float sample_index,
    float composite_level,
    float phase_rel_sample,
    NoiseCompositeState state)
{
    float ground_bounce_harmonic = max(round(COMPOSITE_NOISE_CLOCK_HARMONIC), 1.0);
    float fundamental_hz = ground_bounce_harmonic * state.h_freq_hz;
    float fundamental_cycles = carrier_phase(
        sample_index,
        fundamental_hz,
        state.fs_current,
        0.0
    );
    float drive = equal_energy_odd_harmonic_drive_hsync_locked(
        fundamental_cycles,
        fundamental_hz,
        state.fs_original);
    return abs(drive) * composite_level;
}

void main()
{
    vec2 UV = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(UV.x));
    int output_y_i = int(floor(UV.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= vNoiseState.frame_width || output_y * vNoiseState.frame_width + output_x >= vNoiseState.data_length) {
        FragColor = vec4(0.0);
        return;
    }

    float sample_index = float(double(output_y) * vNoiseState.frame_width + double(output_x));
    vec2 raster = timing_profile_raster_position(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, global.FIELD_ODD, sample_index, vNoiseState.frame_width);

#ifdef OPTION_DEBUG
        if (COMPOSITE_NOISE_BYPASS > 0.5) {
        FragColor = fetch_signal_sample(sample_index, vNoiseState);
        return;
    }
#endif  // OPTION_DEBUG

    NoiseGradeSettings grade = resolve_noise_grade_settings();
    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    float jitter_samples = compute_jitter_samples(sample_index, int(raster.y), frame, grade.jitter_ui);
    float jittered_index = sample_index + jitter_samples;

    vec4 jittered_sample = sample_signal_linear(jittered_index, vNoiseState);

    // With composite video there is no separate Y/C crosstalk path. The signal
    // remains a single composite voltage, so all systematic distortion is
    // captured as scalar interference applied to the line signal itself.
    float awgn_sigma = db_to_linear(grade.awgn_db);
    float ground_bounce_share = db_to_linear(grade.clock_db);

    float ground_bounce_shape = compute_ground_bounce_shape(
        jittered_index,
        jittered_sample.r,
        jittered_sample.a,
        vNoiseState
    );
    float ground_bounce_amount = ground_bounce_share * ground_bounce_shape;

    uvec2 noise_seed = uvec2(uint(raster.x), uint(raster.y));
    float awgn_noise = gaussian_noise2(noise_seed, frame, 0xD3ADB33Fu).x;

    float composite_signal = jittered_sample.r + awgn_sigma * awgn_noise + ground_bounce_amount;
    FragColor = vec4(composite_signal, composite_signal, composite_signal, jittered_sample.a);
}
