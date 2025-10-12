#version 450

/* Filename: scanline-bandlimit.slang

   Copyright (C) 2020 guest(r) - guest.r@gmail.com
   Copyright (C) 2023 W. M. Martinez

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

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float LUMA_CHROMA_MODEL;
} config;

#pragma parameter LUMA_CHROMA_MODEL "Luma-Chroma Color Model (0=YIQ, 1=YUV, 2=YPbPr, 3=YCbCr)" 2 0 3 1
#define LUMA_CHROMA_MODEL config.LUMA_CHROMA_MODEL

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
    vec3 pixel = texture(Source, vTexCoord).rgb;

    pixel.g -= 0.5;
    pixel.b -= 0.5;
    if (LUMA_CHROMA_MODEL < 1)
        pixel = YIQ_TO_RGB * pixel;
    else if (LUMA_CHROMA_MODEL < 2)
        pixel = YUV_TO_RGB * pixel;
    else if (LUMA_CHROMA_MODEL < 3)
        pixel = YPbPr_TO_RGB * pixel;
    else
        pixel = YCbCr_TO_RGB * pixel;
    pixel = clamp(pixel, 0.0, 1.0);
    FragColor = vec4(pixel, 1.0);
}