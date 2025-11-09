#version 450

/* Filename: sys-yc-bs-bp.slang

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

     System-level YC filtering stage applying a horizontal notch (band-stop) to
     luma (Y) and a horizontal band-pass to chroma (C) using modulated Gaussian
     kernels. Intended to emulate composite/S-Video style system bandwidth
     shaping after color encoding but before full demod/decoding.

     Technique: "Modulated Gaussian" as used in composite-mod-prefilter.slang.
     We construct Gaussian envelopes and modulate them by cos(2π f_sc n) to
     center the spectral action at the subcarrier frequency for chroma.

     Sigma selection: uses sigma_tb() from modulation.inc to map (width/2, edge dB)
     into Gaussian σ in texels, based on the current timebase.

     Luma (Y) notch:
         y_out = y - alpha * (Gσ * composite)_cos
         where alpha is derived from desired notch center attenuation.

     Chroma (C) band-pass:
         c_out = gain * (Gσ_bp * composite)_cos  (modulated Gaussian centered at f_sc)
         Normalization factors compensate cos modulation energy (empirical).

     Parameters are system-level equivalents; names prefixed with SYS_ to
     avoid collision with the composite modulation stage.

     Bypasses:
         SYS_YC_BS_BP_BYPASS            -> pass-through of input YC
         SYS_YC_BS_BP_FILTER_BYPASS     -> output raw Y and C w/o filters

     Output: vec4(Y, C, 0, 1)
*/

#include "common.h"
#include "color.h"
#include "modulation.inc"

#pragma name SysYCNotchBandpass
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;

    // Timing / subcarrier
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;

    // Bypasses
    float SYS_YC_BS_BP_BYPASS;        // 0 or 1
    float SYS_YC_BS_BP_FILTER_BYPASS; // 0 or 1

    // Notch design (Y)
    float SYS_NOTCH_WIDTH;           // MHz, symmetric width about f_sc
    float SYS_NOTCH_CENTER_ATTEN_DB; // Desired center attenuation (dB)
    float SYS_NOTCH_EDGE_ATTEN_DB;   // Attenuation at ±width edge (dB)

    // Band-pass design (C)
    float SYS_BANDPASS_WIDTH;        // MHz, approximate -3dB width
    float SYS_BANDPASS_EDGE_ATTEN_DB; // Edge attenuation (dB) for sigma derivation

    // Gains
    float SYS_GAIN_Y;    // Post-notch luma gain
    float SYS_GAIN_C;    // Post-bandpass chroma gain
} config;

// UI parameters
#pragma parameter SYS_YC_HEADER " ==== System YC Notch/Band-Pass Parameters ==== " 0.0 0.0 0.0 0.0
#pragma parameter SYS_YC_BS_BP_BYPASS "System YC notch+bandpass bypass" 0.0 0.0 1.0 1.0
#pragma parameter SYS_YC_BS_BP_FILTER_BYPASS "System YC filter bypass (encode only)" 0.0 0.0 1.0 1.0

// Luma notch
#pragma parameter SYS_NOTCH_WIDTH "System Y notch width (MHz)" 2.6 0.01 10.0 0.01
#pragma parameter SYS_NOTCH_CENTER_ATTEN_DB "System Y notch center attenuation (dB)" 48.0 0.0 120.0 0.5
#pragma parameter SYS_NOTCH_EDGE_ATTEN_DB "System Y notch edge attenuation (dB)" 3.0 0.0 20.0 0.1

// Chroma band-pass
#pragma parameter SYS_BANDPASS_WIDTH "System C band-pass width (MHz)" 2.6 0.01 10.0 0.01
#pragma parameter SYS_BANDPASS_EDGE_ATTEN_DB "System C band-pass edge attenuation (dB)" 3.0 0.0 20.0 0.1

// Gains
#pragma parameter SYS_GAIN_Y "System Gain Y" 1.0 0.0 10.0 0.01
#pragma parameter SYS_GAIN_C "System Gain C" 1.0 0.0 10.0 0.01

// Timing UI (mirrored for consistency with other system shaders)
#pragma parameter V_FREQ "Vertical frequency (Hz)" 59.94 1.0 240.0 0.01
#define V_FREQ config.V_FREQ
#pragma parameter V_LINES_PER_FIELD "Video lines per field" 262.5 0.0 540.0 0.5
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#define SC_FREQ_MODE config.SC_FREQ_MODE
#pragma parameter SC_FREQ "Custom subcarrier frequency (MHz)" 3.579545 0.0 10.0 0.000001
#define SC_FREQ config.SC_FREQ
#define H_FREQ_HZ (V_FREQ * V_LINES_PER_FIELD)
#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT

// Macros
#define BYPASS_STAGE config.SYS_YC_BS_BP_BYPASS
#define BYPASS_FILTER config.SYS_YC_BS_BP_FILTER_BYPASS
#define NOTCH_W_MHZ config.SYS_NOTCH_WIDTH
#define NOTCH_CENTER_DB config.SYS_NOTCH_CENTER_ATTEN_DB
#define NOTCH_EDGE_DB config.SYS_NOTCH_EDGE_ATTEN_DB
#define BP_W_MHZ config.SYS_BANDPASS_WIDTH
#define BP_EDGE_DB config.SYS_BANDPASS_EDGE_ATTEN_DB
#define G_Y config.SYS_GAIN_Y
#define G_C config.SYS_GAIN_C

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
void main(){
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main(){
    if(BYPASS_STAGE >= 1.0){
        vec2 yc_passthrough = texture(Source, vTexCoord).rg;
        FragColor = vec4(yc_passthrough, 0.0, 1.0);
        return;
    }

    // Timebase
    TimebaseConfig tb = compute_timebase(
        float(config.FrameCount),
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);

    // Per-output-pixel time
    float pixel_time_px = tb.pixel_time_px;
    float f_sc_px = tb.sc_freq_hz * pixel_time_px; // cycles per output pixel

    // Set up horizontal traversal with nearest pixel-center addressing (horizontal-only)
    vec2 UV  = vTexCoord * config.OutputSize.xy;
    float baseIndex = floor(UV.x + 0.5);       // round to nearest pixel index
    float baseCenter = baseIndex + 0.5;        // center position in pixel units
    float Ax = UV.x - baseCenter;              // offset from center in [-0.5, 0.5]
    vec2 Tex = vec2(baseCenter * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx  = vec2(config.OutputSize.z, 0.0);

    // Center sample (assumes Source stores Y in .r and C in .g)
    vec2 yc0 = texture(Source, Tex).rg;

    if(BYPASS_FILTER >= 1.0){
        FragColor = vec4(yc0.x * G_Y, yc0.y * G_C, 0.0, 1.0);
        return;
    }

    // Design parameters
    float a_center = pow(10.0, -NOTCH_CENTER_DB / 20.0);
    float alpha    = clamp(2.0 * (1.0 - a_center), 0.0, 2.0); // notch strength scalar

    // Sigma via sigma_tb (cutoff = width/2, attenuation = edge dB)
    float sigma_notch = sigma_tb(tb, max(NOTCH_W_MHZ * 0.5, 1e-6), NOTCH_EDGE_DB);
    float sigma_bp    = sigma_tb(tb, max(BP_W_MHZ    * 0.5, 1e-6), BP_EDGE_DB);

    const float THRESHOLD = 1.0 / 510.0;

    // Accumulators
    float conv_notch = 0.0; // Σ gσ(n)*cos(2π f_sc n)*composite(n)
    float sum_notch  = 0.0; // Σ gσ(n)

    float conv_bp = 0.0;    // Σ gσ_bp(n)*cos(2π f_sc n)*composite(n)
    float sum_bp  = 0.0;    // Σ gσ_bp(n)

    // Approximate composite signal from incoming YC to drive kernels
    float composite0 = yc0.x + yc0.y;

    // Center weights
    float g_notch0 = gaussian(Ax, sigma_notch);
    float w_notch0 = g_notch0 * cos(2.0 * PI * f_sc_px * Ax);
    conv_notch += w_notch0 * composite0;
    sum_notch  += g_notch0;

    float g_bp0 = gaussian(Ax, sigma_bp);
    float w_bp0 = g_bp0 * cos(2.0 * PI * f_sc_px * Ax);
    conv_bp += w_bp0 * composite0;
    sum_bp  += g_bp0;

    // Symmetric lobes
    for(int n=1; n<=32; ++n){
        float nf = float(n);
        // Symmetric distances from kernel center: right = n - Ax, left = n + Ax
        float gN_r = gaussian(nf - Ax, sigma_notch);
        float gN_l = gaussian(nf + Ax, sigma_notch);
        float gB_r = gaussian(nf - Ax, sigma_bp);
        float gB_l = gaussian(nf + Ax, sigma_bp);
        if((gN_r < THRESHOLD && gN_l < THRESHOLD) && (gB_r < THRESHOLD && gB_l < THRESHOLD)) break;

        vec2 ycR = texture(Source, Tex + float(n) * dx).rg;
        vec2 ycL = texture(Source, Tex - float(n) * dx).rg;
        float compositeR = ycR.x + ycR.y;
        float compositeL = ycL.x + ycL.y;

        // Modulated Gaussian weights with correct distances
        float w_notch_r = gN_r * cos(2.0 * PI * f_sc_px * (nf - Ax));
        float w_notch_l = gN_l * cos(2.0 * PI * f_sc_px * (nf + Ax));
        conv_notch += w_notch_r * compositeR + w_notch_l * compositeL;
        sum_notch  += gN_r + gN_l;

        float w_bp_r = gB_r * cos(2.0 * PI * f_sc_px * (nf - Ax));
        float w_bp_l = gB_l * cos(2.0 * PI * f_sc_px * (nf + Ax));
        conv_bp    += w_bp_r * compositeR + w_bp_l * compositeL;
        sum_bp     += gB_r + gB_l;
    }

    // Form notch response for Y and band-pass for C
    float notch_resp = conv_notch / max(sum_notch, EPS);
    float y_filtered = 0.8 * (yc0.x - alpha * notch_resp);
    float c_bp       = 1.2 * 2.0 * conv_bp / max(sum_bp, EPS);

    // Apply gains
    y_filtered *= G_Y;
    c_bp       *= G_C;

    FragColor = vec4(y_filtered, c_bp, 0.0, 1.0);
}
