#version 450

// Filename: frameh.slang
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
// Horizontal frame storage
// ------------------------
// Maps active raster data into a framed field buffer.
//
// The output is a clock-domain field: line lengths follow the timing profile,
// active source texels are held for `ClockFactor` clock samples, and
// blanking remains at 1-sample clock resolution. The linear stream is packed
// horizontally using the data-length-derived power-of-two width, regardless
// of the physical texture dimensions. RGB stores the sample and A is 1.
// The data grid stays anchored to geometry / line carry; any field-dependent
// timebase phase is reconstructed downstream from the contract API rather than
// baked into the storage placement or a texture-carried metadata payload.

#pragma name FrameH
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"

#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#include "raster-mapping.inc"
#define TIMING_PROFILE_MODE vTimingProfileMode

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_FRAME_HEADER " —— Debug Frame —— " 0.0 0.0 0.0 0.0
#pragma parameter DEBUG_FRAME_ACTIVE "Show active content" 1.0 0.0 1.0 1.0
#pragma parameter DEBUG_FRAME_BLANKING "Show frame blanking (yellow)" 0.0 0.0 1.0 1.0
#pragma parameter DEBUG_FRAME_PADDING "Show padding (magenta)" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

// Push constants
layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float H_BLANK_FUZZ;
    float SHORTEN_ODD_FIELD_TIME;
    float PHASE_ZERO;
    float FIELD_ODD;
    float BLANKING_COLOR_R;
    float BLANKING_COLOR_G;
    float BLANKING_COLOR_B;

#ifdef OPTION_DEBUG
    float DEBUG_FRAME_ACTIVE;
    float DEBUG_FRAME_BLANKING;
    float DEBUG_FRAME_PADDING;
#endif  // OPTION_DEBUG

} config;

#define FieldCount config.FrameCount

#ifdef OPTION_DEBUG
#define DEBUG_FRAME_ACTIVE config.DEBUG_FRAME_ACTIVE
#define DEBUG_FRAME_BLANKING config.DEBUG_FRAME_BLANKING
#define DEBUG_FRAME_PADDING config.DEBUG_FRAME_PADDING
#endif  // OPTION_DEBUG

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount, FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, global.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, global.PIXEL_CLOCK_FRAC6, global.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define H_BLANK_FUZZ config.H_BLANK_FUZZ
#define SHORTEN_ODD_FIELD_TIME timing_profile_field_adjustment(TIMING_PROFILE_MODE, config.SHORTEN_ODD_FIELD_TIME)
#define PHASE_ZERO (config.PHASE_ZERO + timing_profile_initial_phase(TIMING_PROFILE_MODE, 0.0))
#define FIELD_ODD config.FIELD_ODD

#define BLANKING_COLOR vec3(config.BLANKING_COLOR_R, config.BLANKING_COLOR_G, config.BLANKING_COLOR_B)

layout(std140, set = 0, binding = 0) uniform UBO
{
    float TIMING_PROFILE;
    mat4 MVP;
    float SC_FREQ_FRAC6;
    float SC_FREQ_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float PIXEL_CLOCK_FRAC11;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float FrameWidth;
layout(location = 2) flat out float FrameHeight;
layout(location = 5) flat out float FullFrameHeight;
layout(location = 6) flat out float IsInterlaced;
layout(location = 7) flat out float Field;
layout(location = 8) flat out float ClocksPerLine;
layout(location = 9) flat out float ClockFactor;
layout(location = 10) flat out float PackedWidth;
layout(location = 11) flat out float DataLength;
layout(location = 12) flat out float TextureFits;
layout(location = 13) flat out vec4 ActivePlacement;
layout(location = 14) flat out int vTimingProfileMode;
layout(location = 15) flat out vec4 vRasterPattern;
layout(location = 16) flat out ivec2 vRasterExceptions;

vec4 compute_active_placement()
{
    float field_parity = IsInterlaced > 0.5 ? Field : 0.0;
    float active_height = IsInterlaced > 0.5
        ? max(floor((config.SourceSize.y - field_parity + 1.0) * 0.5), 0.0)
        : config.SourceSize.y;
    float clock_factor = float(max(int(floor(ClockFactor + 0.5)), 1));
    float left = timing_profile_left_blank_cycles(TIMING_PROFILE_MODE,
        (FrameWidth - config.SourceSize.x * clock_factor) * 0.5);
    float top = timing_profile_top_blank_lines(TIMING_PROFILE_MODE,
        floor((ceil(FrameHeight) - active_height) * 0.5));
    top = timing_profile_active_top(TIMING_PROFILE_MODE, active_height, top);
    if (timing_profile_centered_overscan(TIMING_PROFILE_MODE, 0.0) > 0.5)
        left = timing_profile_active_left(TIMING_PROFILE_MODE, FrameWidth, config.SourceSize.x,
            clock_factor, left);
    return vec4(left, top, active_height, timing_profile_active_left_tracks_line(TIMING_PROFILE_MODE, 0.0));
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vTimingProfileMode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);
    timing_profile_raster_descriptor(TIMING_PROFILE_MODE, config.OriginalSize.y, config.FrameCount,
        FIELD_ODD, vRasterPattern, vRasterExceptions);

    if (TIMING_PROFILE_MODE < 0) {
        ClocksPerLine = 1.0;
        ClockFactor = 1.0;
        FrameWidth = 1.0;
        FrameHeight = 1.0;
        FullFrameHeight = 1.0;
        IsInterlaced = 0.0;
        Field = 0.0;
        DataLength = 1.0;
        PackedWidth = 1.0;
        TextureFits = 0.0;
        ActivePlacement = vec4(0.0);
        return;
    }


    ClocksPerLine = contract_clocks_per_line(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    ClockFactor = contract_clock_factor(
        config.OriginalSize.x,
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        H_BLANK_FUZZ);
    ClockFactor = timing_profile_clock_factor(TIMING_PROFILE_MODE, config.OriginalSize.x, ClockFactor);

    FrameWidth = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    FrameHeight = contract_frame_height(
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

    FullFrameHeight = contract_full_frame_height(
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
    FullFrameHeight = timing_profile_full_frame_height(TIMING_PROFILE_MODE, config.OriginalSize.y, FullFrameHeight);

    IsInterlaced = contract_is_interlaced(
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

    Field = contract_field_parity(FieldCount, FIELD_ODD, config.OriginalFPS, SC_FREQ_MODE, SC_FREQ,
                                  timing_profile_first_field_odd(TIMING_PROFILE_MODE, -1.0));
    DataLength = timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        config.FrameCount, FIELD_ODD, FrameWidth, ceil(contract_data_length(FrameWidth, FrameHeight)));
    PackedWidth = contract_pixel_packed_width(DataLength);
    TextureFits = contract_pixel_texture_fits(config.OutputSize.xy, DataLength, PackedWidth) ? 1.0 : 0.0;
    ActivePlacement = compute_active_placement();
    if (TIMING_PROFILE_MODE > 0 && timing_profile_centered_overscan(TIMING_PROFILE_MODE, 0.0) < 0.5) {
        float active_height = IsInterlaced > 0.5
            ? floor((config.SourceSize.y - Field + 1.0) * 0.5) : config.SourceSize.y;
        if (timing_profile_left_blank_cycles(TIMING_PROFILE_MODE, 0.0) + config.SourceSize.x * ClockFactor > FrameWidth
            || timing_profile_top_blank_lines(TIMING_PROFILE_MODE, 0.0) + active_height > FrameHeight)
            TextureFits = 0.0;
    }
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float FrameWidth;
layout(location = 2) flat in float FrameHeight;
layout(location = 6) flat in float IsInterlaced;
layout(location = 7) flat in float Field;
layout(location = 8) flat in float ClocksPerLine;
layout(location = 9) flat in float ClockFactor;
layout(location = 10) flat in float PackedWidth;
layout(location = 11) flat in float DataLength;
layout(location = 12) flat in float TextureFits;
layout(location = 13) flat in vec4 ActivePlacement;
layout(location = 14) flat in int vTimingProfileMode;
layout(location = 15) flat in vec4 vRasterPattern;
layout(location = 16) flat in ivec2 vRasterExceptions;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

float current_field_parity()
{
    return (IsInterlaced > 0.5) ? Field : 0.0;
}

bool sample_maps_to_active_time(
    float output_x,
    float output_y,
    out vec2 source_sample_pos)
{
    float field_parity = current_field_parity();

    float line_index = floor(output_y);
    int line_index_int = int(line_index);
    int clock_factor_int = max(int(floor(ClockFactor + 0.5)), 1);
    float clock_factor = float(clock_factor_int);
    float active_left = ActivePlacement.x;
    if (ActivePlacement.w > 0.5) {
        float line_width = raster_line_range(vRasterPattern, vRasterExceptions, line_index, FrameWidth).y;
        active_left = timing_profile_active_left(TIMING_PROFILE_MODE, line_width, config.SourceSize.x,
            clock_factor, active_left);
    }

    // Keep the wrapped line-carry in integer clock space so the storage grid
    // stays field-stable and does not drift across wrap boundaries when
    // `line_index` grows. Field/timebase phase is reconstructed downstream via
    // the contract helpers and is intentionally not baked into `source_x`.
    int phase_step_clocks_int = int(floor(ClocksPerLine + 0.5)) % clock_factor_int;
    int row_phase_clocks_int = (line_index_int * phase_step_clocks_int) % clock_factor_int;
    float phase_clocks = TIMING_PROFILE_MODE == 0 ? float(row_phase_clocks_int) : 0.0;

    // Output samples live directly in the pixel-clock domain. Active source
    // texels are held for `ClockFactor` clocks, while blanking remains at the
    // native 1-clock resolution.
    float source_x = (output_x - active_left - phase_clocks) / clock_factor;

    bool in_active_y = line_index >= ActivePlacement.y && line_index < ActivePlacement.y + ActivePlacement.z;
    if (!in_active_y) {
        source_sample_pos = vec2(-1.0);
        return false;
    }

    bool in_active_x = source_x >= 0.0 && source_x < config.SourceSize.x;
    if (!in_active_x) {
        source_sample_pos = vec2(-1.0);
        return false;
    }

    float active_y = line_index - ActivePlacement.y;
    float source_y = (IsInterlaced > 0.5) ? (active_y * 2.0 + field_parity) : active_y;
    source_sample_pos = vec2(source_x, source_y);
    return true;
}

vec3 fetch_source_sample(float source_x, float source_y)
{
    if (source_x < 0.0 || source_x >= config.SourceSize.x ||
        source_y < 0.0 || source_y >= config.SourceSize.y) {
        return BLANKING_COLOR;
    }

    vec2 texel = vec2(source_x + 0.5, source_y + 0.5) * config.SourceSize.zw;
    return texture(Source, texel).rgb;
}

vec3 sample_active_content(vec2 source_sample_pos)
{
    float source_x = floor(source_sample_pos.x);
    float source_y = floor(source_sample_pos.y);
    return fetch_source_sample(source_x, source_y);
}

void main()
{
    float output_x = floor(vTexCoord.x * config.OutputSize.x);
    float output_y = floor(vTexCoord.y * config.OutputSize.y);

    if (TextureFits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    float sample_index = output_y * PackedWidth + output_x;
    bool in_frame = output_x < PackedWidth && sample_index < DataLength;
    if (!in_frame) {
#ifdef OPTION_DEBUG
        if (DEBUG_FRAME_PADDING > 0.5) {
            FragColor = vec4(vec3(1.0, 0.0, 1.0) * 0.5, 0.0);
        } else {
            FragColor = vec4(0.0);
        }
#else
        FragColor = vec4(0.0);
#endif  // OPTION_DEBUG
        return;
    }

    vec2 raster = raster_position(vRasterPattern, vRasterExceptions, sample_index, FrameWidth);
    vec2 source_sample_pos;
    bool in_active = sample_maps_to_active_time(raster.x, raster.y, source_sample_pos);

    vec3 color = in_active ? sample_active_content(source_sample_pos) : BLANKING_COLOR;

#ifdef OPTION_DEBUG
    if (!in_active && in_frame && DEBUG_FRAME_BLANKING > 0.5) {
        color = vec3(1.0, 1.0, 0.0) * 0.5;
    } else if (!in_frame && DEBUG_FRAME_PADDING > 0.5) {
        color = vec3(1.0, 0.0, 1.0) * 0.5;
    }
#endif  // OPTION_DEBUG

    FragColor = vec4(color, 1.0);
}
