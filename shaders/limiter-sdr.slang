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
// Output: Normalized RGB signal [0.0, 1.0]
//
// Clips and normalizes voltage to standard RGB signal range.
//
// There are two techniques for limiting here: hard clipping and soft
// clipping.  Hard clipping simply clamps the value to the min/max
// limits, while soft clipping uses a transfer function to gently roll
// off the signal as it approaches the limits, reducing harsh
// transitions that can cause artifacts.
//
// Most output should remain linear due to the linear range mapping
// directly to SDR range (default settings), but the soft limiter will
// apply distortion to signals that have been modified by the
// amplifiers in the previous stages to go beyond 100 IRE.
//
// A modified Reinhard tone mapper is available, but turned off by
// default as most use cases do not require amplifying core input
// signals.  Turning on the tone mapper will compress 100 IRE white
// level to allow signals (up to max output) to be displayed without
// clipping.

#include "common.inc"
#include "color.inc"

#include "menus/parameters/output-tonemap.inc"
#include "menus/parameters/limiter.inc"

#pragma name Limiter
#pragma format R16G16B16A16_SFLOAT

#pragma parameter LIMITER_BYPASS "Bypass Voltage Limiter" 0.0 0.0 1.0 1.0
#pragma parameter LIMITER_DEBUG_OUT_OF_RANGE "Limiter: show out-of-range colors" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OutputSize;
    uint FrameCount;
    float NTSC_CONVERSION;
    float LIMITER_BYPASS;
    float LIMITER_OUTPUT_RANGE;
    float LIMITER_TYPE;
    float LIMITER_COMPRESSION_POINT;
    float LIMITER_MAX_OUTPUT;
    float LIMITER_DEBUG_OUT_OF_RANGE;
    float TONEMAP_LIMITER;
} config;

#define NTSC_CONVERSION config.NTSC_CONVERSION
#define LIMITER_BYPASS config.LIMITER_BYPASS
#define LIMITER_OUTPUT_RANGE config.LIMITER_OUTPUT_RANGE
#define LIMITER_TYPE config.LIMITER_TYPE
#define LIMITER_COMPRESSION_POINT config.LIMITER_COMPRESSION_POINT
#define LIMITER_MAX_OUTPUT config.LIMITER_MAX_OUTPUT
#define LIMITER_DEBUG_OUT_OF_RANGE config.LIMITER_DEBUG_OUT_OF_RANGE
#define TONEMAP_LIMITER config.TONEMAP_LIMITER

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// Reinhard tone mapping operator (extended version)
vec3 reinhard_extended(vec3 color, float w)
{
    // Convert input color to luminance
    float y = dot(color, vec3(0.299, 0.587, 0.114));  // Rec. 601 Luma
    float y_adj = y * (1.0 + y / (w * w)) / (1.0 + y);

    return color * y_adj / y;
}

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

    if (NTSC_CONVERSION > 0.5) {
        // Apply NTSC conversion matrix
        color = ParkerCCorrection * color;
    }

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

    color = voltage_to_normlimit(color);

    // Tone mapping
    if (TONEMAP_LIMITER > 0.5) {
        // Map peak voltage to normalized range
        float w = peak / VOLTAGE_100;

        color = reinhard_extended(color, w);
    }

    // Debug: Visualize out-of-range colors with sinusoid modulation
    if (LIMITER_DEBUG_OUT_OF_RANGE >= 1.0) {
        bvec3 outOfRange = bvec3(
            color.r < 0.0 || color.r > compression,
            color.g < 0.0 || color.g > compression,
            color.b < 0.0 || color.b > compression
        );
        
        // Create animated temporal square wave (cycles over ~60 frames at 60fps)
        float temporalPhase = float(config.FrameCount) * 0.1;
        float temporalSquare = sign(sin(temporalPhase)) * 0.5 + 0.5; // Square wave: 0.0 or 1.0
        
        // Create spatial square wave pattern (checkerboard-like)
        float spatialPhase = (vTexCoord.x + vTexCoord.y) * config.OutputSize.x / 2.0; // Adjust frequency with multiplier
        float spatialSquare = sin(spatialPhase) * 0.5 + 0.5; // Square wave: 0.0 or 1.0
        
        // Combine temporal and spatial patterns with XOR-like behavior
        float modulation = abs(temporalSquare - spatialSquare);
        
        // Modulate out-of-range channels with the combined pattern
        if (any(outOfRange)) {
            vec3 debugMask = vec3(
                outOfRange.r ? modulation : 1.0,
                outOfRange.g ? modulation : 1.0,
                outOfRange.b ? modulation : 1.0
            );
            color *= debugMask;
        }
    }

    color = clamp(color, 0.0, 1.0);

    FragColor = vec4(color, 1.0);
}