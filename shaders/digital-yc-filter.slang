#version 450

// Filename: digital-yc-filter.slang
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
// Digital YC bandpass filter: filters modulated chroma (C channel)
// -----------------------------------------------------------------
// Input: YC (Y in R, modulated C in G)
// Output: YC (Y in R, filtered modulated C in G)
//
// Applies a Gaussian-based bandpass filter to the modulated chroma
// signal. Bandwidth is controlled by a decimation factor - higher
// decimation values reduce bandwidth. The filter operates in the
// horizontal direction on the modulated subcarrier signal.

#include "common.inc"

#include "menus/parameters/digital-component.inc"

#pragma name DigitalYCFilter
#pragma format A2B10G10R10_UNORM_PACK32

#pragma parameter DIGITAL_YC_FILTER_BYPASS "Bypass digital YC filter" 0.0 0.0 1.0 1.0

#define DIGITAL_YC_FILTER_SIGMA 0.22

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OutputSize;
    float DIGITAL_YC_FILTER_BYPASS;
    float DIGITAL_YC_FILTER_DECIMATION;
} config;

#define DIGITAL_YC_FILTER_BYPASS config.DIGITAL_YC_FILTER_BYPASS
#define DIGITAL_YC_FILTER_DECIMATION config.DIGITAL_YC_FILTER_DECIMATION

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float filter_sigma;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    
    // Compute filter parameters based on decimation factor
    // Sigma is relative to the decimation factor
    filter_sigma = DIGITAL_YC_FILTER_DECIMATION * DIGITAL_YC_FILTER_SIGMA;
}

#pragma stage fragment

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float filter_sigma;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Gaussian weight function
float gaussian_weight(float x, float sigma)
{
    float sigma_sq = sigma * sigma;
    return exp(-0.5 * x * x / sigma_sq);
}

void main()
{
    if (DIGITAL_YC_FILTER_BYPASS > 0.5) {
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Sample center pixel
    vec4 center = texture(Source, vTexCoord);
    float luma = center.r;
    
    // Pixel offset in texture coordinates
    float dx = 1.0 / config.SourceSize.x;
    
    // Apply horizontal Gaussian filter to modulated chroma
    // Start with center pixel (n=0)
    float chroma_center = center.g;
    float w0 = gaussian_weight(0.0, filter_sigma);
    float chroma_filtered = w0 * chroma_center;
    float weight_sum = w0;
    
    // Maximum filter radius (for decimation=16: sigma=3.52, 3.4*sigma ≈ 12)
    const int MAX_RADIUS = 16;
    
    // Process symmetric lobes
    for (int n = 1; n <= MAX_RADIUS; ++n)
    {
        float nf = float(n);
        
        // Compute weights for both lobes
        float weight = gaussian_weight(nf, filter_sigma);
        
        // Early exit when contribution drops below threshold
        if (weight < FILTER_THRESHOLD)
            break;
        
        // Sample both sides
        float chroma_right = texture(Source, vTexCoord + vec2(nf * dx, 0.0)).g;
        float chroma_left = texture(Source, vTexCoord - vec2(nf * dx, 0.0)).g;
        
        chroma_filtered += weight * (chroma_right + chroma_left);
        weight_sum += 2.0 * weight;
    }
    
    // Normalize by total weight
    chroma_filtered /= weight_sum;
    
    // Output: Y unchanged, filtered C in G channel
    FragColor = vec4(luma, chroma_filtered, 0.0, 1.0);
}
