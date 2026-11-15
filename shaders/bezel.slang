#version 450

// Filename: bezel.slang
//
// Copyright (C) 2025-2026 W. M. Martinez
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

#pragma name Bezel
#pragma format A2B10G10R10_UNORM_PACK32

#include "common.inc"
#include "color.inc"
#include "digital.inc"
#include "subframe.inc"
#include "texture.inc"

#include "menus/parameters/factory-geometry.inc"
#include "menus/parameters/output-bezel.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_OUTPUT_GAMUT_SELECT
const float OUTPUT_GAMUT_SELECT = OPTION_OUTPUT_GAMUT_SELECT;
#else
const float OUTPUT_GAMUT_SELECT = 0.0;
#endif

#ifdef OPTION_OUTPUT_COLOR_BIT_DEPTH
const float OUTPUT_COLOR_BIT_DEPTH = OPTION_OUTPUT_COLOR_BIT_DEPTH;
#else
const float OUTPUT_COLOR_BIT_DEPTH = 0.0;
#endif

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_BEZEL_HEADER " —— Debug Bezel —— " 0.0 0.0 0.0 0.0
#pragma parameter BEZEL_BYPASS "Bypass bezel" 0.0 0.0 1.0 1.0
#pragma parameter GLOW_BYPASS "Bypass glow" 0.0 0.0 1.0 1.0
#pragma parameter KEY_THRESH "Bezel chroma key threshold" 0.5 0.0 1.0 0.01
#pragma parameter DEBUG_GLOW "Debug glow" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OutputSize;
    vec4 BORDERSize;
    uint FrameCount;
    uint CurrentSubFrame;
    uint TotalSubFrames;
    float VIEWPORT_V_POS;
    float BEZEL_GAIN;
    float BEZEL_BIAS;
    float USE_MIPMAPPING;
    float GLOW_WEIGHT;
    float GLOW_DIFFUSION;
    float GLOW_COMPRESSION;
    float GLOW_FALLOFF;
    float GLOW_DITHER;
    float GLOW_TEMPERATURE;
    float GLOW_RADIUS_PERCENT;
    float EDGE_GUARD_PERCENT;

    float GAMUT_SELECT;
    float COLOR_OUTPUT_BIT_DEPTH;

#ifdef OPTION_DEBUG
    float BEZEL_BYPASS;
    float GLOW_BYPASS;
    float KEY_THRESH;
    float DEBUG_GLOW;
#endif  // OPTION_DEBUG

    float EnableHDR;
} config;

#define VIEWPORT_V_POS config.VIEWPORT_V_POS

#ifdef OPTION_DEBUG
#define BEZEL_BYPASS config.BEZEL_BYPASS
#else
const float BEZEL_BYPASS = 0.0;
#endif  // OPTION_DEBUG

#define BEZEL_GAIN config.BEZEL_GAIN
#define BEZEL_BIAS config.BEZEL_BIAS

#define USE_MIPMAPPING config.USE_MIPMAPPING

#ifdef OPTION_DEBUG
#define GLOW_BYPASS config.GLOW_BYPASS
#else
const float GLOW_BYPASS = 0.0;
#endif  // OPTION_DEBUG

#define GLOW_WEIGHT config.GLOW_WEIGHT
#define GLOW_DIFFUSION config.GLOW_DIFFUSION
#define GLOW_COMPRESSION config.GLOW_COMPRESSION
#define GLOW_FALLOFF config.GLOW_FALLOFF
#define GLOW_TEMPERATURE config.GLOW_TEMPERATURE
#define GLOW_DITHER config.GLOW_DITHER

#ifdef OPTION_DEBUG
#define KEY_THRESH config.KEY_THRESH
#else
const float KEY_THRESH = 0.5;
#endif  // OPTION_DEBUG

#define KEY_SOFT 0.08

#define GLOW_RADIUS_PERCENT config.GLOW_RADIUS_PERCENT
#define EDGE_GUARD_PERCENT config.EDGE_GUARD_PERCENT

#define GLOW_MIN_WEIGHT 0.001

#define EFFECTIVE_GLOW_RADIUS (GLOW_RADIUS_PERCENT * 0.01)

#define GAMUT_SELECT OUTPUT_GAMUT_SELECT
#define COLOR_OUTPUT_BIT_DEPTH OUTPUT_COLOR_BIT_DEPTH

#ifdef OPTION_DEBUG
#define DEBUG_GLOW config.DEBUG_GLOW
#else
const float DEBUG_GLOW = 0.0;
#endif  // OPTION_DEBUG

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float ASPECT;
    float BEZEL_ZOOM;
    float VIEWPORT_H_POS;
} global;
#define ASPECT global.ASPECT
#define VIEWPORT_H_POS global.VIEWPORT_H_POS
#define BEZEL_ZOOM global.BEZEL_ZOOM

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 screen_coord;
layout(location = 2) out float AspectRatio;
layout(location = 3) out vec2 viewport_max_dist; // Precomputed normalization distances for radial falloff
layout(location = 4) out mat3 color_to_xyz;
layout(location = 7) out mat3 xyz_to_color;

/**
 * Vertex shader: Transforms the vertex position and calculates texture coordinates
 * for both the full output and the aspect-corrected screen viewport.
 * Supports independent horizontal and vertical sizing.
 */
void main()
{
    gl_Position = global.MVP * Position;
    vec2 tex = TexCoord.xy; // Unmodified coords for background/border sampling

    // Fit border in display area based on texture to ouput aspect ratio
    float border_dar = config.BORDERSize.x / config.BORDERSize.y;

    // RA has a bug where BORDERSize is not updated when loading presets, so use 16:9 for now
    border_dar = 16.0 / 9.0;
    float output_dar = config.OutputSize.x / config.OutputSize.y;

    vec2 corrected_size;
    vec2 scale;

    // Selected target aspect ratio for framing
    AspectRatio = (ASPECT < 0.5)   ? (4.0 / 3.0)
        : (ASPECT < 1.5) ? (16.0 / 9.0)
        : (ASPECT < 2.5) ? (5.0 / 4.0)
        : (16.0 / 10.0);

    // Letterbox: fit screen inside output area
    if (AspectRatio > output_dar) {
        // Screen is wider than output area: scale down Y
        corrected_size = vec2(config.OutputSize.x, config.OutputSize.x / AspectRatio);
        scale = config.OutputSize.xy / corrected_size;
    } else {
        // Screen is taller than output area: scale down X
        corrected_size = vec2(config.OutputSize.y * AspectRatio, config.OutputSize.y);
        scale = config.OutputSize.xy / corrected_size;
    }

    // Normalize viewport position offsets to texture coordinate space
    float h_shift = (VIEWPORT_H_POS / 100.0) - 0.5;
    float v_shift = (VIEWPORT_V_POS / 100.0) - 0.5;

    // Center the viewport, then apply user shift (in normalized texture space)
    vec2 offset = (1.0 - scale) * 0.5 + vec2(-h_shift, v_shift) * scale;

    // Precompute max outside distances used for radial glow falloff normalization
    vec2 max_dist = vec2(
        max(offset.x / scale.x, (1.0 - offset.x - scale.x) / scale.x),
        max(offset.y / scale.y, (1.0 - offset.y - scale.y) / scale.y)
    );

    tex = tex * scale + offset;

    // Map texture coordinates to the scaled and shifted screen viewport
    // Align to pixel centers to ensure stable sampling
    screen_coord = (floor(tex * config.OutputSize.xy) + 0.5) * config.OutputSize.zw;

    // Mixed technique: fill output area up to viewport
    vec2 final_border_size;

    if (border_dar > AspectRatio) {
        // Border is wider than view area: scale up X to fill viewport
        final_border_size = vec2(corrected_size.y * border_dar, corrected_size.y);
        scale = config.OutputSize.xy / final_border_size;
    } else {
        // Border is taller than view area: scale up Y to fill viewport
        final_border_size = vec2(corrected_size.x, corrected_size.x / border_dar);
        scale = config.OutputSize.xy / final_border_size;
    }

    // Apply bezel zoom
    scale /= (BEZEL_ZOOM / 100.0);

    vTexCoord = (TexCoord.xy - 0.5) * scale + 0.5;

    // Precompute max distances
    viewport_max_dist = abs((final_border_size - corrected_size) * 0.5) * config.OutputSize.zw;

    // Select color conversion matrices based on HDR and gamut settings
    if (config.EnableHDR > 0.5) {
        color_to_xyz = BT2020_TO_XYZ;
        xyz_to_color = XYZ_TO_BT2020;
    } else if (GAMUT_SELECT < 0.5) {
        color_to_xyz = sRGB_TO_XYZ;
        xyz_to_color = XYZ_TO_sRGB;
    } else if (GAMUT_SELECT < 1.5) {
        color_to_xyz = BT2020_TO_XYZ;
        xyz_to_color = XYZ_TO_BT2020;
    } else {
        color_to_xyz = DCIP3_TO_XYZ;
        xyz_to_color = XYZ_TO_DCIP3;
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 screen_coord;
layout(location = 2) in float AspectRatio;
layout(location = 3) in vec2 viewport_max_dist;
layout(location = 4) in mat3 color_to_xyz;
layout(location = 7) in mat3 xyz_to_color;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;
layout(set = 0, binding = 2) uniform sampler2D BORDER;

// Map GLOW_DIFFUSION preset to base diffusion steps
// 0 = Low (8 steps), 1 = Medium (12 steps), 2 = High (16 steps)
int glow_diffusion_steps()
{
    if (GLOW_DIFFUSION < 0.5) {
        if (USE_MIPMAPPING > 0.5)
            return 2;
        return 4;   // Low: performance mode
    } else if (GLOW_DIFFUSION < 1.5) {
        if (USE_MIPMAPPING > 0.5)
            return 4;
        return 8;  // Medium: balanced
    } else {
        if (USE_MIPMAPPING > 0.5)
            return 8;
        return 16;  // High: quality mode
    }
}

/**
 * Apply PQ curve to LMS tristimulus values for ICtCp conversion
 * (Raw PQ without nits scaling - for ICtCp color space)
 */
vec3 lms_apply_pq(vec3 lms)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    vec3 y = pow(max(lms * 0.0001, vec3(0.0)), vec3(m1));
    return pow((c1 + c2 * y) / (1.0 + c3 * y), vec3(m2));
}

/**
 * Remove PQ curve from LMS tristimulus values for ICtCp conversion
 */
vec3 lms_remove_pq(vec3 lms_pq)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    vec3 p = pow(max(lms_pq, vec3(0.0)), vec3(1.0 / m2));
    vec3 y = pow(max(p - c1, vec3(0.0)) / (c2 - c3 * p), vec3(1.0 / m1));
    return y * 10000.0;
}

/**
 * Convert LMS (after PQ) to ICtCp color space
 */
vec3 lms_pq_to_ictcp(vec3 lms_pq)
{
    return vec3(
        dot(vec3(0.5, 0.5, 0.0), lms_pq),
        dot(vec3(1.6137, -3.3234, 1.7097), lms_pq),
        dot(vec3(4.3780, -4.2455, -0.1325), lms_pq)
    );
}

/**
 * Convert ICtCp back to LMS (in PQ space)
 */
vec3 ictcp_to_lms_pq(vec3 ictcp)
{
    return vec3(
        dot(vec3(1.0, 0.00860514, 0.11103560), ictcp),
        dot(vec3(1.0, -0.00860514, -0.11103560), ictcp),
        dot(vec3(1.0, 0.56004885, -0.32063747), ictcp)
    );
}

/**
 * Combined glow color processing: dynamic-range compression + temperature shift.
 * Consolidates color-space conversions so glow is converted back to RGB once.
 *
 * @param color Input color in linear RGB space
 * @param compression Compression amount [0-1]: 0=maximum compression, 1=no compression
 * @param temperature Temperature shift [-0.5 to 0.5]: negative=warmer, positive=cooler
 * @param noise Signed blue-TPDF jitter sample in [-0.5, 0.5]
 * @param noise_power Jitter amplitude scale
 * @return Processed glow color
 */
vec3 process_glow_color(vec3 color, float compression, float temperature, float noise, float noise_power)
{
    float c = clamp(compression, 0.0, 1.0);
    float amount = 1.0 - c;
    float t = clamp(temperature, -0.5, 0.5);
    float dither = max(noise_power, 0.0);

    if (amount <= EPS && abs(t) <= EPS && dither <= EPS)
        return max(color, vec3(0.0));

    vec3 xyz_in = color_to_xyz * color;
    vec3 xyz_base = xyz_in;

    if (amount > EPS || dither > EPS) {
        if (config.EnableHDR > 0.5) {
            // HDR processing path: RGB → XYZ → LMS(PQ) → ICtCp, then back to XYZ
            vec3 lms = XYZ_TO_LMS * xyz_in;
            vec3 lms_pq = lms_apply_pq(lms);
            vec3 ictcp = lms_pq_to_ictcp(lms_pq);

            if (amount > EPS) {
                float intensity_factor = ictcp.x;  // I component (0-1 range after PQ)
                float chroma_scale = mix(0.3, 1.0, c);  // amount inverted: c=1 → scale=1 (no compression)

                if (intensity_factor > 0.5) {
                    float intensity_boost = (intensity_factor - 0.5) * 2.0;
                    chroma_scale *= mix(1.0, 0.4, intensity_boost * (1.0 - c));
                }

                ictcp.y *= chroma_scale;  // Compress Ct (red-green)
                ictcp.z *= chroma_scale;  // Compress Cp (yellow-blue)
            }

            if (dither > EPS)
                ictcp.x = clamp(ictcp.x + noise * dither, 0.0, 1.0);

            vec3 lms_processed = lms_remove_pq(ictcp_to_lms_pq(ictcp));
            xyz_base = LMS_TO_XYZ * lms_processed;
        } else {
            // SDR/WCG processing path: chroma compression + L* dither in CIE Luv
            vec3 luv = XYZ_to_CIE_LUV(xyz_in);

            if (amount > EPS) {
                float intensity_factor = clamp(luv.x, 0.0, 1.0);
                float chroma_scale = mix(0.3, 1.0, c);

                if (intensity_factor > 0.5) {
                    float intensity_boost = (intensity_factor - 0.5) * 2.0;
                    chroma_scale *= mix(1.0, 0.4, intensity_boost * (1.0 - c));
                }

                luv.y *= chroma_scale;
                luv.z *= chroma_scale;
            }

            if (dither > EPS)
                luv.x = clamp(luv.x + noise * dither * 100.0, EPS, 100.0);

            xyz_base = CIE_LUV_to_XYZ(luv);
        }
    }

    if (abs(t) > EPS) {
        vec3 lms = XYZ_TO_LMS * xyz_base;

        // LMS-domain adaptation: positive t cools (boost S), negative t warms (boost L/M)
        vec3 lms_scale = vec3(
            1.0 - t * 0.35,
            1.0 - t * 0.10,
            1.0 + t * 0.55
        );

        vec3 xyz_shifted = LMS_TO_XYZ * (lms * lms_scale);

        // Log-domain luminance normalization using XYZ Y channel
        float original_luma = max(xyz_base.y, EPS);
        float shifted_luma = max(xyz_shifted.y, EPS);
        float gain = exp2(clamp(log2(original_luma) - log2(shifted_luma), -2.0, 2.0));

        xyz_base = xyz_shifted * gain;
    }

    return max(xyz_to_color * xyz_base, vec3(0.0));
}

/**
 * Calculate screen-space LOD for mipmapped texture sampling.
 * Estimates appropriate mipmap level based on sampling radius and output resolution.
 *
 * @param coord Base texture coordinate
 * @param radius Glow radius in texture space
 * @param distance_factor Normalized distance from viewport (0=near, 1=far)
 * @return Estimated LOD level (0-5)
 */
float compute_manual_lod(vec2 coord, float radius, float distance_factor)
{
    const float LOD_FACTOR = 4.0;  // Lower -> more blurred

    // Convert texture-space radius to pixel-space based on output resolution
    float coord_pixel_space = radius * distance_factor * config.OutputSize.y;

    // LOD scales logarithmically with pixel spread
    float lod = log2(max(1.0, coord_pixel_space / LOD_FACTOR));

    return lod;
}

float glow_falloff(float radial_dist)
{
    float x = clamp(radial_dist * GLOW_FALLOFF, 0.0, 1.0);
    return 1.0 - x;
}

int adaptive_glow_steps(int base_steps, float radial_dist)
{
    int clamped_base = max(1, base_steps);
    float quality = 1.0;

    quality = (radial_dist < 0.25)   ? 1.00
              : (radial_dist < 0.50) ? 0.75
              : (radial_dist < 0.75) ? 0.50
                                     : 0.35;

    return max(1, int(floor(float(clamped_base) * quality + 0.5)));
}

// Mirror a continuous UV into [0,1] using mirrored once, robust for negative UVs too
vec2 mirror01(vec2 uv)
{
    vec2 t = mod(uv, 2.0);
    return 1.0 - abs(t - 1.0);
}

// Convenience: safe mirrored sampling
// Adapts edge guard based on effective glow radius to prevent over-clamping at lower resolutions
vec3 sample_mirror_safe(sampler2D tex, vec2 uv, float lod)
{
    uv = clamp(uv, -2.0, 2.0);

    // Margin sign
    vec2 s;

    s.x = uv.x < 0.0 || uv.x > 1.0 ? -1.0 : 1.0;
    s.y = uv.y < 0.0 || uv.y > 1.0 ? -1.0 : 1.0;

    // Shift to normal space
    uv -= vec2(0.5);

    float margin = EDGE_GUARD_PERCENT * 0.01;
    float edge_scale = 1.0 - 2.0 * margin;
    // PERF: avoids per-sample pow(edge_scale, +/-1) in inner glow loops.
    // Keep reciprocal + select form; this reduced hotspot cost measurably.
    float inv_edge_scale = 1.0 / max(edge_scale, EPS);
    vec2 axis_scale = mix(vec2(inv_edge_scale), vec2(edge_scale), step(vec2(0.0), s));

    uv = uv * axis_scale + s * margin;
    uv += vec2(0.5) * axis_scale;
    vec2 m = mirror01(uv);

    return textureLod(tex, m, lod).rgb;
}

/**
 * Calculates a glow effect by sampling surrounding pixels in multiple directions.
 * Uses an 8-directional sampling pattern with configurable diffusion steps.
 * Supports anisotropic scaling and vertical bias for more natural-looking CRT glow.
 *
 * Features:
 * - Multi-step diffusion: samples at varying distances for smooth falloff
 * - Color compression: reduces extreme brightness impact
 *
 * @param coord Base texture coordinate to sample around
 * @param radius Maximum sampling radius in texture space
 * @param diffusion_steps Number of distance steps per direction (higher = smoother)
 * @return Accumulated glow color
 */
vec3 calculate_glow(vec2 coord, float radius, float diffusion_steps, float radial_dist)
{
    // Define 8 cardinal and intercardinal directions (N, NE, E, SE, S, SW, W, NW)
    const vec2 directions[8] = vec2[8](
        vec2(0.0, 1.0),       // North
        vec2(0.707, 0.707),   // Northeast
        vec2(1.0, 0.0),       // East
        vec2(0.707, -0.707),  // Southeast
        vec2(0.0, -1.0),      // South
        vec2(-0.707, -0.707), // Southwest
        vec2(-1.0, 0.0),      // West
        vec2(-0.707, 0.707)   // Northwest
    );

    vec3 glow = vec3(0.0);
    float total_weight = 0.0;
    int num_steps = adaptive_glow_steps(int(diffusion_steps), radial_dist);

    // Sample in each direction with multiple distance steps for smooth diffusion
    for (int step = 1; step <= num_steps; step++) {
        float distance_factor = float(step) / float(num_steps);

        // Closer samples contribute more (linear falloff)
        float diffusion_weight = 1.0 - (distance_factor - 1.0 / float(num_steps));

        // PERF: split accumulation into two independent chains to reduce
        // loop-carried dependency stalls seen on glow += sample * weight.
        vec3 glow_a = vec3(0.0);
        vec3 glow_b = vec3(0.0);

        for (int i = 0; i < 4; i++) {
            vec2 dir = directions[i];

            // Calculate sample offset with distance scaling
            float step_radius = radius * distance_factor;
            vec2 offset = dir * step_radius;

            // Sample source color
            vec3 sample_linear = sample_mirror_safe(Source, coord + offset, 0.0);

            glow_a += sample_linear * diffusion_weight;
        }

        for (int i = 4; i < 8; i++) {
            vec2 dir = directions[i];

            // Calculate sample offset with distance scaling
            float step_radius = radius * distance_factor;
            vec2 offset = dir * step_radius;

            // Sample source color
            vec3 sample_linear = sample_mirror_safe(Source, coord + offset, 0.0);

            glow_b += sample_linear * diffusion_weight;
        }

        glow += glow_a + glow_b;
        // PERF: one update per step instead of per tap lowers scalar pressure.
        total_weight += 8.0 * diffusion_weight;
    }

    // Normalize to maintain consistent brightness regardless of sample count
    if (total_weight > 0.0)
        glow /= total_weight;

    return max(glow, vec3(0.0));
}

/**
 * MIPMAPPED VARIANT: Calculates glow with LOD-based texture sampling.
 * Uses mipmaps for distant samples to reduce memory bandwidth and aliasing.
 * This path is optimized for backends with proper mipmap support (GL, Vulkan).
 *
 * Key differences from base calculate_glow():
 * - Uses textureLod() instead of texture() for explicit LOD control
 * - LOD increases with distance: near=LOD0 (sharp), far=LOD2-3 (blurred)
 * - Edge guard softness scales with LOD to prevent harsh transitions
 *
 * @param coord Base texture coordinate
 * @param radius Glow radius in texture space
 * @param diffusion_steps Number of distance steps per direction
 * @param radial_dist Normalized distance from viewport (for adaptive sampling)
 * @return Accumulated glow color
 */
vec3 calculate_glow_mipmapped(vec2 coord, float radius, float diffusion_steps, float radial_dist)
{
    // Define 8 cardinal and intercardinal directions
    const vec2 directions[8] = vec2[8](
        vec2(0.0, 1.0),       // North
        vec2(0.707, 0.707),   // Northeast
        vec2(1.0, 0.0),       // East
        vec2(0.707, -0.707),  // Southeast
        vec2(0.0, -1.0),      // South
        vec2(-0.707, -0.707), // Southwest
        vec2(-1.0, 0.0),      // West
        vec2(-0.707, 0.707)   // Northwest
    );

    vec3 glow = vec3(0.0);
    float total_weight = 0.0;
    int num_steps = adaptive_glow_steps(int(diffusion_steps), radial_dist);

    // Sample in each direction with multiple distance steps
    for (int step = 1; step <= num_steps; step++) {
        float distance_factor = float(step) / float(num_steps);
        float diffusion_weight = 1.0 - (distance_factor - 1.0 / float(num_steps));

        // Compute LOD for this distance step
        float step_lod = compute_manual_lod(coord, radius, distance_factor);

        // PERF: same dual-accumulator strategy as non-mip path.
        vec3 glow_a = vec3(0.0);
        vec3 glow_b = vec3(0.0);

        for (int i = 0; i < 4; i++) {
            vec2 dir = directions[i];

            // Calculate sample offset with distance scaling
            float step_radius = radius * distance_factor;
            vec2 offset = dir * step_radius;

            // Sample with explicit LOD
            vec3 sample_linear = sample_mirror_safe(Source, coord + offset, step_lod);

            glow_a += sample_linear * diffusion_weight;
        }

        for (int i = 4; i < 8; i++) {
            vec2 dir = directions[i];

            // Calculate sample offset with distance scaling
            float step_radius = radius * distance_factor;
            vec2 offset = dir * step_radius;

            // Sample with explicit LOD
            vec3 sample_linear = sample_mirror_safe(Source, coord + offset, step_lod);

            glow_b += sample_linear * diffusion_weight;
        }

        glow += glow_a + glow_b;
        // PERF: aggregate once per step, not once per sample tap.
        total_weight += 8.0 * diffusion_weight;
    }

    if (total_weight > 0.0)
        glow /= total_weight;

    return max(glow, vec3(0.0));
}

void write_output_color(vec3 linear, uint frame)
{
    const int WORKING_BITS = 16;

    if (config.EnableHDR > 0.5) {
        // PQ output: SMPTE ST.2084 encoding for HDR10
        vec3 hdr_pq = pq(linear);
        hdr_pq = apply_dither_blue(hdr_pq, WORKING_BITS, 10, vTexCoord * config.OutputSize.xy, frame);
        FragColor = vec4(clamp(hdr_pq, 0.0, 1.0), 1.0);
    } else {
        // SDR WCG output: apply CRT gamma directly to linear RGB
        vec3 final_gamma = crt_gamma(clamp(linear, 0.0, 1.0));
        int output_bits = 8 + 2 * int(COLOR_OUTPUT_BIT_DEPTH);
        final_gamma = apply_dither_blue(final_gamma, WORKING_BITS, output_bits, vTexCoord * config.OutputSize.xy, frame);
        FragColor = vec4(clamp(final_gamma, 0.0, 1.0), 1.0);
    }

}

/**
 * Fragment shader: Composites the CRT screen with bezel/background and glow effect.
 *
 * Pipeline:
 * 1. Sample screen content (with viewport bounds checking)
 * 2. If bypass is enabled, return screen content directly
 * 3. Sample background/bezel texture
 * 4. Calculate glow effect from screen content
 * 5. Process glow color (compression + temperature) in a single pass
 * 6. Apply radial falloff to glow based on distance from viewport
 * 7. Blend glow with background
 * 8. Composite screen over glowing background
 */
void main()
{
    // Sample the main CRT screen content with smooth edge guard
    vec4 screen = vec4(texture(Source, screen_coord).rgb, 1.0);
    screen.rgb = screen.rgb;
    screen.a = 1.0; // Ensure opaque screen

    uint frame = temporal_frame_index(
        config.FrameCount,
        config.CurrentSubFrame,
        config.TotalSubFrames);

#ifdef OPTION_NOBEZEL
    write_output_color(screen.rgb, frame);
    return;
#endif  // OPTION_NOBEZEL

#ifdef OPTION_DEBUG
    // Bypass mode: pass through screen content without bezel/glow processing
    if (BEZEL_BYPASS > 0.5) {
        write_output_color(screen.rgb, frame);
        return;
    }
#endif  // OPTION_DEBUG

    vec3 glow;
    float effective_glow_weight;

    // Sample background/bezel texture with pixel-aligned sampling
    vec2 border_size = vec2(textureSize(BORDER, 0));
    vec2 uv = floor(vTexCoord * border_size) + 0.5; // Align to pixel centers;
    vec2 tex = uv / border_size;
    vec4 background = texture(BORDER, tex);

#ifdef OPTION_NOGLOW
#else
    // PERF: keep this early to hide BORDER texture latency before alpha-key use.
    float radius = EFFECTIVE_GLOW_RADIUS;
    float radial_dist = length(screen_coord - clamp(screen_coord, vec2(0.0), vec2(1.0))) / max(length(viewport_max_dist), EPS);
    float falloff = glow_falloff(radial_dist);
    float base_glow_weight = GLOW_WEIGHT * falloff;
    int diffusion_steps = glow_diffusion_steps();
#endif  // OPTION_NOGLOW

    // Color key against green to create transparency in bezel when JPEG is used
    // Smooth chroma key: alpha is 0 for pure green, 1 for non-green, smooth in between
    float key_dist = distance(background.rgb, vec3(0.0, 1.0, 0.0));
    float key_alpha = smoothstep(KEY_THRESH, KEY_THRESH + KEY_SOFT, key_dist);
    float key_enable = step(1.0 - EPS, background.a);
    background.a *= mix(1.0, key_alpha, key_enable);

    // Convert after keying so the BORDER texture read has more time to retire.
    vec3 background_linear = srgb_linear(background.rgb);

#ifdef OPTION_NOGLOW
    glow = vec3(0.0);
    effective_glow_weight = 0.0;
#else  // OPTION_NOGLOW
    // === GLOW_BYPASS implementation ===
    if (GLOW_BYPASS > 0.5 || background.a < EPS) {
        glow = vec3(0.0);
        effective_glow_weight = 0.0;
    } else {
        effective_glow_weight = base_glow_weight;

        if (effective_glow_weight > GLOW_MIN_WEIGHT) {
            if (USE_MIPMAPPING > 0.5) {
                // Use mipmapped variant for reduced bandwidth and better quality at distance
                glow = calculate_glow_mipmapped(screen_coord, radius, float(diffusion_steps), radial_dist);
            } else {
                // Standard multi-sample glow (Phase 1 optimization)
                glow = calculate_glow(screen_coord, radius, float(diffusion_steps), radial_dist);
            }

            // Combined glow color processing: compression + temperature shift
            // Apply selected dither in perceptual space before converting back to RGB.
            float noise = tpdf_blue_noise(screen_coord * config.OutputSize.xy, frame);
            float noise_power = db_to_linear_power(GLOW_DITHER);

            glow = process_glow_color(glow, GLOW_COMPRESSION, GLOW_TEMPERATURE, noise, noise_power);

            // Clamp glow to prevent negative values before tonemapping
            glow = max(glow, vec3(0.0));
        } else {
            glow = vec3(0.0);
        }
    }
#endif  // OPTION_NOGLOW

    // === Blend glow with background ===
    // Apply bezel gain and bias first
    float bezel_gain = db_to_linear(BEZEL_GAIN);
    float bezel_bias = BEZEL_BIAS / 100.0;
    vec3 background_adjusted = (background_linear + bezel_bias) * bezel_gain;

    if (DEBUG_GLOW > 0.5) {
        background_adjusted = WHITE;
    }

    // Blend background with glow
    background_adjusted = mix(background_adjusted, background_adjusted * glow, effective_glow_weight);

    // Final composite: transparent over opaque composite
    vec3 screen_linear = screen.rgb;
    vec3 final_linear = mix(screen_linear, background_adjusted, background.a);

    write_output_color(final_linear, frame);
}
