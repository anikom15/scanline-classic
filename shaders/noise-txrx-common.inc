// Filename: noise-txrx-common.inc
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
// Each stage is the causal difference over 2^LOD samples. Line-aligned stage
// values are interpolated before their magnitudes are summed.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name NoiseTxRx
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"

#include "menus/parameters/noise-txrx.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#include "timing-profiles.inc"
#include "raster-mapping.inc"
#define TIMING_PROFILE_MODE timingProfileMode

#ifdef OPTION_XTALK_SAMPLE_COUNT
#else
#define OPTION_XTALK_SAMPLE_COUNT 11
#endif

#if OPTION_XTALK_SAMPLE_COUNT < 1 || OPTION_XTALK_SAMPLE_COUNT > 21
#error OPTION_XTALK_SAMPLE_COUNT must be between 1 and 21
#endif

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_RGB_NOISE_HEADER " —— Debug Tx/Rx Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter TXRX_NOISE_BYPASS "Bypass Tx/Rx noise" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_VIEW_MAG_DELTAV "View signed DeltaV" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_MAG_DELTAV_MIP_LOD "DeltaV stage LOD" 0.0 0.0 20.0 1.0
#pragma parameter TXRX_NOISE_GAIN "Tx/Rx Noise Gain" 1.0 1.0 10.0 0.1
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SourceSize;
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

    float TXRX_NOISE_FEEDBACK_DB;
    float TXRX_NOISE_XTALK_DB;

#ifdef OPTION_DEBUG
    float TXRX_NOISE_BYPASS;
    float TXRX_NOISE_VIEW_MAG_DELTAV;
    float TXRX_NOISE_MAG_DELTAV_MIP_LOD;
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
#define DSP_WORKING_FS (DSP_SD_WORKING_FS / 1.0e6)

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
#define TXRX_NOISE_GAIN config.TXRX_NOISE_GAIN
#else
#define TXRX_NOISE_GAIN 1.0
#endif  // OPTION_DEBUG

struct NoiseTxRxState {
    double frame_width;
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
layout(location = 8) flat out vec4 vRasterPattern;
layout(location = 9) flat out ivec2 vRasterExceptions;

NoiseTxRxState compute_noise_state(int timingProfileMode)
{
    NoiseTxRxState state;

#ifdef SEND_PIXEL_DOMAIN
    double frame_width = contract_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
#else
    double frame_width = timing_profile_rate_width(TIMING_PROFILE_MODE, contract_working_frame_width(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ,
        DSP_WORKING_FS), DSP_WORKING_FS);
#endif
    state.frame_width = frame_width;
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
    float nominal_data_length = ceil(contract_data_length(frame_width, frame_height));
    state.data_length = max(timing_profile_storage_length(TIMING_PROFILE_MODE, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, frame_width, nominal_data_length), 1.0);
    state.storage_width = contract_pixel_packed_width(state.data_length);
    state.texture_fits = contract_pixel_texture_fits(config.OutputSize.xy, state.data_length, state.storage_width) &&
        contract_pixel_texture_fits(config.SourceSize.xy, state.data_length, state.storage_width) ? 1.0 : 0.0;
    state.max_lod = float(dyadic_max_lod(int(ceil(state.data_length)), OPTION_XTALK_SAMPLE_COUNT));
    return state;
}

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    int timingProfileMode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);
    timing_profile_raster_descriptor(TIMING_PROFILE_MODE, config.OriginalSize.y, global.FrameCount,
        global.FIELD_ODD, vRasterPattern, vRasterExceptions);
    vNoiseState = compute_noise_state(timingProfileMode);
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in NoiseTxRxState vNoiseState;
layout(location = 8) flat in vec4 vRasterPattern;
layout(location = 9) flat in ivec2 vRasterExceptions;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;
const int XTALK_SAMPLE_COUNT = OPTION_XTALK_SAMPLE_COUNT;

vec4 sample_noise_signal(int sample_index, NoiseTxRxState state)
{
    return fetch_input_sample(Source, config.SourceSize.xy, float(max(sample_index, 0)),
        state.storage_width, ceil(state.data_length) - 1.0);
}

vec4 sample_delta_v_level(int sample_index, int lod_i, int line_start, NoiseTxRxState state)
{
    int span = 1 << lod_i;
    int offset = (sample_index - line_start) % span;
    int anchor = sample_index - offset;
    vec4 anchor_signal = sample_noise_signal(anchor, state);
    vec4 previous = sample_noise_signal(anchor - span, state);
    vec4 earlier = sample_noise_signal(anchor - 2 * span, state);
    return mix(previous - earlier, anchor_signal - previous, float(offset) / float(span));
}

void main()
{
    vec2 uv = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(uv.x));
    int output_y_i = int(floor(uv.y));
    float output_x = float(output_x_i);

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

    vec4 sample_signal = fetch_input_sample(
        Source,
        config.SourceSize.xy,
        sample_index,
        storage_width,
        input_limit);

#ifdef OPTION_DEBUG
    if (TXRX_NOISE_BYPASS > 0.5) {
        FragColor = sample_signal;
        return;
    }
#endif
    vec2 raster = raster_position(vRasterPattern, vRasterExceptions, sample_index, vNoiseState.frame_width);
    if (isnan(raster.x) || isinf(raster.x)) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    int line_start = sample_index_i - int(raster.x);

#ifdef OPTION_DEBUG
    if (TXRX_NOISE_VIEW_MAG_DELTAV > 0.5) {
        int debug_lod = int(floor(clamp(TXRX_NOISE_MAG_DELTAV_MIP_LOD, 0.0, vNoiseState.max_lod)));
        vec4 debug_delta_v = sample_delta_v_level(sample_index_i, debug_lod, line_start, vNoiseState);
        FragColor = debug_delta_v;
        return;
    }
#endif  // OPTION_DEBUG

    vec4 mag_delta = vec4(0.0);
    int max_lod = int(vNoiseState.max_lod);

    int i = 0;
    for (i = 0; i < XTALK_SAMPLE_COUNT; ++i) {
        if (i > max_lod)
            break;

        vec4 delta_sample = sample_delta_v_level(sample_index_i, i, line_start, vNoiseState);
        mag_delta += abs(delta_sample) / float(i+1);
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
