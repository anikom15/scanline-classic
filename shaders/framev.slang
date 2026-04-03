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
// Vertical framing and zero-stuffing
// ----------------------------------
// Maps input texture to full frame height, scales by integer multiples,
// and applies zero-stuffing (renders each scanline once with blanking
// gaps between). Horizontal framing is expected to be applied earlier.
//
// Assumes linear color space

#pragma name FrameV
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/scanraster.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_FRAME_HEADER " —— Debug Frame —— " 0.0 0.0 0.0 0.0
#pragma parameter FRAME_VIZ_ACTIVE "Show active content" 1.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_BLANKING "Show frame blanking (yellow)" 0.0 0.0 1.0 1.0
#pragma parameter FRAME_VIZ_PADDING "Show padding (magenta)" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

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

#ifdef OPTION_DEBUG
    float FRAME_VIZ_ACTIVE;
    float FRAME_VIZ_BLANKING;
    float FRAME_VIZ_PADDING;
#endif  // OPTION_DEBUG

} config;

#ifdef OPTION_DEBUG
#define FRAME_VIZ_ACTIVE config.FRAME_VIZ_ACTIVE
#define FRAME_VIZ_BLANKING config.FRAME_VIZ_BLANKING
#endif  // OPTION_DEBUG

#ifdef OPTION_DEBUG
#define FRAME_VIZ_PADDING config.FRAME_VIZ_PADDING
#endif  // OPTION_DEBUG

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

// Input carries the horizontally framed raster from `frameh.slang`.
// Timing-derived placement now comes from the contract API rather than
// texture-carried metadata.
struct FrameVState {
    float v_scale;
    float full_pad_top;
    float active_top_scaled;
    float full_height_int;
    float is_interlaced;
    float field;
    float effective_double_refresh;
    float subframe_field_offset;
    float num_blanks;
    float is_odd_blanks;
    float frame_width;
};

FrameVState compute_framev_state()
{
    FrameVState state;

    float frame_width = contract_frame_width(
        config.OriginalSize.xy,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);

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

    state.frame_width = max(frame_width, 1.0);
    state.full_height_int = floor(max(full_frame_height, frame_height));
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

    // Choose the integer line scale used for the zero-stuffed output frame.
    state.v_scale = max(round(config.OutputSize.y / max(state.full_height_int, 1.0)), 1.0);
    state.effective_double_refresh = (DOUBLE_REFRESH > 0.5) ? 1.0 : 0.0;

    // When double-refreshing interlaced content with subframes, parity can
    // advance per subframe rather than only once per host frame.
    state.subframe_field_offset = 0.0;
    if (state.is_interlaced > 0.5 && HAS_SUBFRAMES && state.effective_double_refresh > 0.5)
        state.subframe_field_offset = float(CURRENT_SUBFRAME);

    // Precompute the blank-line pattern so the fragment stage only has to look
    // up the current blank index and mix weight.
    float effective_scale = (state.is_interlaced > 0.5)
        ? (state.effective_double_refresh > 0.5 ? state.v_scale : state.v_scale * 2.0)
        : state.v_scale;
    state.num_blanks = effective_scale - 1.0;
    state.is_odd_blanks = mod(state.num_blanks, 2.0) > 0.5 ? 1.0 : 0.0;

    // Center the full framed image vertically, then locate the active region
    // within that framed height.
    float scaled_full_height = state.full_height_int * state.v_scale;
    state.full_pad_top = floor((config.OutputSize.y - scaled_full_height) * 0.5);
    state.active_top_scaled = state.full_pad_top
        + floor((scaled_full_height - config.SourceSize.y * state.v_scale) * 0.5);

    return state;
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
layout(set = 0, binding = 2) uniform sampler2D Source;

// Map an output texel back into the active source raster and then apply the
// zero-stuffing / scanline blanking pattern for the non-live rows.
vec3 sample_active_content(float output_x, float output_y, FrameVState state)
{
    float scaled_active_y = output_y - state.active_top_scaled;

    // Horizontal framing is already resolved upstream, so x maps directly to
    // the framed raster. Vertically, undo the integer scaling to find the
    // originating source scanline and the position inside the scaled block.
    float original_x = floor(output_x);
    float original_y = floor(scaled_active_y / state.v_scale);
    float v_scanline_offset = mod(scaled_active_y, state.v_scale);

    if (v_scanline_offset > state.v_scale / 2.0)
        original_y += 1.0;

    // Clamp against the exact metadata width while keeping the original active
    // source height for vertical addressing.
    original_x = clamp(original_x, 0.0, state.frame_width - 1.0);
    original_y = clamp(original_y, 0.0, config.SourceSize.y - 1.0);

    vec3 base = texture(Source, (vec2(original_x, original_y) + 0.5) / config.SourceSize.xy).rgb;

#ifdef OPTION_NOSCANLINES
    return base;
#endif  // OPTION_NOSCANLINES

    bool scaled_blank_line = v_scanline_offset >= 1.0;

    // Interlaced content needs both parity-aware field blanking and the usual
    // scaled blank rows between live scanlines.
    if (state.is_interlaced > 0.5) {
        float effective_field = state.field + state.subframe_field_offset;
        int field_parity = int(mod(effective_field, 2.0));
        int line_parity = int(mod(original_y, 2.0));
        bool parity_mismatch = line_parity != field_parity;

        if (state.effective_double_refresh > 0.5) {
            if (!scaled_blank_line)
                return base;
        } else {
            if (!parity_mismatch && !scaled_blank_line)
                return base;
        }

        float blank_index;
        if (state.effective_double_refresh > 0.5) {
            blank_index = floor(v_scanline_offset);
        } else {
            blank_index = parity_mismatch && !scaled_blank_line ? 1.0 : floor(v_scanline_offset);
        }

        float blank_center = blank_index + 0.5;
        float blank_mix = SCANLINE_BLANK_WEIGHT / 100.0;
        if (state.num_blanks > 1.0) {
            float effective_scale = state.effective_double_refresh > 0.5 ? state.v_scale : state.v_scale * 2.0;
            float dist_current = blank_center - 0.5;
            float dist_next = (effective_scale + 0.5) - blank_center;
            float min_dist = min(dist_current, dist_next);
            float max_min_dist = effective_scale / 2.0;
            float weight_factor = min_dist / max_min_dist;

            float sum_of_dists = state.is_odd_blanks > 0.5
                ? (state.num_blanks + 1.0) * (state.num_blanks + 1.0) / 4.0
                : state.num_blanks * (state.num_blanks + 2.0) / 4.0;
            float sum_weights = 2.0 * sum_of_dists / effective_scale;

            blank_mix *= weight_factor / sum_weights * state.num_blanks;
        }
        return mix(base, vec3(0.0), blank_mix);
    }

    // Progressive path: only the inserted scaled rows are dimmed.
    if (!scaled_blank_line)
        return base;

    float blank_mix = SCANLINE_BLANK_WEIGHT / 100.0;
    if (state.num_blanks > 1.0) {
        float blank_index = floor(v_scanline_offset);
        float blank_center = blank_index + 0.5;
        float dist_current = blank_center - 0.5;
        float dist_next = (state.v_scale + 0.5) - blank_center;
        float min_dist = min(dist_current, dist_next);
        float max_min_dist = state.v_scale / 2.0;
        float weight_factor = min_dist / max_min_dist;

        float sum_of_dists = state.is_odd_blanks > 0.5
            ? (state.num_blanks + 1.0) * (state.num_blanks + 1.0) / 4.0
            : state.num_blanks * (state.num_blanks + 2.0) / 4.0;
        float sum_weights = 2.0 * sum_of_dists / state.v_scale;

        blank_mix *= weight_factor / sum_weights * state.num_blanks;
    }
    return mix(base, vec3(0.0), blank_mix);
}

// Average the gain reduction introduced by the blank rows. The value is packed
// into alpha so downstream passes can compensate if they need a normalized
// active-region gain estimate.
float average_active_gain(FrameVState state)
{
    float effective_scale = (state.is_interlaced > 0.5)
        ? (state.effective_double_refresh > 0.5 ? state.v_scale : state.v_scale * 2.0)
        : state.v_scale;
    float num_blanks_local = max(effective_scale - 1.0, 0.0);
    float base = SCANLINE_BLANK_WEIGHT / 100.0;
    float avg_blank_mix = (effective_scale > 0.0) ? base * (num_blanks_local / effective_scale) : 0.0;
    return clamp(1.0 - avg_blank_mix, 0.0, 1.0);
}

void main()
{
    FrameVState state = compute_framev_state();

    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);

    float scaled_full_height = state.full_height_int * state.v_scale;

    // Reject anything outside the target surface immediately.
    if (output_y < 0.0 || output_y >= config.OutputSize.y) {
        FragColor = vec4(0.0);
        return;
    }

    // If the centered frame extends above the output, discard the clipped rows.
    if (state.full_pad_top < 0.0 && output_y < 0.0) {
        FragColor = vec4(0.0);
        return;
    }

    // Determine whether this output texel falls in the overall framed image,
    // the active source window, or the padded area around it.
    float frame_top = max(state.full_pad_top, 0.0);
    float frame_bottom = state.full_pad_top + scaled_full_height;
    float active_bottom = state.active_top_scaled + config.SourceSize.y * state.v_scale;

    bool in_source_x = (output_x >= 0.0 && output_x < state.frame_width);
    bool in_frame_y = (output_y >= frame_top && output_y < frame_bottom && output_y < config.OutputSize.y);
    bool in_active_y = (output_y >= state.active_top_scaled && output_y < active_bottom && output_y < config.OutputSize.y);

    bool in_frame = in_source_x && in_frame_y;
    bool in_active = in_source_x && in_active_y;

    vec4 color_gain;

#ifdef OPTION_DEBUG
    if (in_active && FRAME_VIZ_ACTIVE > 0.5) {
        vec3 color = sample_active_content(output_x, output_y, state);
        color_gain = vec4(color, average_active_gain(state));
    } else if (in_frame && !in_active && FRAME_VIZ_BLANKING > 0.5) {
        color_gain = vec4(vec3(1.0, 1.0, 0.0) * 0.5, average_active_gain(state)); // Yellow
    } else if (!in_frame && FRAME_VIZ_PADDING > 0.5) {
        color_gain = vec4(vec3(1.0, 0.0, 1.0) * 0.5, average_active_gain(state)); // Magenta
    } else {
#else
    if (in_active) {
        vec3 color = sample_active_content(output_x, output_y, state);
        color_gain = vec4(color, average_active_gain(state));
    } else {
#endif  // OPTION_DEBUG
        color_gain = vec4(vec3(0.0), average_active_gain(state)); // Black
    }

    FragColor = color_gain;
}
