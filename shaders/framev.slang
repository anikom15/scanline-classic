#version 450

// Filename: framev.slang
//
// Copyright (C) 2026 W. M. Martinez
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
//
// Vertical zero-stuffing and interlace expansion
// ----------------------------------------------
// Consumes the already-framed 1D field signal from `frameh.slang` and the
// downstream DSP chain, expands it to the display frame height, and applies
// scanline blanking / interlace placement. No additional cropping or source
// framing is performed here.
//
// Assumes linear color space

#pragma name FrameV
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/scanraster.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

// Push constants
layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    uint CurrentSubFrame;
    uint TotalSubFrames;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float DOUBLE_REFRESH;
    float SCANLINE_BLANK_WEIGHT;
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define H_BLANK_FUZZ config.H_BLANK_FUZZ

#define DOUBLE_REFRESH config.DOUBLE_REFRESH
#define SCANLINE_BLANK_WEIGHT config.SCANLINE_BLANK_WEIGHT

// Subframe support
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames
#define HAS_SUBFRAMES (TOTAL_SUBFRAMES > 1u)

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

// Input carries the already-framed field raster from `frameh.slang` and the
// true-1D resampler stages. Timing-derived placement comes from the contract
// API rather than any texture-carried metadata payload.
struct FrameVState {
    float v_scale;
    float data_top_scaled;
    float frame_height;
    float full_height;
    float is_interlaced;
    float field;
    float effective_double_refresh;
    float subframe_field_offset;
    float num_blanks;
    float is_odd_blanks;
    float line_period;
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out FrameVState vFrameState;

FrameVState compute_framev_state()
{
    FrameVState state;

    float frame_height = contract_frame_height(
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    float full_frame_height = contract_full_frame_height(
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    state.frame_height = max(frame_height, 1.0);
    state.full_height = max(full_frame_height, state.frame_height);
    state.is_interlaced = contract_is_interlaced(
        config.OriginalSize.xy,
        config.OriginalFPS,
        V_FREQ_MODE,
        V_FREQ,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    state.field = contract_field(config.FrameCount);

    // All fields in `FrameVState` depend only on uniforms / frame state, so
    // compute them once per vertex and pass them to the fragment stage.
    // Use integer vertical scaling and anchor the signal to the top-left so
    // any unused space remains only at the bottom / right edges.
    state.v_scale = max(floor(config.OutputSize.y / max(state.full_height, 1.0)), 1.0);
    state.effective_double_refresh = (DOUBLE_REFRESH > 0.5) ? 1.0 : 0.0;

    state.subframe_field_offset = 0.0;
    if (state.is_interlaced > 0.5 && HAS_SUBFRAMES && state.effective_double_refresh > 0.5)
        state.subframe_field_offset = float(CURRENT_SUBFRAME);

    state.line_period = (state.is_interlaced > 0.5 && state.effective_double_refresh < 0.5)
        ? state.v_scale * 2.0
        : state.v_scale;
    state.num_blanks = max(state.line_period - 1.0, 0.0);
    state.is_odd_blanks = mod(state.num_blanks, 2.0) > 0.5 ? 1.0 : 0.0;
    state.data_top_scaled = 0.0;

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vFrameState = compute_framev_state();
}


#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in FrameVState vFrameState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

// Compute the blank-row dimming strength for the current position inside one
// zero-stuffed scanline block.
float compute_blank_mix(float blank_index, float line_period, FrameVState state)
{
    float blank_center = blank_index + 0.5;
    float blank_mix = SCANLINE_BLANK_WEIGHT / 100.0;

    if (state.num_blanks > 1.0) {
        float dist_current = blank_center - 0.5;
        float dist_next = (line_period + 0.5) - blank_center;
        float min_dist = min(dist_current, dist_next);
        float max_min_dist = line_period / 2.0;
        float weight_factor = min_dist / max_min_dist;

        float sum_of_dists = state.is_odd_blanks > 0.5
            ? (state.num_blanks + 1.0) * (state.num_blanks + 1.0) / 4.0
            : state.num_blanks * (state.num_blanks + 2.0) / 4.0;
        float sum_weights = 2.0 * sum_of_dists / line_period;

        blank_mix *= weight_factor / sum_weights * state.num_blanks;
    }

    return blank_mix;
}

vec3 sample_source_signal(float output_x, float source_y)
{
    if (output_x < 0.0 || output_x >= config.SourceSize.x || source_y < 0.0 || source_y >= config.SourceSize.y)
        return vec3(0.0);

    vec2 source_tex = (vec2(floor(output_x), floor(source_y)) + 0.5) * config.SourceSize.zw;
    return texture(Source, source_tex).rgb;
}

// Map an output texel back into the 1D source field and apply the
// zero-stuffing / scanline blanking pattern for the non-live rows.
vec3 sample_signal_content(float output_x, float output_y, FrameVState state)
{
    float effective_field = state.field + state.subframe_field_offset;
    float field_phase_offset = (state.is_interlaced > 0.5 && state.effective_double_refresh < 0.5)
        ? mod(effective_field, 2.0) * state.v_scale
        : 0.0;

    float scaled_signal_y = output_y - state.data_top_scaled - field_phase_offset;
    float original_y = floor(scaled_signal_y / state.line_period);

    if (scaled_signal_y < 0.0 || original_y < 0.0 || original_y >= ceil(state.frame_height))
        return vec3(0.0);

    vec3 base = sample_source_signal(output_x, original_y);

#ifdef OPTION_NOSCANLINES
    return base;
#endif  // OPTION_NOSCANLINES

    float v_scanline_offset = mod(scaled_signal_y, state.line_period);
    if (v_scanline_offset < 1.0)
        return base;

    float blank_index = floor(v_scanline_offset);
    float blank_mix = compute_blank_mix(blank_index, state.line_period, state);
    return mix(base, vec3(0.0), blank_mix);
}

// Average the gain reduction introduced by the blank rows. The value is packed
// into alpha so downstream passes can compensate if they need a normalized
// live-signal gain estimate.
float average_signal_gain(FrameVState state)
{
    float num_blanks_local = max(state.line_period - 1.0, 0.0);
    float base = SCANLINE_BLANK_WEIGHT / 100.0;
    float avg_blank_mix = (state.line_period > 0.0) ? base * (num_blanks_local / state.line_period) : 0.0;
    return clamp(1.0 - avg_blank_mix, 0.0, 1.0);
}

void main()
{
    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);

    vec3 color = sample_signal_content(output_x, output_y, vFrameState);
    FragColor = vec4(color, average_signal_gain(vFrameState));
}
