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

#include "menus/parameters/colorimetry.inc"
#include "menus/parameters/output-color-sdr.inc"

#pragma name Color
#pragma format R8G8B8A8_UNORM

#pragma parameter COLOR_CONVERSION_BYPASS "Bypass color correction" 0.0 0.0 1.0 1.0
#pragma parameter DEBUG_COLOR_DELTA "Show color correction deltas" 0.0 0.0 1.0 1.0
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
    float W_X;
    float W_Y;
    float CHROMATIC_ADAPTATION;
    float ADAPTATION_LEVEL;
    float GAMUT_COMPRESSION;
    float COLOR_CONVERSION_BYPASS;
    float COLORIMETRY_PRESET;
    float DEBUG_COLOR_DELTA;
    float COLOR_DEBUG_OUT_OF_RANGE;
} config;

#define COLORIMETRY_PRESET config.COLORIMETRY_PRESET
#define R_X config.R_X
#define R_Y config.R_Y
#define G_X config.G_X
#define G_Y config.G_Y
#define B_X config.B_X
#define B_Y config.B_Y
#define W_X config.W_X
#define W_Y config.W_Y
#define CHROMATIC_ADAPTATION config.CHROMATIC_ADAPTATION
#define ADAPTATION_LEVEL config.ADAPTATION_LEVEL
#define GAMUT_COMPRESSION config.GAMUT_COMPRESSION
#define COLOR_CONVERSION_BYPASS config.COLOR_CONVERSION_BYPASS
#define DEBUG_COLOR_DELTA config.DEBUG_COLOR_DELTA
#define COLOR_DEBUG_OUT_OF_RANGE config.COLOR_DEBUG_OUT_OF_RANGE

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

// -- Color space conversion functions -- //

// -- Perceptual color transform functions -- //
// Linear methods are in color.inc

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

// -- Gamut compression functions -- //

// Simple luminance scaling to fit sRGB
vec3 reduce_luminance(const vec3 color)
{
    float maxC = max(max(color.r, color.g), color.b);
    if (maxC > 1.0) {
        // Scale all channels so the maximum is 1.0
        return color / maxC;
    }
    return color;
}

const float THRESHOLD = 1.0 / 256.0;

// --- Advanced gamut compression in CIE Luv space -- //
//
// Reduces luminance and chroma as needed to fit into sRGB gamut.
// Since most displays have luminance headroom in dim environments,
// this method prioritizes preserving chrominance over luminance when
// a channel is greater than 1.0.  Conversely, when a channel is less
// than 0.0, luminance is preserved while chroma is reduced because
// humans are less sensitive to chroma loss in dark colors while being
// more sensitive to changes in luminance.

// Scale luminance in CIE Luv space
float scale_luminance_cieluv(vec3 color, vec3 luv)
{
    // Reduce luminance if any channel > 1
    if (any(greaterThan(color, vec3(1.0)))) {
        float minScale = 0.0;
        float maxScale = 1.0;
        float scale = 1.0;
        for (int i = 0; i < 9; ++i) {
            float testL = luv.x * scale;
            vec3 testRGB = XYZ_TO_sRGB * CIE_LUV_to_XYZ(vec3(testL, luv.y, luv.z));
            if (all(lessThanEqual(testRGB, vec3(1.0)))) {
                minScale = scale;
            } else {
                maxScale = scale;
            }
            scale = 0.5 * (minScale + maxScale);
            if (maxScale - minScale < THRESHOLD)
                break;
        }
        return minScale;
    }
    return 1.0;
}

// Scale chroma in CIE Luv space
float scale_chroma_cieluv(vec3 color, vec3 luv)
{
    // Reduce chroma if any channel < 0
    if (any(lessThan(color, vec3(0.0)))) {
        float minScale = 0.0;
        float maxScale = 1.0;
        float scale = 1.0;
        for (int i = 0; i < 9; ++i) {
            vec3 testLuv = vec3(luv.x, luv.y * scale, luv.z * scale);
            vec3 testRGB = XYZ_TO_sRGB * CIE_LUV_to_XYZ(testLuv);
            if (all(greaterThanEqual(testRGB, vec3(0.0)))) {
                minScale = scale;
            } else {
                maxScale = scale;
            }
            scale = 0.5 * (minScale + maxScale);
            if (maxScale - minScale < THRESHOLD)
                break;
        }
        return minScale;
    }
    return 1.0;
}

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 luv_scale;
layout(location = 2) out mat3 RGB_to_XYZ;
layout(location = 5) out Colorimetry colorimetry;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    vec3 ref_XYZ;
    vec3 white_XYZ;
    vec3 red_XYZ;
    vec3 green_XYZ;
    vec3 blue_XYZ;

    // Set up colorimetry
    if (COLORIMETRY_PRESET < 0.5) {
        // Custom
        colorimetry = Colorimetry(
            vec2(R_X, R_Y),
            vec2(G_X, G_Y),
            vec2(B_X, B_Y),
            vec2(W_X, W_Y));
        ref_XYZ = xyY_to_XYZ(vec3(W_X, W_Y, 1.0));
        red_XYZ = xyY_to_XYZ(vec3(R_X, R_Y, 1.0));
        green_XYZ = xyY_to_XYZ(vec3(G_X, G_Y, 1.0));
        blue_XYZ = xyY_to_XYZ(vec3(B_X, B_Y, 1.0));

        RGB_to_XYZ = get_RGB_to_XYZ(red_XYZ, green_XYZ, blue_XYZ, ref_XYZ);
    } else if (COLORIMETRY_PRESET < 1.5) {
        // Rec. 601
        colorimetry = Colorimetry(
            vec2(0.630, 0.340),
            vec2(0.310, 0.595),
            vec2(0.155, 0.070),
            vec2(0.3127, 0.3290));
        RGB_to_XYZ = SMPTE_C_TO_XYZ;
    } else if (COLORIMETRY_PRESET < 2.5) {
        // Japanese phosphors, D93
        colorimetry = Colorimetry(
            vec2(0.618, 0.350),
            vec2(0.280, 0.605),
            vec2(0.152, 0.063),
            vec2(0.2832, 0.2971));
        RGB_to_XYZ = NTSC_J_TO_XYZ;
    } else if (COLORIMETRY_PRESET < 3.5) {
        // EBU Tech 3213
        colorimetry = Colorimetry(
            vec2(0.640, 0.330),
            vec2(0.290, 0.600),
            vec2(0.150, 0.060),
            vec2(0.3127, 0.3290));
        RGB_to_XYZ = EBU_TO_XYZ;
    } else {
        // Rec. 709
        colorimetry = Colorimetry(
            vec2(0.640, 0.330),
            vec2(0.300, 0.600),
            vec2(0.150, 0.060),
            vec2(0.3127, 0.3290));
        RGB_to_XYZ = sRGB_TO_XYZ;
    }

    ref_XYZ = RGB_to_XYZ * WHITE;
    const vec3 D65_XYZ = vec3(0.95047, 1.0, 1.08883);

    if (CHROMATIC_ADAPTATION < 0.5) {
        // No adaptation, so pass through RGB_to_XYZ
        white_XYZ = RGB_to_XYZ * WHITE;
        red_XYZ = RGB_to_XYZ * RED;
        green_XYZ = RGB_to_XYZ * GREEN;
        blue_XYZ = RGB_to_XYZ * INDIGO;
    } else if (CHROMATIC_ADAPTATION < 1.5) {
        // Linear Bradford adaptation
        RGB_to_XYZ = bradford_linear(ref_XYZ, D65_XYZ) * RGB_to_XYZ;
        white_XYZ = RGB_to_XYZ * WHITE;
        red_XYZ = RGB_to_XYZ * RED;
        green_XYZ = RGB_to_XYZ * GREEN;
        blue_XYZ = RGB_to_XYZ * INDIGO;
    } else if (CHROMATIC_ADAPTATION < 2.5) {
        // Zhai et al. 2018 CAT16 adaptation
        RGB_to_XYZ = zhai2018_cat16(ref_XYZ, D65_XYZ, ADAPTATION_LEVEL) * RGB_to_XYZ;
        white_XYZ = RGB_to_XYZ * WHITE;
        red_XYZ = RGB_to_XYZ * RED;
        green_XYZ = RGB_to_XYZ * GREEN;
        blue_XYZ = RGB_to_XYZ * INDIGO;
    } else {
        // Bradford adaptation; needs more complex handling
        white_XYZ = RGB_to_XYZ * WHITE;
        red_XYZ = RGB_to_XYZ * RED;
        green_XYZ = RGB_to_XYZ * GREEN;
        blue_XYZ = RGB_to_XYZ * INDIGO;
        white_XYZ = bradford(white_XYZ, ref_XYZ);
        red_XYZ = bradford(red_XYZ, ref_XYZ);
        green_XYZ = bradford(green_XYZ, ref_XYZ);
        blue_XYZ = bradford(blue_XYZ, ref_XYZ);
    }

    // Precompute Luv scale factors for advanced gamut compression
    luv_scale = vec2(0.0);

    if (GAMUT_COMPRESSION > 2.5) {
        vec3 white_srgb = XYZ_TO_sRGB * white_XYZ;
        vec3 red_srgb = XYZ_TO_sRGB * red_XYZ;
        vec3 green_srgb = XYZ_TO_sRGB * green_XYZ;
        vec3 blue_srgb = XYZ_TO_sRGB * blue_XYZ;

        vec3 white_luv = XYZ_to_CIE_LUV(white_XYZ);
        vec3 red_luv = XYZ_to_CIE_LUV(red_XYZ);
        vec3 green_luv = XYZ_to_CIE_LUV(green_XYZ);
        vec3 blue_luv = XYZ_to_CIE_LUV(blue_XYZ);

        // Determine luminance pre-scale
        float y_scale = scale_luminance_cieluv(white_srgb, white_luv);

        red_luv.x *= y_scale;
        green_luv.x *= y_scale;
        blue_luv.x *= y_scale;

        // Determine chroma pre-scale
        float red_c_scale = scale_chroma_cieluv(red_srgb, red_luv);
        float green_c_scale = scale_chroma_cieluv(green_srgb, green_luv);
        float blue_c_scale = scale_chroma_cieluv(blue_srgb, blue_luv);
        float c_scale = min(min(red_c_scale, green_c_scale), blue_c_scale);

        luv_scale = vec2(y_scale, c_scale);
    }
}


#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 luv_scale;
layout(location = 2) in mat3 RGB_to_XYZ;
layout(location = 5) in Colorimetry colorimetry;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 Yrgb = texture(Source, vTexCoord).rgb;
    
    // Early exit for full bypass
    if (COLOR_CONVERSION_BYPASS >= 1.0) {
        FragColor = vec4(sdr_gamma(clamp(Yrgb, 0.0, 1.0)), 1.0);
        return;
    }

    mat3 toRGB = XYZ_TO_sRGB;
    vec3 RGB;

    if (CHROMATIC_ADAPTATION < 2.5) {
        // Linear, convert directly from conversion matrix

        // Take advantage of intermediate for advanced compression
        if (GAMUT_COMPRESSION < 1.5) {
            RGB = toRGB * RGB_to_XYZ * Yrgb;
        } else if (GAMUT_COMPRESSION < 2.5) {
            vec3 XYZ = RGB_to_XYZ * Yrgb;
            vec3 Luv = XYZ_to_CIE_LUV(XYZ);

            RGB = toRGB * XYZ;
            Luv.x *= scale_luminance_cieluv(RGB, Luv);
            Luv.yz *= scale_chroma_cieluv(RGB, Luv);

            RGB = toRGB * CIE_LUV_to_XYZ(Luv);
        } else if (GAMUT_COMPRESSION < 3.5) {
            vec3 XYZ = RGB_to_XYZ * Yrgb;
            vec3 Luv = XYZ_to_CIE_LUV(XYZ);

            Luv.x *= luv_scale.x;
            Luv.yz *= luv_scale.y;
            RGB = toRGB * CIE_LUV_to_XYZ(Luv);
        }
    } else {
        // Bradford adaptation requires special handling
        vec3 ref_XYZ = RGB_to_XYZ * WHITE;
        vec3 Yrgb_XYZ = RGB_to_XYZ * Yrgb;
        vec3 adapted_XYZ = bradford(Yrgb_XYZ, ref_XYZ);
        RGB = toRGB * adapted_XYZ;

        if (GAMUT_COMPRESSION < 1.5) {
            // Handle later
        } else if (GAMUT_COMPRESSION < 2.5) {
            vec3 Luv = XYZ_to_CIE_LUV(adapted_XYZ);

            Luv.x *= scale_luminance_cieluv(RGB, Luv);
            Luv.yz *= scale_chroma_cieluv(RGB, Luv);

            RGB = toRGB * CIE_LUV_to_XYZ(Luv);
        } else if (GAMUT_COMPRESSION < 3.5) {
            vec3 Luv = XYZ_to_CIE_LUV(adapted_XYZ);

            Luv.x *= luv_scale.x;
            Luv.yz *= luv_scale.y;
            RGB = toRGB * CIE_LUV_to_XYZ(Luv);
        }
    }

    if (DEBUG_COLOR_DELTA > 0.5) {
        vec3 delta = abs(RGB - Yrgb);
        FragColor = vec4(sdr_gamma(clamp(delta, 0.0, 1.0)), 1.0);
        return;
    }

    // Gamut mapping
    if (GAMUT_COMPRESSION < 0.5) {
        // No gamut compression
    } else if (GAMUT_COMPRESSION < 1.5) {
        RGB = reduce_luminance(RGB);
    } else {
        // Advanced gamut compression
        // Already applied earlier
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
        float spatialPhase = (vTexCoord.x + vTexCoord.y) * config.OutputSize.x / 2.0;  // Adjust frequency as needed
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
        FragColor = vec4(sdr_gamma(clamp(RGB, 0.0, 1.0)), 1.0);
        return;
    }

    vec3 color = RGB;

    // Safety clamp
    color = clamp(color, 0.0, 1.0);
    FragColor = vec4(sdr_gamma(color), 1.0);
}
