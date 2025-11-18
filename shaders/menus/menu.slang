#version 450

// Filename: menu.slang
//
// Copyright (C) 2023, 2025 W. M. Martinez
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
// Menu shader
// ------------
// Input: Passthrough
// Output: Passthrough
//
// Helper shader for loading parameters in the appropriate order.

#include "parameters/output-tonemap.inc"
#include "parameters/output-curve.inc"
#include "parameters/output-color-sdr.inc"
#include "parameters/output-bezel.inc"
#include "parameters/user-common.inc"
#include "parameters/service-geometry.inc"
#include "parameters/scanraster.inc"
#include "parameters/display-rgb.inc"
#include "parameters/factory-geometry.inc"
#include "parameters/mask.inc"
#include "parameters/colorimetry.inc"
#include "parameters/phosphor.inc"
#include "parameters/limiter.inc"
#include "parameters/sys-timing.inc"
#include "parameters/sys-rgb.inc"
#include "parameters/debug-common.inc"

#pragma name Menu
#pragma format R8G8B8A8_UNORM

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
} params;

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
    FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
}