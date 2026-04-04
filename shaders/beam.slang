#version 450

// Filename: beam.slang
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
// CRT beam simulation (geometry + resample)
// ------------------------------------------------
// Input: Linear YrYgYb signal
// Output: Linear YrYgYb signal

#pragma name CRTBeam
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "geometry.inc"
#include "texture.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/dsp.inc"
#include "menus/parameters/factory-geometry.inc"
#include "menus/parameters/service-geometry.inc"
#include "menus/parameters/user-uncommon.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_BEAM_HEADER " —— Debug Beam —— " 0.0 0.0 0.0 0.0
#pragma parameter GEOMETRY_BYPASS "Bypass beam geometry" 0.0 0.0 1.0 1.0
#pragma parameter BEAM_FILTER_TYPE "Beam filter type (fast, accurate, bilinear)" 0.0 0.0 2.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 SourceSize;     // xy = input size in pixels
    vec4 OriginalSize;   // xy = input size in pixels
    vec4 OutputSize;     // xy = output size in pixels
    float OriginalAspect;
    float DSP_WORKING_FS;
    float DSP_OUTPUT_FS;
    float BEAM_FOCUS;
    float CORNER_CORRECTION;      // %
    float DEFLECTION_ANGLE; // degrees
    float MAGNETIC_CORRECTION;    // % (0..100)
    float TRAPEZOIDAL_CORRECTION; // %
    float UNDERSCAN;        // %
    float USER_H_POS;            // % (50 = center)
    float USER_H_SIZE;            // % (50 = 1.0)
    float USER_UNDERSCAN_TOGGLE; // toggle
    float USER_V_POS;            // % (50 = center)
    float USER_V_SIZE;            // % (50 = 1.0)
} config;

#define DSP_WORKING_FS config.DSP_WORKING_FS
#define DSP_OUTPUT_FS config.DSP_OUTPUT_FS
#define BEAM_FOCUS config.BEAM_FOCUS
#define USER_H_SIZE config.USER_H_SIZE
#define USER_V_SIZE config.USER_V_SIZE
#define TRAPEZOIDAL_CORRECTION config.TRAPEZOIDAL_CORRECTION
#define CORNER_CORRECTION config.CORNER_CORRECTION
#define MAGNETIC_CORRECTION config.MAGNETIC_CORRECTION
#define USER_H_POS config.USER_H_POS
#define USER_V_POS config.USER_V_POS
#define USER_UNDERSCAN_TOGGLE config.USER_UNDERSCAN_TOGGLE
#define DEFLECTION_ANGLE config.DEFLECTION_ANGLE
#define UNDERSCAN config.UNDERSCAN

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;

    // Factory/service geometry controls needed here
    float S_CORRECTION_H;   // %
    float S_CORRECTION_V;   // %

    float ASPECT;
    uint FrameCount;
    float H_FREQ_MODE;
    float OriginalFPS;
    float PIXEL_CLOCK;
    float PIXEL_CLOCK_MODE;
    float SC_FREQ;
    float SC_FREQ_MODE;
    float V_FREQ;
    float V_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;

#ifdef OPTION_DEBUG
    // Debug-only stage bypass / diagnostics controls
    float GEOMETRY_BYPASS;
    float BEAM_FILTER_TYPE;
#endif  // OPTION_DEBUG

} global;

#define ASPECT global.ASPECT
#define V_FREQ_MODE global.V_FREQ_MODE
#define V_FREQ global.V_FREQ
#define SC_FREQ_MODE global.SC_FREQ_MODE
#define SC_FREQ global.SC_FREQ
#define PIXEL_CLOCK_MODE global.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK global.PIXEL_CLOCK
#define H_FREQ_MODE global.H_FREQ_MODE
#define H_FREQ global.H_FREQ
#define H_BLANK_FUZZ global.H_BLANK_FUZZ

// Geometry macro bindings
#define S_CORRECTION_H global.S_CORRECTION_H
#define S_CORRECTION_V global.S_CORRECTION_V

#ifdef OPTION_DEBUG
#define GEOMETRY_BYPASS global.GEOMETRY_BYPASS
#define BEAM_FILTER_TYPE global.BEAM_FILTER_TYPE
#endif // OPTION_DEBUG

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float maskAR;
layout(location = 2) flat out float OriginalFrameWidth;
layout(location = 3) flat out float OriginalFrameHeight;
layout(location = 4) flat out float OriginalFullFrameHeight;
layout(location = 5) flat out float IsInterlaced;
layout(location = 6) flat out float OutputFrameWidth;
layout(location = 7) flat out float OutputFrameHeight;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Selected target aspect ratio for framing
    maskAR = (ASPECT < 0.5) ? (4.0 / 3.0)
        : (ASPECT < 1.5) ? (16.0 / 9.0)
        : (ASPECT < 2.5) ? (5.0 / 4.0)
        : (16.0 / 10.0);

    float fs_output = contract_output_sample_rate(
        config.OriginalSize.xy,
        global.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    // Beam geometry still reasons about the intended displayed raster width,
    // while the stored signal itself remains in the clock-domain width.
    OriginalFrameWidth = contract_display_frame_width(
        config.OriginalSize.xy,
        global.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

    float FrameWidth = contract_output_frame_width(
        config.OriginalSize.xy,
        global.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ,
        DSP_WORKING_FS,
        DSP_OUTPUT_FS);

    OriginalFrameHeight = contract_frame_height(
        config.OriginalSize.xy,
        global.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    float FrameHeight = OriginalFrameHeight;
    float frame_scale = max(floor(config.SourceSize.y / FrameHeight), 1.0);

    OutputFrameWidth = FrameWidth;
    OutputFrameHeight = FrameHeight * frame_scale;

    OriginalFullFrameHeight = contract_full_frame_height(
        config.OriginalSize.xy,
        global.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    IsInterlaced = contract_is_interlaced(
        config.OriginalSize.xy,
        global.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float maskAR;
layout(location = 2) flat in float OriginalFrameWidth;
layout(location = 3) flat in float OriginalFrameHeight;
layout(location = 4) flat in float OriginalFullFrameHeight;
layout(location = 5) flat in float IsInterlaced;
layout(location = 6) flat in float OutputFrameWidth;
layout(location = 7) flat in float OutputFrameHeight;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

// ---- Local geometry helpers (subset; barrel handled later stage) ----
// Parameterized pincushion (electrostatic/linear) using anisotropic angles (radians)
vec2 pincushion_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS) return uv;
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);
    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;
    float dx = atan(x * cos(y));
    float dy = atan(y * cos(x));
    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Parameterized pincushion non-linear (magnetic) using anisotropic angles (radians)
// Blends between safe linear-style function near origin and non-linear function away from it
vec2 pincushion_nl_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS)
        return uv;
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);

    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;

    // Smoothly blend from safe linear function near origin to non-linear function away from it
    // This avoids discontinuity at y~=0 and x~=0
    float blend_x = smoothstep(0.05, 0.3, abs(x));
    float blend_y = smoothstep(0.05, 0.3, abs(y));

    // Safe linear-style approximation near origin (avoids asin domain issues)
    float dx_safe = atan(x * cos(y));
    float dy_safe = atan(y * cos(x));

    // Original non-linear (magnetic) function away from origin
    float dx_nl = atan(asin(clamp(x, -1.0, 1.0)) * cos(asin(clamp(y, -1.0, 1.0))));
    float dy_nl = atan(asin(clamp(y, -1.0, 1.0)) * cos(asin(clamp(x, -1.0, 1.0))));

    // Blend smoothly
    float dx = mix(dx_safe, dx_nl, blend_x);
    float dy = mix(dy_safe, dy_nl, blend_y);

    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Map from framebuffer UV to input texture coordinates, applying
// display framing, physical distortions, and electronic service geometry.
// Inputs:
//  - vTexCoord: source framebuffer UV in [0,1]
//  - dar: selected display aspect ratio (e.g., 4/3, 16/9)
// Outputs:
//  - input_tex: UV to sample the source texture
void apply_geometry_pipeline(
    vec2 uv,
    float dar,
    out vec2 input_tex)
{
    // Start in full-video square space
    vec2 uv_screen = uv * 2.0 - 1.0;  // [-1,1] in texture space
    vec2 sq = vec2(uv_screen.x, uv_screen.y / dar);

    // --- Physical distortions (pincushion and magnetic) ---
    float theta_defl = radians(DEFLECTION_ANGLE / 4.0);
    if (DEFLECTION_ANGLE > 4.0) {
        if (DEFLECTION_ANGLE <= 60.0) {
            sq = pincushion_theta(sq, theta_defl, theta_defl);
        } else {
            sq = pincushion_nl_theta(sq, theta_defl, theta_defl);
        }
    }
    float mag_corr = MAGNETIC_CORRECTION * 0.01;
    if (mag_corr > 0.0) {
        sq = magnetic_correction(sq, mag_corr, 2.0 * theta_defl);
    }

    // --- Electronic positioning/sizing and service corrections (all in square space) ---
    float sx = USER_H_SIZE / 50.0;
    float sy = USER_V_SIZE / 50.0;
    float ox = (USER_H_POS - 50.0) / 50.0;
    float oy = (USER_V_POS - 50.0) / 50.0;
    float underscan_scale = (USER_UNDERSCAN_TOGGLE > 0.5) ? (1.0 - (UNDERSCAN * 0.01)) : 1.0;
    // Offset/scale in display-geometry units (dar for X)
    sq = (sq - vec2(ox * dar, oy)) / (vec2(sx, sy) * underscan_scale);

    // Electronic service corrections (trapezoid, corner, S-corrections)
    float trap = TRAPEZOIDAL_CORRECTION * 0.01;
    float corner = CORNER_CORRECTION * 0.01;
    float s_h = S_CORRECTION_H * 0.01;
    float s_v = S_CORRECTION_V * 0.01;
    if (abs(trap) > 0.0001 || abs(corner) > 0.0001 || abs(s_h) > 0.0001 || abs(s_v) > 0.0001) {
        sq = geometric_correction(sq, trap, corner, s_h, s_v);
    }

    // Convert back from display-geometry space to full-video square space, then to normalized
    vec2 uv_full = vec2(sq.x, sq.y * dar);
    input_tex = uv_full * 0.5 + 0.5; // full video area [0,1]
}

// Same coordinate transform path as apply_geometry_pipeline, but with all
// distortion/correction steps removed.
void apply_geometry_pipeline_nodistort(
    vec2 uv,
    float dar,
    out vec2 input_tex)
{
    vec2 uv_screen = uv * 2.0 - 1.0;
    vec2 sq = vec2(uv_screen.x, uv_screen.y / dar);

    // --- Electronic positioning/sizing and service corrections (all in square space) ---
    float sx = USER_H_SIZE / 50.0;
    float sy = USER_V_SIZE / 50.0;
    float ox = (USER_H_POS - 50.0) / 50.0;
    float oy = (USER_V_POS - 50.0) / 50.0;
    float underscan_scale = (USER_UNDERSCAN_TOGGLE > 0.5) ? (1.0 - (UNDERSCAN * 0.01)) : 1.0;
    // Offset/scale in display-geometry units (dar for X)
    sq = (sq - vec2(ox * dar, oy)) / (vec2(sx, sy) * underscan_scale);

    vec2 uv_full = vec2(sq.x, sq.y * dar);
    input_tex = uv_full * 0.5 + 0.5;
}

void main()
{
    // Canonical full-frame dimensions from the timing contract.
    float FrameHeight = max(
        (IsInterlaced < 0.5) ? OriginalFrameHeight : OriginalFullFrameHeight,
        1.0);

    // Aspect ratios for full video
    float original_dar = config.OriginalAspect;
    float original_sar = config.OriginalSize.x * config.OriginalSize.w;
    float original_par = original_dar / max(original_sar, EPS);

    float full_dar = original_par * OriginalFrameWidth / FrameHeight;

    vec2 active_uv = vTexCoord;

    // Fill to mask border (zoom): scale so the smaller axis fills the mask border
    vec2 uv_zoom = 2.0 * active_uv - 1.0;
    float content_aspect = full_dar;
    float target_aspect = maskAR;
    vec2 scale = vec2(1.0);

    if (content_aspect > target_aspect) {
        // Content is wider: scale x up (crop sides)
        scale.x = content_aspect / target_aspect;
    } else {
        // Content is taller: scale y up (crop top/bottom)
        scale.y = target_aspect / content_aspect;
    }
    uv_zoom /= scale;
    active_uv = 0.5 * (uv_zoom + 1.0);

    // ---- Geometry pipeline ----
    vec2 geometry_uv;

#ifdef OPTION_FLAT
    apply_geometry_pipeline_nodistort(
        active_uv,
        maskAR,
        geometry_uv);
#else

#ifdef OPTION_DEBUG
    if (GEOMETRY_BYPASS > 0.5) {
        geometry_uv = active_uv;
    } else {
#endif  // OPTION_DEBUG
    apply_geometry_pipeline(
        active_uv,
        maskAR,
        geometry_uv);
#ifdef OPTION_DEBUG
    }
#endif  // OPTION_DEBUG

#endif  // OPTION_FLAT

    // Remap from geometry UVs to the packed source texture. Data starts at
    // (0,0) in the source texture. Shift geometry_uv to centre, scale into
    // the data region, then shift back to the data centre.
    vec2 source_tex_size = max(config.SourceSize.xy, vec2(1.0));
    vec2 stored_frame_size = min(vec2(OutputFrameWidth, OutputFrameHeight), source_tex_size);
    vec2 frame_uv_scale = stored_frame_size / source_tex_size;
    vec2 data_center = frame_uv_scale * 0.5;
    vec2 input_uv = (geometry_uv - 0.5) * frame_uv_scale + data_center;

    // Bicubic resample from input texture using BEAM_FOCUS
    float focus = clamp(BEAM_FOCUS * 0.01, 0.0, 1.0);
    float C = -1.0 / 3.0 * focus * focus + 5.0 / 6.0 * focus;
    float B = 1.0 - 2.0 * C;

    vec3 color;
    float alpha = texture(Source, clamp01(input_uv)).a;

#ifdef OPTION_DEBUG
    if (BEAM_FILTER_TYPE < 0.5) {
#endif  // OPTION_DEBUG

    color = sample_bicubic_fast(Source, input_uv, config.SourceSize.zw, B, C);

#ifdef OPTION_DEBUG
    } else if (BEAM_FILTER_TYPE < 1.5) {
        color = sample_bicubic(Source, input_uv, config.SourceSize.zw, B, C);
    } else {
        color = texture(Source, input_uv).rgb;
    }
#endif  // OPTION_DEBUG

    FragColor = vec4(max(color, 0.0), alpha);
}
