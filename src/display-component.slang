#version 450

/* Filename: display-component.slang

   Copyright (C) 2025 W. M. Martinez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include "common.h"
#include "color.h"

#pragma name DisplayComponent
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float DISPLAY_COMPONENT_BYPASS;
    float YC_MODEL; // 0=YIQ, 1=YPbPr, 2=YUV, 3=YDbDr, 4=YCbCr
} config;

#pragma parameter DISPLAY_COMPONENT_HEADER " ==== Display Component Parameters ==== " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPONENT_BYPASS "Display component bypass" 0.0 0.0 1.0 1.0
#define DISPLAY_COMPONENT_BYPASS config.DISPLAY_COMPONENT_BYPASS
#pragma parameter YC_MODEL "YC color model (0=YIQ,1=YPbPr,2=YUV,3=YDbDr,4=YCbCr)" 1.0 0.0 4.0 1.0
#define YC_MODEL config.YC_MODEL

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

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
    if (DISPLAY_COMPONENT_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    vec3 pixel = texture(Source, vTexCoord).rgb;

    // Decode from selected luma-chroma model to RGB
    // Modes: 0=YIQ, 1=YPbPr, 2=YUV, 3=YDbDr, 4=YCbCr
    if (YC_MODEL < 0.5) {
        pixel = YIQ_TO_RGB * pixel;
    } else if (YC_MODEL < 1.5) {
        pixel = YPbPr_TO_RGB * pixel;
    } else if (YC_MODEL < 2.5) {
        pixel = YUV_TO_RGB * pixel;
    } else if (YC_MODEL < 3.5) {
        // YDbDr -> YUV -> RGB
        // From sys-component.slang:
        //   Db = (1.333/0.436) * U,  Dr = (-1.333/0.615) * V
        // Invert to get U, V from Db, Dr:
        const float U_FROM_DB = 0.436 / 1.333;  // ≈ 0.327285
        const float V_FROM_DR = -0.615 / 1.333; // ≈ -0.461890
        vec3 yuv = vec3(pixel.r, pixel.g * U_FROM_DB, pixel.b * V_FROM_DR);
        pixel = YUV_TO_RGB * yuv;
    } else {
        pixel = YCbCr_TO_RGB * pixel;
    }

    FragColor = vec4(pixel, 1.0);
}