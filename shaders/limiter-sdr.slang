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

#include "menus/parameters/user-common.inc"
#include "menus/parameters/colorimetry.inc"
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

    // User video adjustments
    float USER_GAMMA;
    
    // Color conversion circuitry (RGB matrix type)
    float NTSC_CONVERSION;
    float NTSC_CONVERSION_WEIGHT;
    float COLORIMETRY_PRESET;
    float R_X;
    float R_Y;
    float G_X;
    float G_Y;
    float B_X;
    float B_Y;
    float W_X;
    float W_Y;

    // Limiter
    float LIMITER_BYPASS;
    float LIMITER_OUTPUT_RANGE;
    float LIMITER_TYPE;
    float LIMITER_COMPRESSION_POINT;
    float LIMITER_MAX_OUTPUT;
    float LIMITER_DEBUG_OUT_OF_RANGE;
} config;

#define USER_GAMMA config.USER_GAMMA

#define NTSC_CONVERSION config.NTSC_CONVERSION
#define NTSC_CONVERSION_WEIGHT config.NTSC_CONVERSION_WEIGHT
#define COLORIMETRY_PRESET config.COLORIMETRY_PRESET
#define R_X config.R_X
#define R_Y config.R_Y
#define G_X config.G_X
#define G_Y config.G_Y
#define B_X config.B_X
#define B_Y config.B_Y
#define W_X config.W_X
#define W_Y config.W_Y

#define LIMITER_BYPASS config.LIMITER_BYPASS
#define LIMITER_OUTPUT_RANGE config.LIMITER_OUTPUT_RANGE
#define LIMITER_TYPE config.LIMITER_TYPE
#define LIMITER_COMPRESSION_POINT config.LIMITER_COMPRESSION_POINT
#define LIMITER_MAX_OUTPUT config.LIMITER_MAX_OUTPUT
#define LIMITER_DEBUG_OUT_OF_RANGE config.LIMITER_DEBUG_OUT_OF_RANGE

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out mat3 CorrectionMatrix;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Prepare NTSC conversion matrix if needed
    CorrectionMatrix = mat3(1.0);

    if (NTSC_CONVERSION > 0.5) {
        // Set up reference conversion matrix (NTSC C)
        const Colorimetry reference = Colorimetry(
            vec2(0.670, 0.330),
            vec2(0.210, 0.710),
            vec2(0.140, 0.080),
            vec2(0.310, 0.316));
        const vec3 wref_XYZ = NTSC_TO_XYZ * WHITE;
        mat3 ref_to_XYZ = NTSC_TO_XYZ;

        // Set up colorimetry
        Colorimetry colorimetry;

        if (COLORIMETRY_PRESET < 0.5) {
            // Custom
            colorimetry = Colorimetry(
                vec2(R_X, R_Y),
                vec2(G_X, G_Y),
                vec2(B_X, B_Y),
                vec2(W_X, W_Y));
        } else if (COLORIMETRY_PRESET < 1.5) {
            // Rec. 601
            colorimetry = Colorimetry(
                vec2(0.630, 0.340),
                vec2(0.310, 0.595),
                vec2(0.155, 0.070),
                vec2(0.3127, 0.3290));
        } else if (COLORIMETRY_PRESET < 2.5) {
            // Japanese phosphors, D93
            colorimetry = Colorimetry(
                vec2(0.618, 0.350),
                vec2(0.280, 0.605),
                vec2(0.152, 0.063),
                vec2(0.2832, 0.2971));
        } else if (COLORIMETRY_PRESET < 3.5) {
            // EBU Tech 3213
            colorimetry = Colorimetry(
                vec2(0.640, 0.330),
                vec2(0.290, 0.600),
                vec2(0.150, 0.060),
                vec2(0.3127, 0.3290));
        } else {
            // Rec. 709
            colorimetry = Colorimetry(
                vec2(0.640, 0.330),
                vec2(0.300, 0.600),
                vec2(0.150, 0.060),
                vec2(0.3127, 0.3290));
        }

        // Modify colorimetry with a distance factor
        colorimetry.red_xy = reference.red_xy + (colorimetry.red_xy - reference.red_xy) * NTSC_CONVERSION_WEIGHT;
        colorimetry.green_xy = reference.green_xy + (colorimetry.green_xy - reference.green_xy) * NTSC_CONVERSION_WEIGHT;
        colorimetry.blue_xy = reference.blue_xy + (colorimetry.blue_xy - reference.blue_xy) * NTSC_CONVERSION_WEIGHT;

        vec3 wout_XYZ = xyY_to_XYZ(vec3(colorimetry.white_xy.x, colorimetry.white_xy.y, 1.0));
        vec3 red_XYZ = xyY_to_XYZ(vec3(colorimetry.red_xy.x, colorimetry.red_xy.y, 1.0));
        vec3 green_XYZ = xyY_to_XYZ(vec3(colorimetry.green_xy.x, colorimetry.green_xy.y, 1.0));
        vec3 blue_XYZ = xyY_to_XYZ(vec3(colorimetry.blue_xy.x, colorimetry.blue_xy.y, 1.0));
        mat3 RGB_to_XYZ = get_RGB_to_XYZ(red_XYZ, green_XYZ, blue_XYZ, wout_XYZ);

        // Compute reference white in XYZ space
        wout_XYZ = RGB_to_XYZ * WHITE;

        // Apply chromatic adaptation to reference matrix
        ref_to_XYZ = bradford_linear(wref_XYZ, wout_XYZ) * ref_to_XYZ;

        // Compute correction matrix
        CorrectionMatrix = inverse(RGB_to_XYZ) * ref_to_XYZ;
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in mat3 CorrectionMatrix;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    vec3 color = texture(Source, vTexCoord).rgb;

    // Clamp negative voltages to zero
    color = max(color, vec3(0.0));

    if (NTSC_CONVERSION > 0.5) {
        // Apply NTSC conversion matrix
        color = CorrectionMatrix * color;
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

    float w = peak / 0.7143;  // white point for tone mapping

    // Apply user video adjustments
    float gamma = (2.4 - USER_GAMMA / 10.0) / 2.4; // Map USER_GAMMA 0-1 to fraction of 2.4

    // Preserve extended values for proper handling
    if (color.r < 1.0)
        color.r = pow(color.r, gamma);
    if (color.g < 1.0)
        color.g = pow(color.g, gamma);
    if (color.b < 1.0)
        color.b = pow(color.b, gamma);

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

    FragColor = vec4(color, 1.0);
}