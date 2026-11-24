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
// Adds simple MagDeltaV-driven crosstalk to the framed 1D
// raster between `frameh.slang` and `framev.slang`.
// Pixel variants run before sys-bandlimit; DSP variants run after it.

#pragma name NoiseTxRx
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "subframe.inc"

#include "menus/parameters/dsp.inc"
#include "menus/parameters/noise-txrx.inc"
#include "menus/parameters/sys-timing.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_RGB_NOISE_HEADER " —— Debug Tx/Rx Noise —— " 0.0 0.0 0.0 0.0
#pragma parameter TXRX_NOISE_BYPASS "Bypass Tx/Rx noise" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_VIEW_MAG_DELTAV "View signed DeltaV" 0.0 0.0 1.0 1.0
#pragma parameter TXRX_NOISE_MAG_DELTAV_MIP_LOD "DeltaV mip LOD" 0.0 0.0 12.0 1.0
#pragma parameter TXRX_NOISE_GAIN "Tx/Rx Noise Gain" 1.0 1.0 10.0 0.1
#endif  // OPTION_DEBUG

layout(push_constant) uniform Push
{
    vec4 OriginalSize;
    vec4 SendSourceSize;
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
    float DSP_WORKING_FS;

    float TXRX_NOISE_FEEDBACK_DB;
    float TXRX_NOISE_XTALK_DB;

#ifdef OPTION_DEBUG
    float TXRX_NOISE_BYPASS;
    float TXRX_NOISE_VIEW_MAG_DELTAV;
    float TXRX_NOISE_MAG_DELTAV_MIP_LOD;
    float TXRX_NOISE_GAIN;
#endif  // OPTION_DEBUG
} config;

#define V_FREQ_MODE config.V_FREQ_MODE
#define V_FREQ config.V_FREQ
#define SC_FREQ_MODE config.SC_FREQ_MODE
#define SC_FREQ config.SC_FREQ
#define PIXEL_CLOCK_MODE config.PIXEL_CLOCK_MODE
#define PIXEL_CLOCK config.PIXEL_CLOCK
#define H_FREQ_MODE config.H_FREQ_MODE
#define H_FREQ config.H_FREQ
#define DSP_WORKING_FS config.DSP_WORKING_FS
#define CURRENT_SUBFRAME config.CurrentSubFrame
#define TOTAL_SUBFRAMES config.TotalSubFrames

#define TXRX_NOISE_FEEDBACK_DB config.TXRX_NOISE_FEEDBACK_DB
#define TXRX_NOISE_XTALK_DB config.TXRX_NOISE_XTALK_DB

layout(std140, set = 0, binding = 0) uniform UBO
{
    mat4 MVP;
} global;

#ifdef OPTION_DEBUG
#define TXRX_NOISE_BYPASS config.TXRX_NOISE_BYPASS
#define TXRX_NOISE_VIEW_MAG_DELTAV config.TXRX_NOISE_VIEW_MAG_DELTAV
#define TXRX_NOISE_MAG_DELTAV_MIP_LOD config.TXRX_NOISE_MAG_DELTAV_MIP_LOD
#define TXRX_NOISE_GAIN config.TXRX_NOISE_GAIN
#endif  // OPTION_DEBUG

struct NoiseTxRxState {
    float frame_width;
    float frame_height;
    float data_length;
    float tau; // Horizontal period in samples.
};

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out NoiseTxRxState vNoiseState;

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
    state.data_length = max(contract_data_length(state.frame_width, state.frame_height), 1.0);
    float horizontal_frequency = contract_h_frequency(
        config.OriginalFPS,
        SC_FREQ_MODE,
        SC_FREQ,
        PIXEL_CLOCK_MODE,
        PIXEL_CLOCK,
        H_FREQ_MODE,
        H_FREQ);
    state.tau = sample_rate / max(horizontal_frequency, EPS);

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
layout(set = 0, binding = 1) uniform sampler2D Source;  // Mip 12 (1-pixel terminal mip)
layout(set = 0, binding = 2) uniform sampler2D SendSource;
layout(set = 0, binding = 3) uniform sampler2D DeltaV;  // Mip 0
layout(set = 0, binding = 4) uniform sampler2D Mip1;
layout(set = 0, binding = 5) uniform sampler2D Mip2;
layout(set = 0, binding = 6) uniform sampler2D Mip3;
layout(set = 0, binding = 7) uniform sampler2D Mip4;
layout(set = 0, binding = 8) uniform sampler2D Mip5;
layout(set = 0, binding = 9) uniform sampler2D Mip6;
layout(set = 0, binding = 10) uniform sampler2D Mip7;
layout(set = 0, binding = 11) uniform sampler2D Mip8;
layout(set = 0, binding = 12) uniform sampler2D Mip9;
layout(set = 0, binding = 13) uniform sampler2D Mip10;
layout(set = 0, binding = 14) uniform sampler2D Mip11;

#ifdef OPTION_XTALK_SAMPLE_COUNT
const int XTALK_SAMPLE_COUNT = OPTION_XTALK_SAMPLE_COUNT;
#else
const int XTALK_SAMPLE_COUNT = 13;
#endif

// Interpolate between row-aligned samples, including across row boundaries.
vec4 sample_packed_delta_v(sampler2D level, int sample_index, int lod_i, NoiseTxRxState state)
{
    return sample_row_aligned_signal(level, sample_index, int(state.frame_width),
        1 << lod_i, max(int(ceil(state.data_length)), 1));
}

vec4 sample_delta_v_level(int sample_index, int lod_i, NoiseTxRxState state)
{
    if (lod_i <= 0)
        return sample_packed_delta_v(DeltaV, sample_index, lod_i, state);
    if (lod_i == 1)
        return sample_packed_delta_v(Mip1, sample_index, lod_i, state);
    if (lod_i == 2)
        return sample_packed_delta_v(Mip2, sample_index, lod_i, state);
    if (lod_i == 3)
        return sample_packed_delta_v(Mip3, sample_index, lod_i, state);
    if (lod_i == 4)
        return sample_packed_delta_v(Mip4, sample_index, lod_i, state);
    if (lod_i == 5)
        return sample_packed_delta_v(Mip5, sample_index, lod_i, state);
    if (lod_i == 6)
        return sample_packed_delta_v(Mip6, sample_index, lod_i, state);
    if (lod_i == 7)
        return sample_packed_delta_v(Mip7, sample_index, lod_i, state);
    if (lod_i == 8)
        return sample_packed_delta_v(Mip8, sample_index, lod_i, state);
    if (lod_i == 9)
        return sample_packed_delta_v(Mip9, sample_index, lod_i, state);
    if (lod_i == 10)
        return sample_packed_delta_v(Mip10, sample_index, lod_i, state);
    if (lod_i == 11)
        return sample_packed_delta_v(Mip11, sample_index, lod_i, state);

    return sample_packed_delta_v(Source, sample_index, lod_i, state);
}

vec4 sample_delta_v_lod(int sample_index, float lod, NoiseTxRxState state)
{
    float lod_clamped = clamp(lod, 0.0, 12.0);
    int lod0_i = int(floor(lod_clamped));
    int lod1_i = min(lod0_i + 1, 12);
    float lod_frac = lod_clamped - float(lod0_i);

    vec4 sample0 = sample_delta_v_level(sample_index, lod0_i, state);
    if (lod_frac == 0.0)
        return sample0;
    vec4 sample1 = sample_delta_v_level(sample_index, lod1_i, state);
    return mix(sample0, sample1, lod_frac);
}

void main()
{
    vec2 uv = vTexCoord * config.OutputSize.xy;
    int output_x_i = int(floor(uv.x));
    int output_y_i = int(floor(uv.y));
    float output_x = float(output_x_i);
    float output_y = float(output_y_i);

    if (output_x >= vNoiseState.frame_width || output_y >= vNoiseState.frame_height) {
        FragColor = vec4(0.0);
        return;
    }

    int sample_index_i = output_y_i * int(vNoiseState.frame_width) + output_x_i;
    float sample_index = float(sample_index_i);

#ifdef OPTION_DEBUG
    if (TXRX_NOISE_BYPASS > 0.5) {
        FragColor = fetch_input_sample(
            SendSource,
            config.SendSourceSize.xy,
            sample_index,
            vNoiseState.frame_width,
            vNoiseState.data_length);
        return;
    }

    if (TXRX_NOISE_VIEW_MAG_DELTAV > 0.5) {
        vec4 debug_delta_v = sample_delta_v_lod(
            sample_index_i,
            TXRX_NOISE_MAG_DELTAV_MIP_LOD,
            vNoiseState);
        FragColor = debug_delta_v;
        return;
    }
#endif  // OPTION_DEBUG

    uint frame = temporal_frame_index(
        config.FrameCount,
        CURRENT_SUBFRAME,
        TOTAL_SUBFRAMES);
    vec4 sample_signal = fetch_input_sample(
        SendSource,
        config.SendSourceSize.xy,
        sample_index,
        vNoiseState.frame_width,
        vNoiseState.data_length);
    vec4 mag_delta = vec4(0.0);
    int max_lod = int(floor(log2(vNoiseState.frame_width)));

    int i = 0;
    for (i = 0; i < XTALK_SAMPLE_COUNT; ++i) {
        if (i > max_lod)
            break;
        float w = exp(-pow(2.0, float(i)) / vNoiseState.tau);

        vec4 delta_sample = sample_delta_v_lod(sample_index_i, float(i), vNoiseState);
        mag_delta += w * abs(delta_sample);
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
