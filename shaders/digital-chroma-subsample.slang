#version 450

// Filename: digital-chroma-subsample.slang
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
// Digital YCbCr Chroma Subsampling stage
// ------------------------------------
// Input: Full-resolution YCbCr video
// Output: YCbCr with optionally subsampled chroma (4:4:4, 4:2:2, or 4:2:0)
//
// Performs chroma subsampling by sampling luma from source RGB
// and applying nearest-neighbor chroma sampling.

#include "common.inc"
#include "color.inc"

#include "menus/parameters/digital-component.inc"

#pragma name DigitalChromaSubsample
#pragma format A2B10G10R10_UNORM_PACK32

#pragma parameter CHROMA_SUBSAMPLE_BYPASS "Bypass chroma subsampling" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OutputSize;

    float CHROMA_SUBSAMPLE_BYPASS;
    float YCBCR_MODEL;
    float CHROMA_SUBSAMPLE;
} config;

#define CHROMA_SUBSAMPLE_BYPASS config.CHROMA_SUBSAMPLE_BYPASS
#define YCBCR_MODEL config.YCBCR_MODEL
#define CHROMA_SUBSAMPLE config.CHROMA_SUBSAMPLE

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
layout(set = 0, binding = 3) uniform sampler2D SourceRGB;

void main()
{
    // Bypass check
    if (CHROMA_SUBSAMPLE_BYPASS >= 1.0) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Determine subsampling mode
    float mode = CHROMA_SUBSAMPLE;
    
    // Auto mode: choose based on color model
    if (mode < 0.5) {
        if (YCBCR_MODEL < 1.5) {
            mode = 1.0; // 4:2:2 for SMPTE/EBU
        } else {
            mode = 2.0; // 4:2:0 for Rec. 709
        }
    }

    // Sample full-resolution YCbCr
    vec3 yc_full = texture(Source, vTexCoord).rgb;
    float y = yc_full.r; // Y component passes through unchanged
    
    // If mode 4:4:4, no chroma subsampling needed
    if (mode < 1.5) {
        FragColor = vec4(yc_full, 1.0);
        return;
    }

    // For 4:2:2 or 4:2:0: subsample chroma (G, B components)
    vec2 output_pixel = vTexCoord * config.OutputSize.xy;
    
    // Determine chroma sampling region
    vec2 chroma_pixel = output_pixel;
    chroma_pixel.x = floor(output_pixel.x * 0.5) * 2.0 + 0.5; // Horizontal 2x subsampling
    
    if (mode > 1.5) {
        chroma_pixel.y = floor(output_pixel.y * 0.5) * 2.0 + 0.5; // Vertical 2x subsampling for 4:2:0
    }
    
    // Determine sampling neighborhood size
    int x_samples = 2;
    int y_samples = (mode > 1.5) ? 2 : 1;
    
    // Average chroma samples from neighborhood
    vec2 chroma = vec2(0.0);
    
    for (int dy = 0; dy < y_samples; dy++) {
        for (int dx = 0; dx < x_samples; dx++) {
            vec2 sample_offset = vec2(float(dx) - 0.5, float(dy) - 0.5);
            vec2 sample_coord = (chroma_pixel + sample_offset) * config.OutputSize.zw;
            chroma += texture(Source, sample_coord).gb;
        }
    }
    
    chroma /= float(x_samples * y_samples);
    
    FragColor = vec4(y, chroma.x, chroma.y, 1.0);
}
