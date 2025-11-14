#version 450

// Filename: crt-mask.slang
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
// CRT Shadow Mask
// ------------------------------------------------
// Input: Linear RGB signal
// Output: Linear RGB signal with aperture grille mask applied

#include "common.inc"
#include "filter.h"

#include "parameters/mask.inc"

#pragma name CRTMask
#pragma format R16G16B16A16_SFLOAT

#pragma parameter MASK_BYPASS "Bypass CRT mask" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 SourceSize;     // xy = input size in pixels
    vec4 OriginalSize;   // xy = input size in pixels
    vec4 OutputSize;     // xy = output size in pixels
    float OriginalAspect;
    float MASK_BYPASS;
    float MASK_TYPE;
    float MASK_INTENSITY;
    float MASK_MONOCHROME;
    float TVL;
    float BEAM_FOCUS;
    float V_LINES_PER_FIELD;
    float MASK_DIFFUSION;
    float X_OFFSET;
    float Y_OFFSET;
} config;

#define MASK_BYPASS config.MASK_BYPASS
#define MASK_TYPE config.MASK_TYPE
#define MASK_INTENSITY config.MASK_INTENSITY
#define MASK_MONOCHROME config.MASK_MONOCHROME
#define TVL config.TVL
#define BEAM_FOCUS config.BEAM_FOCUS
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define MASK_DIFFUSION config.MASK_DIFFUSION

#pragma parameter X_OFFSET "Horizontal Mask Offset" 0.0 -3.0 3.0 0.1
#pragma parameter Y_OFFSET "Vertical Mask Offset" 0.0 -3.0 3.0 0.1
#define X_OFFSET config.X_OFFSET
#define Y_OFFSET config.Y_OFFSET

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

layout(std140, set = 0, binding = 0) uniform UBO {
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
layout(set = 0, binding = 1) uniform sampler2D Source;

// Cyclic distance on a ring of length `period`
// Returns shortest wrapped distance between x and center.
float cyclicDist(float x, float center, float period)
{
    float d = abs(x - center);
    return min(d, period - d);
}

void main()
{
    // Bicubic resample from input texture using BEAM_FOCUS
    float focus = clamp(BEAM_FOCUS * 0.01, 0.0, 1.0);
    float C = -1.0 / 3.0 * focus * focus + 5.0 / 6.0 * focus;
    float B = 1.0 - 2.0 * C;
    vec3 color = sample_bicubic(
        Source,
        vTexCoord,
        1.0 / config.SourceSize.xy,
        B,
        C);

    // Early exit for full bypass
    if (MASK_BYPASS >= 1.0) {
        FragColor = vec4(color, 1.0);
        return;
    }

    // Determine PAR (pixel aspect ratio)
    float dar = config.OriginalAspect;
    float sar = config.OutputSize.x / max(config.OutputSize.y, EPS);
    float par = dar / max(sar, EPS);

    // TVL-based unit scaling independent of output resolution
    // 1 TVL = 6 horizontal units (one RGB triad + gaps) in all modes
    float tvl = max(TVL, 1.0);
    float units_x_total = tvl * 6.0 - 1.0;  // Subtract 1.0 for final dot edge
    
    // Vertical units depend on mask type:
    // Aperture: no vertical structure (use minimal for consistency)
    // Slot: 3-unit vertical cycle (simplified slot with gating)
    // Shadow: 4 vertical units per TVL (4-row shadow mask cycle)
    float units_y_total;
    if (MASK_TYPE < 0.5) {
        units_y_total = tvl; // Aperture has no vertical pattern
    } else if (MASK_TYPE < 1.5) {
        // Each cell is 6 units wide by 3 units high: 6 / 3 = 2
        float cell_ar = 2.0 / par;
        float cell_par = 1.0 / cell_ar;
        units_y_total = tvl / cell_par;
    } else {
        // Each cell is 6 units wide by 4 units high: 6 / 4 = 1.5
        float cell_ar = 1.5 / par;
        float cell_par = 1.0 / cell_ar;
        units_y_total = tvl / cell_par;
    }

    // Continuous unit coordinates for smooth Gaussian weighting
    float x_units = vTexCoord.x * units_x_total;
    float y_units = vTexCoord.y * units_y_total;

    float mask_intensity = MASK_INTENSITY * 0.01;

    vec3 mask_color;

    // Gaussian stripe helper (sigma in pattern units)
    float sigma = max(MASK_DIFFUSION, 1e-5);

    // Horizontal centers aligned to left-edge origin (R starts at [0,1])
    float cycle = mod(x_units - 0.4, 6.0);

    // Use cyclic distances so weights are seamless across the 6-unit wrap
    float dr = cyclicDist(cycle, 0.0, 6.0);
    float dg = cyclicDist(cycle, 2.0, 6.0);
    float db = cyclicDist(cycle, 4.0, 6.0);

    float gauss_r = exp(-0.5 * dr*dr / (sigma*sigma));
    float gauss_g = exp(-0.5 * dg*dg / (sigma*sigma));
    float gauss_b = exp(-0.5 * db*db / (sigma*sigma));

    if (MASK_TYPE < 0.5) {
        // Aperture grille: seamless by cyclic Gaussian distances
        mask_color = vec3(gauss_r, gauss_g, gauss_b);
        float peak = max(mask_color.r, max(mask_color.g, mask_color.b));
        if (peak > 1.0)
            mask_color /= peak;
    } else if (MASK_TYPE < 1.5) {
        // Slot mask: 3-unit vertical cycle with periodic black row suppression
        float cycle_y = mod(y_units + 1.0, 3.0);

        // Horizontal position in 6-unit blocks (continuous)
        float blockF = x_units / 6.0;

        // Position within a 3-block cycle [0, 3)
        float block3 = mod(blockF, 3.0);

        // Horizontal blend width (tied to feather for consistency)
        float sigma_h = sigma;

        // Three candidate black rows for blocks 0, 1, 2 in the 3-block cycle
        int base = int(floor(blockF / 3.0)) * 3;
        int b0 = (base + 0) % 3;
        int b1 = (base + 1) % 3;
        int b2 = (base + 2) % 3;

        // Cyclic distance to three block centers on a 3.0-period ring
        // Empirically aligned centers: -0.6, 0.4, 1.4
        float d0 = cyclicDist(block3, -0.6, 3.0);
        float d1 = cyclicDist(block3,  0.4, 3.0);
        float d2 = cyclicDist(block3,  1.4, 3.0);

        // Gaussian weights per block (do NOT normalize — match shadow behavior)
        float w0 = exp(-0.5 * d0*d0 / (sigma_h*sigma_h));
        float w1 = exp(-0.5 * d1*d1 / (sigma_h*sigma_h));
        float w2 = exp(-0.5 * d2*d2 / (sigma_h*sigma_h));

        // Vertical gating using cyclic distance on 3-unit ring
        float sigma_v = sigma * 0.65;
        float gate_0 = 1.0 - exp(-0.5 * (cyclicDist(cycle_y, float(b0), 3.0) / sigma_v) *
                                        (cyclicDist(cycle_y, float(b0), 3.0) / sigma_v));
        float gate_1 = 1.0 - exp(-0.5 * (cyclicDist(cycle_y, float(b1), 3.0) / sigma_v) *
                                        (cyclicDist(cycle_y, float(b1), 3.0) / sigma_v));
        float gate_2 = 1.0 - exp(-0.5 * (cyclicDist(cycle_y, float(b2), 3.0) / sigma_v) *
                                        (cyclicDist(cycle_y, float(b2), 3.0) / sigma_v));

        // Blend gates by horizontal weights (no normalization, like shadow’s vertical blend)
        float gate = w0 * gate_0 + w1 * gate_1 + w2 * gate_2;

        // RGB stripe pattern from horizontal Gaussians
        vec3 rgb = vec3(gauss_r, gauss_g, gauss_b);
        float peak_rgb = max(rgb.r, max(rgb.g, rgb.b));
        if (peak_rgb > 1.0) rgb /= peak_rgb;

        // Match shadow mask normalization: clamp the final blended result to peak 1
        vec3 out_rgb = rgb * gate;
        float peak_out = max(out_rgb.r, max(out_rgb.g, out_rgb.b));
        if (peak_out > 1.0) out_rgb /= peak_out;

        mask_color = out_rgb;
    } else {
        // Shadow mask (4-row cycle). Two lit rows with a 1-row black gap between:
        // Row 0 centers: R0 G2 B4
        // Row 2 centers: B1 R3 G5
        // Rows 1 and 3 are blank. Blend lit rows smoothly in vertical unit space.

        // Vertical cyclic coordinate with top-edge origin so row centers lie at 0.5 and 2.5
        float vcycle = mod(y_units - 0.4, 4.0);

        // Vertical sigma (slightly smaller than horizontal to keep dots crisp)
        float sigma_v = max(0.08, sigma * 0.65);

        // Vertical weights for the two lit rows (use cyclic distance on 4-unit ring)
        float w0 = exp(-0.5 * (cyclicDist(vcycle, 0.5, 4.0) / sigma_v) *
                               (cyclicDist(vcycle, 0.5, 4.0) / sigma_v)); // row 0
        float w2 = exp(-0.5 * (cyclicDist(vcycle, 2.5, 4.0) / sigma_v) *
                               (cyclicDist(vcycle, 2.5, 4.0) / sigma_v)); // row 2

        // Row 0 horizontal RGB weights (R0,G2,B4)
        float dR0 = cyclicDist(cycle, 0.0, 6.0);
        float dG0 = cyclicDist(cycle, 2.0, 6.0);
        float dB0 = cyclicDist(cycle, 4.0, 6.0);
        vec3 rgb0 = vec3(
            exp(-0.5 * dR0*dR0 / (sigma*sigma)),
            exp(-0.5 * dG0*dG0 / (sigma*sigma)),
            exp(-0.5 * dB0*dB0 / (sigma*sigma))
        );

        // Row 2 horizontal RGB weights (B1,R3,G5) — 1-unit shift
        float dB2 = cyclicDist(cycle, 1.0, 6.0);
        float dR2 = cyclicDist(cycle, 3.0, 6.0);
        float dG2 = cyclicDist(cycle, 5.0, 6.0);
        vec3 rgb2 = vec3(
            exp(-0.5 * dR2*dR2 / (sigma*sigma)),
            exp(-0.5 * dG2*dG2 / (sigma*sigma)),
            exp(-0.5 * dB2*dB2 / (sigma*sigma))
        );

        // Blend lit rows by vertical weights; rows 1 and 3 end up dark naturally
        vec3 rgb = w0 * rgb0 + w2 * rgb2;

        // Optional peak clamp to avoid overbright when both rows overlap slightly
        float peak = max(rgb.r, max(rgb.g, rgb.b));
        if (peak > 1.0)
            rgb /= peak;
        mask_color = rgb;
    }

    // Optional monochrome override with smooth Gaussian-based transition
    if (MASK_MONOCHROME > 0.5) {
        float nb = max(mask_color.r, max(mask_color.g, mask_color.b));
        // Use a wider, gentler curve that respects the Gaussian feathering
        // Map the [0,1] range more smoothly, preserving soft gradients
        float mono = nb * nb * (3.0 - 2.0 * nb); // Hermite smoothstep curve
        // Alternative: exponential soft threshold
        // float mono = 1.0 - exp(-3.0 * nb);
        mask_color = vec3(mono);
    }

    vec3 masked_color = mix(color, color * mask_color, mask_intensity);
    FragColor = vec4(crt_gamma(masked_color), 1.0);
}
