#version 450

// Filename: iq-cv.slang
//
// Copyright (C) 2026 W. M. Martinez
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reconstruct the packed 32 MHz composite stream from half-rate analytic I/Q.
#pragma name IQCV
#pragma format R16_SFLOAT

#include "cv-iq-common.inc"

#pragma stage vertex
#include "cv-iq-vertex.inc"

#pragma stage fragment
#include "cv-iq-fragment.inc"

void main()
{
    vec2 pixel = floor(vTexCoord * config.OutputSize.xy);
    float index = pixel.y * CVWidth + pixel.x;
    if (TextureFits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    if (pixel.x >= CVWidth || index >= CVLength) {
        FragColor = vec4(0.0);
        return;
    }
    float value = 0.0;
    if (mod(index, 2.0) < 0.5) {
        value = fetch_input_sample(Source, config.SourceSize.xy, index * 0.5, IQWidth, IQLength - 1.0).r;
    } else {
        for (int k = 0; k < IQ_CV_MAX_TAPS; ++k) {
            float offset = float(2 * k - (IQ_CV_MAX_TAPS - 1));
            value += IQ_CV_I[k] * fetch_input_sample(Source, config.SourceSize.xy,
                (index - offset) * 0.5, IQWidth, IQLength - 1.0).r;
        }
        for (int k = 0; k < CV_IQ_MAX_TAPS; ++k) {
            float offset = float(2 * k - (CV_IQ_MAX_TAPS - 1));
            value -= CV_IQ_H[k] * fetch_input_sample(Source, config.SourceSize.xy,
                (index - offset) * 0.5, IQWidth, IQLength - 1.0).g;
        }
    }
    FragColor = vec4(value, 0.0, 0.0, 1.0);
}
