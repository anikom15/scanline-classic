#version 450

// Filename: composite-iq.slang
//
// Generates analytic baseband (I + jQ) from RGB by:
// 1) Computing composite baseband from RGB
// 2) Applying a Hilbert transform (Type III FIR, odd-only taps) to get Q
//
// Output format: R16G16_SFLOAT (R=I, G=Q)

#include "common.inc"
#include "modulation.inc"

#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/sys-encode.inc"

#pragma parameter BYPASS_COMPOSITE_MOD "Bypass composite modulation (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter HILBERT_BYPASS "Bypass Hilbert (I only)" 0.0 0.0 1.0 1.0

#pragma name CompositeIQ
#pragma format R16G16_SFLOAT

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float BYPASS_COMPOSITE_MOD;
    float V_FREQ_MODE;
    float V_FREQ;
    float V_LINES_PER_FIELD;
    float SHORTEN_ODD_FIELD_TIME;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float H_BLANK_INACTIVE_LEN;
    float H_BLANK_INACTIVE_UNIT;
    float ENCODER_SETUP;
    float PAL;
    float HILBERT_BYPASS;
} config;

#define BYPASS_COMPOSITE_MOD config.BYPASS_COMPOSITE_MOD
#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define V_LINES_PER_FIELD config.V_LINES_PER_FIELD
#define SHORTEN_ODD_FIELD_TIME config.SHORTEN_ODD_FIELD_TIME
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define H_BLANK_INACTIVE_LEN config.H_BLANK_INACTIVE_LEN
#define H_BLANK_INACTIVE_UNIT config.H_BLANK_INACTIVE_UNIT
#define ENCODER_SETUP config.ENCODER_SETUP
#define PAL config.PAL
#define HILBERT_BYPASS config.HILBERT_BYPASS

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// Hilbert transform taps (fixed, odd-only). Windowing is implicit by truncation.
const int HILBERT_TAPS = 31; // odd length preferred for Type III FIR

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 6) out TimebaseConfig tb;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;

    tb = compute_timebase(
        config.FrameCount,
        vTexCoord,
        config.OriginalSize.xy,
        config.OutputSize.x,
        V_FREQ_MODE,
        config.OriginalFPS,
        V_FREQ,
        V_LINES_PER_FIELD,
        SHORTEN_ODD_FIELD_TIME,
        SC_FREQ_MODE,
        SC_FREQ,
        H_BLANK_INACTIVE_LEN,
        H_BLANK_INACTIVE_UNIT);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 6) in TimebaseConfig tb;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Compute composite baseband from input RGB at time t
float compute_composite_baseband(vec3 pixel, float t, vec2 pal_phase)
{
    float phase = compute_carrier_phase(t, tb.sc_freq_hz, tb.field_phase);
    vec2 phase2 = vec2(phase) + pal_phase;
    phase2 = vec2(normalize_phase(phase2.x), normalize_phase(phase2.y));
    vec2 carrier = sincos_phase_raw(phase2);
    float chroma = pixel.g * carrier.x + pixel.b * carrier.y;

    float y_gain = 1.0;
    float y_offset = 0.0;
    if (ENCODER_SETUP > 0.5) {
        y_gain = 0.925;
        y_offset = 0.075;
    }

    return y_gain * (pixel.r + y_offset) + chroma;
}

void main()
{
    if (BYPASS_COMPOSITE_MOD > 0.5) {
        vec3 rgb = texture(Source, vTexCoord).rgb;
        FragColor = vec4(rgb.r, 0.0, 0.0, 1.0);
        return;
    }

    vec2 UV = vTexCoord * config.OutputSize.xy;
    float line = floor(UV.y);
    float baseIndex = floor(UV.x);
    float baseCenter = baseIndex + 0.5;
    float Ax = UV.x - baseCenter;

    vec2 Tex = vec2(
        baseCenter * config.OutputSize.z,
        (line + 0.5) * config.OutputSize.w);

    float offset0 = baseCenter;
    vec2 pal_phase_base = vec2(0.0, floor(mod(line, 2.0)) * PI * PAL);
    float t0 = line / tb.h_freq_hz + offset0 * tb.pixel_time_px;

    vec2 dx = vec2(config.OutputSize.z, 0.0);

    // Central sample
    vec3 pixel0 = texture(Source, Tex).rgb;
    float i_analytic = compute_composite_baseband(pixel0, t0, pal_phase_base);

    float q_analytic = 0.0;
    if (HILBERT_BYPASS <= 0.5) {
        float q_wsum = 0.0;
        // Hilbert transform approximation (Type III FIR, odd-only)
        for (int n = 1; n <= HILBERT_TAPS; ++n) {
            if ((n & 1) == 0) continue; // odd-only
            float nf = float(n);

            // Right sample
            vec2 tex_r = Tex + nf * dx;
            vec3 pixel_r = texture(Source, tex_r).rgb;
            float t_r = t0 + nf * tb.pixel_time_px;
            float comp_r = compute_composite_baseband(pixel_r, t_r, pal_phase_base);
            float pos_r = nf - Ax;
            float sin_r = sin(PI * pos_r * 0.5);
            float h_r = (2.0 / PI) * (sin_r * sin_r) / pos_r;

            // Left sample
            vec2 tex_l = Tex - nf * dx;
            vec3 pixel_l = texture(Source, tex_l).rgb;
            float t_l = t0 - nf * tb.pixel_time_px;
            float comp_l = compute_composite_baseband(pixel_l, t_l, pal_phase_base);
            float pos_l = -nf - Ax;
            float sin_l = sin(PI * pos_l * 0.5);
            float h_l = (2.0 / PI) * (sin_l * sin_l) / pos_l;

            q_analytic += h_r * comp_r + h_l * comp_l;
            q_wsum += abs(h_r) + abs(h_l);
        }
        q_analytic /= max(q_wsum, EPS);
    }

    FragColor = vec4(i_analytic, q_analytic, 0.0, 1.0);
}
