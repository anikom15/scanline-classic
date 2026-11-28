#version 450

// Filename: cv-iq.slang
//
// Copyright (C) 2026 W. M. Martinez
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composite to analytic I/Q, retaining one complex sample per two real samples.
#pragma name CVIQ
#pragma format R16G16_SFLOAT

#define CV_IQ_ANALYSIS
#include "cv-iq-common.inc"

#pragma stage vertex
#include "cv-iq-vertex.inc"

#pragma stage fragment
#include "cv-iq-fragment.inc"

void main()
{
    vec2 pixel = floor(vTexCoord * config.OutputSize.xy);
    float index = pixel.y * IQWidth + pixel.x;
    if (TextureFits < 0.5) {
        FragColor = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    if (pixel.x >= IQWidth || index >= IQLength) {
        FragColor = vec4(0.0);
        return;
    }
    float center = 2.0 * index;
    float i = fetch_input_sample(Source, config.SourceSize.xy, center, CVWidth, CVLength - 1.0).r;
    float q = 0.0;
    for (int k = 0; k < CV_IQ_MAX_TAPS; ++k) {
        float offset = float(2 * k - (CV_IQ_MAX_TAPS - 1));
        q += CV_IQ_H[k] * fetch_input_sample(
            Source, config.SourceSize.xy, center - offset, CVWidth, CVLength - 1.0).r;
    }
    FragColor = vec4(i, q, 0.0, 1.0);
}
