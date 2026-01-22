#version 450

// Filename: digital-upsample.slang
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
// Digital colorbCr Upsampling stage
// ----------------------------
// Input: colorbCr video
// Output: Upsampled colorbCr video
//
// Performs upsampling with Kaiser-windowed sinc interpolation.
// Provides ~62 dB stopband rejection with ≤0.5 dB passband ripple.
// Uses zero-insertion approach optimized for integer scale factors.
// Tap count automatically determined based on scale factors.

#include "common.inc"
#include "window.inc"

#pragma name DigitalUpsample
#pragma format A2B10G10R10_UNORM_PACK32

#pragma parameter UPSAMPLE_BYPASS "Bypass upsampling stage" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OutputSize;

    float UPSAMPLE_BYPASS;
    float UPSAMPLER_INPUT;
    float GAMMA_CORRECT_BLENDING;
} config;

#define UPSAMPLE_BYPASS config.UPSAMPLE_BYPASS
#define KAISER_BETA 5.87  // Default value for ~62 dB stopband attenuation
#define TRANSITION_WIDTH 0.15  // Default transition width factor, max 0.5 dB passband ripple
#define UPSAMPLER_INPUT config.UPSAMPLER_INPUT
#define GAMMA_CORRECT_BLENDING config.GAMMA_CORRECT_BLENDING

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 scale;
layout(location = 2) out vec2 fc_norm;
layout(location = 3) out vec2 taps;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    
    // Compute scale factors
    scale = config.OutputSize.xy / config.SourceSize.xy;
    
    // Normalized cutoff frequencies: 1/scale for bandwidth preservation
    fc_norm = 1.0 / scale;
    
    // Improved Kaiser tap count formula incorporating scale factor
    // Derived from: N = (A_s - 13) / (14.6 * (Δf / f_s))
    // where transition band Δf/f_s = TRANSITION_WIDTH / scale
    // Therefore: N = (A_s - 13) * scale / (14.6 * TRANSITION_WIDTH)
    // This ensures tap count scales linearly with upsampling ratio for consistent quality
    float A_s = 8.0 + 2.285 * KAISER_BETA;  // Stopband attenuation (dB)
    const float KAISER_DESIGN_CONST = 14.6;  // Standard Kaiser design constant
    
    vec2 taps_calc = (A_s - 13.0) * scale / (KAISER_DESIGN_CONST * TRANSITION_WIDTH);
    
    // Round to odd numbers for symmetric filtering
    taps.x = ceil(taps_calc.x);
    if (mod(taps.x, 2.0) == 0.0) taps.x += 1.0;
    taps.y = ceil(taps_calc.y);
    if (mod(taps.y, 2.0) == 0.0) taps.y += 1.0;
    
    // Clamp to reasonable range
    taps = clamp(taps, vec2(5.0), vec2(65.0));
}

#pragma stage fragment

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 scale;
layout(location = 2) in vec2 fc_norm;
layout(location = 3) in vec2 taps;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Helper functions for gamma correction
vec3 to_linear(vec3 c) {
    if (GAMMA_CORRECT_BLENDING < 0.5) {
        return c; // No gamma correction
    } else if (GAMMA_CORRECT_BLENDING < 1.5) {
        return c * c; // Fast: square
    } else {
        return sdr_linear(c); // Accurate
    }
}

vec3 to_gamma(vec3 c) {
    if (GAMMA_CORRECT_BLENDING < 0.5) {
        return c; // No gamma correction
    } else if (GAMMA_CORRECT_BLENDING < 1.5) {
        return sqrt(c); // Fast: sqrt
    } else {
        return sdr_gamma(c); // Accurate
    }
}

void main()
{
    // Bypass check
    if (UPSAMPLE_BYPASS >= 1.0) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
    
    // Check if upsampling is needed
    if (scale.x < 1.001 && scale.y < 1.001) {
        // No upsampling needed: direct pass-through
        FragColor = texture(Source, vTexCoord);
        return;
    }

    // Determine which pixel in the upsampled grid we're at
    vec2 output_pixel = vTexCoord * config.OutputSize.xy;
    vec2 source_pixel = output_pixel / scale;
    
    // Find the source pixel center (zero-insertion point)
    vec2 src_center = floor(source_pixel) + 0.5;
    
    // Fractional offset from the center (in source pixel coordinates)
    vec2 frac = source_pixel - src_center;
    
    // Apply separable 2D Kaiser-windowed sinc filtering
    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    
    int max_tap_half_x = int(floor(taps.x * 0.5));
    int max_tap_half_y = int(floor(taps.y * 0.5));
    
    // Separable filtering: compute weights and accumulate
    for (int dy = -max_tap_half_y; dy <= max_tap_half_y; dy++) {
        float fy = float(dy) - frac.y;
        float weight_y = sinc_lowpass_kaiser(fy, fc_norm.y, taps.y, KAISER_BETA);
        
        for (int dx = -max_tap_half_x; dx <= max_tap_half_x; dx++) {
            float fx = float(dx) - frac.x;
            float weight_x = sinc_lowpass_kaiser(fx, fc_norm.x, taps.x, KAISER_BETA);
            
            // 2D weight as product of separable 1D weights
            float weight = weight_x * weight_y;
            
            // Skip negligible contributions for performance
            if (abs(weight) < FILTER_THRESHOLD)
                continue;
            
            vec2 sample_pos = src_center + vec2(float(dx), float(dy));
            vec2 sample_coord = sample_pos * config.SourceSize.zw;
            
            // Clamp to valid texture coordinates
            sample_coord = clamp(sample_coord, vec2(0.0), vec2(1.0));
            
            vec3 color = texture(Source, sample_coord).rgb;

            // For RGB input, apply gamma correction if needed
            if (UPSAMPLER_INPUT < 0.5) {
                color = to_linear(color);
            }

            sum += color * weight;
            weight_sum += weight;
        }
    }
    
    // Normalize to preserve gain
    vec3 result = sum / max(weight_sum, EPS);

    // For RGB input, apply gamma correction if needed
    if (UPSAMPLER_INPUT < 0.5) {
        result = to_gamma(result);
    }
    
    FragColor = vec4(result, 1.0);
}