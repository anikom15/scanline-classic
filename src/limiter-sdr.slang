#version 450

// Filename: limiter-sdr.slang
//
// Copyright (C) 2025 W. M. Martinez
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
// Voltage limiter (SDR output range)
// -----------------
// Input: Voltage
// Output: Limited range normalized RGB signal [0.0, 1.0]
//
// Clips and normalizes voltage to standard RGB signal range.
//
// There are two techniques for limiting here: hard clipping and soft clipping.
// Hard clipping simply clamps the value to the min/max limits, while soft
// clipping uses a transfer function to gently roll off the signal as it
// approaches the limits, reducing harsh transitions that can cause artifacts.
//
// Most output should remain linear due to the linear range mapping
// directly to SDR range (default settings), but the soft limiter will
// apply distortion to signals that have been modified by the
// amplifiers in the previous stages to go beyond 100 IRE.
//
// The SDR version clamps any values outside the standard 0-100 IRE
// range, mapping them to 0.0-1.0 normalized RGB output.  See the HDR
// version for tone-mapping extended range signals.

#include "common.inc"

#include "parameters/limiter.inc"

#pragma name Limiter
#pragma format R8G8B8A8_UNORM

#pragma parameter LIMITER_BYPASS "Bypass Voltage Limiter" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    float LIMITER_BYPASS;
    float LIMITER_OUTPUT_RANGE;
    float LIMITER_TYPE;
    float LIMITER_COMPRESSION_POINT;
    float LIMITER_MAX_OUTPUT;
} config;

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#define LIMITER_BYPASS config.LIMITER_BYPASS
#define LIMITER_OUTPUT_RANGE config.LIMITER_OUTPUT_RANGE
#define LIMITER_TYPE config.LIMITER_TYPE
#define LIMITER_COMPRESSION_POINT config.LIMITER_COMPRESSION_POINT
#define LIMITER_MAX_OUTPUT config.LIMITER_MAX_OUTPUT

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    vec3 color = texture(Source, vTexCoord).rgb;

    // Bypass limiter, but translate to expected unit
    if (LIMITER_BYPASS >= 1.0) {
        color = voltage_to_normlimit(color);
        FragColor = vec4(color, 1.0);
        return;
    }

    float compression = LIMITER_COMPRESSION_POINT * 7.143e-3; // Convert IRE to V

    if (LIMITER_TYPE > 0.5) {
        // Hard limiter
        color = clamp(color, 0.0, compression);
        color = voltage_to_normlimit(color);
        FragColor = vec4(color, 1.0);
        return;
    }

    // Soft limiter
    float peak = LIMITER_MAX_OUTPUT * 7.143e-3; // Convert IRE to V
    float distortion = peak - compression;

    if (any(greaterThan(color, vec3(compression)))) {
        // Hyperbolic tangent gives us a smooth roll-off
        vec3 softColor = distortion * tanh((color - compression) / distortion) + compression;

        color = min(color, softColor);        
    }

    color = clamp(color, 0.0, peak);
    color = voltage_to_normlimit(color);

    FragColor = vec4(color, 1.0);
}