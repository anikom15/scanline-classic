#version 450

// Filename: sys-yc-amp.slang
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

#pragma name YCAmplifier
#pragma format R16G16_SFLOAT

#include "common.inc"

#include "menus/parameters/sys-yc-amp.inc"
#include "menus/parameters/noise-txrx.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_YC_AMP_HEADER " —— Debug Sys YC Amp —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_YC_AMP_BYPASS "Bypass YC Amplifier" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    float SYS_BIAS_Y;
    float SYS_BIAS_C;
    float SYS_GAIN_Y;
    float SYS_GAIN_C;

#ifdef OPTION_DEBUG
    float SYS_YC_AMP_BYPASS;
#endif  // OPTION_DEBUG

} config;

#ifdef OPTION_DEBUG
#define SYS_YC_AMP_BYPASS config.SYS_YC_AMP_BYPASS
#endif  // OPTION_DEBUG

#define SYS_BIAS_Y config.SYS_BIAS_Y
#define SYS_BIAS_C config.SYS_BIAS_C

#define SYS_GAIN_Y config.SYS_GAIN_Y
#define SYS_GAIN_C config.SYS_GAIN_C

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 gain;
layout(location = 2) out vec2 bias;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    gain = vec2(
        db_to_linear(SYS_GAIN_Y),
        db_to_linear(SYS_GAIN_C)
    );

    bias = vec2(
        SYS_BIAS_Y * 10e-3,
        SYS_BIAS_C * 10e-3
    );
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 gain;
layout(location = 2) in vec2 bias;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec2 v = texture(Source, vTexCoord).rg;

#ifdef OPTION_DEBUG
    if (SYS_YC_AMP_BYPASS > 0.5) {
        FragColor = vec4(v, 0.0, 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    v = gain * v + bias;
    FragColor = vec4(v, 0.0, 1.0);
}
