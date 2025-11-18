#version 450

// Filename: crt-geometry.slang
//
// Copyright (C) 2025 W. M. Martinez
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
// CRT Geometry + Bicubic Resampling
// ------------------------------------------------
// Input: RGB signal (expected linear)
// Output: RGB signal (linear)

#include "common.inc"
#include "geometry.inc"
#include "filter.h"
#include "modulation.inc"

#include "menus/parameters/factory-geometry.inc"
#include "menus/parameters/service-geometry.inc"
#include "menus/parameters/user-common.inc"
#include "menus/parameters/sys-timing.inc"

#pragma name CRTGeometry
#pragma format R16G16B16A16_SFLOAT

#pragma parameter GEOMETRY_BYPASS "Bypass CRT geometry" 0.0 0.0 1.0 1.0
#pragma parameter GEOMETRY_DEBUG_PADDING "Show timing regions" 0.0 0.0 1.0 1.0
#pragma parameter GEOMETRY_DEBUG_MODE "Debug geometry (10PMBE)" 0.0 0.0 5.0 1.0
#pragma parameter GEOMETRY_DEBUG_NO_BICUBIC "Disable upscaler" 0.0 0.0 1.0 1.0
#pragma parameter GEOMETRY_DEBUG_OUT_OF_BOUNDS "Show out-of-bounds" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    // IO
    vec4 SourceSize;     // xy = input size in pixels
    vec4 OriginalSize;   // xy = input size in pixels
    vec4 OutputSize;     // xy = output size in pixels
    uint FrameCount;
    float OriginalFPS;
    float OriginalAspect;

    // Control
    float GEOMETRY_BYPASS;
    float GEOMETRY_DEBUG_PADDING;

    // Factory geometry (angles in degrees)
    float DEFLECTION_ANGLE;  // Pincushion/deflection angle
    float SCREEN_ANGLE_H;    // Screen curvature horizontal
    float SCREEN_ANGLE_V;    // Screen curvature vertical

    // Service geometry (percent-based)
    float UNDERSCAN;              // %
    float FOCUS;                  // %
    float S_CORRECTION_H;       // %
    float S_CORRECTION_V;       // %
    float TRAPEZOIDAL_CORRECTION; // %
    float CORNER_CORRECTION;      // %
    float MAGNETIC_CORRECTION;    // % (0..100)

    // System timing
    float V_LINES_PER_FIELD;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
} config;

// Macro bindings for consistency with code style
#define GEOMETRY_BYPASS config.GEOMETRY_BYPASS
#define GEOMETRY_DEBUG_PADDING config.GEOMETRY_DEBUG_PADDING

#define DEFLECTION_ANGLE       config.DEFLECTION_ANGLE
#define SCREEN_ANGLE_H         config.SCREEN_ANGLE_H
#define SCREEN_ANGLE_V         config.SCREEN_ANGLE_V

#define UNDERSCAN              config.UNDERSCAN
#define FOCUS                  config.FOCUS
#define S_CORRECTION_H         config.S_CORRECTION_H
#define S_CORRECTION_V         config.S_CORRECTION_V
#define TRAPEZOIDAL_CORRECTION config.TRAPEZOIDAL_CORRECTION
#define CORNER_CORRECTION      config.CORNER_CORRECTION
#define MAGNETIC_CORRECTION    config.MAGNETIC_CORRECTION

#define V_LINES_PER_FIELD      config.V_LINES_PER_FIELD
#define SC_FREQ_MODE           config.SC_FREQ_MODE
#define SC_FREQ                config.SC_FREQ
#define H_BLANK_INACTIVE_LEN   config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT  config.H_BLANK_INACTIVE_UNIT

// MVP / matrix UBO (matches project convention)
layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    float FIELD_ORDER;
    float SHORTEN_ODD_FIELD_TIME;
    // User common
    float USER_H_SIZE;           // % (50 = 1.0)
    float USER_V_SIZE;           // % (50 = 1.0)
    float USER_H_POS;            // % (50 = center)
    float USER_V_POS;            // % (50 = center)
    float USER_UNDERSCAN_TOGGLE; // toggle
    float GEOMETRY_DEBUG_MODE;
    float GEOMETRY_DEBUG_NO_BICUBIC;
    float GEOMETRY_DEBUG_OUT_OF_BOUNDS;
} global;

#define FIELD_ORDER global.FIELD_ORDER
#define SHORTEN_ODD_FIELD_TIME global.SHORTEN_ODD_FIELD_TIME

#define USER_H_SIZE global.USER_H_SIZE
#define USER_V_SIZE global.USER_V_SIZE
#define USER_H_POS global.USER_H_POS
#define USER_V_POS global.USER_V_POS
#define USER_UNDERSCAN_TOGGLE global.USER_UNDERSCAN_TOGGLE

#define GEOMETRY_DEBUG_MODE global.GEOMETRY_DEBUG_MODE
#define GEOMETRY_DEBUG_NO_BICUBIC global.GEOMETRY_DEBUG_NO_BICUBIC
#define GEOMETRY_DEBUG_OUT_OF_BOUNDS global.GEOMETRY_DEBUG_OUT_OF_BOUNDS

// ---- Helpers ----

// Parameterized barrel distortion using anisotropic angles (radians)
vec2 barrel_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS) return uv;

    // Use small value (0.001) instead of 0 to preserve cross-axis coupling
    // This matches scanline-advanced.slang's approach for cylindrical curvature
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);
    
    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;
    
    // barrel formula: dx = tan(x)/cos(y), dy = tan(y)/cos(x)
    float dx = tan(x) / cos(y);
    float dy = tan(y) / cos(x);
    
    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Parameterized pincushion (electrostatic/linear) using anisotropic angles (radians)
vec2 pincushion_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS) return uv;

    // Use small value (0.001) instead of 0 to preserve cross-axis coupling
    // This matches scanline-advanced.slang's approach for cylindrical curvature
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);
    
    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;
    
    // pincushion formula: dx = atan(x*cos(y)), dy = atan(y*cos(x))
    float dx = atan(x * cos(y));
    float dy = atan(y * cos(x));
    
    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Parameterized pincushion non-linear (magnetic) using anisotropic angles (radians)
vec2 pincushion_nl_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS) return uv;

    // Use small value (0.001) instead of 0 to preserve cross-axis coupling
    // This matches scanline-advanced.slang's approach for cylindrical curvature
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);
    
    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;
    
    // pincushion_nl formula: dx = atan(asin(x)*cos(asin(y))), dy = atan(asin(y)*cos(asin(x)))
    float dx = atan(asin(x) * cos(asin(y)));
    float dy = atan(asin(y) * cos(asin(x)));
    
    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Bicubic texture sampling (4x4 Mitchell-Netravali)
// Rewritten to match scanline-advanced.slang's approach
vec3 sample_bicubic(sampler2D source, vec2 uv, vec2 stepxy, float B, float C)
{
    vec2 texSize = vec2(textureSize(source, 0));
    
    // Calculate fractional position within pixel grid
    vec2 pos = uv + stepxy / 2.0;
    vec2 f = fract(pos / stepxy);
    
    // Calculate bicubic filter coefficients
    vec4 xtaps = bicubic4(1.0 - f.x, B, C);
    vec4 ytaps = bicubic4(1.0 - f.y, B, C);
    
    // Normalize taps to ensure they sum to 1.0 (preserve brightness)
    xtaps /= xtaps.r + xtaps.g + xtaps.b + xtaps.a;
    ytaps /= ytaps.r + ytaps.g + ytaps.b + ytaps.a;
    
    // Calculate starting position for 4x4 kernel (centered on pixel)
    vec2 xystart = (-1.5 - f) * stepxy + pos;
    
    // Precompute 4 horizontal sample positions
    vec4 xpos = vec4(xystart.x,
                     xystart.x + stepxy.x,
                     xystart.x + stepxy.x * 2.0,
                     xystart.x + stepxy.x * 3.0);
    
    // Track if any sample is out of bounds
    bool out_of_bounds = false;
    
    // Check all sample positions if debug enabled
    if (GEOMETRY_DEBUG_OUT_OF_BOUNDS > 0.5)
    {
        float y0 = xystart.y;
        float y1 = xystart.y + stepxy.y;
        float y2 = xystart.y + stepxy.y * 2.0;
        float y3 = xystart.y + stepxy.y * 3.0;
        
        // Check if any coordinate is outside [0,1]
        out_of_bounds = (xpos.r < 0.0 || xpos.r > 1.0 ||
                        xpos.g < 0.0 || xpos.g > 1.0 ||
                        xpos.b < 0.0 || xpos.b > 1.0 ||
                        xpos.a < 0.0 || xpos.a > 1.0 ||
                        y0 < 0.0 || y0 > 1.0 ||
                        y1 < 0.0 || y1 > 1.0 ||
                        y2 < 0.0 || y2 > 1.0 ||
                        y3 < 0.0 || y3 > 1.0);
    }
    
    // Apply 4x4 bicubic filter
    vec3 col = vec3(0.0);
    
    // Row 0 (topmost)
    float y0 = xystart.y;
    col += (texture(source, vec2(xpos.r, y0)).rgb * xtaps.r +
            texture(source, vec2(xpos.g, y0)).rgb * xtaps.g +
            texture(source, vec2(xpos.b, y0)).rgb * xtaps.b +
            texture(source, vec2(xpos.a, y0)).rgb * xtaps.a) * ytaps.r;

    // Row 1
    float y1 = xystart.y + stepxy.y;
    col += (texture(source, vec2(xpos.r, y1)).rgb * xtaps.r +
            texture(source, vec2(xpos.g, y1)).rgb * xtaps.g +
            texture(source, vec2(xpos.b, y1)).rgb * xtaps.b +
            texture(source, vec2(xpos.a, y1)).rgb * xtaps.a) * ytaps.g;

    // Row 2
    float y2 = xystart.y + stepxy.y * 2.0;
    col += (texture(source, vec2(xpos.r, y2)).rgb * xtaps.r +
            texture(source, vec2(xpos.g, y2)).rgb * xtaps.g +
            texture(source, vec2(xpos.b, y2)).rgb * xtaps.b +
            texture(source, vec2(xpos.a, y2)).rgb * xtaps.a) * ytaps.b;

    // Row 3 (bottommost)
    float y3 = xystart.y + stepxy.y * 3.0;
    col += (texture(source, vec2(xpos.r, y3)).rgb * xtaps.r +
            texture(source, vec2(xpos.g, y3)).rgb * xtaps.g +
            texture(source, vec2(xpos.b, y3)).rgb * xtaps.b +
            texture(source, vec2(xpos.a, y3)).rgb * xtaps.a) * ytaps.a;

    // Apply yellow tint if out of bounds
    if (out_of_bounds)
    {
        col = mix(col, vec3(1.0, 1.0, 0.0), 0.5);
    }

    return col;
}

// ---- Vertex Shader ----

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

// ---- Fragment Shader ----

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    // Simple bypass
    if (GEOMETRY_BYPASS > 0.5) {
        vec3 color = texture(Source, vTexCoord).rgb;
        FragColor = vec4(color, 1.0);
        return;
    }

    // Compute timebase to determine active vs blanking regions
    TimebaseConfig tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        config.OriginalFPS,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Compute blanking/inactive regions
    // Horizontal: inactive pixels computed from timing parameters
    float inactive_pixels_h;
    if (H_BLANK_INACTIVE_UNIT < 0.5)
        inactive_pixels_h = H_BLANK_INACTIVE_LEN;
    else if (H_BLANK_INACTIVE_UNIT < 1.5)
        inactive_pixels_h = H_BLANK_INACTIVE_LEN * 1.0e-6 * tb.h_freq_hz * config.OriginalSize.x;
    else
        inactive_pixels_h = H_BLANK_INACTIVE_LEN / 100.0 * config.OriginalSize.x;

    // Total horizontal pixels including blanking
    float total_h_pixels = config.OriginalSize.x + inactive_pixels_h;
    float active_region_h = config.OriginalSize.x / total_h_pixels;

    // Vertical: compute inactive lines (blanking interval)
    float total_v_lines = V_LINES_PER_FIELD;
    
    // Detect interlacing: if OriginalSize.y is approximately double the expected active lines,
    // then interlacing has doubled the vertical resolution and we need to compensate
    float expected_active_lines = total_v_lines - (total_v_lines - config.OriginalSize.y);
    float interlace_scale = 1.0;
    
    // Check if the input has been scaled by interlacing (with some tolerance)
    if (config.OriginalSize.y > total_v_lines * 1.7) {
        // Interlaced: input resolution is doubled
        interlace_scale = 2.0;
    }
    
    float active_v_lines = config.OriginalSize.y / interlace_scale;
    float active_region_v = active_v_lines / max(total_v_lines, 1.0);

    // Aspect ratios
    float dar = config.OriginalAspect;
    // Compensate SAR for interlacing
    float sar = config.OriginalSize.x / (config.OriginalSize.y / interlace_scale);
    float par = dar / sar;

    // Compute aspect ratio of the full video signal (active + blanking)
    float full_aspect = par * total_h_pixels / total_v_lines;

    // Check if current output pixel is in padding/blanking region
    bool in_h_padding = (vTexCoord.x < (1.0 - active_region_h) * 0.5) || 
                        (vTexCoord.x > 1.0 - (1.0 - active_region_h) * 0.5);
    bool in_v_padding = (vTexCoord.y < (1.0 - active_region_v) * 0.5) || 
                        (vTexCoord.y > 1.0 - (1.0 - active_region_v) * 0.5);

    // Debug visualization of padding regions
    if (GEOMETRY_DEBUG_PADDING > 0.5) {
        vec3 debug_color = vec3(0.0); // Start with black for blanking
        if (!in_h_padding && !in_v_padding) {
            // Sample input texture only in active region
            vec2 active_sample = vec2(
                (vTexCoord.x - (1.0 - active_region_h) * 0.5) / active_region_h,
                (vTexCoord.y - (1.0 - active_region_v) * 0.5) / active_region_v
            );
            debug_color = texture(Source, active_sample).rgb;
        }
        if (in_h_padding || in_v_padding) {
            // Tint blanking regions yellow with 50% blend
            debug_color = mix(debug_color, vec3(1.0, 1.0, 0.0), 0.5);
        }
        FragColor = vec4(debug_color, 1.0);
        return;
    }

    // Convert output coordinate to normalized [-1,1]
    vec2 uv = vTexCoord * 2.0 - 1.0;
    
    // To square space for isotropic distortions (use full aspect including blanking)
    vec2 sq = vec2(uv.x * full_aspect, uv.y);

    // Physical CRT geometry pipeline
    // NOTE: Angles divided to match scanline-advanced.slang intensity
    // Deflection angle divided by 4, screen angles divided by 2
    float theta_defl = radians(DEFLECTION_ANGLE / 4.0);
    float theta_h = radians(SCREEN_ANGLE_H / 2.0);
    float theta_v = radians(SCREEN_ANGLE_V / 2.0);

    // Debug mode: selectively enable/disable geometric distortions
    // 0 = all (normal), 1 = all off, 2 = pincushion only, 3 = magnetic only, 4 = barrel only, 5 = electronic only
    int debug_mode = int(GEOMETRY_DEBUG_MODE);
    bool apply_pincushion = (debug_mode == 0 || debug_mode == 2);
    bool apply_magnetic = (debug_mode == 0 || debug_mode == 3);
    bool apply_barrel = (debug_mode == 0 || debug_mode == 4);
    bool apply_electronic = (debug_mode == 0 || debug_mode == 5);

    // Apply physical CRT distortions centered on screen (independent of H_POS/V_POS/H_SIZE/V_SIZE)
    // These distortions represent the physical behavior of the CRT tube itself
    
    // 1) Pincushion from deflection yoke
    // Switch to non-linear method for deflection angles > 60°
    if (apply_pincushion && DEFLECTION_ANGLE > 4.0) {
        if (DEFLECTION_ANGLE <= 60.0) {
            // Linear (electrostatic) pincushion for low angles (4-60°)
            sq = pincushion_theta(sq, theta_defl, theta_defl);
        } else {
            // Non-linear (magnetic) pincushion for higher angles (>60°)
            sq = pincushion_nl_theta(sq, theta_defl, theta_defl);
        }
    }

    // 2) Magnetic correction (partial inverse pincushion)
    if (apply_magnetic) {
        float mag_corr = MAGNETIC_CORRECTION * 0.01; // percent -> [0,1]
        if (mag_corr > 0.0) {
            // Use 2× the deflection theta for magnetic correction (matches scanline-advanced.slang)
            sq = magnetic_correction(sq, mag_corr, 2.0 * theta_defl);
        }
    }

    // 3) Barrel from screen curvature (anisotropic)
    if (apply_barrel) {
        sq = barrel_theta(sq, theta_h, theta_v);
    }

    // Now apply viewport controls (position, size, underscan)
    // These adjust the viewing window - what portion of the distorted raster we see
    float sx = USER_H_SIZE / 50.0;
    float sy = USER_V_SIZE / 50.0;
    float ox = (USER_H_POS - 50.0) / 50.0;
    float oy = (USER_V_POS - 50.0) / 50.0;
    
    float underscan_scale = 1.0;
    if (USER_UNDERSCAN_TOGGLE > 0.5)
        underscan_scale = 1.0 - (UNDERSCAN * 0.01);
    
    // Apply viewport: position offset, then size/underscan scaling
    sq = (sq - vec2(ox * full_aspect, oy)) / (vec2(sx, sy) * underscan_scale);

    // 4) Electronic service corrections (percent -> scalar)
    // These corrections move with the viewport because they represent
    // digital geometry processing that compensates for the shifted view
    if (apply_electronic) {
        float trap = TRAPEZOIDAL_CORRECTION * 0.01;
        float corner = CORNER_CORRECTION * 0.01;
        float s_h = S_CORRECTION_H * 0.01;
        float s_v = S_CORRECTION_V * 0.01;
        if (abs(trap) > 0.0001 || abs(corner) > 0.0001 || abs(s_h) > 0.0001 || abs(s_v) > 0.0001) {
            sq = geometric_correction(sq, trap, corner, s_h, s_v);
        }
    }

    // Back to texture space
    vec2 uv2 = vec2(sq.x / full_aspect, sq.y);
    vec2 tex = uv2 * 0.5 + 0.5;

    // Map from full video area back to active region for texture sampling
    // The input texture only contains active video, so scale to fit within active region
    tex.x = tex.x * active_region_h + (1.0 - active_region_h) * 0.5;
    tex.y = tex.y * active_region_v + (1.0 - active_region_v) * 0.5;

    // Remap to sample from input texture (which spans [0,1] for active content only)
    vec2 input_tex = vec2(
        (tex.x - (1.0 - active_region_h) * 0.5) / active_region_h,
        (tex.y - (1.0 - active_region_v) * 0.5) / active_region_v
    );

    // Compute bicubic filter coefficients from focus parameter
    float focus = clamp(FOCUS * 0.01, 0.0, 1.0);
    float C = -1.0 / 3.0 * focus * focus + 5.0 / 6.0 * focus;
    float B = 1.0 - 2.0 * C;

    // Bicubic resample from input texture (or nearest if debug mode enabled)
    vec3 color;
    if (GEOMETRY_DEBUG_NO_BICUBIC > 0.5) {
        // Nearest neighbor sampling
        color = texture(Source, input_tex).rgb;
    } else {
        // Bicubic sampling
        color = sample_bicubic(
            Source,
            input_tex,
            1.0 / config.SourceSize.xy,
            B,
            C);
    }

    FragColor = vec4(crt_gamma(color), 1.0);
}
