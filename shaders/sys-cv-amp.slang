#version 450

// Filename: sys-cv-amp.slang
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
// System-level amplifier
// ------------------------
// Input: Voltage
// Output: Voltage
//
// Can be used to alter channel level, e.g. to compensate an emulator's
// output being too dark or too bright

#pragma name CVAmplifier
#pragma format R16_SFLOAT

#include "common.inc"

#include "menus/parameters/sys-cv.inc"
#include "menus/parameters/noise-txrx.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_CV_AMP_HEADER " —— Debug Sys CV Amp —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_CV_AMP_BYPASS "Bypass CV Amplifier" 0 0 1 1
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    float SYS_BIAS;
    float SYS_GAIN;

    float TXRX_NOISE_IMD2;
    float TXRX_NOISE_IMD3;

#ifdef OPTION_DEBUG
    float SYS_CV_AMP_BYPASS;
#endif  // OPTION_DEBUG

} config;

#ifdef OPTION_DEBUG
#define SYS_CV_AMP_BYPASS config.SYS_CV_AMP_BYPASS
#endif  // OPTION_DEBUG

#define SYS_BIAS config.SYS_BIAS

#define SYS_GAIN config.SYS_GAIN

#define TXRX_NOISE_IMD2 config.TXRX_NOISE_IMD2
#define TXRX_NOISE_IMD3 config.TXRX_NOISE_IMD3

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float gain;
layout(location = 2) out float bias;
layout(location = 3) out vec2 imd;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    gain = db_to_linear(SYS_GAIN);
    bias = SYS_BIAS * 10e-3;

    imd = vec2(
        pow(10.0, TXRX_NOISE_IMD2 / 20.0),
        4.0 / 3.0 * pow(10.0, TXRX_NOISE_IMD3 / 20.0)
    );
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float gain;
layout(location = 2) in float bias;
layout(location = 3) in vec2 imd;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    float v = texture(Source, vTexCoord).r;

#ifdef OPTION_DEBUG
    if (SYS_CV_AMP_BYPASS > 0.5) {
        FragColor = vec4(v, 0.0, 0.0, 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    float distortion = imd.x * (v * v) - imd.y * (v * v * v);

    v = gain * (v + distortion) + bias;
    FragColor = vec4(v, 0.0, 0.0, 1.0);
}
