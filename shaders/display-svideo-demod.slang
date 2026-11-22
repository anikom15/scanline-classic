#version 450

// Filename: display-svideo-demod.slang
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
// Display-side S-Video decoder I, demodulator
// -------------------------------------------
// Input: Real Y, modulated C voltage
// Output: Real YPbPr voltage (unfiltered)
//
// Demodulates the chroma channel from a real subcarrier.  The sample rate
// must be high enough to avoid aliasing from mixer images.

#pragma name DisplaySVideoDemod
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "comb.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/display-svideo.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/user-video.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_SVIDEO_DEMOD_HEADER " —— Debug Display S-Video Demodulator —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_SVIDEO_DEMOD_BYPASS "Bypass display S-Video stage" 0.0 0.0 1.0 1.0
#pragma parameter CORRELATION "PAL delay-line correlation" 0.5 0.0 1.0 0.01
#pragma parameter COMB_ADJUST_X "PAL delay-line phase adjustment X (samples)" 0.0 -10.0 10.0 0.01
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    float OriginalFPS;
    uint FrameCount;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float V_FREQ_MODE;
    float V_FREQ;
    float PHASE_ZERO;
    float SHORTEN_ODD_FIELD_TIME;
    float DSP_WORKING_FS;

    float DECODER_SETUP;
    float DECODER_TYPE;
    float PAL_DECODER_MODE;

    float USER_COLOR;
    float USER_TINT;

#ifdef OPTION_DEBUG
    float DISPLAY_SVIDEO_DEMOD_BYPASS;
    float CORRELATION;
    float COMB_ADJUST_X;
#endif  // OPTION_DEBUG

} config;

#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define PHASE_ZERO config.PHASE_ZERO
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#define DSP_WORKING_FS config.DSP_WORKING_FS

#define DECODER_SETUP config.DECODER_SETUP
#define DECODER_TYPE config.DECODER_TYPE
#define PAL_DECODER_MODE config.PAL_DECODER_MODE

#define USER_COLOR config.USER_COLOR
#define USER_TINT config.USER_TINT

#ifdef OPTION_DEBUG
#define DISPLAY_SVIDEO_DEMOD_BYPASS config.DISPLAY_SVIDEO_DEMOD_BYPASS
#endif  // OPTION_DEBUG

layout(std140, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float FrameWidth;
layout(location = 2) flat out float FrameHeight;
layout(location = 3) flat out float DataLength;
layout(location = 4) flat out float InitialSubcarrierPhaseFrac;
layout(location = 5) flat out float Fs;
layout(location = 6) flat out float Fsc;
layout(location = 7) flat out float HorizontalFrequency;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    InitialSubcarrierPhaseFrac = contract_initial_subcarrier_phase_frac(
        config.OriginalSize.xy, config.OriginalFPS, config.FrameCount,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        SC_FREQ_MODE, SC_FREQ,
        H_FREQ_MODE, H_FREQ,
        V_FREQ_MODE, V_FREQ,
        SHORTEN_ODD_FIELD_TIME,
        PHASE_ZERO
    );

    FrameWidth = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ,
        DSP_WORKING_FS
    );

    FrameHeight = contract_frame_height(
        config.OriginalSize.xy, config.OriginalFPS,
        V_FREQ_MODE, V_FREQ,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ
    );

    DataLength = max(contract_data_length(FrameWidth, FrameHeight), 1.0);

    Fs = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ,
        DSP_WORKING_FS
    );

    Fsc = contract_subcarrier_freq_hz(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ
    );

    HorizontalFrequency = contract_h_frequency(
        config.OriginalFPS,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ
    );
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 3) flat in float DataLength;
layout(location = 4) flat in float InitialSubcarrierPhaseFrac;
layout(location = 5) flat in float Fs;
layout(location = 6) flat in float Fsc;
layout(location = 7) flat in float HorizontalFrequency;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

#ifdef OPTION_DEBUG
#define CORRELATION config.CORRELATION
#define COMB_ADJUST_X config.COMB_ADJUST_X
#else
const float CORRELATION = 0.5;
const float COMB_ADJUST_X = 0.0;
#endif  // OPTION_DEBUG

void main()
{
#ifdef OPTION_DEBUG
    if (DISPLAY_SVIDEO_DEMOD_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
#endif  // OPTION_DEBUG

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float sample_x = floor(UV.x);
    float sample_y = floor(UV.y);

    if (sample_x >= FrameWidth || sample_y >= FrameHeight) {
        FragColor = vec4(0.0);
        return;
    }

    float sample_index = sample_y * FrameWidth + sample_x;
    if (sample_index >= DataLength) {
        FragColor = vec4(0.0);
        return;
    }

    vec2 yc = fetch_input_sample(Source, config.OutputSize.xy, sample_index, FrameWidth, DataLength - 1.0).rg;

    // Demodulate chroma from real subcarrier
    float phase = 2.0 * PI * carrier_phase(
        sample_index,
        Fsc, Fs, InitialSubcarrierPhaseFrac
    );

    // PAL V-axis alternation is applied after delay-line component separation.
    float pal_v_sign = 1.0 - 2.0 * floor(mod(sample_y, 2.0)) * DECODER_TYPE;

    float c_gain = 0.01 * (2.0 * USER_COLOR);
    float c_phase = PI * USER_TINT / 180.0;
    float phase_with_hue = phase + c_phase;
    vec2 simple_components = vec2(
        2.0 * yc.g * sin(phase_with_hue),
        pal_v_sign * 2.0 * yc.g * cos(phase_with_hue));
    vec2 chroma_components = simple_components;

    if (DECODER_TYPE > 0.5 && PAL_DECODER_MODE > 0.5 &&
        Fsc > 0.0 && Fs > 0.0 && HorizontalFrequency > 0.0) {
        float phase_inc_per_sample = 2.0 * PI * Fsc / Fs;
        float system_phase_shift = comb_system_phase_shift(Fsc, HorizontalFrequency);
        float phase_offset = comb_phase_offset(0.0, system_phase_shift, phase_inc_per_sample);
        phase_offset += COMB_ADJUST_X;

        float pal_delay = fetch_comb_line_sample(
            Source, config.OutputSize.xy, sample_x - phase_offset, sample_y - 1.0,
            FrameWidth, DataLength, 1);
        vec2 delay_components = vec2(
            (yc.g + pal_delay) * sin(phase_with_hue),
            pal_v_sign * (yc.g - pal_delay) * cos(phase_with_hue));

        if (PAL_DECODER_MODE > 1.5) {
            float previous_phase = 2.0 * PI * carrier_phase(
                sample_index - FrameWidth,
                Fsc, Fs, InitialSubcarrierPhaseFrac);
            float actual_phase_shift = normalize_phase(phase - previous_phase);
            float phase_error = normalize_phase(actual_phase_shift - system_phase_shift);
            float phase_blend = smoothstep(0.017453, 0.087266, abs(phase_error));

            float correlation = comb_point_correlation(yc.g, pal_delay);
            float correlation_weight = smoothstep(
                CORRELATION - 0.05, CORRELATION + 0.05, correlation);
            chroma_components = mix(
                simple_components, delay_components,
                max(phase_blend, correlation_weight));
        } else {
            chroma_components = delay_components;
        }
    }

    float setup_gain = mix(1.0, 1.0 / 0.925, DECODER_SETUP);
    vec3 component = vec3(
        mix(yc.r, (yc.r - 0.075) / 0.925, DECODER_SETUP),
        setup_gain * chroma_components * c_gain
    );

    FragColor = vec4(component, 1.0);
}
