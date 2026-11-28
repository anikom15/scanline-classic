// Filename: noise-txrx-common.slang
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
// General noise injection in the selected sample domain
// --------------------------------------------
// Input: voltage
// Output: voltage
//
// Adds DeltaV-driven feedback and crosstalk to a framed 1D signal.
// DeltaV is the signed difference between consecutive SendSource samples.
// Each mip averages consecutive DeltaV samples over twice the previous span;
// LOD 0 is DeltaV, and LOD k has one sample per 2^k original samples.
// The noise estimate sums the absolute values from the selected discrete
// levels, then applies the feedback and per-channel crosstalk gains.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name NoiseTxRx
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/noise-txrx.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#define TIMING_PROFILE_MODE timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS)

#ifdef OPTION_XTALK_SAMPLE_COUNT
#else
#define OPTION_XTALK_SAMPLE_COUNT 9
#endif

#if OPTION_XTALK_SAMPLE_COUNT < 1 || OPTION_XTALK_SAMPLE_COUNT > 9
#error OPTION_XTALK_SAMPLE_COUNT must be between 1 and 9
#endif

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_RGB_NOISE_HEADER " —— Debug Tx/Rx Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter TXRX_NOISE_BYPASS "Bypass Tx/Rx noise" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_VIEW_MAG_DELTAV "View signed DeltaV" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_MAG_DELTAV_MIP_LOD "DeltaV mip LOD" 0.0 0.0 8.0 1.0
#pragma parameter TXRX_NOISE_INTERPOLATE_MIPS "Interpolate DeltaV samples in field time" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_GAIN "Tx/Rx Noise Gain" 1.0 1.0 10.0 0.1
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SendSourceSize;
    vec4 OutputSize;
    float OriginalFPS;
    float V_FREQ_MODE;
    float V_FREQ;
    float SC_FREQ_MODE;
    float SC_FREQ_WHOLE;
    float PIXEL_CLOCK_MODE;
    float PIXEL_CLOCK_WHOLE;
    float H_FREQ_MODE;
    float H_FREQ;
    float DSP_WORKING_FS;

    float TXRX_NOISE_FEEDBACK_DB;
    float TXRX_NOISE_XTALK_DB;

#ifdef OPTION_DEBUG
    float TXRX_NOISE_BYPASS;
    float TXRX_NOISE_VIEW_MAG_DELTAV;
    float TXRX_NOISE_MAG_DELTAV_MIP_LOD;
    float TXRX_NOISE_INTERPOLATE_MIPS;
    float TXRX_NOISE_GAIN;
#endif  // OPTION_DEBUG
    float PIXEL_CLOCK_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float SC_FREQ_FRAC11;
} config;

#define V_FREQ_MODE timing_profile_v_mode(TIMING_PROFILE_MODE, config.OriginalSize.y, config.V_FREQ_MODE)
#define V_FREQ timing_profile_v_freq(TIMING_PROFILE_MODE, config.OriginalSize.y, global.FrameCount, global.FIELD_ODD, config.V_FREQ)
#define SC_FREQ_MODE timing_profile_sc_mode(TIMING_PROFILE_MODE, config.SC_FREQ_MODE)
#define SC_FREQ timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, config.SC_FREQ_FRAC11))
#define PIXEL_CLOCK_MODE timing_profile_pixel_mode(TIMING_PROFILE_MODE, config.PIXEL_CLOCK_MODE)
#define PIXEL_CLOCK timing_profile_pixel_value(TIMING_PROFILE_MODE, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, config.PIXEL_CLOCK_FRAC6, config.PIXEL_CLOCK_FRAC11)))
#define H_FREQ_MODE timing_profile_h_mode(TIMING_PROFILE_MODE, config.H_FREQ_MODE)
#define H_FREQ timing_profile_h_freq(TIMING_PROFILE_MODE, config.H_FREQ)
#define DSP_WORKING_FS config.DSP_WORKING_FS

#define TXRX_NOISE_FEEDBACK_DB config.TXRX_NOISE_FEEDBACK_DB
#define TXRX_NOISE_XTALK_DB config.TXRX_NOISE_XTALK_DB

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
    float SC_FREQ_FRAC6;
} global;

#ifdef OPTION_DEBUG
#define TXRX_NOISE_BYPASS config.TXRX_NOISE_BYPASS
#define TXRX_NOISE_VIEW_MAG_DELTAV config.TXRX_NOISE_VIEW_MAG_DELTAV
#define TXRX_NOISE_MAG_DELTAV_MIP_LOD config.TXRX_NOISE_MAG_DELTAV_MIP_LOD
#define TXRX_NOISE_INTERPOLATE_MIPS config.TXRX_NOISE_INTERPOLATE_MIPS
#define TXRX_NOISE_GAIN config.TXRX_NOISE_GAIN
#else
#define TXRX_NOISE_GAIN 1.0
#endif  // OPTION_DEBUG

struct NoiseTxRxState {
    float frame_width; // Logical raster line width in the current domain.
    float frame_height;
    float data_length; // Number of original-domain samples in the field.
    float storage_width; // Base signal stride; differs from frame_width when packed.
    float texture_fits; // Input and output capacity check.
    float max_lod; // Limited by quality, available levels and field length.
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseTxRxState vNoiseState;

// Derive the logical line width, field length, storage stride and usable LOD
// once per vertex. Raster width determines time; storage width maps samples
// to texels and may include a different row arrangement.
NoiseTxRxState compute_noise_state()
{
    NoiseTxRxState state;

#ifdef SEND_PIXEL_DOMAIN
    state.frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    float sample_rate = contract_fs_original(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK);
#else
    state.frame_width = contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
    float sample_rate = contract_working_sample_rate(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS);
#endif
    state.frame_height = contract_frame_height(
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
    float nominal_data_length = ceil(contract_data_length(state.frame_width, state.frame_height));
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, state.frame_width, nominal_data_length), 1.0);
    state.storage_width = contract_pixel_packed_width(state.data_length);
    state.texture_fits = contract_pixel_texture_fits(config.OutputSize.xy, state.data_length, state.storage_width) &&
        contract_pixel_texture_fits(config.SendSourceSize.xy, state.data_length, state.storage_width) ? 1.0 : 0.0;
    state.max_lod = float(pyramid_max_lod(int(ceil(state.data_length)), OPTION_XTALK_SAMPLE_COUNT));
    float horizontal_frequency = contract_h_frequency(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);

    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    vNoiseState = compute_noise_state();
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in NoiseTxRxState vNoiseState;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D SendSource;
layout(set = 0, binding = 2) uniform sampler2D DeltaV;  // Mip 0
#if OPTION_XTALK_SAMPLE_COUNT > 1
layout(set = 0, binding = 3) uniform sampler2D Mip1;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 2
layout(set = 0, binding = 4) uniform sampler2D Mip2;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 3
layout(set = 0, binding = 5) uniform sampler2D Mip3;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 4
layout(set = 0, binding = 6) uniform sampler2D Mip4;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 5
layout(set = 0, binding = 7) uniform sampler2D Mip5;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 6
layout(set = 0, binding = 8) uniform sampler2D Mip6;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 7
layout(set = 0, binding = 9) uniform sampler2D Mip7;
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 8
layout(set = 0, binding = 10) uniform sampler2D Source;  // Mip 8
#endif
const int XTALK_SAMPLE_COUNT = OPTION_XTALK_SAMPLE_COUNT;

// The base level uses the signal's storage stride; reduced levels use their
// own packed texture width. Normally, align lookup boundaries to the raster
// line and fetch the preceding sample. The debug option instead interpolates
// adjacent samples at the unshifted field-relative time.
vec4 sample_packed_delta_v(sampler2D level, int sample_index, int lod_i, NoiseTxRxState state)
{
    int width = lod_i == 0 ? int(state.storage_width) : textureSize(level, 0).x;
    int span = 1 << lod_i;  // exp2(lod_i)
    int data_length = max(int(ceil(state.data_length)), 1);
    int index = clamp(sample_index, 0, data_length - 1);
#ifdef OPTION_DEBUG
    if (TXRX_NOISE_INTERPOLATE_MIPS > 0.5) {
        int remainder = index % span;
        vec4 current = sample_pyramid_signal(level, index, width, span, data_length);
        if (remainder == 0)
            return current;
        vec4 next = sample_pyramid_signal(level, min(index + span, data_length - 1), width, span, data_length);
        return mix(current, next, float(remainder) / float(span));
    }
#endif  // OPTION_DEBUG
    vec2 raster = timing_profile_raster_position(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, float(index), state.frame_width);
    int line_start = index - int(raster.x);
    int aligned_index = index - line_start % span;

    return sample_pyramid_signal(level, aligned_index, width, span, data_length);
}

// Select one discrete mip texture at a field-relative original-sample index.
// Each level is sampled independently, without interpolation between LODs.
// Source is the final mip pass; earlier mips are addressed by alias. Unknown
// levels return magenta as an error color.
vec4 sample_delta_v_level(int sample_index, int lod_i, NoiseTxRxState state)
{
    if (lod_i <= 0)
        return sample_packed_delta_v(DeltaV, sample_index, lod_i, state);
#if OPTION_XTALK_SAMPLE_COUNT > 1
    if (lod_i == 1)
        return sample_packed_delta_v(Mip1, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 2
    if (lod_i == 2)
        return sample_packed_delta_v(Mip2, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 3
    if (lod_i == 3)
        return sample_packed_delta_v(Mip3, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 4
    if (lod_i == 4)
        return sample_packed_delta_v(Mip4, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 5
    if (lod_i == 5)
        return sample_packed_delta_v(Mip5, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 6
    if (lod_i == 6)
        return sample_packed_delta_v(Mip6, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 7
    if (lod_i == 7)
        return sample_packed_delta_v(Mip7, sample_index, lod_i, state);
#endif
#if OPTION_XTALK_SAMPLE_COUNT > 8
    if (lod_i == 8)
        return sample_packed_delta_v(Source, sample_index, lod_i, state);
#endif
    return vec4(1.0, 0.0, 1.0, 1.0);
}

void main()
{
    vec2 uv = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(uv.x));
    int output_y_i = int(floor(uv.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    float storage_width = vNoiseState.storage_width;
    if (vNoiseState.texture_fits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    int sample_index_i = output_y_i * int(storage_width) + output_x_i;
    if (output_x >= storage_width || float(sample_index_i) >= vNoiseState.data_length) {
        FragColor = vec4(0.0);
        return;
    }
    float sample_index = float(sample_index_i);
    float input_limit = ceil(vNoiseState.data_length) - 1.0;

#ifdef OPTION_DEBUG
    if (TXRX_NOISE_BYPASS > 0.5) {
        FragColor = fetch_input_sample(
            SendSource,
            config.SendSourceSize.xy,
            sample_index,
            storage_width,
            input_limit);
        return;
    }

    if (TXRX_NOISE_VIEW_MAG_DELTAV > 0.5) {
        int debug_lod = int(floor(clamp(TXRX_NOISE_MAG_DELTAV_MIP_LOD, 0.0, vNoiseState.max_lod)));
        vec4 debug_delta_v = sample_delta_v_level(
            sample_index_i,
            debug_lod,
            vNoiseState);
        FragColor = debug_delta_v * exp2(float(debug_lod));
        return;
    }
#endif  // OPTION_DEBUG

    vec4 sample_signal = fetch_input_sample(
        SendSource,
        config.SendSourceSize.xy,
        sample_index,
        storage_width,
        input_limit);
    vec4 mag_delta = vec4(0.0);
    int max_lod = int(vNoiseState.max_lod);

    int i = 0;
    for (i = 0; i < XTALK_SAMPLE_COUNT; ++i) {
        if (i > max_lod)
            break;

        vec4 delta_sample = sample_delta_v_level(sample_index_i, i, vNoiseState);
        mag_delta += abs(delta_sample);
    }

    float feedback_gain = db_to_linear(TXRX_NOISE_FEEDBACK_DB);
    vec4 feedback = feedback_gain * mag_delta;

    float crosstalk_gain = db_to_linear(TXRX_NOISE_XTALK_DB);
    vec4 crosstalk_drive = vec4(
        dot(mag_delta.gba, vec3(1.0)),
        dot(mag_delta.rba, vec3(1.0)),
        dot(mag_delta.rga, vec3(1.0)),
        dot(mag_delta.rgb, vec3(1.0))
    );
    vec4 crosstalk = crosstalk_gain * crosstalk_drive;

    vec4 out_signal = sample_signal + TXRX_NOISE_GAIN * (feedback + crosstalk);

    FragColor = out_signal;
}
