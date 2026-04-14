#version 450

// Filename: limiter.slang
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
// Display-side RGB amplifier and gamma adjustment
// -----------------------------------------------
// Input: Real RGB voltage
// Output: Real RGB voltage
//
// Applies NTSC conversion matrix if needed, user gamma adjustment,
// and RGB drive and bias.

#pragma name DisplayRGBAmp
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "tools/zebra.inc"

#include "menus/parameters/colorimetry.inc"
#include "menus/parameters/display-rgb-amp.inc"
#include "menus/parameters/user-uncommon.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_RGB_AMP_HEADER " —— Debug Display RGB Amplifier —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_RGB_AMP_BYPASS "Bypass display RGB amplifier" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_DEBUG_OUT_OF_RANGE "Display: show out-of-range colors" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    // Output size info
    vec4 OutputSize;
    uint FrameCount;

    // User video adjustments
    float USER_GAMMA;
    float USER_BLUE_ONLY;

    // Color conversion circuitry (RGB matrix type)
    float NTSC_CONVERSION;
    float NTSC_CONVERSION_WEIGHT;
    float R_X;
    float R_Y;
    float G_X;
    float G_Y;
    float B_X;
    float B_Y;
    float W_X;
    float W_Y;
    float COLORIMETRY_PRESET;

    // Amp
    float DISPLAY_GAIN_R;
    float DISPLAY_GAIN_G;
    float DISPLAY_GAIN_B;
    float DISPLAY_BIAS_R;
    float DISPLAY_BIAS_G;
    float DISPLAY_BIAS_B;

#ifdef OPTION_DEBUG
    float DISPLAY_DEBUG_OUT_OF_RANGE;
    float DISPLAY_RGB_AMP_BYPASS;
#endif // OPTION_DEBUG

} config;

#define USER_GAMMA config.USER_GAMMA
#define USER_BLUE_ONLY config.USER_BLUE_ONLY

#define NTSC_CONVERSION config.NTSC_CONVERSION
#define NTSC_CONVERSION_WEIGHT config.NTSC_CONVERSION_WEIGHT
#define R_X config.R_X
#define R_Y config.R_Y
#define G_X config.G_X
#define G_Y config.G_Y
#define B_X config.B_X
#define B_Y config.B_Y
#define W_X config.W_X
#define W_Y config.W_Y
#define COLORIMETRY_PRESET config.COLORIMETRY_PRESET

#define DISPLAY_GAIN_R config.DISPLAY_GAIN_R
#define DISPLAY_GAIN_G config.DISPLAY_GAIN_G
#define DISPLAY_GAIN_B config.DISPLAY_GAIN_B
#define DISPLAY_BIAS_R config.DISPLAY_BIAS_R
#define DISPLAY_BIAS_G config.DISPLAY_BIAS_G
#define DISPLAY_BIAS_B config.DISPLAY_BIAS_B

#ifdef OPTION_DEBUG
#define DISPLAY_DEBUG_OUT_OF_RANGE config.DISPLAY_DEBUG_OUT_OF_RANGE
#define DISPLAY_RGB_AMP_BYPASS config.DISPLAY_RGB_AMP_BYPASS
#endif // OPTION_DEBUG

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out flat vec3 rgbGain;
layout(location = 2) out flat vec3 rgbBias;
layout(location = 3) out flat mat3 correctionMatrix;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Prepare NTSC conversion matrix if needed
    correctionMatrix = mat3(1.0);

#ifdef OPTION_NOCOLOR
#else
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
        correctionMatrix = inverse(RGB_to_XYZ) * ref_to_XYZ;
    }
#endif // OPTION_NOCOLOR

    rgbGain = vec3(
            db_to_linear(DISPLAY_GAIN_R),
            db_to_linear(DISPLAY_GAIN_G),
            db_to_linear(DISPLAY_GAIN_B)
        );
    rgbBias = vec3(
        DISPLAY_BIAS_R * 10e-3,  // Convert IRE to V
        DISPLAY_BIAS_G * 10e-3,
        DISPLAY_BIAS_B * 10e-3
    );
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in vec3 rgbGain;
layout(location = 2) flat in vec3 rgbBias;
layout(location = 3) flat in mat3 correctionMatrix;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 color = texture(Source, vTexCoord).rgb;

#ifdef OPTION_DEBUG
    if (DISPLAY_RGB_AMP_BYPASS > 0.5) {
        FragColor = vec4(color, 1.0);
        return;
    }
#endif  // OPTION_DEBUG

    // Apply NTSC conversion matrix
    color = mix(color, correctionMatrix * color, NTSC_CONVERSION);

    // Blue-only toggle
    color.rg *= vec2(1.0 - USER_BLUE_ONLY);

    // Apply user video adjustments
    float gamma = (2.4 - USER_GAMMA / 10.0) / 2.4; // Map USER_GAMMA 0-1 to fraction of 2.4

    // Preserve extended values for proper handling
    if (color.r < 1.0)
        color.r = pow(color.r, gamma);
    if (color.g < 1.0)
        color.g = pow(color.g, gamma);
    if (color.b < 1.0)
        color.b = pow(color.b, gamma);

#ifdef OPTION_DEBUG
    if (DISPLAY_DEBUG_OUT_OF_RANGE >= 1.0) {
        // Debug: Visualize out-of-range colors with zebra pattern
        color = zebra(color, 0.0, 1.0, vTexCoord, config.OutputSize.xy, config.FrameCount, 1.0);
    }
#endif  // OPTION_DEBUG

    // Apply RGB drive and bias
    color = rgbGain * (color + rgbBias);

    // Clamp negative values to 0
    color = max(color, vec3(0.0));

    FragColor = vec4(color, 1.0);
}
