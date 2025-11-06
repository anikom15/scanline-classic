#version 450

/* Filename: composite.slang

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

#pragma name Composite
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float SIGNAL_BANDWIDTH_Y;
    float SIGNAL_BANDWIDTH_C;
    float FILTER_CUTOFF_ATTEN_Y;
    float FILTER_CUTOFF_ATTEN_C;
    float FILTER_SIZE_YC;
    float COLOR_FILTER_MODE;
    float NOTCH_OFFSET_L;
    float NOTCH_OFFSET_R;
} config;

#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
#define V_FREQ config.V_FREQ

#pragma parameter V_LINES_PER_FIELD "Video lines per field" 262.5 0.0 540.0 0.5
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD

#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME

#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#define SC_FREQ_MODE config.SC_FREQ_MODE

#define H_FREQ_HZ (V_FREQ * V_LINES_PER_FIELD)

#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

#pragma parameter SIGNAL_BANDWIDTH_Y "Signal bandwidth Y (MHz)" 6.75 0.0 75.0 0.1
#define SIGNAL_BANDWIDTH_Y config.SIGNAL_BANDWIDTH_Y
#pragma parameter SIGNAL_BANDWIDTH_C "Signal bandwidth C (MHz)" 1.79 0.0 6.75 0.01
#define SIGNAL_BANDWIDTH_C config.SIGNAL_BANDWIDTH_C

#pragma parameter FILTER_CUTOFF_ATTEN_Y "Filter cutoff attenuation Y (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_Y config.FILTER_CUTOFF_ATTEN_Y
#pragma parameter FILTER_CUTOFF_ATTEN_C "Filter cutoff attenuation C (dB)" 3.0 0.0 30.0 1.0
#define FILTER_CUTOFF_ATTEN_C config.FILTER_CUTOFF_ATTEN_C

#pragma parameter FILTER_SIZE_YC "Gaussian filter radius Y/C" 14.0 0.0 40.0 1.0
#define FILTER_SIZE_YC config.FILTER_SIZE_YC

#pragma parameter COLOR_FILTER_MODE "Color filter mode (0=BS, 1=Comb, 2=0·1, 3=Feedback, 4=Off)" 0.0 0.0 4.0 1.0
#define COLOR_FILTER_MODE config.COLOR_FILTER_MODE

#pragma parameter NOTCH_OFFSET_L "Notch filter left cutoff offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_L config.NOTCH_OFFSET_L
#pragma parameter NOTCH_OFFSET_R "Notch filter right cutoff offset" 1.3 -10.0 10.0 0.1
#define NOTCH_OFFSET_R config.NOTCH_OFFSET_R

#define LINE_TIME (1.0 / H_FREQ_HZ)
#define FIELD_TIME (1.0 / V_FREQ)

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float COMB_FILTER_TAPS;
    float NOTCH_COMB_W;
    float BW_MODE;
    float NOTCH_TEST_LP;
    float NOTCH_TEST_HP;
    float SC_FREQ;
} global;

#pragma parameter COMB_FILTER_TAPS "Comb Filter Taps" 1 1 3 1
#define COMB_FILTER_TAPS global.COMB_FILTER_TAPS

#pragma parameter SC_FREQ "Custom Subcarrier Frequency (MHz)" 3.579545 0.0 10.0 0.000001
#define SC_FREQ global.SC_FREQ

#pragma parameter NOTCH_COMB_W "Notch-Comb Mixing Weight" 0.5 0.0 1.0 0.1
#define NOTCH_COMB_W global.NOTCH_COMB_W

#pragma parameter BW_MODE "Monochrome Display (0=Off, 1=On)" 0 0 1 1
#define BW_MODE global.BW_MODE

#pragma parameter NOTCH_TEST_LP "Notch Filter Test Lowpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_LP global.NOTCH_TEST_LP

#pragma parameter NOTCH_TEST_HP "Notch Filter Test Highpass (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define NOTCH_TEST_HP global.NOTCH_TEST_HP

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

    // Filter characteristics
    vec3 sigma = sigma601(
        vec3(SIGNAL_BANDWIDTH_Y, SIGNAL_BANDWIDTH_C, SIGNAL_BANDWIDTH_C),
        vec3(FILTER_CUTOFF_ATTEN_Y, FILTER_CUTOFF_ATTEN_C, FILTER_CUTOFF_ATTEN_C),
        config.OutputSize.x);

    // Notch filter characteristics
    vec2 c = 1.0 / pow(vec2(10.0, 10.0), vec2(-2.0 / 20.0, -2.0 / 20.0));
    vec2 notch_res = vec2(
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 - NOTCH_OFFSET_L),
        720.0 / 6.75 * (tb.sc_freq_hz / 1.0e6 - NOTCH_OFFSET_R));
    vec2 notch_sigma = vec2(
        sqrt(log(c.g)) / (notch_res.x / config.OutputSize.x),
        sqrt(log(c.g)) / (config.OutputSize.x / notch_res.y));

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

    // Optimized symmetric lobed approach with early exit
    vec2 UV = vTexCoord * config.OutputSize.xy;
    vec2 A = fract(UV);
    vec2 Tex = (floor(UV) + 0.5) * config.OutputSize.zw;
    vec2 dx = vec2(config.OutputSize.z, 0.0);

    const float THRESHOLD = 1.0 / 510.0;
    
    vec3 color_notch = vec3(0.0);
    vec3 color_comb = vec3(0.0);
    vec3 color_raw = vec3(0.0);
    vec3 wsum_notch = vec3(0.0);
    vec3 wsum_comb = vec3(0.0);
    vec3 wsum_raw = vec3(0.0);
    
    float luma_hp = 0.0;
    float wsum_hp = 0.0;
    float identity = 0.0;
    float t_identity = 0.0;

    // Process center sample
    float offset0 = Tex.x * config.OriginalSize.x;
    float t0 = tb.line * LINE_TIME + offset0 * tb.pixel_time;
    
    vec3 pixel0 = texture(Source, Tex).rgb;
    float phase0 = compute_carrier_phase(t0, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier0 = sincos_phase(phase0);
    
    float chroma0 = pixel0.g * carrier0.x + pixel0.b * carrier0.y;
    float composite0 = pixel0.r + chroma0;
    
    identity = composite0;
    t_identity = t0;
    
    vec3 demod0;
    demod0.r = composite0;
    demod0.g = composite0 * carrier0.x;
    demod0.b = composite0 * carrier0.y;
    
    // Center weights for all filter modes
    float w_raw_y0 = gaussian(A.x, sigma.x);
    float w_raw_c0 = gaussian(A.x, sigma.y);
    float w_notch_y0 = gaussian(A.x, sqrt(sq(sigma.x) + sq(notch_sigma.x)));
    float w_notch_c0 = w_raw_c0;
    float w_hp0 = gaussian(A.x, notch_sigma.y);
    
    color_raw += vec3(w_raw_y0 * demod0.r, w_raw_c0 * demod0.g, w_raw_c0 * demod0.b);
    wsum_raw += vec3(w_raw_y0, w_raw_c0, w_raw_c0);
    
    color_notch += vec3(w_notch_y0 * demod0.r, w_notch_c0 * demod0.g, w_notch_c0 * demod0.b);
    wsum_notch += vec3(w_notch_y0, w_notch_c0, w_notch_c0);
    
    luma_hp += demod0.r * w_hp0;
    wsum_hp += w_hp0;
    
    // Comb filter for center sample
    mat3 comb_taps_yuv0 = mat3(
        texture(Source, Tex + comb_dy_1).rgb,
        texture(Source, Tex + comb_dy_2).rgb,
        texture(Source, Tex + comb_dy_3).rgb);
    
    float phase_1_0 = compute_carrier_phase(t0 - t_offset_1, tb.sc_freq_hz, tb.field_phase);
    float phase_2_0 = compute_carrier_phase(t0 - t_offset_2, tb.sc_freq_hz, tb.field_phase);
    float phase_3_0 = compute_carrier_phase(t0 - t_offset_3, tb.sc_freq_hz, tb.field_phase);
    vec2 carrier_1_0 = sincos_phase(phase_1_0);
    vec2 carrier_2_0 = sincos_phase(phase_2_0);
    vec2 carrier_3_0 = sincos_phase(phase_3_0);
    
    vec3 comb_taps_composite0 = vec3(
        dot(comb_taps_yuv0[0], vec3(1.0, carrier_1_0.x, carrier_1_0.y)),
        dot(comb_taps_yuv0[1], vec3(1.0, carrier_2_0.x, carrier_2_0.y)),
        dot(comb_taps_yuv0[2], vec3(1.0, carrier_3_0.x, carrier_3_0.y)));
    
    float chroma_comb0;
    vec3 demod_comb0;
    if (COMB_FILTER_TAPS < 2) {
        chroma_comb0 = 0.5 * (composite0 - comb_taps_composite0.x);
        demod_comb0.r = 0.5 * (composite0 + comb_taps_composite0.x);
    } else if (COMB_FILTER_TAPS < 3) {
        chroma_comb0 = 0.5 * (0.5 * composite0 - comb_taps_composite0.x + 0.5 * comb_taps_composite0.y);
        demod_comb0.r = 0.5 * (0.5 * composite0 + comb_taps_composite0.x + 0.5 * comb_taps_composite0.y);
    } else {
        chroma_comb0 = 1.0 / 3.0 * (0.5 * composite0 - comb_taps_composite0.x + comb_taps_composite0.y - 0.5 * comb_taps_composite0.z);
        demod_comb0.r = 1.0 / 3.0 * (0.5 * composite0 + comb_taps_composite0.x + comb_taps_composite0.y + 0.5 * comb_taps_composite0.z);
    }
    demod_comb0.g = chroma_comb0 * carrier0.x;
    demod_comb0.b = chroma_comb0 * carrier0.y;
    
    float w_comb_y0 = w_raw_y0;
    float w_comb_c0 = w_raw_c0;
    
    color_comb += vec3(w_comb_y0 * demod_comb0.r, w_comb_c0 * demod_comb0.g, w_comb_c0 * demod_comb0.b);
    wsum_comb += vec3(w_comb_y0, w_comb_c0, w_comb_c0);

    // Symmetric lobed processing with early exit
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n) + A.x;
        
        // Compute weights for all filter modes
        float w_raw_y = gaussian(nf, sigma.x);
        float w_raw_c = gaussian(nf, sigma.y);
        float w_notch_y = gaussian(nf, sqrt(sq(sigma.x) + sq(notch_sigma.x)));
        float w_notch_c = w_raw_c;
        float w_hp = gaussian(nf, notch_sigma.y);
        float w_comb_y = w_raw_y;
        float w_comb_c = w_raw_c;
        
        // Early exit if all weights negligible
        if (w_raw_y < THRESHOLD && w_raw_c < THRESHOLD && 
            w_notch_y < THRESHOLD && w_hp < THRESHOLD)
            break;
        
        // Right sample
        float offsetR = (Tex.x + float(n) * dx.x) * config.OriginalSize.x;
        float tR = tb.line * LINE_TIME + offsetR * tb.pixel_time;
        
        vec3 pixelR = texture(Source, Tex + float(n) * dx).rgb;
        float phaseR = compute_carrier_phase(tR, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierR = sincos_phase(phaseR);
        
        float chromaR = pixelR.g * carrierR.x + pixelR.b * carrierR.y;
        float compositeR = pixelR.r + chromaR;
        
        vec3 demodR;
        demodR.r = compositeR;
        demodR.g = compositeR * carrierR.x;
        demodR.b = compositeR * carrierR.y;
        
        // Left sample
        float offsetL = (Tex.x - float(n) * dx.x) * config.OriginalSize.x;
        float tL = tb.line * LINE_TIME + offsetL * tb.pixel_time;
        
        vec3 pixelL = texture(Source, Tex - float(n) * dx).rgb;
        float phaseL = compute_carrier_phase(tL, tb.sc_freq_hz, tb.field_phase);
        vec2 carrierL = sincos_phase(phaseL);
        
        float chromaL = pixelL.g * carrierL.x + pixelL.b * carrierL.y;
        float compositeL = pixelL.r + chromaL;
        
        vec3 demodL;
        demodL.r = compositeL;
        demodL.g = compositeL * carrierL.x;
        demodL.b = compositeL * carrierL.y;
        
        // Accumulate raw filter
        color_raw.r += w_raw_y * (demodR.r + demodL.r);
        color_raw.g += w_raw_c * (demodR.g + demodL.g);
        color_raw.b += w_raw_c * (demodR.b + demodL.b);
        wsum_raw.x += 2.0 * w_raw_y;
        wsum_raw.y += 2.0 * w_raw_c;
        wsum_raw.z += 2.0 * w_raw_c;
        
        // Accumulate notch filter
        color_notch.r += w_notch_y * (demodR.r + demodL.r);
        color_notch.g += w_notch_c * (demodR.g + demodL.g);
        color_notch.b += w_notch_c * (demodR.b + demodL.b);
        wsum_notch.x += 2.0 * w_notch_y;
        wsum_notch.y += 2.0 * w_notch_c;
        wsum_notch.z += 2.0 * w_notch_c;
        
        // Accumulate high-pass for notch
        luma_hp += w_hp * (demodR.r + demodL.r);
        wsum_hp += 2.0 * w_hp;
        
        // Comb filter processing for right sample
        mat3 comb_taps_yuv_R = mat3(
            texture(Source, Tex + float(n) * dx + comb_dy_1).rgb,
            texture(Source, Tex + float(n) * dx + comb_dy_2).rgb,
            texture(Source, Tex + float(n) * dx + comb_dy_3).rgb);
        
        float phase_1_R = compute_carrier_phase(tR - t_offset_1, tb.sc_freq_hz, tb.field_phase);
        float phase_2_R = compute_carrier_phase(tR - t_offset_2, tb.sc_freq_hz, tb.field_phase);
        float phase_3_R = compute_carrier_phase(tR - t_offset_3, tb.sc_freq_hz, tb.field_phase);
        vec2 carrier_1_R = sincos_phase(phase_1_R);
        vec2 carrier_2_R = sincos_phase(phase_2_R);
        vec2 carrier_3_R = sincos_phase(phase_3_R);
        
        vec3 comb_taps_composite_R = vec3(
            dot(comb_taps_yuv_R[0], vec3(1.0, carrier_1_R.x, carrier_1_R.y)),
            dot(comb_taps_yuv_R[1], vec3(1.0, carrier_2_R.x, carrier_2_R.y)),
            dot(comb_taps_yuv_R[2], vec3(1.0, carrier_3_R.x, carrier_3_R.y)));
        
        float chroma_comb_R;
        vec3 demod_comb_R;
        if (COMB_FILTER_TAPS < 2) {
            chroma_comb_R = 0.5 * (compositeR - comb_taps_composite_R.x);
            demod_comb_R.r = 0.5 * (compositeR + comb_taps_composite_R.x);
        } else if (COMB_FILTER_TAPS < 3) {
            chroma_comb_R = 0.5 * (0.5 * compositeR - comb_taps_composite_R.x + 0.5 * comb_taps_composite_R.y);
            demod_comb_R.r = 0.5 * (0.5 * compositeR + comb_taps_composite_R.x + 0.5 * comb_taps_composite_R.y);
        } else {
            chroma_comb_R = 1.0 / 3.0 * (0.5 * compositeR - comb_taps_composite_R.x + comb_taps_composite_R.y - 0.5 * comb_taps_composite_R.z);
            demod_comb_R.r = 1.0 / 3.0 * (0.5 * compositeR + comb_taps_composite_R.x + comb_taps_composite_R.y + 0.5 * comb_taps_composite_R.z);
        }
        demod_comb_R.g = chroma_comb_R * carrierR.x;
        demod_comb_R.b = chroma_comb_R * carrierR.y;
        
        // Comb filter processing for left sample
        mat3 comb_taps_yuv_L = mat3(
            texture(Source, Tex - float(n) * dx + comb_dy_1).rgb,
            texture(Source, Tex - float(n) * dx + comb_dy_2).rgb,
            texture(Source, Tex - float(n) * dx + comb_dy_3).rgb);
        
        float phase_1_L = compute_carrier_phase(tL - t_offset_1, tb.sc_freq_hz, tb.field_phase);
        float phase_2_L = compute_carrier_phase(tL - t_offset_2, tb.sc_freq_hz, tb.field_phase);
        float phase_3_L = compute_carrier_phase(tL - t_offset_3, tb.sc_freq_hz, tb.field_phase);
        vec2 carrier_1_L = sincos_phase(phase_1_L);
        vec2 carrier_2_L = sincos_phase(phase_2_L);
        vec2 carrier_3_L = sincos_phase(phase_3_L);
        
        vec3 comb_taps_composite_L = vec3(
            dot(comb_taps_yuv_L[0], vec3(1.0, carrier_1_L.x, carrier_1_L.y)),
            dot(comb_taps_yuv_L[1], vec3(1.0, carrier_2_L.x, carrier_2_L.y)),
            dot(comb_taps_yuv_L[2], vec3(1.0, carrier_3_L.x, carrier_3_L.y)));
        
        float chroma_comb_L;
        vec3 demod_comb_L;
        if (COMB_FILTER_TAPS < 2) {
            chroma_comb_L = 0.5 * (compositeL - comb_taps_composite_L.x);
            demod_comb_L.r = 0.5 * (compositeL + comb_taps_composite_L.x);
        } else if (COMB_FILTER_TAPS < 3) {
            chroma_comb_L = 0.5 * (0.5 * compositeL - comb_taps_composite_L.x + 0.5 * comb_taps_composite_L.y);
            demod_comb_L.r = 0.5 * (0.5 * compositeL + comb_taps_composite_L.x + 0.5 * comb_taps_composite_L.y);
        } else {
            chroma_comb_L = 1.0 / 3.0 * (0.5 * compositeL - comb_taps_composite_L.x + comb_taps_composite_L.y - 0.5 * comb_taps_composite_L.z);
            demod_comb_L.r = 1.0 / 3.0 * (0.5 * compositeL + comb_taps_composite_L.x + comb_taps_composite_L.y + 0.5 * comb_taps_composite_L.z);
        }
        demod_comb_L.g = chroma_comb_L * carrierL.x;
        demod_comb_L.b = chroma_comb_L * carrierL.y;
        
        // Accumulate comb filter
        color_comb.r += w_comb_y * (demod_comb_R.r + demod_comb_L.r);
        color_comb.g += w_comb_c * (demod_comb_R.g + demod_comb_L.g);
        color_comb.b += w_comb_c * (demod_comb_R.b + demod_comb_L.b);
        wsum_comb.x += 2.0 * w_comb_y;
        wsum_comb.y += 2.0 * w_comb_c;
        wsum_comb.z += 2.0 * w_comb_c;
    }
    
    // Normalize
    color_notch /= max(wsum_notch, vec3(EPS));
    color_notch.r += identity - luma_hp / max(wsum_hp, EPS);
    color_comb /= max(wsum_comb, vec3(EPS));
    color_raw /= max(wsum_raw, vec3(EPS));

    // Select color filter mode
    vec3 color;
    if (COLOR_FILTER_MODE < 0.5) {
        if (NOTCH_TEST_LP > 0.5) {
            color_notch.r -= identity - luma_hp / max(wsum_hp, EPS);
        } else if (NOTCH_TEST_HP > 0.5) {
            color_notch.r = identity - luma_hp / max(wsum_hp, EPS);
        }
        color = color_notch;
    } else if (COLOR_FILTER_MODE < 1.5) {
        color = color_comb;
    } else if (COLOR_FILTER_MODE < 2.5) {
        color = mix(color_notch, color_comb, NOTCH_COMB_W);
    } else if (COLOR_FILTER_MODE < 3.5) {
        float phase_identity = compute_carrier_phase(t_identity, tb.sc_freq_hz, tb.field_phase);
        vec2 carrier_identity = sincos_phase(phase_identity);
        float chroma = 2.0 * color_raw.g * carrier_identity.x
            + 2.0 * color_raw.b * carrier_identity.y;
        color.r = identity - chroma;
        color.gb = color_raw.gb;
    } else {
        color = color_raw;
    }

    if (BW_MODE > 0.5) {
        color = color_raw;
        color.g = 0.0;
        color.b = 0.0;
    }

    // Adjust chroma amplitude
    color.g *= 2.0;
    color.b *= 2.0;
    FragColor = vec4(color, 1.0);
}
