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
#pragma parameter COLORIMETRY_PRESET "Colorimetry Preset (Off, Rec. 601, Rec. 709)" 0.0 0.0 2.0 1.0
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
    float R_WEIGHT;
    float G_WEIGHT;
    float B_WEIGHT;
    float CHROMATIC_ADAPTATION;
    float ADAPTATION_LEVEL;
    float GAMUT_COMPRESSION;
    float COLOR_CONVERSION_BYPASS;
    float COLORIMETRY_PRESET;
    float DEBUG_COLOR_DELTA;
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
#define CHROMATIC_ADAPTATION config.CHROMATIC_ADAPTATION
#define ADAPTATION_LEVEL config.ADAPTATION_LEVEL
#define GAMUT_COMPRESSION config.GAMUT_COMPRESSION
#define COLOR_CONVERSION_BYPASS config.COLOR_CONVERSION_BYPASS
#define COLORIMETRY_PRESET config.COLORIMETRY_PRESET
#define DEBUG_COLOR_DELTA config.DEBUG_COLOR_DELTA
#define COLOR_DEBUG_OUT_OF_RANGE config.COLOR_DEBUG_OUT_OF_RANGE

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

// -- Color space conversion functions -- //

struct Colorimetry {
    vec2 R; // Red primary (x, y)
    vec2 G; // Green primary (x, y)
    vec2 B; // Blue primary (x, y)
    vec3 W; // White point weights (Wr, Wg, Wb)
};

// Precomputed gamut space for CIELuv gamut compression
struct ReferenceColors {
    vec3 ref_XYZ;
    vec3 white_sRGB;
    vec3 red_sRGB;
    vec3 green_sRGB;
    vec3 blue_sRGB;
    vec3 white_Luv;
    vec3 red_Luv;
    vec3 green_Luv;
    vec3 blue_Luv;
};

// Convert from linear RGB to XYZ by way of xy chromaticity
//
// Yrgb: Input color in Yrgb space
// W: Weighting vector for RGB channels
vec3 Yrgb_to_XYZ(vec3 Yrgb, Colorimetry colorimetry)
{
    mat3 xyYrgb = mat3(
        colorimetry.R.x, colorimetry.R.y, Yrgb.r,
        colorimetry.G.x, colorimetry.G.y, Yrgb.g,
        colorimetry.B.x, colorimetry.B.y, Yrgb.b);
    mat3 XYZrgb = mat3(
        xyY_to_XYZ(xyYrgb[0]),
        xyY_to_XYZ(xyYrgb[1]),
        xyY_to_XYZ(xyYrgb[2]));
    vec3 XYZ = vec3(
        dot(colorimetry.W, vec3(XYZrgb[0].r, XYZrgb[1].r, XYZrgb[2].r)),
        dot(colorimetry.W, vec3(XYZrgb[0].g, XYZrgb[1].g, XYZrgb[2].g)),
        dot(colorimetry.W, vec3(XYZrgb[0].b, XYZrgb[1].b, XYZrgb[2].b)));
    return XYZ;
}

// Direct conversion from Yrgb to RGB
//
// Yrgb: Input color in Yrgb space
// W: Weighting vector for RGB channels
// toRGB: Matrix to convert from XYZ to RGB
vec3 Yrgb_to_RGB(vec3 Yrgb, Colorimetry colorimetry, mat3 toRGB)
{
    vec3 XYZ = Yrgb_to_XYZ(Yrgb, colorimetry);
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

mat3 zhai2018_cat16_adaptation_matrix(vec3 src_white, float d) {
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
        d * tgt_cone.x / src_cone.x + 1.0 - d, 0.0, 0.0,
        0.0, d * tgt_cone.y / src_cone.y + 1.0 - d, 0.0,
        0.0, 0.0, d * tgt_cone.z / src_cone.z + 1.0 - d);

    return cat16_M_inv * D * cat16_M;
}

vec3 adapt_color_cat16(vec3 color_xyz, vec3 src_white, float d) {
    mat3 adapt = zhai2018_cat16_adaptation_matrix(src_white, d);
    return adapt * color_xyz;
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

// Advanced gamut compression using CIE Luv space
//
// color: Input RGB color
// Returns: Gamut-compressed RGB color
//
// Reduces luminance and chroma as needed to fit into sRGB gamut.
// Since most displays have luminance headroom in dim environments,
// this method prioritizes preserving chrominance over luminance when
// a channel is greater than 1.0.  Conversely, when a channel is less
// than 0.0, luminance is preserved while chroma is reduced because
// humans are less sensitive to chroma loss in dark colors while being
// more sensitive to changes in luminance.
vec3 compress_gamut_cieluv(vec3 color)
{
    vec3 xyz = sRGB_TO_XYZ * clamp(color, 0.0, 1.0);
    vec3 luv = XYZ_to_CIE_LUV(xyz);

    luv.x *= scale_luminance_cieluv(color, luv);
    luv.yz *= scale_chroma_cieluv(color, luv);

    return XYZ_TO_sRGB * CIE_LUV_to_XYZ(luv);
}

vec3 compress_gamut_cieluv_prescaling(vec3 color, ReferenceColors ref_colors)
{
    vec3 white_srgb = ref_colors.white_sRGB;
    vec3 red_srgb = ref_colors.red_sRGB;
    vec3 green_srgb = ref_colors.green_sRGB;
    vec3 blue_srgb = ref_colors.blue_sRGB;

    vec3 white_luv = ref_colors.white_Luv;
    vec3 red_luv = ref_colors.red_Luv;
    vec3 green_luv = ref_colors.green_Luv;
    vec3 blue_luv = ref_colors.blue_Luv;

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

    // Apply pre-scaling
    vec3 luv = XYZ_to_CIE_LUV(sRGB_TO_XYZ * color);
    luv.x *= y_scale;
    luv.yz *= c_scale;
    return XYZ_TO_sRGB * CIE_LUV_to_XYZ(luv);
}

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out Colorimetry colorimetry;
layout(location = 5) out ReferenceColors ref_colors;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Set up colorimetry
    if (COLORIMETRY_PRESET < 0.5) {
        // Custom
        colorimetry = Colorimetry(
            vec2(R_X, R_Y),
            vec2(G_X, G_Y),
            vec2(B_X, B_Y),
            vec3(R_WEIGHT, G_WEIGHT, B_WEIGHT));
    } else if (COLORIMETRY_PRESET < 1.5) {
        // Rec. 601
        colorimetry = Colorimetry(
            vec2(0.630, 0.340),
            vec2(0.310, 0.595),
            vec2(0.155, 0.070),
            vec3(0.2124, 0.7011, 0.0866)); // D65 weights
    } else {
        // Rec. 709
        colorimetry = Colorimetry(
            vec2(0.640, 0.330),
            vec2(0.300, 0.600),
            vec2(0.150, 0.060),
            vec3(0.2126, 0.7152, 0.0722)); // D65 weights
    }

    ref_colors = ReferenceColors(
        Yrgb_to_XYZ(WHITE, colorimetry),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0),
        vec3(0.0));
    ref_colors.ref_XYZ = Yrgb_to_XYZ(WHITE, colorimetry);

    // Set up reference colors for advanced gamut compression
    if (GAMUT_COMPRESSION > 2.5) {
        vec3 white_XYZ = ref_colors.ref_XYZ;
        vec3 red_XYZ = Yrgb_to_XYZ(RED, colorimetry);
        vec3 green_XYZ = Yrgb_to_XYZ(GREEN, colorimetry);
        vec3 blue_XYZ = Yrgb_to_XYZ(INDIGO, colorimetry);

        if (CHROMATIC_ADAPTATION < 0.5) {
            // No adaptation
        } else if (CHROMATIC_ADAPTATION < 1.5) {
            // Bradford adaptation
            white_XYZ = bradford(white_XYZ, ref_colors.ref_XYZ);
            red_XYZ = bradford(red_XYZ, ref_colors.ref_XYZ);
            green_XYZ = bradford(green_XYZ, ref_colors.ref_XYZ);
            blue_XYZ = bradford(blue_XYZ, ref_colors.ref_XYZ);
        } else if (CHROMATIC_ADAPTATION < 2.5) {
            // Linear Bradford adaptation
            white_XYZ = bradford_linear(white_XYZ, ref_colors.ref_XYZ);
            red_XYZ = bradford_linear(red_XYZ, ref_colors.ref_XYZ);
            green_XYZ = bradford_linear(green_XYZ, ref_colors.ref_XYZ);
            blue_XYZ = bradford_linear(blue_XYZ, ref_colors.ref_XYZ);
        } else {
            // Zhai et al. 2018 CAT16 adaptation
            white_XYZ = adapt_color_cat16(white_XYZ, ref_colors.ref_XYZ, ADAPTATION_LEVEL);
            red_XYZ = adapt_color_cat16(red_XYZ, ref_colors.ref_XYZ, ADAPTATION_LEVEL);
            green_XYZ = adapt_color_cat16(green_XYZ, ref_colors.ref_XYZ, ADAPTATION_LEVEL);
            blue_XYZ = adapt_color_cat16(blue_XYZ, ref_colors.ref_XYZ, ADAPTATION_LEVEL);
        }
        ref_colors.white_sRGB = XYZ_TO_sRGB * white_XYZ;
        ref_colors.red_sRGB = XYZ_TO_sRGB * red_XYZ;
        ref_colors.green_sRGB = XYZ_TO_sRGB * green_XYZ;
        ref_colors.blue_sRGB = XYZ_TO_sRGB * blue_XYZ;
        ref_colors.white_Luv = XYZ_to_CIE_LUV(white_XYZ);
        ref_colors.red_Luv = XYZ_to_CIE_LUV(red_XYZ);
        ref_colors.green_Luv = XYZ_to_CIE_LUV(green_XYZ);
    }
}


#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in Colorimetry colorimetry;
layout(location = 5) in ReferenceColors ref_colors;
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
    vec3 RGB;

    if (CHROMATIC_ADAPTATION < 0.5) {
        // No adaptation, just convert RGBref to XYZ to RGBout
        RGB = Yrgb_to_RGB(Yrgb, colorimetry, toRGB);
    } else if (CHROMATIC_ADAPTATION < 1.5) {
        // Bradford adaptation
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, colorimetry);
        vec3 adapted_XYZ = bradford(Yrgb_XYZ, ref_colors.ref_XYZ);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    } else if (CHROMATIC_ADAPTATION < 2.5) {
        // Linear Bradford adaptation
        // Forgoes precise blue channel adaptation for performance
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, colorimetry);
        vec3 adapted_XYZ = bradford_linear(Yrgb_XYZ, ref_colors.ref_XYZ);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    } else {
        // Zhai et al. 2018 CAT16 adaptation
        vec3 Yrgb_XYZ = Yrgb_to_XYZ(Yrgb, colorimetry);
        vec3 adapted_XYZ = adapt_color_cat16(Yrgb_XYZ, ref_colors.ref_XYZ, ADAPTATION_LEVEL);
        RGB = XYZ_TO_sRGB * adapted_XYZ;
    }

    if (DEBUG_COLOR_DELTA > 0.5) {
        vec3 delta = abs(RGB - Yrgb);
        FragColor = vec4(crt_gamma(clamp(delta, 0.0, 1.0)), 1.0);
        return;
    }

    // Gamut mapping
    if (GAMUT_COMPRESSION < 0.5) {
        // No gamut compression
    } else if (GAMUT_COMPRESSION < 1.5) {
        RGB = reduce_luminance(RGB);
    } else if (GAMUT_COMPRESSION < 2.5) {
        RGB = compress_gamut_cieluv(RGB);
    } else {
        RGB = compress_gamut_cieluv_prescaling(RGB, ref_colors);
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
        FragColor = vec4(crt_gamma(clamp(RGB, 0.0, 1.0)), 1.0);
        return;
    }

    vec3 color = RGB;

    // Safety clamp
    color = clamp(color, 0.0, 1.0);
    FragColor = vec4(crt_gamma(color), 1.0);
}
