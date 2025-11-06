#version 450

/* Filename: composite-mod-prefilter.slang

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
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include "common.h"
#include "color.h"
#include "bandlimit.inc"
#include "modulation.inc"

#pragma name CompositeMod
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float BYPASS_COMPOSITE_MOD;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float COLOR_FILTER_MODE;
    float NOTCH_OFFSET_L;
    float NOTCH_OFFSET_R;
    float COMB_FILTER_TAPS;
    float NOTCH_COMB_W;
    float NOTCH_TEST_LP;
    float NOTCH_TEST_HP;
} config;

#pragma parameter COMPOSITE_HEADER " ==== Composite Video Mod. Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass Composite modulation (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD

#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
#define V_FREQ config.V_FREQ

#pragma parameter V_LINES_PER_FIELD "Video lines per field" 262.5 0.0 540.0 0.5
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD

#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#define SC_FREQ_MODE config.SC_FREQ_MODE

#pragma parameter SC_FREQ "Custom Subcarrier Frequency (MHz)" 3.579545 0.0 10.0 0.000001
#define SC_FREQ config.SC_FREQ

#define H_FREQ_HZ (V_FREQ * V_LINES_PER_FIELD)

#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter COLOR_FILTER_MODE "Filter mode (0=Notch,1=Comb,2=Notch+Comb,3=Off)" 0.0 0.0 3.0 1.0
#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#pragma parameter NOTCH_OFFSET_L "Notch filter left cutoff offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_L config.NOTCH_OFFSET_L
#pragma parameter NOTCH_OFFSET_R "Notch filter right cutoff offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_R config.NOTCH_OFFSET_R

#pragma parameter COMB_FILTER_TAPS "Comb Filter Taps" 1 1 3 1
#define COMB_FILTER_TAPS config.COMB_FILTER_TAPS

#pragma parameter NOTCH_COMB_W "Notch-Comb Mixing Weight" 0.5 0.0 1.0 0.1
#define NOTCH_COMB_W config.NOTCH_COMB_W

#pragma parameter NOTCH_TEST_LP "Notch Filter Test Lowpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_LP config.NOTCH_TEST_LP

#pragma parameter NOTCH_TEST_HP "Notch Filter Test Highpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_HP config.NOTCH_TEST_HP

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (1.0 / V_FREQ)

layout(std140, set = 0, binding = 0) uniform UBO
{
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
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    if (BYPASS_COMPOSITE_MOD >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Use consolidated timebase helper
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        config.OriginalSize.xy,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Notch filter characteristics
    vec4 c = 1.0 / pow(vec4(10.0), vec4(-2.0 / 20.0));
    vec4 notch_res = vec4(
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 - NOTCH_OFFSET_L),
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 - NOTCH_OFFSET_R),
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 + NOTCH_OFFSET_L),
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 + NOTCH_OFFSET_R));
    vec4 notch_sigma = vec4(
        sqrt(log(c.g)) / (notch_res.x / config.OutputSize.x),
        sqrt(log(c.g)) / (config.OutputSize.x / notch_res.y),
        sqrt(log(c.b)) / (notch_res.z / config.OutputSize.x),
        sqrt(log(c.b)) / (config.OutputSize.x / notch_res.w));

    // Optimized symmetric lobed approach with early exit
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 A = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * config.OutputSize.zw;
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    vec2 color_notch = vec2(0.0);
    vec2 color_comb = vec2(0.0);
    vec2 wsum_notch = vec2(0.0);
    vec2 wsum_comb = vec2(0.0);
    
    float luma_hp = 0.0;
    float wsum_hp = 0.0;

    // Process center sample
    float offset0 = Tex.x * config.OriginalSize.x;
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time;
    
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0);
    
    float chroma0 = pixel0.g * carrier0.x + pixel0.b * carrier0.y;
    float composite0 = pixel0.r + chroma0;
    
    // Center weights for Notch Filter
    float w_notch_lp_y0 = gaussian(A.x, notch_sigma.x);
    float w_notch_hp_y0 = gaussian(A.x, notch_sigma.y);
    float w_notch_lp_c0 = gaussian(A.x, notch_sigma.z);
    float w_notch_hp_c0 = gaussian(A.x, notch_sigma.w);

    if (NOTCH_TEST_HP < 0.5) {
        color_notch += vec2(
        w_notch_lp_y0 * composite0,
        w_notch_lp_c0 * composite0);
        wsum_notch += vec2(
            w_notch_lp_y0,
            w_notch_lp_c0);
    }

    if (NOTCH_TEST_LP < 0.5) {
        color_notch += vec2(
            (1.0 - w_notch_hp_y0) * composite0,
            (1.0 - w_notch_hp_c0) * composite0);
        wsum_notch += vec2(
            (1.0 - w_notch_hp_y0),
            (1.0 - w_notch_hp_c0));
    }
    
    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n) + A.x;
        float nmf = float(n) - A.x;
        
        // Compute weights for notch filter (matching center sample approach)
        float w_notch_lp_y = gaussian(nf, notch_sigma.x);
        float w_notch_hp_y = gaussian(nf, notch_sigma.y);
        float w_notch_lp_c = gaussian(nf, notch_sigma.z);
        float w_notch_hp_c = gaussian(nf, notch_sigma.w);
        
        // Early exit if all weights negligible
        if (w_notch_lp_y < THRESHOLD && w_notch_hp_y < THRESHOLD && 
            w_notch_lp_c < THRESHOLD && w_notch_hp_c < THRESHOLD)
            break;
        
        // Right sample
        float offsetR = (Tex.x + float(n) * dx.x) * config.OriginalSize.x;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time;
        
        vec3 pixelR = texture(Source, Tex + float(n) * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR);
        
        float chromaR = pixelR.g * carrierR.x + pixelR.b * carrierR.y;
        float compositeR = pixelR.r + chromaR;
        
        // Left sample
        float offsetL = (Tex.x - float(n) * dx.x) * config.OriginalSize.x;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time;
        
        vec3 pixelL = texture(Source, Tex - float(n) * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL);
        
        float chromaL = pixelL.g * carrierL.x + pixelL.b * carrierL.y;
        float compositeL = pixelL.r + chromaL;
        
        // Accumulate notch filter (matching center sample structure)
        if (NOTCH_TEST_HP < 0.5) {
            color_notch += vec2(
                w_notch_lp_y * (compositeR + compositeL),
                w_notch_lp_c * (compositeR + compositeL));
            wsum_notch += vec2(
                2.0 * w_notch_lp_y,
                2.0 * w_notch_lp_c);
        }
        if (NOTCH_TEST_LP < 0.5) {
            color_notch += vec2(
                (1.0 - w_notch_hp_y) * (compositeR + compositeL),
                (1.0 - w_notch_hp_c) * (compositeR + compositeL));
            wsum_notch += vec2(
                2.0 * (1.0 - w_notch_hp_y),
                2.0 * (1.0 - w_notch_hp_c));
        }
    }
    
    // Normalize
    color_notch /= max(wsum_notch, vec2(EPS));

    // Comb filter setup
    float phase_per_line = mod(2.0 * PI * tb.sc_freq_hz * LINE_TIME, 2.0 * PI);
    float lines_per_180deg = PI / phase_per_line;
    float phase_per_pixel = 2.0 * PI * tb.sc_freq_hz * tb.pixel_time;
    float fractional_line = fract(lines_per_180deg);
    float horizontal_pixel_offset = (fractional_line * phase_per_line) / phase_per_pixel;

    vec2 comb_dy_1 = vec2(horizontal_pixel_offset * config.OriginalSize.z,
                          -floor(lines_per_180deg) * config.OriginalSize.w);
    vec2 comb_dy_2 = vec2(2.0 * horizontal_pixel_offset * config.OriginalSize.z,
                          -floor(2.0 * lines_per_180deg) * config.OriginalSize.w);
    vec2 comb_dy_3 = vec2(3.0 * horizontal_pixel_offset * config.OriginalSize.z,
                          -floor(3.0 * lines_per_180deg) * config.OriginalSize.w);

    float t_offset_1 = floor(lines_per_180deg) * LINE_TIME 
                      + horizontal_pixel_offset * tb.pixel_time;
    float t_offset_2 = floor(2.0 * lines_per_180deg) * LINE_TIME 
                      + 2.0 * horizontal_pixel_offset * tb.pixel_time;
    float t_offset_3 = floor(3.0 * lines_per_180deg) * LINE_TIME 
                      + 3.0 * horizontal_pixel_offset * tb.pixel_time;

    // Comb filter for center sample
    mat3 comb_taps_yuv = mat3(
        texture(Source, Tex + comb_dy_1).rgb,
        texture(Source, Tex + comb_dy_2).rgb,
        texture(Source, Tex + comb_dy_3).rgb);

    float phase_1 = compute_carrier_phase(t0 - t_offset_1, tb.sc_freq_hz, tb.field_phase);
    float phase_2 = compute_carrier_phase(t0 - t_offset_2, tb.sc_freq_hz, tb.field_phase);
    float phase_3 = compute_carrier_phase(t0 - t_offset_3, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier_1 = sincos_phase(phase_1);
    vec2 carrier_2 = sincos_phase(phase_2);
    vec2 carrier_3 = sincos_phase(phase_3);

    vec3 comb_taps_composite0 = vec3(
        dot(comb_taps_yuv[0], vec3(1.0, carrier_1.x, carrier_1.y)),
        dot(comb_taps_yuv[1], vec3(1.0, carrier_2.x, carrier_2.y)),
        dot(comb_taps_yuv[2], vec3(1.0, carrier_3.x, carrier_3.y)));

    if (COMB_FILTER_TAPS < 2) {
        color_comb.r = 0.5 * (composite0 + comb_taps_composite0.x);
        color_comb.g = 0.5 * (composite0 - comb_taps_composite0.x);
    } else if (COMB_FILTER_TAPS < 3) {
        color_comb.r = 0.5 * (0.5 * composite0 + comb_taps_composite0.x + 0.5 * comb_taps_composite0.y);
        color_comb.g = 0.5 * (0.5 * composite0 - comb_taps_composite0.x + 0.5 * comb_taps_composite0.y);
    } else {
        color_comb.r = 1.0 / 3.0 * (0.5 * composite0 + comb_taps_composite0.x + comb_taps_composite0.y + 0.5 * comb_taps_composite0.z);
        color_comb.g = 1.0 / 3.0 * (0.5 * composite0 - comb_taps_composite0.x + comb_taps_composite0.y - 0.5 * comb_taps_composite0.z);
    }

    // Select color filter mode
    vec3 color;
    if (COLOR_FILTER_MODE < 0.5) {
        color = vec3(color_notch, 0.0);
    } else if (COLOR_FILTER_MODE < 1.5) {
        color = vec3(color_comb, 0.0);
    } else if (COLOR_FILTER_MODE < 2.5) {
        color = vec3(mix(color_notch, color_comb, NOTCH_COMB_W), 0.0);
    } else if (COLOR_FILTER_MODE < 3.5) {
        color = vec3(composite0, composite0, 0.0);
    }

    FragColor = vec4(color, 1.0);
}
