#version 450

// Filename: limiter.slang
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
// Voltage limiter
// ------------------------
// Input: Real voltage
// Output: Real voltage
//
// Applies a soft knee compression using a hyperbolic tangent function

#pragma name Limiter
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"

#include "menus/parameters/limiter.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_LIMITER_HEADER " —— Debug Limiter —— " 0.0 0.0 0.0 0.0
#pragma parameter LIMITER_BYPASS "Bypass limiter" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OutputSize;
    float LIMITER_TYPE;
    float LIMITER_RYCV_COMPRESSION_POINT;
    float LIMITER_GCPb_COMPRESSION_POINT;
    float LIMITER_BCPR_COMPRESSION_POINT;
    float LIMITER_RYCV_MAX_OUTPUT;
    float LIMITER_GCPb_MAX_OUTPUT;
    float LIMITER_BCPR_MAX_OUTPUT;

#ifdef OPTION_DEBUG
    float LIMITER_BYPASS;
#endif  // OPTION_DEBUG

} config;

#define LIMITER_TYPE config.LIMITER_TYPE
#define LIMITER_RYCV_COMPRESSION_POINT config.LIMITER_RYCV_COMPRESSION_POINT
#define LIMITER_GCPb_COMPRESSION_POINT config.LIMITER_GCPb_COMPRESSION_POINT
#define LIMITER_BCPR_COMPRESSION_POINT config.LIMITER_BCPR_COMPRESSION_POINT
#define LIMITER_RYCV_MAX_OUTPUT config.LIMITER_RYCV_MAX_OUTPUT
#define LIMITER_GCPb_MAX_OUTPUT config.LIMITER_GCPb_MAX_OUTPUT
#define LIMITER_BCPR_MAX_OUTPUT config.LIMITER_BCPR_MAX_OUTPUT

#ifdef OPTION_DEBUG
#define LIMITER_BYPASS config.LIMITER_BYPASS
#endif  // OPTION_DEBUG

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out vec3 compression;
layout(location = 2) flat out vec3 peak;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    compression = vec3(LIMITER_RYCV_COMPRESSION_POINT, LIMITER_GCPb_COMPRESSION_POINT, LIMITER_BCPR_COMPRESSION_POINT) * 10e-3; // Convert IRE to V
    peak = vec3(LIMITER_RYCV_MAX_OUTPUT, LIMITER_GCPb_MAX_OUTPUT, LIMITER_BCPR_MAX_OUTPUT) * 10e-3; // Convert IRE to V
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec3 compression;
layout(location = 2) flat in vec3 peak;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec4 color = texture(Source, vTexCoord);

#ifdef OPTION_DEBUG
    if (LIMITER_BYPASS > 0.5) {
        FragColor = color;
        return;
    }
#endif  // OPTION_DEBUG

    if (LIMITER_TYPE > 0.5) {
        // Hard limiter
        color.rgb = clamp(color.rgb, vec3(0.0), compression);
        FragColor = color;
        return;
    }

    // Soft limiter
    vec3 distortion = peak - compression;
    vec3 softColor = distortion * tanh((color.rgb - compression) / distortion) + compression;

    color.rgb = mix(color.rgb, softColor, greaterThan(color.rgb, compression));

    FragColor = color;
}
