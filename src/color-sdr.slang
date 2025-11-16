#version 450

// Filename: color-sdr.slang
//
// Copyright (C) 2025 W. M. Martinez
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Color converter (SDR version)
// ------------------------------------------------
// Input: Linear RGB signal
// Output: sRGB signal

#include "common.inc"
#include "color.inc"

#include "parameters/color.inc"

#pragma name Color
#pragma format R8G8B8A8_UNORM

#pragma parameter COLOR_CONVERSION_BYPASS "Bypass color correction" 0.0 0.0 1.0 1.0
#pragma parameter TONE_MAPPING_BYPASS "Bypass tone mapping" 0.0 0.0 1.0 1.0
#pragma parameter DEBUG_COLOR_DELTA "Show color correction deltas" 0.0 0.0 1.0 1.0
#pragma parameter DEBUG_TONE_MAP_DELTA "Show tone mapping deltas" 0.0 0.0 1.0 1.0
#pragma parameter COLOR_DEBUG_OUT_OF_RANGE "Debug out-of-range colors" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float R_X;
    float R_Y;
    float G_X;
    float G_Y;
    float B_X;
    float B_Y;
    float R_WEIGHT;
    float G_WEIGHT;
    float B_WEIGHT;
    float COLOR_CONVERSION_METHOD;
    float TONE_MAP_TYPE;
    float COLOR_CONVERSION_BYPASS;
    float TONE_MAPPING_BYPASS;
    float DEBUG_COLOR_DELTA;
    float DEBUG_TONE_MAP_DELTA;
    float COLOR_DEBUG_OUT_OF_RANGE;
} config;

#define R_X config.R_X
#define R_Y config.R_Y
#define G_X config.G_X
#define G_Y config.G_Y
#define B_X config.B_X
#define B_Y config.B_Y
#define R_WEIGHT config.R_WEIGHT
#define G_WEIGHT config.G_WEIGHT
#define B_WEIGHT config.B_WEIGHT
#define COLOR_CONVERSION_METHOD config.COLOR_CONVERSION_METHOD
#define TONE_MAP_TYPE config.TONE_MAP_TYPE
#define COLOR_CONVERSION_BYPASS config.COLOR_CONVERSION_BYPASS
#define TONE_MAPPING_BYPASS config.TONE_MAPPING_BYPASS
#define DEBUG_COLOR_DELTA config.DEBUG_COLOR_DELTA
#define DEBUG_TONE_MAP_DELTA config.DEBUG_TONE_MAP_DELTA
#define COLOR_DEBUG_OUT_OF_RANGE config.COLOR_DEBUG_OUT_OF_RANGE

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

// -- Color space conversion functions -- //

// Convert from linear RGB to XYZ by way of xy chromaticity
//
// Yrgb: Input color in Yrgb space
// W: Weighting vector for RGB channels
vec3 Yrgb_to_XYZ(vec3 Yrgb, vec3 W)
{
    mat3 xyYrgb = mat3(
        R_X, R_Y, Yrgb.r,
        G_X, G_Y, Yrgb.g,
        B_X, B_Y, Yrgb.b);
    mat3 XYZrgb = mat3(
        xyY_to_XYZ(xyYrgb[0]),
        xyY_to_XYZ(xyYrgb[1]),
        xyY_to_XYZ(xyYrgb[2]));
    vec3 XYZ = vec3(
        dot(W, vec3(XYZrgb[0].r, XYZrgb[1].r, XYZrgb[2].r)),
        dot(W, vec3(XYZrgb[0].g, XYZrgb[1].g, XYZrgb[2].g)),
        dot(W, vec3(XYZrgb[0].b, XYZrgb[1].b, XYZrgb[2].b)));
    return XYZ;
}

// Direct conversion from Yrgb to RGB
//
// Yrgb: Input color in Yrgb space
// W: Weighting vector for RGB channels
// toRGB: Matrix to convert from XYZ to RGB
vec3 Yrgb_to_RGB(vec3 Yrgb, vec3 W, mat3 toRGB)
{
    vec3 XYZ = Yrgb_to_XYZ(Yrgb, W);
    return toRGB * XYZ;
}

// -- Perceptual color transform functions -- //

// Standard Bradford transform
//
// color_XYZ: Input color in XYZ space
// wref_XYZ: Reference white point in XYZ space
//
// Inputs should be normalized by Y before calling this function. 
vec3 bradford(vec3 color_XYZ, vec3 wref_XYZ)
{
    // Target white point is always D65
    const vec3 D65_XYZ = vec3(0.95047, 1.0, 1.08883);
    const mat3 M = mat3(
         0.8951, -0.7502,  0.0389,
         0.2664,  1.7135, -0.0685,
        -0.1614,  0.0367,  1.0296);
    const mat3 M_inv = mat3(
         0.9869929,  0.4323053, -0.0085287,
        -0.1470543,  0.5183603,  0.0400428,
         0.1599627,  0.0492912,  0.9684867);

    vec3 color_RGB = M * color_XYZ;
    vec3 wref_RGB = M * wref_XYZ;
    vec3 wout_RGB = M * D65_XYZ;
    vec2 adapted_RG = wout_RGB.rg * (color_RGB.rg / wref_RGB.rg);
    float p = pow(wref_RGB.b / wout_RGB.b, 0.0834);  // 1/12
    float adapted_B = wout_RGB.b * pow(color_RGB.b / wref_RGB.b, p);
    vec3 result = M_inv * vec3(adapted_RG, adapted_B);
    return result;
}

// Linear Bradford transform
vec3 bradford_linear(vec3 color_XYZ, vec3 wref_XYZ)
{
    // Target white point is always D65
    const vec3 D65_XYZ = vec3(0.95047, 1.0, 1.08883);
    const mat3 M = mat3(
         0.8951, -0.7502,  0.0389,
         0.2664,  1.7135, -0.0685,
        -0.1614,  0.0367,  1.0296);
    const mat3 M_inv = mat3(
         0.9869929,  0.4323053, -0.0085287,
        -0.1470543,  0.5183603,  0.0400428,
         0.1599627,  0.0492912,  0.9684867);

    vec3 color_RGB = M * color_XYZ;
    vec3 wref_RGB = M * wref_XYZ;
    vec3 wout_RGB = M * D65_XYZ;
    mat3 M_adt = mat3(
        wout_RGB.r / wref_RGB.r, 0.0, 0.0,
        0.0, wout_RGB.g / wref_RGB.g, 0.0,
        0.0, 0.0, wout_RGB.b / wref_RGB.b);
    vec3 adapted_RGB = M_adt * color_RGB;
    return M_inv * adapted_RGB;
}

// Chromatic adaptation model (Zhai et al. 2018) using CAT16

mat3 zhai2018_cat16_adaptation_matrix(vec3 src_white) {
    const vec3 tgt_white = vec3(0.95047, 1.0, 1.08883); // D65

    // CAT16 matrix
    const mat3 cat16_M = mat3(
         0.401288, -0.250268, -0.002079,
         0.650173,  1.204414,  0.048952,
        -0.051461,  0.045854,  0.953127);

    // Inverse CAT16 matrix
    const mat3 cat16_M_inv = mat3(
         1.8620678,  0.387526, -0.015841,
        -1.0112546,  0.621447, -0.034123,
         0.1491868, -0.008974,  1.049964);

    vec3 src_cone = cat16_M * src_white;
    vec3 tgt_cone = cat16_M * tgt_white;

    mat3 D = mat3(
        tgt_cone.x / src_cone.x, 0.0, 0.0,
        0.0, tgt_cone.y / src_cone.y, 0.0,
        0.0, 0.0, tgt_cone.z / src_cone.z);

    return cat16_M_inv * D * cat16_M;
}

vec3 adapt_color_cat16(vec3 color_xyz, vec3 src_white) {
    mat3 adapt = zhai2018_cat16_adaptation_matrix(src_white);
    return adapt * color_xyz;
}

// -- Tone mapping functions -- //

// Reinhard tone mapping
vec3 reinhard(vec3 color)
{
    return color / (1.0 + color);
}

// Reinhard tone mapping, luminance only
vec3 reinhard_yonly(vec3 color)
{
    // Calculate luminance
    float y = max(dot(color, vec3(0.2126, 0.7152, 0.0722)), EPS);
    float y_sdr = y / (1.0 + y);

    return color * y_sdr / y;
}

// Reinhard tone mapping with white point compensation
// w is the white point scaling factor
vec3 reinhard_extended(vec3 color, const float w) {
    vec3 safe_w = vec3(max(w, EPS));
    return color * (1.0 + color / (safe_w * safe_w)) / (1.0 + color);
}

// Reinhard tone mapping with white point compensation, luminance only
// w is the white point scaling factor
vec3 reinhard_extended_yonly(vec3 color, const float w) {
    // Calculate luminance
    float safe_w = max(w, EPS);
    float y = max(dot(color, vec3(0.2126, 0.7152, 0.0722)), EPS);
    float y_sdr = y * (1.0 + y / (safe_w * safe_w)) / (1.0 + y);

    return color * y_sdr / y;
}

// ACES approximation (Narkowicz 2015)
vec3 tone_map_aces(vec3 color) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((color * (a * color + b)) / (color * (c * color + d) + e), 0.0, 1.0);
}

vec3 uncharted2_tonemap_partial(vec3 x)
{
    float A = 0.15f;
    float B = 0.50f;
    float C = 0.10f;
    float D = 0.20f;
    float E = 0.02f;
    float F = 0.30f;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

vec3 uncharted2_filmic(vec3 v, const float w, const float exposure_bias)
{
    vec3 curr = uncharted2_tonemap_partial(v * exposure_bias);

    vec3 W = vec3(w);
    vec3 white_scale = vec3(1.0f) / uncharted2_tonemap_partial(W);
    return curr * white_scale;
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
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 Yrgb = texture(Source, vTexCoord).rgb;
    
    // Early exit for full bypass
    if (COLOR_CONVERSION_BYPASS >= 1.0) {
        FragColor = vec4(crt_gamma(clamp(Yrgb, 0.0, 1.0)), 1.0);
        return;
    }

    mat3 toRGB = XYZ_TO_sRGB;
    vec3 W = vec3(
        R_WEIGHT,
        G_WEIGHT,
        B_WEIGHT);
    vec3 RGB;

    if (COLOR_CONVERSION_METHOD < 0.5) {
        // No adaptation, just convert RGBref to XYZ to RGBout
        RGB = Yrgb_to_RGB(Yrgb, W, toRGB);
    } else if (COLOR_CONVERSION_METHOD < 1.5) {
        // Bradford adaptation
        vec3 white_XYZ = Yrgb_to_XYZ(WHITE, W);
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, W);
        vec3 adapted_XYZ = bradford(Yrgb_XYZ, white_XYZ);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    } else if (COLOR_CONVERSION_METHOD < 2.5) {
        // Linear Bradford adaptation
        // Forgoes precise blue channel adaptation for performance
        vec3 white_XYZ = Yrgb_to_XYZ(WHITE, W);
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, W);
        vec3 adapted_XYZ = bradford_linear(Yrgb_XYZ, white_XYZ);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    } else {
        // Zhai et al. 2018 CAT16 adaptation
        vec3 white_XYZ = Yrgb_to_XYZ(WHITE, W);
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, W);
        vec3 adapted_XYZ = adapt_color_cat16(Yrgb_XYZ, white_XYZ);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    }

    if (DEBUG_COLOR_DELTA > 0.5) {
        vec3 delta = abs(RGB - Yrgb);
        FragColor = vec4(crt_gamma(clamp(delta, 0.0, 1.0)), 1.0);
        return;
    }

    // Debug: Visualize out-of-range colors with sinusoid modulation
    if (COLOR_DEBUG_OUT_OF_RANGE > 0.5) {
        const float compression = 1.0;
        bvec3 outOfRange = bvec3(
            RGB.r < 0.0 || RGB.r > compression,
            RGB.g < 0.0 || RGB.g > compression,
            RGB.b < 0.0 || RGB.b > compression
        );

        // Create animated temporal square wave (cycles over ~60 frames at 60fps)
        float temporalPhase = float(config.FrameCount) * 0.1;
        float temporalSquare = sign(sin(temporalPhase)) * 0.5 + 0.5; // Square wave: 0.0 or 1.0

        // Create spatial square wave pattern (checkerboard-like)
        float spatialPhase = (vTexCoord.x + vTexCoord.y) * config.OutputSize.x / 4.0;  // Adjust frequency as needed
        float spatialSquare = sign(sin(spatialPhase)) * 0.5 + 0.5; // Square wave: 0.0 or 1.0

        // Combine temporal and spatial patterns with XOR-like behavior
        float modulation = abs(temporalSquare - spatialSquare);

        // Modulate out-of-range channels between max and opposite color
        if (any(outOfRange)) {
            vec3 debugColor = RGB;
            if (outOfRange.r) {
                // Red channel: modulate between Red and Cyan
                debugColor.r = modulation * RGB.r + (1.0 - modulation) * 0.0;
                debugColor.g = modulation * RGB.g + (1.0 - modulation) * RGB.g;
                debugColor.b = modulation * RGB.b + (1.0 - modulation) * RGB.b;
                debugColor.g += (1.0 - modulation) * RGB.r; // Add red to green for cyan
                debugColor.b += (1.0 - modulation) * RGB.r; // Add red to blue for cyan
            }
            if (outOfRange.g) {
                // Green channel: modulate between Green and Magenta
                debugColor.r = modulation * debugColor.r + (1.0 - modulation) * RGB.g;
                debugColor.g = modulation * debugColor.g + (1.0 - modulation) * 0.0;
                debugColor.b = modulation * debugColor.b + (1.0 - modulation) * RGB.g;
            }
            if (outOfRange.b) {
                // Blue channel: modulate between Blue and Yellow
                debugColor.r = modulation * debugColor.r + (1.0 - modulation) * RGB.b;
                debugColor.g = modulation * debugColor.g + (1.0 - modulation) * RGB.b;
                debugColor.b = modulation * debugColor.b + (1.0 - modulation) * 0.0;
            }
            RGB = debugColor;
        }
        FragColor = vec4(crt_gamma(clamp(RGB, 0.0, 1.0)), 1.0);
        return;
    }

    // Gamut mapping goes here

    // Tone mapping
    vec3 color;
    if (TONE_MAPPING_BYPASS < 1.0) {
        // Calculate white point
        vec3 white = Yrgb_to_RGB(WHITE, W, toRGB);
        float G = max(max(white.r, white.g), white.b);

        // Apply tone mapping
        if (TONE_MAP_TYPE < 0.5) {
            color = reinhard(RGB);
        } else if (TONE_MAP_TYPE < 1.5) {
            color = reinhard_yonly(RGB);
        } else if (TONE_MAP_TYPE < 2.5) {
            color = reinhard_extended(RGB, 1.33);
        } else if (TONE_MAP_TYPE < 3.5) {
            color = reinhard_extended_yonly(RGB, 1.33);
        } else if (TONE_MAP_TYPE < 4.5) {
            color = uncharted2_filmic(RGB, 11.2, 2.0);
        } else {
            color = tone_map_aces(0.8 * RGB);
        }
    } else {
        color = RGB;
    }

    if (DEBUG_TONE_MAP_DELTA > 0.5) {
        vec3 delta = abs(RGB - color);
        FragColor = vec4(crt_gamma(clamp(delta, 0.0, 1.0)), 1.0);
        return;
    }

    // Safety clamp
    color = clamp(color, 0.0, 1.0);
    FragColor = vec4(crt_gamma(color), 1.0);
}
