#version 450

/* Filename: bezel.slang

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
   along with this program.  If not, see <https://www.gnu.org/licenses/>.
   
   ==== SHADER OVERVIEW === =
   
   This shader provides a bezel frame effect for CRT simulation:
   
   1. BEZEL FRAME: Curved rectangular frame that masks the image edges
   2. SLOPED EDGES: Gradient shading simulates inward-sloping bezel surface
   3. AMBIENT LIGHT: Blurred reflection/glow effect from screen content onto bezel
   
   The bezel covers approximately:
   - 3.33% at the midpoint of each edge (top, bottom, left, right)
   - 6.67% at each corner (diagonal coverage)
   
   ==== COORDINATE SYSTEM === =
   
   The bezel operates in normalized coordinates (-1 to 1) for symmetric
   shaping. The curved frame uses distance fields to create smooth,
   natural-looking edges with corner rounding.
   
*/ 

#include "common.h"

#pragma name Bezel
#pragma format R8G8B8A8_UNORM

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 OutputSize;
    vec4 OriginalSize;
    vec4 SourceSize;
    uint FrameCount;
} global;

layout(push_constant) uniform Push {
    float BEZEL_WIDTH_MID;
    float BEZEL_WIDTH_CORNER;
    float BEZEL_CURVE_STRENGTH;
    float BEZEL_EDGE_SOFTNESS;
    float BEZEL_COLOR_R;
    float BEZEL_COLOR_G;
    float BEZEL_COLOR_B;
    float BEZEL_SLOPE_GRADIENT;
    float BEZEL_AMBIENT_STRENGTH;
    float BEZEL_AMBIENT_SAMPLES;
    float BEZEL_AMBIENT_BLUR;
} config;

// ==== Shader Parameters === =

#pragma parameter BEZEL_HEADER " ==== Bezel Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BEZEL_WIDTH_MID "Bezel width at edges (%%)" 3.33 0.0 20.0 0.1
#define BEZEL_WIDTH_MID config.BEZEL_WIDTH_MID

#pragma parameter BEZEL_WIDTH_CORNER "Bezel width at corners (%%)" 6.67 0.0 20.0 0.1
#define BEZEL_WIDTH_CORNER config.BEZEL_WIDTH_CORNER

#pragma parameter BEZEL_CURVE_STRENGTH "Bezel curve strength" 0.5 0.0 2.0 0.05
#define BEZEL_CURVE_STRENGTH config.BEZEL_CURVE_STRENGTH

#pragma parameter BEZEL_EDGE_SOFTNESS "Bezel edge softness" 0.5 0.0 2.0 0.05
#define BEZEL_EDGE_SOFTNESS config.BEZEL_EDGE_SOFTNESS

#pragma parameter BEZEL_COLOR_R "Bezel color R" 0.1 0.0 1.0 0.01
#define BEZEL_COLOR_R config.BEZEL_COLOR_R

#pragma parameter BEZEL_COLOR_G "Bezel color G" 0.1 0.0 1.0 0.01
#define BEZEL_COLOR_G config.BEZEL_COLOR_G

#pragma parameter BEZEL_COLOR_B "Bezel color B" 0.1 0.0 1.0 0.01
#define BEZEL_COLOR_B config.BEZEL_COLOR_B

#pragma parameter BEZEL_SLOPE_GRADIENT "Bezel slope gradient strength" 0.6 0.0 2.0 0.05
#define BEZEL_SLOPE_GRADIENT config.BEZEL_SLOPE_GRADIENT

#pragma parameter BEZEL_AMBIENT_STRENGTH "Ambient light strength" 0.5 0.0 2.0 0.05
#define BEZEL_AMBIENT_STRENGTH config.BEZEL_AMBIENT_STRENGTH

#pragma parameter BEZEL_AMBIENT_SAMPLES "Ambient light samples" 12.0 4.0 32.0 1.0
#define BEZEL_AMBIENT_SAMPLES config.BEZEL_AMBIENT_SAMPLES

#pragma parameter BEZEL_AMBIENT_BLUR "Ambient light blur radius" 0.8 0.1 2.0 0.05
#define BEZEL_AMBIENT_BLUR config.BEZEL_AMBIENT_BLUR

// ==== Helper Functions === =

/**
 * Calculate distance to bezel edge with four trapezoid segments and mitered corners
 * Returns: smooth distance field and segment ID
 * @param uv Normalized coordinates (-1 to 1)
 * @return vec2(distance, segment_id) where segment_id: 0=top, 1=right, 2=bottom, 3=left
 */
vec2 bezelDistanceSegmented(vec2 uv)
{
    float mid_width = BEZEL_WIDTH_MID / 100.0;
    float corner_width = BEZEL_WIDTH_CORNER / 100.0;
    vec2 abs_uv = abs(uv);
    
    // Determine which segment we're in based on dominant axis and sign
    // Use 45-degree mitered corners
    float segment_id = 0.0;
    float dist = 0.0;
    
    // Calculate distances to each edge
    float dist_top = 1.0 - mid_width - uv.y;
    float dist_bottom = 1.0 - mid_width + uv.y;
    float dist_left = 1.0 - mid_width + uv.x;
    float dist_right = 1.0 - mid_width - uv.x;
    
    // Miter joints at 45 degrees: use abs(x) + abs(y) distance at corners
    // Determine which bezel segment this pixel belongs to
    bool in_corner_region = (abs_uv.x > (1.0 - corner_width)) && (abs_uv.y > (1.0 - corner_width));
    
    if (in_corner_region) {
        // In corner: use diagonal miter (45-degree cut)
        // The miter line is at abs(x) + abs(y) = constant
        float miter_dist = 1.0 - corner_width - (abs_uv.x + abs_uv.y) * 0.5;
        dist = miter_dist;
        
        // Assign segment based on which edge is closer
        if (abs_uv.x > abs_uv.y) {
            segment_id = (uv.x > 0.0) ? 1.0 : 3.0; // Right or Left
        } else {
            segment_id = (uv.y > 0.0) ? 0.0 : 2.0; // Top or Bottom
        }
    } else {
        // Not in corner: assign to closest edge
        float min_dist = min(min(dist_top, dist_bottom), min(dist_left, dist_right));
        dist = min_dist;
        
        if (min_dist == dist_top) {
            segment_id = 0.0; // Top
        } else if (min_dist == dist_right) {
            segment_id = 1.0; // Right
        } else if (min_dist == dist_bottom) {
            segment_id = 2.0; // Bottom
        } else {
            segment_id = 3.0; // Left
        }
    }
    
    float softness = BEZEL_EDGE_SOFTNESS * 0.01;
    float smoothed_dist = smoothstep(-softness, softness, dist);
    
    return vec2(smoothed_dist, segment_id);
}

/**
 * Calculate slope gradient for bezel shading per segment
 * Each trapezoid has lighting based on its surface orientation
 * @param bezel_mask Distance to bezel (0.0 = outer, 1.0 = viewport)
 * @param segment_id Which bezel segment (0=top, 1=right, 2=bottom, 3=left)
 * @param uv_normalized Normalized coordinates for position calculation
 * @return Gradient factor for shading
 */
float bezelSlopeGradient(float bezel_mask, float segment_id, vec2 uv_normalized)
{
    if (bezel_mask >= 0.999) return 1.0; // No gradient in visible area
    
    // Distance from outer edge (0.0 = outer edge, 1.0 = inner edge/viewport)
    float slope_position = bezel_mask;
    
    // Define light direction (from top-left)
    vec3 light_dir = normalize(vec3(-0.5, -0.5, -1.0));
    
    // Calculate surface normal based on segment
    // Each trapezoid slopes inward, so normal points outward and upward
    vec3 surface_normal;
    
    int seg = int(segment_id + 0.5);
    if (seg == 0) {
        // Top segment: normal points up and outward
        surface_normal = normalize(vec3(0.0, -1.0, 0.7));
    } else if (seg == 1) {
        // Right segment: normal points right and outward
        surface_normal = normalize(vec3(1.0, 0.0, 0.7));
    } else if (seg == 2) {
        // Bottom segment: normal points down and outward
        surface_normal = normalize(vec3(0.0, 1.0, 0.7));
    } else {
        // Left segment: normal points left and outward
        surface_normal = normalize(vec3(-1.0, 0.0, 0.7));
    }
    
    // Calculate directional lighting
    float directional = max(dot(surface_normal, -light_dir), 0.0);
    
    // Combine slope position with directional lighting
    // Outer edge is darker, inner edge is lighter
    float base_gradient = slope_position; // Linear gradient across slope
    float lighting = mix(0.3, 1.0, base_gradient); // Darker at outer edge
    lighting *= mix(0.6, 1.0, directional); // Modulate by directional lighting
    
    return clamp(lighting, 0.0, 1.0);
}

/**
 * Sample ambient light from screen content with blur
 * Combines reflection and glow into a single chaotic, diffuse effect
 * @param uv Current texture coordinate
 * @param edge_uv Coordinate at the edge
 * @param tex Source texture
 * @return Blurred ambient light color
 */
vec3 sampleAmbientLight(vec2 uv, vec2 edge_uv, sampler2D tex)
{
    if (BEZEL_AMBIENT_STRENGTH <= 0.0)
        return vec3(0.0);

    int samples = int(clamp(BEZEL_AMBIENT_SAMPLES, 4.0, 16.0));
    float blur_radius = BEZEL_AMBIENT_BLUR;
    vec3 ambient = vec3(0.0);
    float total_weight = 0.0;

    // Calculate direction from current position to edge
    vec2 to_edge = edge_uv - uv;
    vec2 edge_tangent = vec2(-to_edge.y, to_edge.x); // Perpendicular to edge direction

    // Sample in a large chaotic pattern around the edge area
    for (int i = 0; i < 16; i++) {
        if (i >= samples) break;
        for (int j = 0; j < 16; j++) {
            if (j >= samples) break;
            
            // Create grid coordinates centered at (0, 0)
            float tx = (float(i) / float(samples - 1)) - 0.5;
            float ty = (float(j) / float(samples - 1)) - 0.5;
            
            // Apply large blur radius for chaotic scattered sampling
            vec2 offset = (to_edge * tx + edge_tangent * ty) * blur_radius;
            vec2 sample_uv = edge_uv + offset;
            sample_uv = clamp(sample_uv, 0.0, 1.0);
            
            // Sample color and calculate brightness
            vec3 sample_col = texture(tex, sample_uv).rgb;
            float brightness = dot(sample_col, vec3(0.299, 0.587, 0.114));
            
            // Weight by distance (Gaussian-like falloff for blur)
            float dist = length(vec2(tx, ty));
            float weight = exp(-dist * dist * 3.0); // Gaussian blur kernel
            
            // Emphasize bright areas more (glow-like behavior)
            weight *= 1.0 + brightness * 0.5;
            
            ambient += sample_col * weight;
            total_weight += weight;
        }
    }
    
    return total_weight > 0.0 ? ambient / total_weight : vec3(0.0);
}

// ==== Vertex Shader === =

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

// ==== Fragment Shader === =

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Convert to normalized coordinates for bezel calculation
    vec2 uv_normalized = vTexCoord * 2.0 - 1.0;

    // Calculate distance to bezel and segment ID
    vec2 bezel_data = bezelDistanceSegmented(uv_normalized);
    float bezel_mask = bezel_data.x;
    float segment_id = bezel_data.y;

    // Sample the source image
    vec3 image_color = texture(Source, vTexCoord).rgb;

    // If fully in visible area, just return the image
    if (bezel_mask >= 0.999) {
        FragColor = vec4(image_color, 1.0);
        return;
    }

    // Base bezel color
    vec3 bezel_color = vec3(BEZEL_COLOR_R, BEZEL_COLOR_G, BEZEL_COLOR_B);

    // Apply slope gradient based on segment orientation
    float slope_gradient = bezelSlopeGradient(bezel_mask, segment_id, uv_normalized);
    vec3 shaded_bezel = bezel_color * mix(1.0, slope_gradient, BEZEL_SLOPE_GRADIENT);

    // Calculate edge UV for ambient light sampling
    vec2 edge_uv = vTexCoord;
    vec2 centered = vTexCoord - 0.5;
    vec2 abs_centered = abs(centered);
    if (abs_centered.x / abs_centered.y > (global.OutputSize.x / global.OutputSize.y)) {
        float edge_x = centered.x > 0.0 ? (1.0 - BEZEL_WIDTH_MID / 100.0) : (BEZEL_WIDTH_MID / 100.0);
        edge_uv.x = edge_x;
    } else {
        float edge_y = centered.y > 0.0 ? (1.0 - BEZEL_WIDTH_MID / 100.0) : (BEZEL_WIDTH_MID / 100.0);
        edge_uv.y = edge_y;
    }

    // Sample ambient light (combined reflection/glow with blur)
    vec3 ambient = sampleAmbientLight(vTexCoord, edge_uv, Source);

    // Add ambient light to bezel with proper strength
    float effect_strength = pow(1.0 - bezel_mask, 0.5);
    shaded_bezel += ambient * BEZEL_AMBIENT_STRENGTH * effect_strength;

    // Blend bezel and image based on mask
    vec3 final_color = mix(shaded_bezel, image_color, bezel_mask);

    FragColor = vec4(final_color, 1.0);
}
