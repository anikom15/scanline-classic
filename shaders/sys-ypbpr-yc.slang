#version 450

// Filename: sys-ypbpr-yc.slang
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
// System-level YPbPr to YC modulator
// ----------------------------------
// Input: Real YPbPr voltage
// Output: Real Y, modulated C voltage
//     OR: Real composite video voltage
//
// Modulates the chroma channel on a real subcarrier according to
// contract frequency and phase and optionally sums the result.

#pragma name SysYPbPrYC
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/sys-encode.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_YPBPR_YC_HEADER " —— Debug Sys YPbPr to YC Modulator —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_YPBPR_YC_BYPASS "Bypass Sys YPbPr to YC modulator" 0.0 0.0 1.0 1.0
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
    float PAL;
    float SVIDEO;

#ifdef OPTION_DEBUG
    float SYS_YPBPR_YC_BYPASS;
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
#define PAL config.PAL
#define SVIDEO config.SVIDEO

#ifdef OPTION_DEBUG
#define SYS_YPBPR_YC_BYPASS config.SYS_YPBPR_YC_BYPASS
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

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    InitialSubcarrierPhaseFrac = contract_initial_subcarrier_phase_frac(
        config.FrameCount, config.OriginalSize.xy, config.OriginalFPS,
        V_FREQ_MODE, V_FREQ,
        SC_FREQ_MODE, SC_FREQ,
        PIXEL_CLOCK_MODE, PIXEL_CLOCK,
        H_FREQ_MODE, H_FREQ, H_BLANK_FUZZ,
        SHORTEN_ODD_FIELD_TIME, PHASE_ZERO
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
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 3) flat in float DataLength;
layout(location = 4) flat in float InitialSubcarrierPhaseFrac;
layout(location = 5) flat in float Fs;
layout(location = 6) flat in float Fsc;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
#ifdef OPTION_DEBUG
    if (SYS_YPBPR_YC_BYPASS > 0.5) {
        FragColor = fetch_input_sample(Source, config.OutputSize.xy, vTexCoord * config.OutputSize.xy, FrameWidth, DataLength - 1.0);
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

    vec4 ypbpra = fetch_input_sample(Source, config.OutputSize.xy, sample_index, FrameWidth, DataLength - 1.0);

    // Modulate chroma on real subcarrier
    float phase = 2.0 * PI * carrier_phase(
        sample_index,
        ypbpra.a,
        Fsc, Fs, InitialSubcarrierPhaseFrac
    );

    // PAL V-axis alternation: simply invert V on odd lines
    float pal_v_sign = 1.0 - 2.0 * floor(mod(sample_y, 2.0)) * PAL;

    vec3 yc = vec3(
        mix(ypbpra.r, 0.925 * (ypbpra.r + 0.075), ENCODER_SETUP),
        ypbpra.g * sin(phase) + pal_v_sign * ypbpra.b * cos(phase),
        0.0
    );
    vec3 cv = vec3(yc.r + yc.g, 0.0, 0.0);

    FragColor = vec4(mix(cv, yc, SVIDEO), ypbpra.a);
}
