#version 450

// Filename: mask.slang
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
// CRT mask simulation
// ------------------------------------------------
// Input: Linear YrYgYb signal
// Output: Linear YrYgYb signal

#include "common.inc"
#include "color.inc"
#include "tools/zebra.inc"

#include "menus/parameters/mask.inc"
#include "menus/parameters/user-common.inc"
#include "menus/parameters/user-uncommon.inc"
#include "menus/parameters/colorimetry.inc"

#pragma name CRTMask
#pragma format R16G16B16A16_SFLOAT

#pragma parameter MASK_BYPASS "Bypass CRT mask" 0.0 0.0 1.0 1.0
#pragma parameter MASK_FRAME_DEBUG "Mask frame debug (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#pragma parameter MASK_DEBUG_OUT_OF_RANGE "Beam-mask: Show out-of-range colors" 0.0 0.0 1.0 1.0

layout(push_constant) uniform Push
{
    vec4 OutputSize;     // xy = output size in pixels
    uint FrameCount;
    float ASPECT;
    float MASK_FRAME_DEBUG;
    float MASK_BYPASS;
    float MASK_TYPE;
    float MASK_INTENSITY;
    float TVL;
    float MASK_DIFFUSION;
    float MASK_DEBUG_OUT_OF_RANGE;
    float USER_PICTURE;
    float USER_BRIGHTNESS;
    float R_X;
    float R_Y;
    float G_X;
    float G_Y;
    float B_X;
    float B_Y;
    float W_X;
    float W_Y;
    float COLORIMETRY_PRESET;
} config;

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
} global;

#define ASPECT config.ASPECT
#define MASK_FRAME_DEBUG config.MASK_FRAME_DEBUG
#define MASK_BYPASS config.MASK_BYPASS
#define MASK_TYPE config.MASK_TYPE
#define MASK_INTENSITY config.MASK_INTENSITY
#define TVL config.TVL
#define MASK_DIFFUSION config.MASK_DIFFUSION
#define MASK_DEBUG_OUT_OF_RANGE config.MASK_DEBUG_OUT_OF_RANGE
#define USER_PICTURE config.USER_PICTURE
#define USER_BRIGHTNESS config.USER_BRIGHTNESS
#define COLORIMETRY_PRESET config.COLORIMETRY_PRESET
#define R_X config.R_X
#define R_Y config.R_Y
#define G_X config.G_X
#define G_Y config.G_Y
#define B_X config.B_X
#define B_Y config.B_Y
#define W_X config.W_X
#define W_Y config.W_Y

// Cyclic distance on a ring of length `period`
// Returns shortest wrapped distance between x and center.
float cyclicDist(float x, float center, float period)
{
    float d = abs(x - center);
    return min(d, period - d);
}

// ---- Mask computation with numerical integration for anti-aliasing ----
// Numerically integrate Gaussian stripe contributions across pixel extent
// Uses multiple sample points to average the Gaussian values within the pixel
vec3 integrate_aperture_grille_numerical(float x_min, float x_max, float sigma_x, int samples)
{
    vec3 sum = vec3(0.0);
    float step = (x_max - x_min) / float(samples);

    for (int i = 0; i < samples; ++i) {
        float x = x_min + (float(i) + 0.5) * step;

        // Evaluate Gaussian at each RGB stripe center (0, 2, 4 in 6-unit cycle)
        float dr = cyclicDist(mod(x - 0.5, 6.0), 0.0, 6.0);
        float dg = cyclicDist(mod(x - 0.5, 6.0), 2.0, 6.0);
        float db = cyclicDist(mod(x - 0.5, 6.0), 4.0, 6.0);

        sum.r += exp(-0.5 * dr*dr / (sigma_x*sigma_x));
        sum.g += exp(-0.5 * dg*dg / (sigma_x*sigma_x));
        sum.b += exp(-0.5 * db*db / (sigma_x*sigma_x));
    }

    return sum / float(samples);
}

// 2D numerical integration for slot mask (18-unit horizontal, 3-unit vertical cycle)
vec3 integrate_slot_mask_numerical(
    float x_min, float x_max, float y_min, float y_max,
    float sigma_x, float sigma_v,
    int samples_x, int samples_y)
{
    // Vertical weights at sample points (slot mask has 3-unit vertical cycle)
    vec3 v_weights = vec3(0.0);
    float step_y = (y_max - y_min) / float(samples_y);

    for (int j = 0; j < samples_y; ++j) {
        float y = y_min + (float(j) + 0.5) * step_y;
        float vc = mod(y - 0.5, 3.0);

        float w0 = exp(-0.5 * pow(cyclicDist(vc, 0.0, 3.0), 2.0) / (sigma_v * sigma_v));
        float w1 = exp(-0.5 * pow(cyclicDist(vc, 1.0, 3.0), 2.0) / (sigma_v * sigma_v));
        float w2 = exp(-0.5 * pow(cyclicDist(vc, 2.0, 3.0), 2.0) / (sigma_v * sigma_v));

        v_weights += vec3(w0, w1, w2);
    }
    v_weights /= float(samples_y);

    // Horizontal integration for each vertical row pattern (18-unit cycle)
    float step_x = (x_max - x_min) / float(samples_x);
    vec3 row0 = vec3(0.0), row1 = vec3(0.0), row2 = vec3(0.0);

    for (int i = 0; i < samples_x; ++i) {
        float x = x_min + (float(i) + 0.5) * step_x;
        float cycle = mod(x - 0.5, 18.0);

        // Row 0: RGB at 6, 8, 10 and 12, 14, 16
        vec2 dR0 = vec2(cyclicDist(cycle, 6.0, 18.0), cyclicDist(cycle, 12.0, 18.0));
        vec2 dG0 = vec2(cyclicDist(cycle, 8.0, 18.0), cyclicDist(cycle, 14.0, 18.0));
        vec2 dB0 = vec2(cyclicDist(cycle, 10.0, 18.0), cyclicDist(cycle, 16.0, 18.0));

        row0 += vec3(
            exp(-0.5 * dR0.x * dR0.x / (sigma_x * sigma_x)) + exp(-0.5 * dR0.y * dR0.y / (sigma_x * sigma_x)),
            exp(-0.5 * dG0.x * dG0.x / (sigma_x * sigma_x)) + exp(-0.5 * dG0.y * dG0.y / (sigma_x * sigma_x)),
            exp(-0.5 * dB0.x * dB0.x / (sigma_x * sigma_x)) + exp(-0.5 * dB0.y * dB0.y / (sigma_x * sigma_x))
        );

        // Row 1: RGB at 0, 2, 4 and 12, 14, 16
        vec2 dR1 = vec2(cyclicDist(cycle, 0.0, 18.0), cyclicDist(cycle, 12.0, 18.0));
        vec2 dG1 = vec2(cyclicDist(cycle, 2.0, 18.0), cyclicDist(cycle, 14.0, 18.0));
        vec2 dB1 = vec2(cyclicDist(cycle, 4.0, 18.0), cyclicDist(cycle, 16.0, 18.0));

        row1 += vec3(
            exp(-0.5 * dR1.x * dR1.x / (sigma_x * sigma_x)) + exp(-0.5 * dR1.y * dR1.y / (sigma_x * sigma_x)),
            exp(-0.5 * dG1.x * dG1.x / (sigma_x * sigma_x)) + exp(-0.5 * dG1.y * dG1.y / (sigma_x * sigma_x)),
            exp(-0.5 * dB1.x * dB1.x / (sigma_x * sigma_x)) + exp(-0.5 * dB1.y * dB1.y / (sigma_x * sigma_x))
        );

        // Row 2: RGB at 0, 2, 4 and 6, 8, 10
        vec2 dR2 = vec2(cyclicDist(cycle, 0.0, 18.0), cyclicDist(cycle, 6.0, 18.0));
        vec2 dG2 = vec2(cyclicDist(cycle, 2.0, 18.0), cyclicDist(cycle, 8.0, 18.0));
        vec2 dB2 = vec2(cyclicDist(cycle, 4.0, 18.0), cyclicDist(cycle, 10.0, 18.0));

        row2 += vec3(
            exp(-0.5 * dR2.x * dR2.x / (sigma_x * sigma_x)) + exp(-0.5 * dR2.y * dR2.y / (sigma_x * sigma_x)),
            exp(-0.5 * dG2.x * dG2.x / (sigma_x * sigma_x)) + exp(-0.5 * dG2.y * dG2.y / (sigma_x * sigma_x)),
            exp(-0.5 * dB2.x * dB2.x / (sigma_x * sigma_x)) + exp(-0.5 * dB2.y * dB2.y / (sigma_x * sigma_x))
        );
    }

    row0 /= float(samples_x);
    row1 /= float(samples_x);
    row2 /= float(samples_x);

    // Combine: weighted average of rows
    return v_weights.x * row0 + v_weights.y * row1 + v_weights.z * row2;
}

// 2D numerical integration for shadow mask (6-unit horizontal, 4-unit vertical cycle)
vec3 integrate_shadow_mask_numerical(
    float x_min, float x_max, float y_min, float y_max,
    float sigma_x, float sigma_y,
    int samples_x, int samples_y)
{
    // Shadow mask: 6-unit horizontal, 4-unit vertical cycle
    // Two rows: row 0 at y=0 (RGB at x=0,2,4), row 2 at y=2 (BRG at x=1,3,5)

    // Vertical weights
    vec2 v_weights = vec2(0.0);
    float step_y = (y_max - y_min) / float(samples_y);

    for (int j = 0; j < samples_y; ++j) {
        float y = y_min + (float(j) + 0.5) * step_y;
        float vc = mod(y - 1.0, 4.0);

        float w0 = exp(-0.5 * pow(cyclicDist(vc, 0.0, 4.0), 2.0) / (sigma_y * sigma_y));
        float w2 = exp(-0.5 * pow(cyclicDist(vc, 2.0, 4.0), 2.0) / (sigma_y * sigma_y));

        v_weights += vec2(w0, w2);
    }
    v_weights /= float(samples_y);

    // Horizontal integration
    float step_x = (x_max - x_min) / float(samples_x);
    vec3 row0 = vec3(0.0), row2 = vec3(0.0);

    for (int i = 0; i < samples_x; ++i) {
        float x = x_min + (float(i) + 0.5) * step_x;
        float cycle = mod(x - 0.5, 6.0);

        // Row 0: R=0, G=2, B=4
        float dR0 = cyclicDist(cycle, 0.0, 6.0);
        float dG0 = cyclicDist(cycle, 2.0, 6.0);
        float dB0 = cyclicDist(cycle, 4.0, 6.0);

        row0 += vec3(
            exp(-0.5 * dR0*dR0 / (sigma_x*sigma_x)),
            exp(-0.5 * dG0*dG0 / (sigma_x*sigma_x)),
            exp(-0.5 * dB0*dB0 / (sigma_x*sigma_x))
        );

        // Row 2: B=1, R=3, G=5
        float dB2 = cyclicDist(cycle, 1.0, 6.0);
        float dR2 = cyclicDist(cycle, 3.0, 6.0);
        float dG2 = cyclicDist(cycle, 5.0, 6.0);

        row2 += vec3(
            exp(-0.5 * dR2*dR2 / (sigma_x*sigma_x)),
            exp(-0.5 * dG2*dG2 / (sigma_x*sigma_x)),
            exp(-0.5 * dB2*dB2 / (sigma_x*sigma_x))
        );
    }

    row0 /= float(samples_x);
    row2 /= float(samples_x);

    return v_weights.x * row0 + v_weights.y * row2;
}

// Compute mask with analytical anti-aliasing when pixels_per_unit < threshold
vec3 compute_mask(vec2 screen_uv, float units_x_total, float units_y_total, vec2 pixels_per_unit)
{
    vec2 sigma = vec2(MASK_DIFFUSION);

    // Scale sigma for Shadow Mask
    if (MASK_TYPE >= 1.5) {
        sigma *= 0.625;
    }

    // Continuous unit coordinates for smooth Gaussian weighting
    float x_units = screen_uv.x * units_x_total;
    float y_units = screen_uv.y * units_y_total;

    // Three-case resolution handling:
    // Case 1: pixels_per_unit >= 1.0 -> Point sampling (sufficient resolution)
    // Case 2: 1/3 <= pixels_per_unit < 1.0 -> Numerical integration (anti-aliasing)
    // Case 3: pixels_per_unit < 1/3 -> Passthrough (pattern nearly unresolvable)
    const float INTEGRATION_THRESHOLD = 1.0;
    const float PASSTHROUGH_THRESHOLD = 1.0 / 3.0;

    bool use_integration_x = (pixels_per_unit.x >= PASSTHROUGH_THRESHOLD &&
                              pixels_per_unit.x < INTEGRATION_THRESHOLD);
    bool use_integration_y = (pixels_per_unit.y >= PASSTHROUGH_THRESHOLD &&
                              pixels_per_unit.y < INTEGRATION_THRESHOLD);
    bool passthrough_x = pixels_per_unit.x < PASSTHROUGH_THRESHOLD;
    bool passthrough_y = pixels_per_unit.y < PASSTHROUGH_THRESHOLD;

    // Pixel extent in unit space
    float pixel_width_units = 1.0 / max(pixels_per_unit.x, EPS);
    float pixel_height_units = 1.0 / max(pixels_per_unit.y, EPS);

    // Pixel bounds in unit space (centered on current position)
    float x_min = x_units - pixel_width_units * 0.5;
    float x_max = x_units + pixel_width_units * 0.5;
    float y_min = y_units - pixel_height_units * 0.5;
    float y_max = y_units + pixel_height_units * 0.5;

    vec3 mask_color;

    if (MASK_TYPE < 0.5) {
        // Aperture grille (6-unit horizontal cycle, R G B at 0, 2, 4)

        if (passthrough_x) {
            // Case 3: Resolution too low, disable mask
            mask_color = vec3(1.0);
        } else if (use_integration_x) {
            // Case 2: Numerical integration with adaptive sample count
            // Use more samples when pixel spans more units
            int samples = int(clamp(pixel_width_units * 6.0, 6.0, 24.0));
            mask_color = integrate_aperture_grille_numerical(x_min, x_max, sigma.x, samples);
        } else {
            // Case 1: Point sampling (original method)
            float cycle = mod(x_units - 0.5, 6.0);
            float dr = cyclicDist(cycle, 0.0, 6.0);
            float dg = cyclicDist(cycle, 2.0, 6.0);
            float db = cyclicDist(cycle, 4.0, 6.0);

            float gauss_rx = exp(-0.5 * dr*dr / (sigma.x*sigma.x));
            float gauss_gx = exp(-0.5 * dg*dg / (sigma.x*sigma.x));
            float gauss_bx = exp(-0.5 * db*db / (sigma.x*sigma.x));

            mask_color = vec3(gauss_rx, gauss_gx, gauss_bx);
        }
    } else if (MASK_TYPE < 1.5) {
        // Slot mask: 18-unit horizontal, 3-unit vertical cycle
        // For now, only point sampling supported (integration TODO)
        if (passthrough_x && passthrough_y) {
            mask_color = vec3(1.0);
        } else if (use_integration_x || use_integration_y) {
            // 2D numerical integration with adaptive sample counts
            int samples_x = int(clamp(pixel_width_units * 6.0, 6.0, 24.0));
            int samples_y = int(clamp(pixel_height_units * 4.0, 4.0, 16.0));
            float sigma_v = sigma.y * 0.5;
            mask_color = integrate_slot_mask_numerical(x_min, x_max, y_min, y_max, sigma.x, sigma_v, samples_x, samples_y);
            float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));
            mask_color /= brightness_ratio;
        } else {
            // Original point sampling code
            float cycle = mod(x_units - 0.5, 18.0);
            float vcycle = mod(y_units - 0.5, 3.0);
            float sigma_v = sigma.y * 0.5;
            float w0 = exp(-0.5 * pow(cyclicDist(vcycle, 0.0, 3.0), 2.0) / (sigma_v * sigma_v));
            float w1 = exp(-0.5 * pow(cyclicDist(vcycle, 1.0, 3.0), 2.0) / (sigma_v * sigma_v));
            float w2 = exp(-0.5 * pow(cyclicDist(vcycle, 2.0, 3.0), 2.0) / (sigma_v * sigma_v));

            vec2 dR0 = vec2(cyclicDist(cycle, 6.0, 18.0), cyclicDist(cycle, 12.0, 18.0));
            vec2 dG0 = vec2(cyclicDist(cycle, 8.0, 18.0), cyclicDist(cycle, 14.0, 18.0));
            vec2 dB0 = vec2(cyclicDist(cycle, 10.0, 18.0), cyclicDist(cycle, 16.0, 18.0));
            vec3 rgb0 = vec3(
                exp(-0.5 * dR0.x * dR0.x / (sigma.x * sigma.x)) + exp(-0.5 * dR0.y * dR0.y / (sigma.x * sigma.x)),
                exp(-0.5 * dG0.x * dG0.x / (sigma.x * sigma.x)) + exp(-0.5 * dG0.y * dG0.y / (sigma.x * sigma.x)),
                exp(-0.5 * dB0.x * dB0.x / (sigma.x * sigma.x)) + exp(-0.5 * dB0.y * dB0.y / (sigma.x * sigma.x)));

            vec2 dR1 = vec2(cyclicDist(cycle, 0.0, 18.0), cyclicDist(cycle, 12.0, 18.0));
            vec2 dG1 = vec2(cyclicDist(cycle, 2.0, 18.0), cyclicDist(cycle, 14.0, 18.0));
            vec2 dB1 = vec2(cyclicDist(cycle, 4.0, 18.0), cyclicDist(cycle, 16.0, 18.0));
            vec3 rgb1 = vec3(
                exp(-0.5 * dR1.x * dR1.x / (sigma.x * sigma.x)) + exp(-0.5 * dR1.y * dR1.y / (sigma.x * sigma.x)),
                exp(-0.5 * dG1.x * dG1.x / (sigma.x * sigma.x)) + exp(-0.5 * dG1.y * dG1.y / (sigma.x * sigma.x)),
                exp(-0.5 * dB1.x * dB1.x / (sigma.x * sigma.x)) + exp(-0.5 * dB1.y * dB1.y / (sigma.x * sigma.x)));

            vec2 dR2 = vec2(cyclicDist(cycle, 0.0, 18.0), cyclicDist(cycle, 6.0, 18.0));
            vec2 dG2 = vec2(cyclicDist(cycle, 2.0, 18.0), cyclicDist(cycle, 8.0, 18.0));
            vec2 dB2 = vec2(cyclicDist(cycle, 4.0, 18.0), cyclicDist(cycle, 10.0, 18.0));
            vec3 rgb2 = vec3(
                exp(-0.5 * dR2.x * dR2.x / (sigma.x * sigma.x)) + exp(-0.5 * dR2.y * dR2.y / (sigma.x * sigma.x)),
                exp(-0.5 * dG2.x * dG2.x / (sigma.x * sigma.x)) + exp(-0.5 * dG2.y * dG2.y / (sigma.x * sigma.x)),
                exp(-0.5 * dB2.x * dB2.x / (sigma.x * sigma.x)) + exp(-0.5 * dB2.y * dB2.y / (sigma.x * sigma.x)));

            mask_color = w0 * rgb0 + w1 * rgb1 + w2 * rgb2;
            float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));
            mask_color /= brightness_ratio;
        }
    } else {
        // Shadow mask: 6-unit horizontal, 4-unit vertical cycle
        if (passthrough_x && passthrough_y) {
            mask_color = vec3(1.0);
        } else if (use_integration_x || use_integration_y) {
            // 2D numerical integration with adaptive sample counts
            int samples_x = int(clamp(pixel_width_units * 6.0, 6.0, 24.0));
            int samples_y = int(clamp(pixel_height_units * 4.0, 4.0, 16.0));
            mask_color = integrate_shadow_mask_numerical(x_min, x_max, y_min, y_max, sigma.x, sigma.y, samples_x, samples_y);
            float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));
            mask_color /= brightness_ratio;
        } else {
            // Point sampling
            float cycle = mod(x_units - 0.5, 6.0);
            float vcycle = mod(y_units - 1.0, 4.0);
            float sigma_v = sigma.y;
            float w0 = exp(-0.5 * pow(cyclicDist(vcycle, 0.0, 4.0), 2.0) / (sigma_v * sigma_v));
            float w2 = exp(-0.5 * pow(cyclicDist(vcycle, 2.0, 4.0), 2.0) / (sigma_v * sigma_v));

            float dR0 = cyclicDist(cycle, 0.0, 6.0);
            float dG0 = cyclicDist(cycle, 2.0, 6.0);
            float dB0 = cyclicDist(cycle, 4.0, 6.0);
            vec3 rgb0 = vec3(
                exp(-0.5 * dR0*dR0 / (sigma.x*sigma.x)),
                exp(-0.5 * dG0*dG0 / (sigma.x*sigma.x)),
                exp(-0.5 * dB0*dB0 / (sigma.x*sigma.x))
            );

            float dB2 = cyclicDist(cycle, 1.0, 6.0);
            float dR2 = cyclicDist(cycle, 3.0, 6.0);
            float dG2 = cyclicDist(cycle, 5.0, 6.0);
            vec3 rgb2 = vec3(
                exp(-0.5 * dR2*dR2 / (sigma.x*sigma.x)),
                exp(-0.5 * dG2*dG2 / (sigma.x*sigma.x)),
                exp(-0.5 * dB2*dB2 / (sigma.x*sigma.x))
            );

            mask_color = w0 * rgb0 + w2 * rgb2;
            float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));
            mask_color /= brightness_ratio;
        }
    }

    return mask_color;
}

float erf_approx(float x)
{
    float sign = x < 0.0 ? -1.0 : 1.0;
    x = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * x);
    float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t) * exp(-x * x);
    return sign * y;
}

float average_cyclic_gauss(float period, float sigma)
{
    float s = max(sigma, EPS);
    float half_period = 0.5 * period;
    float arg = half_period / (sqrt(2.0) * s);
    float integral = sqrt(0.5 * PI) * s * erf_approx(arg);
    return (2.0 / period) * integral;
}

vec3 average_mask_color(vec2 pixels_per_unit)
{
    vec2 sigma = vec2(MASK_DIFFUSION);
    if (MASK_TYPE >= 1.5) {
        sigma *= 0.625;
    }

    const float INTEGRATION_THRESHOLD = 1.0;
    bool use_integration = (pixels_per_unit.x < INTEGRATION_THRESHOLD && pixels_per_unit.x >= 1.0 / 3.0) ||
                           (pixels_per_unit.y < INTEGRATION_THRESHOLD && pixels_per_unit.y >= 1.0 / 3.0);
    bool passthrough = (pixels_per_unit.x < 1.0 / 3.0) || (pixels_per_unit.y < 1.0 / 3.0);

    if (passthrough) {
        return vec3(1.0);  // Mask disabled at very low resolution
    }

    if (MASK_TYPE < 0.5) {
        float avg_x = average_cyclic_gauss(6.0, sigma.x);
        return vec3(avg_x);  // Aperture has no vertical component
    }

    // Brightness ratio for normalization based on vertical diffusion
    float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));

    if (MASK_TYPE < 1.5) {
        // Slot mask: horizontal 18-unit, vertical 3-unit
        float sigma_v = sigma.y * 0.5;
        float avg_w = average_cyclic_gauss(3.0, sigma_v);
        float avg_row = 2.0 * average_cyclic_gauss(18.0, sigma.x);
        float avg_mask = (avg_w * 3.0 * avg_row) / brightness_ratio;
        return vec3(avg_mask);
    }

    // Shadow mask: horizontal 6-unit, vertical 4-unit
    float avg_w = average_cyclic_gauss(4.0, sigma.y);
    float avg_row = average_cyclic_gauss(6.0, sigma.x);
    float avg_mask = (avg_w * 2.0 * avg_row) / brightness_ratio;
    return vec3(avg_mask);
}

vec3 peak_mask_color_point(vec2 sigma)
{
    float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));

    if (MASK_TYPE < 0.5) {
        float s2 = 2.0 / (sigma.x * sigma.x);
        float rb_contrib = exp(-s2);
        return vec3(rb_contrib, 1.0, rb_contrib);
    }

    if (MASK_TYPE < 1.5) {
        float g_dist1 = 0.0;
        float g_dist2 = cyclicDist(8.0, 14.0, 18.0);
        float g_contrib = exp(-0.5 * g_dist1 * g_dist1 / (sigma.x * sigma.x))
                        + exp(-0.5 * g_dist2 * g_dist2 / (sigma.x * sigma.x));

        float r_dist1 = cyclicDist(8.0, 6.0, 18.0);
        float r_dist2 = cyclicDist(8.0, 12.0, 18.0);
        float r_contrib = exp(-0.5 * r_dist1 * r_dist1 / (sigma.x * sigma.x))
                        + exp(-0.5 * r_dist2 * r_dist2 / (sigma.x * sigma.x));

        float b_dist1 = cyclicDist(8.0, 10.0, 18.0);
        float b_dist2 = cyclicDist(8.0, 16.0, 18.0);
        float b_contrib = exp(-0.5 * b_dist1 * b_dist1 / (sigma.x * sigma.x))
                        + exp(-0.5 * b_dist2 * b_dist2 / (sigma.x * sigma.x));

        vec3 peak = vec3(r_contrib, g_contrib, b_contrib);
        return peak / brightness_ratio;
    }

    float peak_r = exp(-0.5 * 2.0 * 2.0 / (sigma.x * sigma.x))
                 + exp(-0.5 * 1.0 * 1.0 / (sigma.x * sigma.x));
    float peak_g = 1.0 + exp(-0.5 * 3.0 * 3.0 / (sigma.x * sigma.x));
    float peak_b = exp(-0.5 * 2.0 * 2.0 / (sigma.x * sigma.x))
                 + exp(-0.5 * 1.0 * 1.0 / (sigma.x * sigma.x));

    float vert_r0 = 1.0;
    float vert_r2 = exp(-0.5 * 2.0 * 2.0 / (sigma.y * sigma.y));

    vec3 peak = vec3(
        peak_r * vert_r0 * (1.0 + vert_r2),
        peak_g * vert_r0 * (1.0 + vert_r2),
        peak_b * vert_r0 * (1.0 + vert_r2)
    );

    return peak / brightness_ratio;
}

vec3 peak_mask_color(vec2 pixels_per_unit)
{
    vec2 sigma = vec2(MASK_DIFFUSION);
    if (MASK_TYPE >= 1.5) {
        sigma *= 0.625;
    }

    const float INTEGRATION_THRESHOLD = 1.0;
    const float PASSTHROUGH_THRESHOLD = 1.0 / 3.0;

    bool use_integration_x = (pixels_per_unit.x >= PASSTHROUGH_THRESHOLD && pixels_per_unit.x < INTEGRATION_THRESHOLD);
    bool use_integration_y = (pixels_per_unit.y >= PASSTHROUGH_THRESHOLD && pixels_per_unit.y < INTEGRATION_THRESHOLD);
    bool passthrough_x = pixels_per_unit.x < PASSTHROUGH_THRESHOLD;
    bool passthrough_y = pixels_per_unit.y < PASSTHROUGH_THRESHOLD;

    // If passthrough (pattern unresolvable), peak = average
    if ((passthrough_x && MASK_TYPE < 1.5) || (passthrough_x && passthrough_y && MASK_TYPE >= 1.5)) {
        return average_mask_color(pixels_per_unit);
    }

    vec3 point_peak = peak_mask_color_point(sigma);

    float brightness_ratio = sqrt(1.0 + (sigma.y * sigma.y));

    if (MASK_TYPE < 0.5) {
        // Aperture: peak at center of green stripe
        // At integration: peak approaches average (stripes blend)
        if (use_integration_x) {
            // During integration, peak flattens toward average
            float avg_x = average_cyclic_gauss(6.0, sigma.x);
            return mix(vec3(avg_x), vec3(1.0), pixels_per_unit.x);
        }
        // Point sampling: sharp peak
        return point_peak;
    }

    if (MASK_TYPE < 1.5) {
        // Slot mask
        float sigma_v = sigma.y * 0.5;

        if (use_integration_x || use_integration_y) {
            // During integration: peak flattens toward average
            float avg_w = average_cyclic_gauss(3.0, sigma_v);
            float avg_row = 2.0 * average_cyclic_gauss(18.0, sigma.x);
            float avg_mask = (avg_w * 3.0 * avg_row) / brightness_ratio;

            // Blend sharp peak with average based on resolution
            float blend = min(pixels_per_unit.x, pixels_per_unit.y);
            return mix(vec3(avg_mask), point_peak, blend);
        }

        // Point sampling: compute sharp peak
        return point_peak;
    }

    // Shadow mask
    if (use_integration_x || use_integration_y) {
        // During integration: peak approaches average
        float avg_w = average_cyclic_gauss(4.0, sigma.y);
        float avg_row = average_cyclic_gauss(6.0, sigma.x);
        float avg_mask = (avg_w * 2.0 * avg_row) / brightness_ratio;

        float blend = min(pixels_per_unit.x, pixels_per_unit.y);
        return mix(vec3(avg_mask), point_peak, blend);
    }

    // Point sampling: compute sharp peak
    return point_peak;
}

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out float maskAR;
layout(location = 2) out float avg_mask_luma;
layout(location = 3) out float avg_nomask_luma;
layout(location = 4) out float peak_mask_luma;
layout(location = 5) out float peak_nomask_luma;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    // Selected target aspect ratio for framing
    maskAR = (ASPECT < 0.5) ? (4.0 / 3.0)
        : (ASPECT < 1.5) ? (16.0 / 9.0)
        : (ASPECT < 2.5) ? (5.0 / 4.0)
        : (16.0 / 10.0);

    mat3 RGB_to_XYZ;
    if (COLORIMETRY_PRESET < 0.5) {
        vec3 ref_XYZ = xyY_to_XYZ(vec3(W_X, W_Y, 1.0));
        vec3 red_XYZ = xyY_to_XYZ(vec3(R_X, R_Y, 1.0));
        vec3 green_XYZ = xyY_to_XYZ(vec3(G_X, G_Y, 1.0));
        vec3 blue_XYZ = xyY_to_XYZ(vec3(B_X, B_Y, 1.0));

        RGB_to_XYZ = get_RGB_to_XYZ(red_XYZ, green_XYZ, blue_XYZ, ref_XYZ);
    } else if (COLORIMETRY_PRESET < 1.5) {
        RGB_to_XYZ = SMPTE_C_TO_XYZ;
    } else if (COLORIMETRY_PRESET < 2.5) {
        RGB_to_XYZ = NTSC_J_TO_XYZ;
    } else if (COLORIMETRY_PRESET < 3.5) {
        RGB_to_XYZ = EBU_TO_XYZ;
    } else {
        RGB_to_XYZ = sRGB_TO_XYZ;
    }

    vec3 luma_weights = vec3(RGB_to_XYZ[0][1], RGB_to_XYZ[1][1], RGB_to_XYZ[2][1]);

    // Compute white_level from user controls (matching crt-linear.slang)
    float black_level = 2.0 * USER_BRIGHTNESS / 100.0 - 1.0;
    float white_level = 100.0 * 2.0 * USER_PICTURE / 100.0 + black_level;

    float tvl = max(TVL, 1.0);
    float units_x_total = tvl * 6.0;
    float units_y_total;
    if (MASK_TYPE < 0.5) {
        units_y_total = tvl;
    } else if (MASK_TYPE < 1.5) {
        units_y_total = tvl / maskAR * 2.5;
    } else {
        units_y_total = tvl / maskAR * 6.0;
    }

    float mask_intensity = MASK_INTENSITY * 0.01;
    vec2 pixels_per_unit = config.OutputSize.xy / vec2(units_x_total, units_y_total);
    vec3 avg_mask = average_mask_color(pixels_per_unit);
    vec3 peak_mask = peak_mask_color(pixels_per_unit);
    vec3 avg_mask_gain = mix(vec3(1.0), avg_mask, mask_intensity);
    vec3 peak_mask_gain = mix(vec3(1.0), peak_mask, mask_intensity);

    // Compute integration scaling factor for subpixel summation
    // When pixels_per_unit < 1.0, multiple pattern units contribute to each output pixel
    // The total integrated luminance scales by the number of pattern units per pixel
    vec2 pattern_units_per_pixel = max(vec2(1.0), vec2(1.0) / pixels_per_unit);
    float integration_scale = pattern_units_per_pixel.x * pattern_units_per_pixel.y;

    avg_mask_luma = integration_scale * white_level * dot(avg_mask_gain, luma_weights);
    avg_nomask_luma = integration_scale * white_level * dot(vec3(1.0), luma_weights);
    peak_mask_luma = integration_scale * white_level * dot(peak_mask_gain, luma_weights);
    peak_nomask_luma = avg_nomask_luma;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in float maskAR;
layout(location = 2) in float avg_mask_luma;
layout(location = 3) in float avg_nomask_luma;
layout(location = 4) in float peak_mask_luma;
layout(location = 5) in float peak_nomask_luma;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;

void main()
{
    vec3 color = texture(Source, vTexCoord).rgb;

    // If mask is bypassed, return color as-is
    if (MASK_BYPASS >= 1.0) {
        FragColor = vec4(color, peak_nomask_luma);
        return;
    }

    // TVL-based unit scaling independent of output resolution
    // 1 TVL = 6 horizontal units (one RGB triad + gaps) in all modes
    // TVL here is defined for the selected frame aspect
    float tvl = max(TVL, 1.0);
    float units_x_total = tvl * 6.0;

    // Vertical units depend on mask type:
    // Aperture: no vertical structure (use minimal for consistency)
    // Slot: 3-unit vertical cycle (simplified slot with gating)
    // Shadow: 4 vertical units per TVL (4-row shadow mask cycle)
    float units_y_total;
    if (MASK_TYPE < 0.5) {
        units_y_total = tvl; // Aperture has no vertical pattern
    } else if (MASK_TYPE < 1.5) {
        units_y_total = tvl / maskAR * 2.5;
    } else {
        units_y_total = tvl / maskAR * 6.0;
    }

    float mask_intensity = MASK_INTENSITY * 0.01;

    // Gaussian stripe helper (sigma in pattern units)
    vec2 pixels_per_unit = config.OutputSize.xy / vec2(units_x_total, units_y_total);

    vec3 mask_color = compute_mask(vTexCoord, units_x_total, units_y_total, pixels_per_unit);
    vec3 masked_color = mix(color, color * mask_color, mask_intensity);

    if (MASK_DEBUG_OUT_OF_RANGE >= 1.0) {
        masked_color = zebra(masked_color, 0.0, 100.0, vTexCoord, config.OutputSize.xy, config.FrameCount, 2.0);
    }

    FragColor = vec4(masked_color, peak_mask_luma);
}
