#version 450

// Filename: sys-component-yc.slang
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
// System-level component video to YC modulator
// ----------------------------------
// Input: Real component video voltage (Y, R-Y, B-Y)
// Output: Real Y, modulated C voltage
//     OR: Real composite video voltage
//
// Modulates the chroma channel on a real subcarrier according to
// contract frequency and phase and optionally sums the result.

#pragma name SyscomponentYC
#pragma format R16G16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-encode.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/noise-svideo.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_component_YC_HEADER " —— Debug Sys component to YC Modulator —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_component_YC_BYPASS "Bypass Sys component to YC modulator" 0.0 0.0 1.0 1.0
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

    float ENCODER_SETUP;
    float CARRIER_SHAPE;
    float PAL;
    float SVIDEO;

    float SVIDEO_CARRIER_LEAKAGE;
    float SVIDEO_IQ_IMBALANCE;

#ifdef OPTION_DEBUG
    float SYS_component_YC_BYPASS;
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

#define ENCODER_SETUP config.ENCODER_SETUP
#define CARRIER_SHAPE config.CARRIER_SHAPE
#define PAL config.PAL
#define SVIDEO config.SVIDEO

#define SVIDEO_CARRIER_LEAKAGE config.SVIDEO_CARRIER_LEAKAGE
#define SVIDEO_IQ_IMBALANCE config.SVIDEO_IQ_IMBALANCE

#ifdef OPTION_DEBUG
#define SYS_component_YC_BYPASS config.SYS_component_YC_BYPASS
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
layout(location = 7) flat out float c_leakage;
layout(location = 8) flat out float g_iq;

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

    c_leakage = pow(10.0, SVIDEO_CARRIER_LEAKAGE / 20.0);
    g_iq = pow(10.0, SVIDEO_IQ_IMBALANCE / 20.0);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 3) flat in float DataLength;
layout(location = 4) flat in float InitialSubcarrierPhaseFrac;
layout(location = 5) flat in float Fs;
layout(location = 6) flat in float Fsc;
layout(location = 7) flat in float c_leakage;
layout(location = 8) flat in float g_iq;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
#ifdef OPTION_DEBUG
    if (SYS_component_YC_BYPASS > 0.5) {
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

    vec3 component = fetch_input_sample(Source, config.OutputSize.xy, sample_index, FrameWidth, DataLength - 1.0).rgb;

    // Scale color difference signals
    component.g *= 0.492111;
    component.b *= 0.877283;

    // Modulate chroma on real subcarrier
    float phase = 2.0 * PI * carrier_phase(
        sample_index,
        Fsc, Fs, InitialSubcarrierPhaseFrac
    );

    vec2 carrier = vec2(sin(phase), cos(phase));

    // Obtain carrier signal components for distorted carrier if enabled
    if (CARRIER_SHAPE > 0.5) {
        vec3 phase_harmonics = vec3(
            2.0 * PI * carrier_phase(sample_index, 3.0 * Fsc, Fs, InitialSubcarrierPhaseFrac),
            2.0 * PI * carrier_phase(sample_index, 5.0 * Fsc, Fs, InitialSubcarrierPhaseFrac),
            2.0 * PI * carrier_phase(sample_index, 7.0 * Fsc, Fs, InitialSubcarrierPhaseFrac)
        );
        carrier = vec2(
            carrier.x + sin(phase_harmonics.x) / 3.0 + sin(phase_harmonics.y) / 5.0 + sin(phase_harmonics.z) / 7.0,
            carrier.y + cos(phase_harmonics.x) / 3.0 + cos(phase_harmonics.y) / 5.0 + cos(phase_harmonics.z) / 7.0
        );
    }

    // PAL V-axis alternation: simply invert V on odd lines
    float pal_v_sign = 1.0 - 2.0 * floor(mod(sample_y, 2.0)) * PAL;

    // Scale IQ imbalance with squared luma, reaching its maximum at |Y| = 1.
    float iq_gain = sqrt(mix(1.0, g_iq, min(component.r * component.r, 1.0)));
    component.g /= iq_gain;
    component.b *= iq_gain;

    vec2 yc = vec2(
        mix(component.r, 0.925 * (component.r + 0.075), ENCODER_SETUP),
        dot(mix(1.0, 0.925, ENCODER_SETUP) * component.gb,
            vec2(carrier.x, pal_v_sign * carrier.y))
    );

    // Apply carrier leakage
    yc.g += c_leakage;

    vec2 cv = vec2(yc.r + yc.g, 0.0);

    FragColor = vec4(mix(cv, yc, SVIDEO), 0.0, 0.0);
}
