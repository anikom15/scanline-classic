#version 450

/* Filename: sys-component.slang

   Encodes linear RGB into a chosen luma-chroma color space (YIQ / YPbPr / YUV / YDbDr / YCbCr),
   then optionally bandlimits each component with a horizontal Gaussian (lobe technique) to
   approximate analog system bandwidth. Component-wise SYS_GAIN/SYS_BIAS are applied after filtering.

   Notes:
   - YDbDr is implemented by first computing YUV, then scaling chroma:
       Db = (1.333 / 0.436) * U  ≈  3.05688 * U
       Dr = (-1.333 / 0.615) * V ≈ -2.16829 * V
   - Bandwidth/attenuation to sigma mapping uses sigma601() (BT.601-style) from bandlimit.inc.
   - Filtering is performed in the color space domain, not RGB, to better emulate analog chains.
   - Bypasses:
       SYS_COMPONENT_BYPASS          -> output source RGB unmodified (skip color conversion + filter)
       SYS_COMPONENT_FILTER_BYPASS   -> convert to selected color space and apply SYS_GAIN/BIAS, but skip filtering
*/

#include "common.h"
#include "color.h"
#include "bandlimit.inc"
#include "modulation.inc"

#pragma name SysComponent
#pragma format R16G16B16A16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;

    // Timing parameters for timebase computation
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;

    // Bypasses
    float SYS_COMPONENT_BYPASS;        // 0 or 1
    float SYS_COMPONENT_FILTER_BYPASS; // 0 or 1

    // Color model selection
    float YC_MODEL; // 0=YIQ, 1=YPbPr, 2=YUV, 3=YDbDr, 4=YCbCr

    // Per-component analog bandlimit (MHz/dB), mapped via sigma601
    float SYS_BANDWIDTH_Y;     // default 6.75 MHz
    float SYS_BANDWIDTH_U;     // default 1.30 MHz (or Db)
    float SYS_BANDWIDTH_V;     // default 1.30 MHz (or Dr)
    float SYS_CUTOFF_ATTEN_Y;  // default 3 dB
    float SYS_CUTOFF_ATTEN_U;  // default 2 dB
    float SYS_CUTOFF_ATTEN_V;  // default 2 dB

    // Post-filter gain/bias per component
    float SYS_GAIN_Y;
    float SYS_GAIN_U;
    float SYS_GAIN_V;
} config;

// UI parameters
#pragma parameter SYS_COMPONENT_HEADER " ==== System Component Parameters ==== " 0.0 0.0 0.0 0.0
#pragma parameter SYS_COMPONENT_BYPASS "System component bypass" 0.0 0.0 1.0 1.0
#pragma parameter SYS_COMPONENT_FILTER_BYPASS "System component filter bypass" 0.0 0.0 1.0 1.0

#pragma parameter YC_MODEL "YC color model (0=YIQ,1=YPbPr,2=YUV,3=YDbDr,4=YCbCr)" 1.0 0.0 4.0 1.0

#pragma parameter SYS_BANDWIDTH_Y "System Luma (Y) bandwidth (MHz)" 5.4 0.0 75.0 0.01
#pragma parameter SYS_BANDWIDTH_U "System Chroma (U) bandwidth (MHz)" 3.6 0.0 15.0 0.01
#pragma parameter SYS_BANDWIDTH_V "System Chroma (V) bandwidth (MHz)" 3.6 0.0 15.0 0.01

#pragma parameter SYS_CUTOFF_ATTEN_Y "System Y cutoff attenuation (dB)" 12.5 0.0 30.0 1.0
#pragma parameter SYS_CUTOFF_ATTEN_U "System U cutoff attenuation (dB)" 20.0 0.0 30.0 1.0
#pragma parameter SYS_CUTOFF_ATTEN_V "System V cutoff attenuation (dB)" 20.0 0.0 30.0 1.0

#pragma parameter SYS_GAIN_Y "System Gain Y" 1.0 0.0 10.0 0.01
#pragma parameter SYS_GAIN_U "System Gain U" 1.0 0.0 10.0 0.01
#pragma parameter SYS_GAIN_V "System Gain V" 1.0 0.0 10.0 0.01

#pragma parameter SYS_BIAS_Y "System Bias Y" 0.0 -1.0 1.0 0.001
#pragma parameter SYS_BIAS_U "System Bias U" 0.0 -1.0 1.0 0.001
#pragma parameter SYS_BIAS_V "System Bias V" 0.0 -1.0 1.0 0.001

// Timing UI parameters
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

// Short-hand macros
#define SYS_COMPONENT_BYPASS        config.SYS_COMPONENT_BYPASS
#define SYS_COMPONENT_FILTER_BYPASS config.SYS_COMPONENT_FILTER_BYPASS

#define MODEL config.YC_MODEL

#define BW_Y  config.SYS_BANDWIDTH_Y
#define BW_U  config.SYS_BANDWIDTH_U
#define BW_V  config.SYS_BANDWIDTH_V
#define ATN_Y config.SYS_CUTOFF_ATTEN_Y
#define ATN_U config.SYS_CUTOFF_ATTEN_U
#define ATN_V config.SYS_CUTOFF_ATTEN_V

#define G_Y config.SYS_GAIN_Y
#define G_U config.SYS_GAIN_U
#define G_V config.SYS_GAIN_V

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
    float SYS_BIAS_Y;
    float SYS_BIAS_U;
    float SYS_BIAS_V;
} global;

#define B_Y global.SYS_BIAS_Y
#define B_U global.SYS_BIAS_U
#define B_V global.SYS_BIAS_V

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

// Convert RGB to selected luma-chroma space.
// For YDbDr: RGB -> YUV -> scale (U,V) to (Db,Dr).
vec3 rgb_to_luma_chroma(vec3 rgb, float model)
{
    if (model < 0.5) { // YIQ
        return RGB_TO_YIQ * rgb;
    } else if (model < 1.5) { // YPbPr
        return RGB_TO_YPbPr * rgb;
    } else if (model < 2.5) { // YUV
        return RGB_TO_YUV * rgb;
    } else if (model < 3.5) { // YDbDr via YUV scale
        vec3 yuv = RGB_TO_YUV * rgb;
        // Db = (1.333 / 0.436) * U ; Dr = (-1.333 / 0.615) * V
        const float K_DB_FROM_U = 1.333 / 0.436;  // ≈ 3.056880734
        const float K_DR_FROM_V = -1.333 / 0.615; // ≈ -2.168292683
        return vec3(yuv.r, K_DB_FROM_U * yuv.g, K_DR_FROM_V * yuv.b);
    } else { // YCbCr
        return RGB_TO_YCbCr * rgb;
    }
}

layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
    // Full stage bypass: pass through RGB
    if (SYS_COMPONENT_BYPASS >= 1.0) {
        FragColor = vec4(texture(Source, vTexCoord).rgb, 1.0);
        return;
    }

    // Filter bypass: convert once and apply SYS_GAIN/BIAS only
    if (SYS_COMPONENT_FILTER_BYPASS >= 1.0) {
        vec3 yc = rgb_to_luma_chroma(texture(Source, vTexCoord).rgb, MODEL);
        yc.x = yc.x * G_Y + B_Y;
        yc.y = yc.y * G_U + B_U;
        yc.z = yc.z * G_V + B_V;
        FragColor = vec4(yc, 1.0);
        return;
    }

    // Precompute per-component sigmas (in texels) from MHz/dB specs.
    // We reuse the vec3 return as (Y, U/Db, V/Dr).
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
        H_BLANK_INACTIVE_UNIT
    );
    vec3 sigma;
    sigma.x = sigma_tb(tb, BW_Y, ATN_Y);
    sigma.y = sigma_tb(tb, BW_U, ATN_U);
    sigma.z = sigma_tb(tb, BW_V, ATN_V);

    // Horizontal Gaussian convolution in the chosen luma-chroma space.
    // Follows a lobe technique similar to bandlimit_convolve_gaussian_x,
    // but transforms each sample to the selected color model and applies
    // component-wise weights/sigmas.
    const float THRESHOLD = 1.0 / 510.0;

    // Horizontal coordinate handling per bandlimit.inc (no vertical shift)
    vec2 UV  = vTexCoord * config.OutputSize.xy;
    float UX = UV.x - 0.5;
    float Ax = fract(UX);
    vec2 Tex = vec2((floor(UX) + 0.5) * config.OutputSize.z,
                    (floor(UV.y) + 0.5) * config.OutputSize.w);
    vec2 dx  = vec2(config.OutputSize.z, 0.0); // one texel to the right

    // Accumulators and weights for Y, U/Db, V/Dr
    vec3 accum = vec3(0.0);
    vec3 wsum  = vec3(0.0);

    // Center sample
    vec3 rgb0 = texture(Source, Tex).rgb;
    vec3 yc_c = rgb_to_luma_chroma(rgb0, MODEL);

    float wy = gaussian(Ax, sigma.x);
    float wu = gaussian(Ax, sigma.y);
    float wv = gaussian(Ax, sigma.z);

    accum += vec3(wy * yc_c.x, wu * yc_c.y, wv * yc_c.z);
    wsum  += vec3(wy, wu, wv);

    // Symmetric lobes
    // Limited to 32 iterations for faster shader compilation
    // Gaussian weights fall off rapidly, so early exit handles quality
    for (int n = 1; n <= 32; ++n) {
        float nf = float(n);
        float wy_r = gaussian(nf + Ax, sigma.x);
        float wy_l = gaussian(nf - Ax, sigma.x);
        float wu_r = gaussian(nf + Ax, sigma.y);
        float wu_l = gaussian(nf - Ax, sigma.y);
        float wv_r = gaussian(nf + Ax, sigma.z);
        float wv_l = gaussian(nf - Ax, sigma.z);

        // Early out if all components negligible on both sides
        if (wy_r < THRESHOLD && wy_l < THRESHOLD &&
            wu_r < THRESHOLD && wu_l < THRESHOLD &&
            wv_r < THRESHOLD && wv_l < THRESHOLD)
            break;

        vec3 rgbr = texture(Source, Tex + nf * dx).rgb;
        vec3 rgbl = texture(Source, Tex - nf * dx).rgb;

        vec3 yc_r = rgb_to_luma_chroma(rgbr, MODEL);
        vec3 yc_l = rgb_to_luma_chroma(rgbl, MODEL);

        // Accumulate right and left for each component
        accum.x += wy_r * yc_r.x + wy_l * yc_l.x;
        accum.y += wu_r * yc_r.y + wu_l * yc_l.y;
        accum.z += wv_r * yc_r.z + wv_l * yc_l.z;

        wsum.x  += wy_r + wy_l;
        wsum.y  += wu_r + wu_l;
        wsum.z  += wv_r + wv_l;
    }

    // Normalize and apply per-component SYS_GAIN/SYS_BIAS
    vec3 outyc = accum / max(wsum, vec3(EPS));
    outyc.x = outyc.x * G_Y + B_Y;
    outyc.y = outyc.y * G_U + B_U;
    outyc.z = outyc.z * G_V + B_V;

    // Emit in the selected luma-chroma space
    FragColor = vec4(outyc, 1.0);
}