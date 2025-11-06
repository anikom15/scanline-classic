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
#include "bandlimit.inc"

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
    float DISPLAY_COMPONENT_FILTER_BYPASS;
    float DISPLAY_BANDWIDTH_Y;
    float DISPLAY_BANDWIDTH_U;
    float DISPLAY_BANDWIDTH_V;
    float DISPLAY_CUTOFF_ATTEN_Y;
    float DISPLAY_CUTOFF_ATTEN_U;
    float DISPLAY_CUTOFF_ATTEN_V;
} config;


#pragma parameter DISPLAY_COMPONENT_HEADER " ==== Display Component Parameters ==== " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPONENT_BYPASS "Display component bypass" 0.0 0.0 1.0 1.0
#define DISPLAY_COMPONENT_BYPASS config.DISPLAY_COMPONENT_BYPASS
#pragma parameter YC_MODEL "YC color model (0=YIQ,1=YPbPr,2=YUV,3=YDbDr,4=YCbCr)" 1.0 0.0 4.0 1.0
#define YC_MODEL config.YC_MODEL
#pragma parameter DISPLAY_COMPONENT_FILTER_BYPASS "Display component filter bypass" 0.0 0.0 1.0 1.0
#define DISPLAY_COMPONENT_FILTER_BYPASS config.DISPLAY_COMPONENT_FILTER_BYPASS
#pragma parameter DISPLAY_BANDWIDTH_Y "Display Luma (Y) bandwidth (MHz)" 6.75 0.0 75.0 0.01
#pragma parameter DISPLAY_BANDWIDTH_U "Display Chroma (U) bandwidth (MHz)" 1.30 0.0 15.0 0.01
#pragma parameter DISPLAY_BANDWIDTH_V "Display Chroma (V) bandwidth (MHz)" 1.30 0.0 15.0 0.01
#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display Y cutoff attenuation (dB)" 3.0 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_U "Display U cutoff attenuation (dB)" 2.0 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_V "Display V cutoff attenuation (dB)" 2.0 0.0 30.0 1.0

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


// Helper: decode from selected luma-chroma model to RGB
vec3 decode_luma_chroma_to_rgb(vec3 yc, float model) {
    if (model < 0.5) {
        return YIQ_TO_RGB * yc;
    } else if (model < 1.5) {
        return YPbPr_TO_RGB * yc;
    } else if (model < 2.5) {
        return YUV_TO_RGB * yc;
    } else if (model < 3.5) {
        // YDbDr -> YUV -> RGB
        const float U_FROM_DB = 0.436 / 1.333;
        const float V_FROM_DR = -0.615 / 1.333;
        vec3 yuv = vec3(yc.r, yc.g * U_FROM_DB, yc.b * V_FROM_DR);
        return YUV_TO_RGB * yuv;
    } else {
        return YCbCr_TO_RGB * yc;
    }
}

void main()
{
    if (DISPLAY_COMPONENT_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Filter bypass: decode center sample without Gaussian lobes
    if (DISPLAY_COMPONENT_FILTER_BYPASS > 0.5) {
        vec3 yc = texture(Source, vTexCoord).rgb;
        vec3 rgb = decode_luma_chroma_to_rgb(yc, YC_MODEL);
        FragColor = vec4(rgb, 1.0);
        return;
    }

    // Precompute per-component sigmas (in texels) from MHz/dB specs.
    vec3 sigma = sigma601(
        vec3(config.DISPLAY_BANDWIDTH_Y, config.DISPLAY_BANDWIDTH_U, config.DISPLAY_BANDWIDTH_V),
        vec3(config.DISPLAY_CUTOFF_ATTEN_Y, config.DISPLAY_CUTOFF_ATTEN_U, config.DISPLAY_CUTOFF_ATTEN_V),
        config.OutputSize.x);

    const float THRESHOLD = 1.0 / 510.0;

    vec2 UV  = vTexCoord * config.OutputSize.xy;
    vec2 A   = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * config.OutputSize.zw;
    vec2 dx  = vec2(config.OutputSize.z, 0.0);

    // Accumulators and weights for Y, U/Db, V/Dr
    vec3 accum = vec3(0.0);
    vec3 wsum  = vec3(0.0);

    // Center sample
    vec3 yc_c = texture(Source, Tex).rgb;
    float wy = gaussian(A.x, sigma.x);
    float wu = gaussian(A.x, sigma.y);
    float wv = gaussian(A.x, sigma.z);
    accum += vec3(wy * yc_c.x, wu * yc_c.y, wv * yc_c.z);
    wsum  += vec3(wy, wu, wv);

    // Symmetric lobes
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n) + A.x;
        float wy_n = gaussian(nf, sigma.x);
        float wu_n = gaussian(nf, sigma.y);
        float wv_n = gaussian(nf, sigma.z);
        if (wy_n < THRESHOLD && wu_n < THRESHOLD && wv_n < THRESHOLD)
            break;
        vec3 yc_r = texture(Source, Tex + float(n) * dx).rgb;
        vec3 yc_l = texture(Source, Tex - float(n) * dx).rgb;
        accum.x += wy_n * (yc_r.x + yc_l.x);
        accum.y += wu_n * (yc_r.y + yc_l.y);
        accum.z += wv_n * (yc_r.z + yc_l.z);
        wsum.x  += 2.0 * wy_n;
        wsum.y  += 2.0 * wu_n;
        wsum.z  += 2.0 * wv_n;
    }

    // Normalize
    vec3 outyc = accum / max(wsum, vec3(EPS));
    vec3 pixel = decode_luma_chroma_to_rgb(outyc, YC_MODEL);
    FragColor = vec4(pixel, 1.0);
}