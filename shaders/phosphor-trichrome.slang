#version 450

// Filename: phosphor-trichrome.slang
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
// Trichrome phosphor simulation
// ------------------------------------------------
// Input: Linear YrYgYb signal
// Output: Linear YrYgYb signal

#pragma name Phosphor3
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"

#include "menus/parameters/phosphor.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_PHOSPHOR_TRICHROME_HEADER " —— Debug Phosphor Trichrome —— " 0.0 0.0 0.0 0.0
#pragma parameter PHOSPHOR_BYPASS "Phosphor trichrome bypass" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    float OriginalFPS;
    uint TotalSubFrames;
    float PHOSPHOR_DECAY_10_R;
    float PHOSPHOR_DECAY_10_G;
    float PHOSPHOR_DECAY_10_B;

    float PHOSPHOR_DECAY_0P1_R;
    float PHOSPHOR_DECAY_0P1_G;
    float PHOSPHOR_DECAY_0P1_B;

#ifdef OPTION_DEBUG
    float PHOSPHOR_BYPASS;
#endif  // OPTION_DEBUG

} config;

#ifdef OPTION_DEBUG
#define PHOSPHOR_BYPASS config.PHOSPHOR_BYPASS
#endif  // OPTION_DEBUG

// Subframe support
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define PHOSPHOR_DECAY_10_R config.PHOSPHOR_DECAY_10_R
#define PHOSPHOR_DECAY_10_G config.PHOSPHOR_DECAY_10_G
#define PHOSPHOR_DECAY_10_B config.PHOSPHOR_DECAY_10_B

#define PHOSPHOR_DECAY_0P1_R config.PHOSPHOR_DECAY_0P1_R
#define PHOSPHOR_DECAY_0P1_G config.PHOSPHOR_DECAY_0P1_G
#define PHOSPHOR_DECAY_0P1_B config.PHOSPHOR_DECAY_0P1_B

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec3 vn;
layout(location = 2) out vec3 vtau;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    vec3 t10 = 0.001 * vec3(
        PHOSPHOR_DECAY_10_R,
        PHOSPHOR_DECAY_10_G,
        PHOSPHOR_DECAY_10_B);
    vec3 t0p1 = vec3(
        PHOSPHOR_DECAY_0P1_R,
        PHOSPHOR_DECAY_0P1_G,
        PHOSPHOR_DECAY_0P1_B);

    // Ensure that t10 is greater than zero
    t10 = max(t10, vec3(EPS));

    // Ensure t0p1 is bounded
    t0p1 = max(t0p1, vec3(0.01));

    // R and a from the system of equations for phosphor decay
    // from 10% and 0.1% decay time constants
    vec3 R = t0p1 / t10;
    vec3 a = (-1.0 + sqrt(4.0 * R - 3.0)) / 2.0;
    vn = log(10.0) / log(a);
    vtau = t10 / (pow(vec3(10.0), 1.0 / vn) - 1.0);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec3 vn;
layout(location = 2) in vec3 vtau;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;
layout(set = 0, binding = 2) uniform sampler2D Phosphor3Feedback;

void main()
{
    vec2 Tex = vTexCoord;

    vec4 src = texture(Source, Tex);
    vec3 color = src.rgb;
    float alpha = src.a;

    // Early exit for full bypass

#ifdef OPTION_NOPHOSPHOR
    FragColor = vec4(color, alpha);
    return;
#endif  // OPTION_NOPHOSPHOR

#ifdef OPTION_DEBUG
    if (PHOSPHOR_BYPASS >= 1.0) {
        FragColor = vec4(color, alpha);
        return;
    }
#endif  // OPTION_DEBUG

    // Use per-subframe time step for smoother decay
    float fps = max(config.OriginalFPS, 1.0);
    float subframes = max(float(TOTAL_SUBFRAMES), 1.0);
    vec3 tau_frame = vtau * fps * subframes;

    vec3 color1 = texture(Phosphor3Feedback, Tex).rgb;
    vec3 decay = pow(1.0 + 1.0 / tau_frame * pow(color1 / TARGET_NITS, 1.0 / vn), vn);

    // Make decay safe
    vec3 persistence = min(color1 / max(decay, vec3(EPS)), color1 * (1.0 - EPS));

    color = persistence + color;

    FragColor = vec4(color, alpha);
}
