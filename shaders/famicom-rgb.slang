#version 450

// Filename: famicom-rgb.slang
//
// Copyright (C) 2026 W. M. Martinez
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
// Decodes packed Famicom palette indices to RGB using 2C03 palette data.

#pragma name FamicomRGB
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"

layout(push_constant) uniform Push
{
    vec4 OutputSize;
} config;

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

// The 2C03 palette as 7-bit DAC values
const ivec3 PALETTE_2C03[64] = ivec3[](
    ivec3(3, 3, 3), ivec3(0, 1, 4), ivec3(0, 0, 6), ivec3(3, 2, 6),
    ivec3(4, 0, 3), ivec3(5, 0, 3), ivec3(5, 1, 0), ivec3(4, 2, 0),
    ivec3(3, 2, 0), ivec3(1, 2, 0), ivec3(0, 3, 1), ivec3(0, 4, 0),
    ivec3(0, 2, 2), ivec3(0, 0, 0), ivec3(0, 0, 0), ivec3(0, 0, 0),

    ivec3(5, 5, 5), ivec3(0, 3, 6), ivec3(0, 2, 7), ivec3(4, 0, 7),
    ivec3(5, 0, 7), ivec3(7, 0, 5), ivec3(7, 0, 0), ivec3(6, 3, 0),
    ivec3(4, 3, 0), ivec3(1, 4, 0), ivec3(0, 4, 0), ivec3(0, 5, 3),
    ivec3(0, 4, 4), ivec3(0, 0, 0), ivec3(0, 0, 0), ivec3(0, 0, 0),

    ivec3(7, 7, 7), ivec3(3, 5, 7), ivec3(4, 4, 7), ivec3(6, 3, 7),
    ivec3(7, 0, 7), ivec3(7, 3, 7), ivec3(7, 4, 0), ivec3(7, 5, 0),
    ivec3(6, 6, 0), ivec3(3, 6, 0), ivec3(4, 7, 0), ivec3(2, 7, 5),
    ivec3(4, 6, 7), ivec3(0, 0, 0), ivec3(0, 0, 0), ivec3(0, 0, 0),

    ivec3(7, 7, 7), ivec3(5, 6, 7), ivec3(6, 5, 7), ivec3(7, 5, 7),
    ivec3(7, 4, 7), ivec3(7, 5, 5), ivec3(7, 6, 4), ivec3(7, 7, 3),
    ivec3(7, 7, 4), ivec3(5, 7, 3), ivec3(4, 7, 5), ivec3(3, 7, 6),
    ivec3(4, 6, 7), ivec3(0, 0, 0), ivec3(0, 0, 0), ivec3(0, 0, 0)
);

vec3 apply_emphasis_max(vec3 color, int emphasis)
{
    if ((emphasis & 0x1) != 0) {
        color.r = 1.0;
    }
    if ((emphasis & 0x2) != 0) {
        color.g = 1.0;
    }
    if ((emphasis & 0x4) != 0) {
        color.b = 1.0;
    }
    return color;
}

layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 packed = texture(Source, vTexCoord).rgb;
    int color = clamp(int(floor((packed.r * 15.0) + 0.5)), 0, 15);
    int level = clamp(int(floor((packed.g * 3.0) + 0.5)), 0, 3);
    int emphasis = clamp(int(floor((packed.b * 7.0) + 0.5)), 0, 7);
    int palette_index = level * 16 + color;
    vec3 rgb = vec3(PALETTE_2C03[palette_index]) / 7.0;

    rgb = apply_emphasis_max(rgb, emphasis);
    FragColor = vec4(rgb, 1.0);
}
