#version 450

/* Filename: scanline-advanced.slang

   Copyright (C) 2010 Team XBMC
   Copyright (C) 2011 Stefanos A.
   Copyright (C) 2023-2025 W. M. Martinez

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
   
   ==== SHADER OVERVIEW ====
   
   This shader provides comprehensive CRT simulation with physically accurate
   geometry distortion and correction. It models the complete signal chain:
   
   1. BLANKING INTERVALS: Simulates horizontal/vertical blanking with configurable porches
   2. CRT GEOMETRY DISTORTION: 
      - Pincushion distortion from electron beam deflection (90-120° deflection angles)
      - Magnetic correction simulating physical correction magnets
      - Barrel distortion from curved screen surface
   3. ELECTRONIC CORRECTIONS: Trapezoid, corner, and S-correction for geometric refinement
   4. BICUBIC FILTERING: Mitchell-Netravali 4x4 kernel for high-quality resampling
   5. SCANLINES & MASKS: Physically based scanline rendering with subpixel masks
   
   ==== COORDINATE SPACE PIPELINE ====
   
   The shader operates through multiple coordinate spaces:
   - Texture space (0-1): Input and output texture coordinates
   - Normalized space (-1 to 1): For geometry distortions
   - Square space: Aspect-normalized coordinates for equal X/Y distortion
   
   Distortions are applied in square space to ensure equal behavior on both axes,
   then transformed back to account for aspect ratio. This prevents diagonal artifacts
   and maintains geometric accuracy.
   
   ==== OPTIMIZATION NOTES ====
   
   - Bypass functionality with early exit for performance testing
   - Bicubic filter unrolled to 16 explicit taps (4x4 kernel) for clarity
   - All distortions consolidated to single normalized space transform
   - ZOOM integrated into distortion scale for viewport-only zoom
   - Electronic corrections called directly for efficiency
   
   ==== PHYSICAL ACCURACY ====
   
   - Deflection angles mapped to realistic 0-120° range (safety margin below tan singularity)
   - Magnetic correction models physical magnet placement and field strength
   - Pincushion and barrel are mathematical inverses via tan/atan transforms
   - Correction pipeline mimics real CRT correction circuit ordering
   
   ==== PINCUSHION DISTORTION NOTES ====
   
   - Angles <4°: No distortion applied (numerical precision issues near center axes)
   - Angles 4-30°: Linear (electrostatic) pincushion only (stable at low deflection)
   - Angles >30°: Full distortion type selection (electrostatic or magnetic/non-linear)
   
   The linear pincushion function is more numerically stable at low deflection angles,
   while the non-linear (magnetic) variant better models real CRT behavior at higher
   deflection angles (70-120°) where magnetic deflection yokes dominate.
   
*/ 

#include "common.h"
#include "color.h"
#include "filter.h"
#include "geometry.h"
#include "subpixel_masks.h"

#pragma name ScanlineAdvanced
#pragma format A2B10G10R10_UNORM_PACK32

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 OutputSize;
    vec4 OriginalSize;
    vec4 SourceSize;
    uint FrameCount;
} global;

layout(push_constant) uniform Push {
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float COLOR_MODE;
    float SCAN_TYPE;
    float MAX_SCAN_RATE;
    float LINE_DOUBLER;
    float FOCUS;
    float MASK_TYPE;
    float PIN_DISTORTION_TYPE;
    float DEFLECTION_ANGLE;
    float MAGNETIC_CORRECTION;
    float SCREEN_ANGLE_H;
    float SCREEN_ANGLE_V;
    float TRAPEZOID_STRENGTH;
    float CORNER_STRENGTH;
    float S_CORRECTION_H;
    float S_CORRECTION_V;
    float UNDERSCAN;
    float ZOOM;
    float SCANLINE_ADVANCED_BYPASS;
    float MASK_SCALE;
} config;

// ==== Shader Parameters ====

#pragma parameter SCANLINE_ADVANCED_HEADER " ==== Scanline Advanced Parameters ==== " 0.0 0.0 0.0 0.0
#pragma parameter SCANLINE_ADVANCED_BYPASS "Scanline advanced bypass" 0.0 0.0 1.0 1.0
#define SCANLINE_ADVANCED_BYPASS config.SCANLINE_ADVANCED_BYPASS

// ==== Quick Start Guide ====
//
// FOR BASIC CRT LOOK:
// 1. Set DEFLECTION_ANGLE to 90-110° (pincushion distortion)
// 2. Set MAGNETIC_CORRECTION to 0.0-0.5 (optional: simulates correction magnets)
// 3. Set SCREEN_ANGLE_H and Y to 50-70° (barrel curvature)
// 4. Leave all electronic corrections at 0.0 for pure CRT distortion
//
// FOR CORRECTED CRT LOOK (like a well-calibrated monitor):
// 1. Set up pincushion and barrel as above
// 2. Set MAGNETIC_CORRECTION to 0.3-0.6 (realistic correction magnet strength)
// 3. Adjust TRAPEZOID_STRENGTH (0.05-0.15) for edge correction
// 4. Adjust CORNER_STRENGTH (0.1-0.3) to square up corners
// 5. Fine-tune S_CORRECTION_H and S_CORRECTION_V (-0.1 to 0.1)
//
// UNDERSTANDING THE CORRECTION PIPELINE:
// - DEFLECTION_ANGLE creates pincushion (electron beam deflection)
// - MAGNETIC_CORRECTION applies magnetic field correction (0=none, 1=full inverse)
// - SCREEN_ANGLE creates barrel distortion (curved screen surface)
// - Electronic corrections (trapezoid, S-correction, corner) provide final tweaks
//
// FOR DEBUGGING:
// - Use SCANLINE_ADVANCED_BYPASS to compare processed vs. unprocessed
// - Set MAGNETIC_CORRECTION to 0.0 to see pure pincushion+barrel
// - Set all corrections to 0.0 to see pure pincushion+barrel effect
// - Adjust one parameter at a time to understand each effect
//
// ==== End Quick Start ====


#pragma parameter V_FREQ "Vertical Frequency (Hz)" 59.94 1.0 240.0 0.01
#define V_FREQ config.V_FREQ
#pragma parameter V_LINES_PER_FIELD "Video Lines per Field" 262.5 0.0 540.0 0.5
#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal Blank Inactive Length" 138.0 0.0 1000.0 0.1
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal Blank Inactive Unit (0=px, 1=µs, 2=%% active)" 0.0 0.0 2.0 1.0

// Display mode parameters
#pragma parameter COLOR_MODE "Chromaticity mode" 3.0 1.0 3.0 1.0
#pragma parameter SCAN_TYPE "Scan type" 1.0 1.0 2.0 1.0
#pragma parameter MAX_SCAN_RATE "Maximum active lines" 480.0 1.0 1200.0 1.0
#pragma parameter LINE_DOUBLER "Enable line-doubler" 0.0 0.0 1.0 1.0
#pragma parameter FOCUS "Focus (%)" 0.25 0.0 1.0 0.01

// Subpixel mask parameter
#pragma parameter MASK_TYPE "Subpixel layout" 1.0 1.0 25.0 1.0

// CRT geometry distortion parameters
#pragma parameter PIN_DISTORTION_TYPE "Pincushion type (1=electrostatic [linear], 2=magnetic)" 2.0 1.0 2.0 1.0
#pragma parameter DEFLECTION_ANGLE "CRT deflection angle (°; 0-30°=linear only)" 110.0 0.0 120.0 1.0
#pragma parameter MAGNETIC_CORRECTION "Magnetic correction strength (0=off, 1=full)" 0.5 0.0 1.0 0.05
#pragma parameter SCREEN_ANGLE_H "CRT H. curvature angle (°)" 40.0 0.0 90.0 1.0
#pragma parameter SCREEN_ANGLE_V "CRT V. curvature angle (°)" 40.0 0.0 90.0 1.0

// == Electronic Geometry Correction Parameters == //
// Simulates the digital geometry processors found in high-end CRT monitors
// These corrections compensate for various geometric distortions:
// - Trapezoid: Corrects for dynamic scan width (top/bottom narrower than middle)
//   Typical range: -0.2 to 0.2 (negative = narrower top, positive = wider top)
// - Corner: Fourth-order correction for corner squaring
//   Typical range: 0.0 to 0.3 (0 = no correction, higher = more square corners)
// - S-correction: Parabolic axis-independent correction for S-shaped distortion
//   Typical range: -0.2 to 0.2 per axis (horizontal and vertical independent)
//
// NOTE: Set all to 0.0 to disable electronic corrections (pure CRT distortion)
#pragma parameter TRAPEZOID_STRENGTH "Trapezoid correction strength" 0.0 -1.0 1.0 0.01
#pragma parameter CORNER_STRENGTH "Corner correction strength" 0.0 0.0 1.0 0.01
#pragma parameter S_CORRECTION_H "S-correction horizontal strength" 0.0 -1.0 1.0 0.01
#pragma parameter S_CORRECTION_V "S-correction vertical strength" 0.0 -1.0 1.0 0.01

#pragma parameter UNDERSCAN "Underscan (%)" 0.0 0.0 100.0 1.0
#pragma parameter ZOOM "Viewport zoom" 1.0 0.0 10.0 0.001

#pragma parameter MASK_SCALE "Subpixel mask scale" 1.0 0.1 4.0 0.1

#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define COLOR_MODE config.COLOR_MODE
#define SCAN_TYPE config.SCAN_TYPE
#define MAX_SCAN_RATE config.MAX_SCAN_RATE
#define LINE_DOUBLER config.LINE_DOUBLER
#define FOCUS config.FOCUS
#define MASK_TYPE config.MASK_TYPE
#define PIN_DISTORTION_TYPE config.PIN_DISTORTION_TYPE
#define DEFLECTION_ANGLE config.DEFLECTION_ANGLE
#define MAGNETIC_CORRECTION config.MAGNETIC_CORRECTION
#define SCREEN_ANGLE_H config.SCREEN_ANGLE_H
#define SCREEN_ANGLE_V config.SCREEN_ANGLE_V
#define TRAPEZOID_STRENGTH config.TRAPEZOID_STRENGTH
#define CORNER_STRENGTH config.CORNER_STRENGTH
#define S_CORRECTION_H config.S_CORRECTION_H
#define S_CORRECTION_V config.S_CORRECTION_V
#define UNDERSCAN config.UNDERSCAN
#define ZOOM config.ZOOM
#define MASK_SCALE config.MASK_SCALE

// ==== Helper Functions ====

/**
 * Apply subpixel mask weights based on screen position
 * @param uv Screen-space coordinates (in output pixels)
 * @return RGB mask weights (0.0-1.0 per channel)
 */
vec3 mask(vec2 uv)
{
    // Scale down the coordinates to make the mask pattern larger
    // MASK_SCALE = 1.0: native output pixel resolution (very fine)
    // MASK_SCALE = 2.0: 2x larger mask pattern (half the frequency)
    // MASK_SCALE = 3.0: 3x larger mask pattern (1/3 the frequency)
    return mask_weights(uv / MASK_SCALE, 1.0, int(MASK_TYPE - 1.0));
}

/**
 * Apply subpixel mask with anisotropic filtering to reduce aliasing
 * Uses box filtering based on the local anisotropy of the coordinate transform
 * @param uv Screen-space coordinates
 * @param ddx_uv Partial derivative in X direction (horizontal screen-space gradient)
 * @param ddy_uv Partial derivative in Y direction (vertical screen-space gradient)
 * @return RGB mask weights (0.0-1.0 per channel) with filtering applied
 */
vec3 mask_anisotropic(vec2 uv, vec2 ddx_uv, vec2 ddy_uv)
{
    // Calculate anisotropic stretching factors
    // These tell us how much the mask is stretched per output pixel
    float dx = length(ddx_uv);
    float dy = length(ddy_uv);
    
    // Determine filter kernel size based on maximum stretching
    // If stretching > 1 pixel, we need to filter multiple mask samples
    float max_aniso = max(dx, dy);
    
    // Use point sampling if anisotropy is small (< 1.5 pixels)
    if (max_aniso < 1.5)
        return mask(uv);
    
    // Calculate number of samples needed (clamped to reasonable range)
    // We use sqrt to reduce sample count while maintaining quality
    int samples = int(clamp(ceil(sqrt(max_aniso)), 2.0, 16.0));
    
    // Determine dominant stretch direction
    vec2 filter_dir;
    float filter_extent;
    
    if (dx > dy) {
        // Horizontal stretching dominates
        filter_dir = ddx_uv / dx;  // Normalize to unit vector
        filter_extent = dx;
    } else {
        // Vertical stretching dominates
        filter_dir = ddy_uv / dy;
        filter_extent = dy;
    }
    
    // Apply box filter along dominant direction
    vec3 filtered = vec3(0.0);
    float step_size = filter_extent / float(samples);
    vec2 step_vec = filter_dir * step_size;
    
    // Start offset to center the filter kernel
    vec2 start_offset = -filter_dir * filter_extent * 0.5;
    
    for (int i = 0; i < samples; i++) {
        vec2 sample_pos = uv + start_offset + step_vec * (float(i) + 0.5);
        filtered += mask(sample_pos);
    }
    
    return filtered / float(samples);
}

/**
 * Sample a pixel with scanline effects applied
 * Handles interlacing, line-doubling, and scanline gaps
 * @param x Horizontal texture coordinate (0.0-1.0)
 * @param y Vertical texture coordinate (0.0-1.0)
 * @param tex Source texture sampler
 * @return RGB color with scanline effects applied
 */
vec3 pixel(float x, float y, sampler2D tex)
{
    // Determine effective vertical resolution based on scan type and line doubling
    float yThres = (SCAN_TYPE < 2.0 && global.OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0)
        ? global.OriginalSize.y / 2.0  // Interlaced mode
        : global.OriginalSize.y;        // Progressive mode
    float scanw;
    int line;

    // Apply line-doubler if enabled and source resolution is low enough
    if (LINE_DOUBLER > 0.0 && global.OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
        yThres *= 2.0;
    
    // Calculate scanline width (gap between lines)
    scanw = max(0.0, 2.0 * (yThres / MAX_SCAN_RATE - 0.5));
    
    // Determine which scanline we're on
    if (SCAN_TYPE < 2.0 && global.OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0) {
        // Interlaced: alternate fields based on frame count
        uint t = global.FrameCount % 2u;
        line = int(2.0 * yThres * y + float(t));
    } else {
        // Progressive: fixed scanline pattern
        line = int(2.0 * yThres * y);
    }

    // Return black for out-of-bounds coordinates
    if (any(lessThan(vec2(x, y), vec2(0.0, 0.0))) ||
        any(greaterThan(vec2(x, y), vec2(1.0, 1.0))))
        return BLACK;
    else {
        // Odd scanlines: darken or make black depending on scanline width
        if (line % 2 > 0)
            return mix(BLACK, texture(tex, vec2(x, y)).rgb, scanw);
        else
            return texture(tex, vec2(x, y)).rgb;
    }
}

// ==== Vertex Shader ====

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

// ==== Fragment Shader ====

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 src = texture(Source, vTexCoord).rgb;

    // Bypass: skip all processing and return gamma-corrected source
    if (SCANLINE_ADVANCED_BYPASS >= 1.0) {
        FragColor = vec4(crt_gamma(src), 1.0);
        return;
    }

    vec2 uv = vTexCoord.xy;
    
    // Calculate aspect ratios
    float ar = global.OutputSize.x / global.OutputSize.y;    // Output aspect ratio
    float sar = global.OriginalSize.x / global.OriginalSize.y; // Source aspect ratio
    float par = ar / sar;  // Pixel aspect ratio correction

    // Convert to normalized coordinates (-1.0 to 1.0)
    uv = 2.0 * (uv - 0.5);

    // ==== Add blanking interval padding ====
    // Calculate inactive horizontal blanking in pixels
    float H_FREQ_HZ = V_FREQ * V_LINES_PER_FIELD;
    float inactive_pixels;
    if (H_BLANK_INACTIVE_UNIT < 0.5)
        inactive_pixels = H_BLANK_INACTIVE_LEN;
    else if (H_BLANK_INACTIVE_UNIT < 1.5)
        inactive_pixels = H_BLANK_INACTIVE_LEN * 1.0e-6 * H_FREQ_HZ * global.OriginalSize.x;
    else
        inactive_pixels = H_BLANK_INACTIVE_LEN / 100.0 * global.OriginalSize.x;

    float hsize = par * (global.OriginalSize.x + inactive_pixels);
    float vsize = V_LINES_PER_FIELD;
    float hscale = par * global.OriginalSize.x / hsize;
    float vscale = global.OriginalSize.y / vsize;

    // ==== Apply CRT geometry distortions ====
    
    // Update aspect ratio with padding
    ar = hsize / vsize;
    
    // Apply scaling
    uv.x *= hscale;
    uv.y *= vscale;

    // ==== Apply electronic geometric corrections ====
    // These corrections operate in screen space (before real CRT distortions)
    // Simulates digital geometry processors found in high-end CRT monitors
    uv = trapezoid(uv, TRAPEZOID_STRENGTH);
    uv = corner_correction(uv, CORNER_STRENGTH);
    uv = s_correction(uv, S_CORRECTION_H, S_CORRECTION_V);

    // Define viewport: larger ZOOM => larger viewport (zoom out).
    // Keep distortions invariant by compensating inside square-space normalization.
    float zoom = max(ZOOM, 1e-6);
    uv /= zoom;

    // Aspect ratio pre-compensation for distortion
    if (hsize > vsize)
        uv.y /= ar;
    else
        uv.x *= ar;
    
    // Normalize to square space with ZOOM folded in
    // This keeps the distortion domain normalized regardless of zoom.
    vec2 dist_scale = (hsize > vsize) ? vec2(1.0, ar) : vec2(1.0 / ar, 1.0);
    vec2 dist_scale_zoom = dist_scale * zoom;
    
    // Transform to normalized square space for entire distortion pipeline
    vec2 uv_normalized = uv * dist_scale_zoom;

    // ==== CRT GEOMETRY PIPELINE ====
    // All distortions and corrections operate in normalized square space
    float deflection_theta = DEFLECTION_ANGLE / 4.0 * (PI / 180.0);

    // Step 1: Pincushion distortion (simulates CRT electron beam deflection)
    // 
    // DISTORTION FUNCTION SELECTION:
    // - Angles <4°: Skipped (numerical precision issues cause texel crushing near axes)
    // - Angles 4-30°: Linear pincushion (electrostatic model, numerically stable)
    // - Angles >30°: User-selected type (linear or non-linear/magnetic)
    //
    // Rationale: The non-linear (magnetic) pincushion function uses higher-order
    // terms that become unstable at low deflection angles. Linear pincushion
    // provides adequate accuracy for subtle distortions while maintaining stability.
    if (DEFLECTION_ANGLE > 4.0) {
        // Use linear pincushion for low angles (4-30°) regardless of distortion type
        // Use selected distortion type only for higher angles (>30°)
        if (DEFLECTION_ANGLE <= 30.0 || PIN_DISTORTION_TYPE <= 1.0)
            uv_normalized = pincushion(uv_normalized * deflection_theta) / deflection_theta;
        else
            uv_normalized = pincushion_nl(uv_normalized * deflection_theta) / deflection_theta;
    }
    
    // Step 2: Magnetic pincushion correction (simulates correction magnets)
    if (MAGNETIC_CORRECTION > 0.0 && DEFLECTION_ANGLE > 0.0) {
        uv_normalized = magnetic_correction(uv_normalized, MAGNETIC_CORRECTION, 2.0 * deflection_theta);
    }
    
    // Step 3: Barrel distortion (simulates curved CRT screen)
    float screen_theta_x = SCREEN_ANGLE_H / 2.0 * (PI / 180.0);
    float screen_theta_y = SCREEN_ANGLE_V / 2.0 * (PI / 180.0);

    bool has_h = SCREEN_ANGLE_H > 0.0;
    bool has_v = SCREEN_ANGLE_V > 0.0;

    if (has_h && has_v) {
        uv_normalized = barrel(uv_normalized * vec2(screen_theta_x, screen_theta_y));
        uv_normalized /= vec2(screen_theta_x, screen_theta_y);
    } else if (has_h && !has_v) {
        uv_normalized = barrel(uv_normalized * vec2(screen_theta_x, 0.001));
        uv_normalized /= vec2(screen_theta_x, 0.001);
    } else if (!has_h && has_v) {
        uv_normalized = barrel(uv_normalized * vec2(0.001, screen_theta_y));
        uv_normalized /= vec2(0.001, screen_theta_y);
    }

    // Transform back from normalized square space to aspect-corrected space
    uv = uv_normalized / dist_scale_zoom;

    // Aspect ratio post-compensation
    if (hsize > vsize)
        uv.y *= ar;
    else
        uv.x /= ar;
    
    // Reverse scaling (do not re-multiply by ZOOM; larger ZOOM keeps larger viewport)
    uv.x /= hscale;
    uv.y /= vscale;
    
    // Apply underscan (shrink image to show more border)
    uv *= 1.0 + tan(PI * UNDERSCAN / 200.0);

    // Back to texture coordinates
    uv = uv / 2.0 + 0.5;

    // ==== Bicubic filtering setup ====
    
    vec2 stepxy = 1.0 / global.SourceSize.xy;

    // Adjust vertical step for scanlines/interlacing
    if (SCAN_TYPE > 1.0 || global.OriginalSize.y < 1.7 * MAX_SCAN_RATE / 2.0)
        stepxy.y /= 2.0;

    // Adjust for line-doubler
    if (LINE_DOUBLER > 0.0 && global.OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
        stepxy.y /= 2.0;

    // Prevent horizontal over-blur for low-resolution content
    if (stepxy.y < stepxy.x)
        stepxy.x /= 2.0;

    // Calculate fractional position within pixel grid
    vec2 pos = uv + stepxy / 2.0;
    vec2 f = fract(pos / stepxy);

    // Calculate bicubic filter coefficients (Mitchell-Netravali)
    // C and B parameters control sharpness vs. ringing trade-off
    float C = -1.0 / 3.0 * sq(FOCUS) + 5.0 / 6.0 * FOCUS;
    float B = 1.0 - 2.0 * C;

    // Generate 4-tap filter weights for horizontal and vertical
    vec4 xtaps = bicubic4(1.0 - f.x, B, C);
    vec4 ytaps = bicubic4(1.0 - f.y, B, C);

    // Normalize taps to ensure they sum to 1.0 (preserve brightness)
    xtaps /= xtaps.r + xtaps.g + xtaps.b + xtaps.a;
    ytaps /= ytaps.r + ytaps.g + ytaps.b + ytaps.a;

    // Calculate starting position for 4x4 kernel (centered on pixel)
    vec2 xystart = (-1.5 - f) * stepxy + pos;
    
    // Precompute 4 horizontal sample positions
    vec4 x = vec4(xystart.x,
                  xystart.x + stepxy.x,
                  xystart.x + stepxy.x * 2.0,
                  xystart.x + stepxy.x * 3.0);

    // ==== Apply 4x4 bicubic filter ====
    // Process each of 4 vertical rows, sampling 4 horizontal taps per row
    // Each row is weighted by its vertical tap weight
    vec3 col = vec3(0.0);
    
    // Row 0 (topmost)
    float y0 = xystart.y;
    col += (pixel(x.r, y0, Source) * xtaps.r +
            pixel(x.g, y0, Source) * xtaps.g +
            pixel(x.b, y0, Source) * xtaps.b +
            pixel(x.a, y0, Source) * xtaps.a) * ytaps.r;
    
    // Row 1
    float y1 = xystart.y + stepxy.y;
    col += (pixel(x.r, y1, Source) * xtaps.r +
            pixel(x.g, y1, Source) * xtaps.g +
            pixel(x.b, y1, Source) * xtaps.b +
            pixel(x.a, y1, Source) * xtaps.a) * ytaps.g;
    
    // Row 2
    float y2 = xystart.y + stepxy.y * 2.0;
    col += (pixel(x.r, y2, Source) * xtaps.r +
            pixel(x.g, y2, Source) * xtaps.g +
            pixel(x.b, y2, Source) * xtaps.b +
            pixel(x.a, y2, Source) * xtaps.a) * ytaps.b;
    
    // Row 3 (bottommost)
    float y3 = xystart.y + stepxy.y * 3.0;
    col += (pixel(x.r, y3, Source) * xtaps.r +
            pixel(x.g, y3, Source) * xtaps.g +
            pixel(x.b, y3, Source) * xtaps.b +
            pixel(x.a, y3, Source) * xtaps.a) * ytaps.a;

    // Apply subpixel mask if color mode enables it
    if (COLOR_MODE > 2.0) {
        // Calculate mask coordinates with barrel distortion applied
        // This makes the mask follow the curved CRT screen
        vec2 mask_coord = vTexCoord.xy;
        
        // Convert to normalized coordinates (-1.0 to 1.0)
        mask_coord = 2.0 * (mask_coord - 0.5);
        
        // Reverse underscan
        mask_coord /= 1.0 + tan(PI * UNDERSCAN / 200.0);
        
        // Apply scaling from blanking intervals
        mask_coord.x *= hscale;
        mask_coord.y *= vscale;
        
        // Aspect ratio pre-compensation for distortion
        if (hsize > vsize)
            mask_coord.y /= ar;
        else
            mask_coord.x *= ar;
        
        // Transform to normalized square space with zoom
        vec2 mask_normalized = mask_coord * dist_scale_zoom;
        
        // Apply barrel distortion (same as image content)
        float screen_theta_x = SCREEN_ANGLE_H / 2.0 * (PI / 180.0);
        float screen_theta_y = SCREEN_ANGLE_V / 2.0 * (PI / 180.0);
        
        bool has_h = SCREEN_ANGLE_H > 0.0;
        bool has_v = SCREEN_ANGLE_V > 0.0;
        
        if (has_h && has_v) {
            mask_normalized = barrel(mask_normalized * vec2(screen_theta_x, screen_theta_y));
            mask_normalized /= vec2(screen_theta_x, screen_theta_y);
        } else if (has_h && !has_v) {
            mask_normalized = barrel(mask_normalized * vec2(screen_theta_x, 0.001));
            mask_normalized /= vec2(screen_theta_x, 0.001);
        } else if (!has_h && has_v) {
            mask_normalized = barrel(mask_normalized * vec2(0.001, screen_theta_y));
            mask_normalized /= vec2(0.001, screen_theta_y);
        }
        
        // Transform back from normalized square space
        mask_coord = mask_normalized / dist_scale_zoom;
        
        // Aspect ratio post-compensation
        if (hsize > vsize)
            mask_coord.y *= ar;
        else
            mask_coord.x /= ar;
        
        // Reverse blanking interval scaling
        mask_coord.x /= hscale;
        mask_coord.y /= vscale;
        
        // Back to texture coordinates (0-1)
        mask_coord = mask_coord / 2.0 + 0.5;
        
        // Convert to screen pixel coordinates for mask lookup
        vec2 mask_uv = mask_coord * global.OutputSize.xy;
        
        // ==== Calculate anisotropy for filtered mask sampling ====
        // Compute partial derivatives to determine how much the mask is stretched
        // This is essential for reducing aliasing from the barrel distortion
        
        // Use automatic derivatives (dFdx/dFdy) to measure coordinate stretching
        vec2 ddx_mask = dFdx(mask_uv);
        vec2 ddy_mask = dFdy(mask_uv);
        
        // Apply anisotropic filtering to reduce aliasing
        col *= mask_anisotropic(mask_uv, ddx_mask, ddy_mask);
    }

    FragColor = vec4(col, 1.0);
}
