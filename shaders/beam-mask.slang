#version 450

// Filename: beam-mask.slang
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
// CRT beam simulation with mask
// ------------------------------------------------
// Input: Linear RGB signal
// Output: Linear RGB signal

#include "common.inc"
#include "filter.h"
#include "geometry.inc"
#include "modulation.inc"

#include "menus/parameters/mask.inc"
#include "menus/parameters/factory-geometry.inc"
#include "menus/parameters/service-geometry.inc"
#include "menus/parameters/user-common.inc"

#pragma name CRTMask
#pragma format R16G16B16A16_SFLOAT

#pragma parameter MASK_BYPASS "Bypass CRT mask" 0.0 0.0 1.0 1.0
#pragma parameter MASK_DEBUG_PADDING "Show timing regions" 0.0 0.0 1.0 1.0
// When enabled, areas outside the frame are shown as 50% gray instead of black
#pragma parameter MASK_FRAME_DEBUG "Mask frame debug (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#pragma parameter MASK_DEBUG_PAD "Highlight padding (yellow)" 0.0 0.0 1.0 1.0

#pragma parameter GEOMETRY_BYPASS "Bypass beam geometry" 0.0 0.0 1.0 1.0
#pragma parameter FILTER_BYPASS "Bypass beam filter" 0.0 0.0 1.0 1.0

#if 0
#pragma parameter PARTIAL_OFFSET_X "Partial-dot detection offset X" 0.0 -3.0 3.0 0.1
#pragma parameter PARTIAL_OFFSET_Y "Partial-dot detection offset Y" 0.0 -3.0 3.0 0.1

// NEW: user-tunable partial-dot radius scale (DOT_K)
#pragma parameter MASK_PARTIAL_K "Partial-dot radius factor (DOT_K)" 1.75 0.5 3.0 0.05
#endif

layout(push_constant) uniform Push
{
    vec4 SourceSize;     // xy = input size in pixels
    vec4 OriginalSize;   // xy = input size in pixels
    vec4 OutputSize;     // xy = output size in pixels
    uint FrameCount;
    float OriginalFPS;
    float OriginalAspect;
    float MASK_BYPASS;
    float MASK_TYPE;
    float MASK_INTENSITY;
    float MASK_MONOCHROME;
    float TVL;
    float BEAM_FOCUS;
    float V_LINES_PER_FIELD;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float MASK_DIFFUSION;
    float ASPECT;
    float MASK_FRAME_DEBUG;
    float MASK_DEBUG_PADDING;
    // ---- Geometry/user viewport controls ----
    float USER_H_SIZE;           // % (50 = 1.0)
    float USER_V_SIZE;           // % (50 = 1.0)
} config;

#define MASK_BYPASS config.MASK_BYPASS
#define MASK_TYPE config.MASK_TYPE
#define MASK_INTENSITY config.MASK_INTENSITY
#define MASK_MONOCHROME config.MASK_MONOCHROME
#define TVL config.TVL
#define BEAM_FOCUS config.BEAM_FOCUS
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define MASK_DIFFUSION config.MASK_DIFFUSION
#define ASPECT config.ASPECT
#define MASK_FRAME_DEBUG config.MASK_FRAME_DEBUG
#define MASK_DEBUG_PADDING config.MASK_DEBUG_PADDING

// Geometry macro bindings
#define USER_H_SIZE            config.USER_H_SIZE
#define USER_V_SIZE            config.USER_V_SIZE

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    float TRAPEZOIDAL_CORRECTION; // %
    float CORNER_CORRECTION;      // %
    float MAGNETIC_CORRECTION;    // % (0..100)
    float SHORTEN_ODD_FIELD_TIME;
    float USER_H_POS;            // % (50 = center)
    float USER_V_POS;            // % (50 = center)
    float USER_UNDERSCAN_TOGGLE; // toggle
    // Factory/service geometry controls needed here
    float DEFLECTION_ANGLE; // degrees
    float UNDERSCAN;        // %
    float S_CORRECTION_H;   // %
    float S_CORRECTION_V;   // %
    float MASK_DEBUG_PAD;
    float GEOMETRY_BYPASS;
    float FILTER_BYPASS;

#if 0
    // NEW: measurement-center offsets for partial-dot detection (mask units)
    float PARTIAL_OFFSET_X; // horizontal units; affects only partial-dot detection
    float PARTIAL_OFFSET_Y; // vertical units; affects only partial-dot detection
                            // NEW: user parameter for partial-dot radius scale
    float MASK_PARTIAL_K;
#endif

} global;

#define GEOMETRY_BYPASS global.GEOMETRY_BYPASS
#define FILTER_BYPASS global.FILTER_BYPASS

#define TRAPEZOIDAL_CORRECTION global.TRAPEZOIDAL_CORRECTION
#define CORNER_CORRECTION global.CORNER_CORRECTION
#define MAGNETIC_CORRECTION global.MAGNETIC_CORRECTION
#define SHORTEN_ODD_FIELD_TIME global.SHORTEN_ODD_FIELD_TIME
#define USER_H_POS global.USER_H_POS
#define USER_V_POS global.USER_V_POS
#define USER_UNDERSCAN_TOGGLE global.USER_UNDERSCAN_TOGGLE

#define DEFLECTION_ANGLE global.DEFLECTION_ANGLE
#define UNDERSCAN global.UNDERSCAN
#define S_CORRECTION_H global.S_CORRECTION_H
#define S_CORRECTION_V global.S_CORRECTION_V

#define MASK_DEBUG_PAD global.MASK_DEBUG_PAD

// NEW:
#if 0
#define PARTIAL_OFFSET_X global.PARTIAL_OFFSET_X
#define PARTIAL_OFFSET_Y global.PARTIAL_OFFSET_Y
#define MASK_PARTIAL_K global.MASK_PARTIAL_K
#endif

#define PINCUSHION_FACTOR global.PINCUSHION_FACTOR

// Bicubic texture sampling (4x4 Mitchell-Netravali)
// Matches implementation style from crt-geometry.slang
vec3 sample_bicubic(sampler2D source, vec2 uv, vec2 stepxy, float B, float C)
{
    vec2 pos = uv + stepxy / 2.0;
    vec2 f = fract(pos / stepxy);

    vec4 xtaps = bicubic4(1.0 - f.x, B, C);
    vec4 ytaps = bicubic4(1.0 - f.y, B, C);
    xtaps /= (xtaps.r + xtaps.g + xtaps.b + xtaps.a);
    ytaps /= (ytaps.r + ytaps.g + ytaps.b + ytaps.a);

    vec2 xystart = (-1.5 - f) * stepxy + pos;

    vec4 xpos = vec4(xystart.x,
             xystart.x + stepxy.x,
             xystart.x + stepxy.x * 2.0,
             xystart.x + stepxy.x * 3.0);

    vec3 col = vec3(0.0);

    float y0 = xystart.y;
    col += (texture(source, vec2(xpos.r, y0)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y0)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y0)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y0)).rgb * xtaps.a) * ytaps.r;

    float y1 = xystart.y + stepxy.y;
    col += (texture(source, vec2(xpos.r, y1)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y1)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y1)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y1)).rgb * xtaps.a) * ytaps.g;

    float y2 = xystart.y + stepxy.y * 2.0;
    col += (texture(source, vec2(xpos.r, y2)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y2)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y2)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y2)).rgb * xtaps.a) * ytaps.b;

    float y3 = xystart.y + stepxy.y * 3.0;
    col += (texture(source, vec2(xpos.r, y3)).rgb * xtaps.r +
        texture(source, vec2(xpos.g, y3)).rgb * xtaps.g +
        texture(source, vec2(xpos.b, y3)).rgb * xtaps.b +
        texture(source, vec2(xpos.a, y3)).rgb * xtaps.a) * ytaps.a;

    return col;
}

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
vec2 pincushion_nl_theta(vec2 uv, const float theta_h, const float theta_v)
{
    if (theta_h < EPS && theta_v < EPS) return uv;
    float safe_theta_h = max(theta_h, 0.001);
    float safe_theta_v = max(theta_v, 0.001);
    vec2 t = uv * vec2(safe_theta_h, safe_theta_v);
    float x = t.x;
    float y = t.y;
    float dx = atan(asin(x) * cos(asin(y)));
    float dy = atan(asin(y) * cos(asin(x)));
    vec2 out_uv = vec2(dx / safe_theta_h, dy / safe_theta_v);
    return out_uv;
}

// Cyclic distance on a ring of length `period`
// Returns shortest wrapped distance between x and center.
float cyclicDist(float x, float center, float period)
{
    float d = abs(x - center);
    return min(d, period - d);
}

#if 0
// NEW: Edge-aware cyclic distance.
// Increases effective distance when a gaussian of `radius` centered at `center` would be clipped by edges.
// Use this when you want a distance that "self-suppresses" near the frame edges.
float cyclicDistEdge(float x,
                     float center,
                     float period,
                     float edgeMin,
                     float edgeMax,
                     float radius,
                     float feather)
{
    // Base cyclic distance on the ring.
    float d = abs(x - center);
    d = min(d, period - d);

    // Overshoot if the gaussian footprint would exceed the visible domain.
    float leftOver  = max(0.0, edgeMin - (center - radius));
    float rightOver = max(0.0, (center + radius) - edgeMax);
    float over = max(leftOver, rightOver);

    // If no overshoot, return the base cyclic distance unchanged.
    if (over <= 0.0) return d;

    // Softly push distance toward "far" when overshooting, which kills the gaussian weight.
    float t = clamp(over / max(feather, 1e-6), 0.0, 1.0);
    // period*0.5 is the maximum cyclic distance on the ring.
    return mix(d, period * 0.5, t);
}

// NEW: One-dimensional edge feather based on how much a radius would overshoot the edges.
// Returns 1.0 when fully safe; ramps to 0.0 as overshoot grows beyond `feather`.
float edgeFeather1D(float center,
                    float radius,
                    float edgeMin,
                    float edgeMax,
                    float eps,
                    float feather)
{
    float leftOver  = max(0.0, (edgeMin + eps) - (center - radius));
    float rightOver = max(0.0, (center + radius) - (edgeMax - eps));
    float over = max(leftOver, rightOver);
    return 1.0 - smoothstep(0.0, max(feather, 1e-6), over);
}
#endif

// Map from framebuffer UV to input active texture coordinates, applying
// display framing, physical distortions, and electronic service geometry.
// Inputs:
//  - vTexCoord: source framebuffer UV in [0,1]
//  - maskAR: selected display aspect ratio (e.g., 4/3, 16/9)
//  - full_aspect: aspect of the full video frame (active + padding)
//  - active_region_h/v: normalized width/height of the active video within full frame
// Outputs:
//  - inside: whether the pixel is within the full video bounds after geometry
//  - in_active: whether the pixel is inside the active region after geometry
//  - input_tex: UV inside the active region to sample the source texture
void apply_geometry_pipeline(
    vec2 vTexCoord,
    float maskAR,
    float full_aspect,
    float active_region_h,
    float active_region_v,
    out bool inside,
    out bool in_active,
    out vec2 input_tex)
{
    // Start in full-video square space, then remap X into display-geometry space (maskAR)
    vec2 uv_frame = clamp(vTexCoord, 0.0, 1.0);
    vec2 uv_screen = uv_frame * 2.0 - 1.0;  // [-1,1] in texture space
    vec2 sq = vec2(uv_screen.x * full_aspect, uv_screen.y);
    float to_mask = maskAR / max(full_aspect, EPS);
    sq.x *= to_mask;

    // Physical distortions (pincushion and magnetic) - tied to mask/tube
    // We divide the deflection angle by 5 to get a reasonable range for typical CRTs
    float theta_defl = radians(DEFLECTION_ANGLE / 5.0);
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

    // Electronic positioning/sizing and service corrections (all in square space)
    float display_aspect = maskAR;
    float content_aspect = full_aspect;

    // Calculate scaling to fit content within display aspect
    float aspect_fit_scale_x = 1.0;
    float aspect_fit_scale_y = 1.0;
    if (content_aspect > display_aspect) {
        // Content is wider than display - need pillarbox (shrink horizontally)
        aspect_fit_scale_x = display_aspect / content_aspect;
    } else {
        // Content is taller than display - need letterbox (shrink vertically)
        aspect_fit_scale_y = content_aspect / display_aspect;
    }

    float sx = (USER_H_SIZE / 50.0) / aspect_fit_scale_x;
    float sy = (USER_V_SIZE / 50.0) / aspect_fit_scale_y;
    float ox = (USER_H_POS - 50.0) / 50.0;
    float oy = (USER_V_POS - 50.0) / 50.0;
    float underscan_scale = (USER_UNDERSCAN_TOGGLE > 0.5) ? (1.0 - (UNDERSCAN * 0.01)) : 1.0;
    // Offset/scale in display-geometry units (maskAR for X)
    sq = (sq - vec2(ox * maskAR, oy)) / (vec2(sx, sy) * underscan_scale);

    // Electronic service corrections (trapezoid, corner, S-corrections)
    float trap = TRAPEZOIDAL_CORRECTION * 0.01;
    float corner = CORNER_CORRECTION * 0.01;
    float s_h = S_CORRECTION_H * 0.01;
    float s_v = S_CORRECTION_V * 0.01;
    if (abs(trap) > 0.0001 || abs(corner) > 0.0001 || abs(s_h) > 0.0001 || abs(s_v) > 0.0001) {
        sq = geometric_correction(sq, trap, corner, s_h, s_v);
    }

    // Convert back from display-geometry space to full-video square space, then to normalized
    float to_full = max(full_aspect, EPS) / maskAR;
    sq.x *= to_full;
    vec2 uv_full = vec2(sq.x / full_aspect, sq.y);
    vec2 tex = uv_full * 0.5 + 0.5; // full video area [0,1]

    // Inside full video bounds after geometry
    inside = (tex.x >= 0.0 && tex.x <= 1.0 && tex.y >= 0.0 && tex.y <= 1.0);

    // Active region bounds within full video space
    float x_active_min = (1.0 - active_region_h) * 0.5;
    float x_active_max = 1.0 - x_active_min;
    float y_active_min = (1.0 - active_region_v) * 0.5;
    float y_active_max = 1.0 - y_active_min;

    in_active = (tex.x >= x_active_min && tex.x <= x_active_max &&
                 tex.y >= y_active_min && tex.y <= y_active_max);

    // Remap to input active texture coordinates only if inside active region
    input_tex = vec2(
        (tex.x - x_active_min) / max(active_region_h, EPS),
        (tex.y - y_active_min) / max(active_region_v, EPS)
    );
    input_tex = clamp(input_tex, 0.0, 1.0);
}

// ---- Mask computation as a subroutine ----
vec3 compute_mask(vec2 screen_uv, float units_x_total, float units_y_total, float sigma)
{
    // Continuous unit coordinates for smooth Gaussian weighting
    float x_units = screen_uv.x * units_x_total;
    float y_units = screen_uv.y * units_y_total;

    // Horizontal centers aligned to left-edge origin (R starts at [0,1])
    float cycle = mod(x_units - 0.4, 6.0);

    // Use cyclic distances so weights are seamless across the 6-unit wrap
    float dr = cyclicDist(cycle, 0.0, 6.0);
    float dg = cyclicDist(cycle, 2.0, 6.0);
    float db = cyclicDist(cycle, 4.0, 6.0);

    float gauss_r = exp(-0.5 * dr*dr / (sigma*sigma));
    float gauss_g = exp(-0.5 * dg*dg / (sigma*sigma));
    float gauss_b = exp(-0.5 * db*db / (sigma*sigma));

    vec3 mask_color;
    if (MASK_TYPE < 0.5) {
        // Aperture grille
        mask_color = vec3(gauss_r, gauss_g, gauss_b);

        float avg = (mask_color.r + mask_color.g + mask_color.b) / 3.0;
        if (avg > 0.0) {
            mask_color /= avg;
        }
    } else if (MASK_TYPE < 1.5) {
        // Slot mask: 3-unit vertical cycle with periodic black row suppression
        float cycle_y = mod(y_units + 1.0, 3.0);

        float blockF = x_units / 6.0;
        float block3 = mod(blockF, 3.0);
        float sigma_h = sigma;

        int base = int(floor(blockF / 3.0)) * 3;
        int b0 = (base + 0) % 3;
        int b1 = (base + 1) % 3;
        int b2 = (base + 2) % 3;

        float d0 = cyclicDist(block3, -0.6, 3.0);
        float d1 = cyclicDist(block3,  0.4, 3.0);
        float d2 = cyclicDist(block3,  1.4, 3.0);

        float w0 = exp(-0.5 * d0*d0 / (sigma_h*sigma_h));
        float w1 = exp(-0.5 * d1*d1 / (sigma_h*sigma_h));
        float w2 = exp(-0.5 * d2*d2 / (sigma_h*sigma_h));

        float sigma_v = sigma * 0.65;
        float gate_0 = 1.0 - exp(-0.5 * pow(cyclicDist(cycle_y, float(b0), 3.0) / sigma_v, 2.0));
        float gate_1 = 1.0 - exp(-0.5 * pow(cyclicDist(cycle_y, float(b1), 3.0) / sigma_v, 2.0));
        float gate_2 = 1.0 - exp(-0.5 * pow(cyclicDist(cycle_y, float(b2), 3.0) / sigma_v, 2.0));

        float gate = w0 * gate_0 + w1 * gate_1 + w2 * gate_2;

        mask_color = vec3(gauss_r, gauss_g, gauss_b) * gate;

        // After computing mask_color for slot mask
        float avg = (mask_color.r + mask_color.g + mask_color.b) / 3.0;
        if (avg > 0.0) {
            mask_color /= avg;
        }

#if 0
        // -------- Partial-slot detection: 9-phase mapping + edge-aware feather --------
        // The slot pattern is a 3-row vertical cycle with a 1-unit horizontal shift per row.
        // If we measure horizontal in 2-unit color steps, the combined state cycles every 9 steps.
        // We use that to deterministically pick the "black row" for this x and y without clumping.
        float dotK = MASK_PARTIAL_K;
        float sigma_v_local = sigma_v;
        float r_y = dotK * sigma_v_local;

        const float EDGE_EPS_Y = 0.02;
        const float FEATHER_UNITS = 0.30; // softening for overshoot ramp

        // Vertical row index in {0,1,2}, with measurement offset applied only to detection
        int rowIdx = int(floor(mod(y_units + 1.0 + PARTIAL_OFFSET_Y, 3.0)));

        // Local absolute base of this 3-row cell (aligns to black-line indices 0,1,2)
        float Sy = y_units + 1.0 + PARTIAL_OFFSET_Y;
        float cy_base = floor(Sy / 3.0);
        float y_cell_base = cy_base * 3.0 - 1.0 - PARTIAL_OFFSET_Y;

        // 9-phase horizontal index based on 2-unit steps of the color sequence
        // (x_units - 0.4) aligns with the RGB phase used above; 2.0 steps hop between sub-triad centers.
        int idx9 = int(floor(mod((x_units - 0.4) / 2.0, 9.0)));
        int phase3 = idx9 % 3;

        // Deterministic "black-row" for this x and y: rotates with horizontal phase and vertical row
        int blackRow = (phase3 + rowIdx) % 3;

        // Absolute center of that black row within our local cell
        float black_center = y_cell_base + float(blackRow);

        // Directional checks: nearest black-line to the north for top edge, and to the south for bottom
        float north_center = black_center - 3.0;
        float south_center = black_center + 3.0;

        // Compute overshoot in "mask units" and convert to a smooth feather factor
        float dist_top = north_center - r_y - EDGE_EPS_Y;                         // >0 means safe
        float dist_bot = units_y_total - EDGE_EPS_Y - (south_center + r_y);       // >0 means safe
        float over_top = max(0.0, -dist_top);
        float over_bot = max(0.0, -dist_bot);
        float overshoot = max(over_top, over_bot);

        float feather = 1.0 - smoothstep(0.0, FEATHER_UNITS, overshoot);
        mask_color *= feather;
#endif
    } else {
        // Shadow mask (4-row cycle)
        float vcycle = mod(y_units - 0.4, 4.0);
        float sigma_v = max(0.08, sigma * 0.65);
        float w0 = exp(-0.5 * pow(cyclicDist(vcycle, 0.5, 4.0) / sigma_v, 2.0));
        float w2 = exp(-0.5 * pow(cyclicDist(vcycle, 2.5, 4.0) / sigma_v, 2.0));

        float dR0 = cyclicDist(cycle, 0.0, 6.0);
        float dG0 = cyclicDist(cycle, 2.0, 6.0);
        float dB0 = cyclicDist(cycle, 4.0, 6.0);
        vec3 rgb0 = vec3(
            exp(-0.5 * dR0*dR0 / (sigma*sigma)),
            exp(-0.5 * dG0*dG0 / (sigma*sigma)),
            exp(-0.5 * dB0*dB0 / (sigma*sigma))
        );

        float dB2 = cyclicDist(cycle, 1.0, 6.0);
        float dR2 = cyclicDist(cycle, 3.0, 6.0);
        float dG2 = cyclicDist(cycle, 5.0, 6.0);
        vec3 rgb2 = vec3(
            exp(-0.5 * dR2*dR2 / (sigma*sigma)),
            exp(-0.5 * dG2*dG2 / (sigma*sigma)),
            exp(-0.5 * dB2*dB2 / (sigma*sigma))
        );

        mask_color = w0 * rgb0 + w2 * rgb2;
        // After computing mask_color for slot mask
        float avg = (mask_color.r + mask_color.g + mask_color.b) / 3.0;
        if (avg > 0.0) {
            mask_color /= avg;
        }

#if 0
        // -------- Partial-dot detection (Shadow): all four edges, stable centers --------
        float dotK = MASK_PARTIAL_K;
        float r_y = dotK * sigma_v;
        float r_x = dotK * sigma;

        const float EDGE_EPS_X = 0.02;
        const float EDGE_EPS_Y = 0.02;

        // Stable absolute base for vertical rows (period 4.0, centers at 0.5 and 2.5 with -0.4 phase)
        float Sy = y_units - 0.4 + PARTIAL_OFFSET_Y;
        float ty = floor(Sy / 4.0);
        float baseVy = ty * 4.0 + 0.4 - PARTIAL_OFFSET_Y;

        float dy = y_units - baseVy;
        float cVy = (abs(dy - 0.5) <= abs(dy - 2.5)) ? 0.5 : 2.5;
        float y_center = baseVy + cVy;

        // Stable absolute base for horizontal triads (period 6.0, phase -0.4)
        float Sx = x_units - 0.4 + PARTIAL_OFFSET_X;
        float tx = floor(Sx / 6.0);
        float baseX = tx * 6.0 + 0.4 - PARTIAL_OFFSET_X;

        float dx = x_units - baseX;

        // Choose nearest dot center from the correct parity set based on the dominant row
        bool useRow0 = (w0 >= w2);
        float cHx;
        if (useRow0) {
            // even set {0,2,4}
            float nearest_even = round(dx / 2.0) * 2.0;
            cHx = clamp(nearest_even, 0.0, 4.0);
        } else {
            // odd set {1,3,5}
            float nearest_odd = 1.0 + round((dx - 1.0) / 2.0) * 2.0;
            cHx = clamp(nearest_odd, 1.0, 5.0);
        }
        float x_center = baseX + cHx;

        bool partial_y = (y_center - r_y < 0.0 + EDGE_EPS_Y) ||
                         (y_center + r_y > units_y_total - EDGE_EPS_Y);
        bool partial_x = (x_center - r_x < 0.0 + EDGE_EPS_X) ||
                         (x_center + r_x > units_x_total - EDGE_EPS_X);

        if (partial_x || partial_y) {
            mask_color = vec3(0.0);
        }
#endif
    }

    if (MASK_MONOCHROME > 0.5) {
        float nb = max(mask_color.r, max(mask_color.g, mask_color.b));
        float mono = nb * nb * (3.0 - 2.0 * nb);
        mask_color = vec3(mono);
    }

    return mask_color;
}

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
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    // Selected target aspect ratio for framing
    float maskAR = (ASPECT < 0.5) ? (4.0/3.0)
        : (ASPECT < 1.5) ? (16.0/9.0)
        : (ASPECT < 2.5) ? (5.0/4.0)
        : (16.0/10.0);

    // Compute timebase and padding/active regions (like CRTGeometry)
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

    // Horizontal inactive pixels (blanking)
    float inactive_pixels_h;
    if (H_BLANK_INACTIVE_UNIT < 0.5)
        inactive_pixels_h = H_BLANK_INACTIVE_LEN;
    else if (H_BLANK_INACTIVE_UNIT < 1.5)
        inactive_pixels_h = H_BLANK_INACTIVE_LEN * 1.0e-6 * tb.h_freq_hz * config.OriginalSize.x;
    else
        inactive_pixels_h = H_BLANK_INACTIVE_LEN / 100.0 * config.OriginalSize.x;

    float total_h_pixels = config.OriginalSize.x + inactive_pixels_h;
    float active_region_h = config.OriginalSize.x / max(total_h_pixels, 1.0);

    // Vertical inactive (blanking) lines
    float total_v_lines = V_LINES_PER_FIELD;

    // Interlace detection/compensation
    float interlace_scale = 1.0;
    if (config.OriginalSize.y > total_v_lines * 1.7)
        interlace_scale = 2.0;

    float active_v_lines = config.OriginalSize.y / interlace_scale;
    float active_region_v = active_v_lines / max(total_v_lines, 1.0);

    // Aspect ratios for full video (active + blanking)
    float dar = config.OriginalAspect;
    float sar = config.OriginalSize.x / (config.OriginalSize.y / interlace_scale);
    float par = dar / max(sar, EPS);

    // Full video aspect (active + blanking) - represents the ideal aspect including padding
    float full_aspect = par * total_h_pixels / max(total_v_lines, 1.0);

    // Work directly in source texture space (no initial scaling needed)
    vec2 uv_frame = vTexCoord;

    // Initial inside test: are we within the full video frame (including padding)?
    bool inside_initial = (uv_frame.x >= 0.0 && uv_frame.x <= 1.0 &&
                           uv_frame.y >= 0.0 && uv_frame.y <= 1.0);

    uv_frame = clamp(uv_frame, 0.0, 1.0);

    // Optional timing padding debug (inside the frame)
    if (MASK_DEBUG_PADDING > 0.5) {
        vec3 debug_color = vec3(0.0);
        if (inside_initial) {
            bool in_h_padding = (uv_frame.x < (1.0 - active_region_h) * 0.5) ||
                                (uv_frame.x > 1.0 - (1.0 - active_region_h) * 0.5);
            bool in_v_padding = (uv_frame.y < (1.0 - active_region_v) * 0.5) ||
                                (uv_frame.y > 1.0 - (1.0 - active_region_v) * 0.5);

            if (!in_h_padding && !in_v_padding) {
                vec2 active_sample = vec2(
                    (uv_frame.x - (1.0 - active_region_h) * 0.5) / max(active_region_h, EPS),
                    (uv_frame.y - (1.0 - active_region_v) * 0.5) / max(active_region_v, EPS)
                );
                active_sample = clamp(active_sample, 0.0, 1.0);
                debug_color = texture(Source, active_sample).rgb;
            }
            if (in_h_padding || in_v_padding) {
                debug_color = mix(debug_color, vec3(1.0, 1.0, 0.0), 0.5);
            }
        } else {
            float outsideGray = (MASK_FRAME_DEBUG > 0.5) ? 0.5 : 0.0;
            debug_color = vec3(outsideGray);
        }
        FragColor = vec4(debug_color, 1.0);
        return;
    }

    // ---- Unified geometry pipeline in a subroutine ----
    bool inside;
    bool in_active;
    vec2 input_tex;

    if (GEOMETRY_BYPASS >= 1.0) {
        // Geometry bypass: treat vTexCoord as direct input
        inside = (vTexCoord.x >= 0.0 && vTexCoord.x <= 1.0 &&
                  vTexCoord.y >= 0.0 && vTexCoord.y <= 1.0);
        in_active = inside;
        input_tex = clamp(vTexCoord, 0.0, 1.0);
    } else {
        apply_geometry_pipeline(
            uv_frame,
            maskAR,
            full_aspect,
            active_region_h,
            active_region_v,
            inside,
            in_active,
            input_tex);
    }

    // Bicubic resample from input texture using BEAM_FOCUS
    float focus = clamp(BEAM_FOCUS * 0.01, 0.0, 1.0);
    float C = -1.0 / 3.0 * focus * focus + 5.0 / 6.0 * focus;
    float B = 1.0 - 2.0 * C;
    // Base color: sample content inside frame; outside use debug gray or black
    float outsideGray = (MASK_FRAME_DEBUG > 0.5) ? 0.5 : 0.0;
    vec3 inside_color;
    if (in_active) {
        if (FILTER_BYPASS < 0.5) {
            inside_color = sample_bicubic(Source, input_tex, 1.0 / config.SourceSize.xy, B, C);
        } else {
            inside_color = texture(Source, input_tex).rgb;
        }
    } else {
        // Render padding (blanking) as black
        inside_color = vec3(0.0);
    }
    vec3 color = inside ? inside_color : vec3(outsideGray);

    // If mask is bypassed, still honor framing but skip mask application
    if (MASK_BYPASS >= 1.0) {
        FragColor = vec4(color, 1.0);
        return;
    }

    // TVL-based unit scaling independent of output resolution
    // 1 TVL = 6 horizontal units (one RGB triad + gaps) in all modes
    // TVL here is defined for the selected frame aspect
    float tvl = max(TVL, 1.0);
    float units_x_total = tvl * 6.0 - 1.0;

    // Vertical units depend on mask type:
    // Aperture: no vertical structure (use minimal for consistency)
    // Slot: 3-unit vertical cycle (simplified slot with gating)
    // Shadow: 4 vertical units per TVL (4-row shadow mask cycle)
    float units_y_total;
    if (MASK_TYPE < 0.5) {
        units_y_total = tvl; // Aperture has no vertical pattern
    } else if (MASK_TYPE < 1.5) {
        units_y_total = tvl / maskAR * 3.0;
    } else {
        units_y_total = tvl / maskAR * 4.5;
    }

    if (MASK_DEBUG_PAD > 0.5) {
        bool is_padding = inside && !in_active;
        if (is_padding) {
            // Padding area: yellow
            color = vec3(0.18, 0.18, 0.0);
        } else if (!inside) {
            // Outside full video frame: gray
            color = vec3(0.18);
        }
        // else: active content, show normally with mask
    }

    float mask_intensity = MASK_INTENSITY * 0.01;
    // Gaussian stripe helper (sigma in pattern units)
    float pixels_per_unit = config.OutputSize.x / units_x_total;
    float sigma = MASK_DIFFUSION * 1.0 / pixels_per_unit;
    vec3 mask_color = compute_mask(vTexCoord, units_x_total, units_y_total, sigma);

    vec3 masked_color = mix(color, color * mask_color, mask_intensity);

    FragColor = vec4(max(masked_color, 0.0), 1.0);
}