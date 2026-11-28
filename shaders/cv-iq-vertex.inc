// Filename: cv-iq-vertex.inc
// Copyright (C) 2026 W. M. Martinez
// SPDX-License-Identifier: GPL-3.0-or-later

layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out float CVLength;
layout(location = 2) flat out float IQLength;
layout(location = 3) flat out float CVWidth;
layout(location = 4) flat out float IQWidth;
layout(location = 5) flat out float TextureFits;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    int mode = timing_profile_select(global.TIMING_PROFILE, config.OriginalSize.xy, config.OriginalFPS);
    float sc_mode = timing_profile_sc_mode(mode, config.SC_FREQ_MODE);
    float sc_freq = timing_decimal_value(vec3(config.SC_FREQ_WHOLE, global.SC_FREQ_FRAC6, global.SC_FREQ_FRAC11));
    float pixel_mode = timing_profile_pixel_mode(mode, config.PIXEL_CLOCK_MODE);
    float pixel_freq = timing_profile_pixel_value(mode, timing_decimal_value(vec3(config.PIXEL_CLOCK_WHOLE, global.PIXEL_CLOCK_FRAC6, global.PIXEL_CLOCK_FRAC11)));
    float h_mode = timing_profile_h_mode(mode, config.H_FREQ_MODE);
    float h_freq = timing_profile_h_freq(mode, config.H_FREQ);
    double frame_width = timing_profile_rate_width(mode, contract_working_frame_width(
        config.OriginalFPS, sc_mode, sc_freq, pixel_mode, pixel_freq, h_mode, h_freq,
        DSP_SD_WORKING_FS / 1.0e6), DSP_SD_WORKING_FS / 1.0e6);
    float height = contract_frame_height(config.OriginalSize.xy, config.OriginalFPS,
        timing_profile_v_mode(mode, config.OriginalSize.y, config.V_FREQ_MODE),
        timing_profile_v_freq(mode, config.OriginalSize.y, global.FrameCount, global.FIELD_ODD, config.V_FREQ),
        sc_mode, sc_freq, pixel_mode, pixel_freq, h_mode, h_freq);
    CVLength = max(timing_profile_storage_length(mode, config.OriginalSize.y,
        global.FrameCount, global.FIELD_ODD, frame_width, contract_data_length(frame_width, height)), 1.0);
    IQLength = ceil(CVLength * (DSP_SD_IQ_WORKING_FS / DSP_SD_WORKING_FS));
    CVWidth = contract_pixel_packed_width(CVLength);
    IQWidth = contract_pixel_packed_width(IQLength);
#ifdef CV_IQ_ANALYSIS
    TextureFits = contract_pixel_texture_fits(config.SourceSize.xy, CVLength, CVWidth) &&
        contract_pixel_texture_fits(config.OutputSize.xy, IQLength, IQWidth) ? 1.0 : 0.0;
#else
    TextureFits = contract_pixel_texture_fits(config.SourceSize.xy, IQLength, IQWidth) &&
        contract_pixel_texture_fits(config.OutputSize.xy, CVLength, CVWidth) ? 1.0 : 0.0;
#endif
}
