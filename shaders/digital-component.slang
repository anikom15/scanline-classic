#version 450

// Filename: digital-component.slang
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
// Digital RGB to YC Component stage
// -------------------------------
// Input: Gamma-corrected RGB
// Output: YCbCr (rec. 601 or rec. 709) or other luma-chroma space
//
// Encodes RGB into a chosen luma-chroma color space, and optionally
// performs chroma subsampling.  The result is also interpolated based
// on the ratio of output size to source size (to the nearest integer
// scale).
//
// By default, 4:2:2 subsampling is used for rec. 601 and 4:2:0 for rec. 709.

#include "common.inc"
#include "color.inc"

#include "menus/parameters/digital-component.inc"

#pragma name DigitalComponent
#pragma format A2B10G10R10_UNORM_PACK32

#pragma parameter DIGITAL_COMPONENT_BYPASS "Bypass system component stage" 0.0 0.0 1.0 1.0
#pragma parameter DIGITAL_POST_BYPASS "Bypass digital component postprocessing" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OutputSize;

    float YCBCR_MODEL;
    float CHROMA_SUBSAMPLE;
    float GAMMA_CORRECT_BLENDING;
    float DIGITAL_COMPONENT_BYPASS;
    float DIGITAL_POST_BYPASS;
} config;

#define DIGITAL_COMPONENT_BYPASS config.DIGITAL_COMPONENT_BYPASS
#define DIGITAL_POST_BYPASS config.DIGITAL_POST_BYPASS

#define YCBCR_MODEL config.YCBCR_MODEL
#define CHROMA_SUBSAMPLE config.CHROMA_SUBSAMPLE
#define GAMMA_CORRECT_BLENDING config.GAMMA_CORRECT_BLENDING

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// Convert RGB to selected luma-chroma space.
// For YDbDr: RGB -> YUV -> scale (U,V) to (Db,Dr).
vec3 rgb_to_luma_chroma(vec3 rgb, float model)
{
    if (model < 0.5) { // SMPTE
        return RGB_TO_YPbPr * rgb; 
    } else { // Rec. 709
        return RGB_TO_YCbCr * rgb;
    }
}

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 resample_mode;
layout(location = 2) out float subsample_mode;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Chroma subsampling
    subsample_mode = 0.0;

    if (CHROMA_SUBSAMPLE < 0.5) {
        // Auto: choose based on color model
        if (YCBCR_MODEL < 1.5) {
            subsample_mode = 1.0;
        } else {
            subsample_mode = 2.0;
        }
    }

    // Determine if we are resampling
    resample_mode = vec2(0.0, 0.0);

    if (config.OutputSize.x < config.SourceSize.x) {
        resample_mode.x = -1.0;
    } else if (config.OutputSize.x > config.SourceSize.x) {
        resample_mode.x = 1.0;
    }

    if (config.OutputSize.y < config.SourceSize.y) {
        resample_mode.y = -1.0;
    } else if (config.OutputSize.y > config.SourceSize.y) {
        resample_mode.y = 1.0;
    }
}

#pragma stage fragment

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 resample_mode;
layout(location = 2) in float subsample_mode;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Full stage bypass: pass through RGB
    if (DIGITAL_COMPONENT_BYPASS >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Sample input and convert to luma-chroma space
    vec3 rgb = texture(Source, vTexCoord).rgb;
    vec3 yc = rgb_to_luma_chroma(rgb, YCBCR_MODEL);

    // Shift chroma for output range
    yc.gb += vec2(0.5, 0.5);
    
    FragColor = vec4(yc, 1.0);
}