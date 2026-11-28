// Filename: cv-iq-common.inc
// Copyright (C) 2026 W. M. Martinez
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Packed 32 MHz composite and half-rate analytic stream geometry.
#include "common.inc"
#include "contract.inc"
#include "dsp.inc"
#include "filter-taps.inc"
#include "menus/parameters/sys-timing.inc"
#pragma include_optional "../config/options.cfg"
#include "timing-profiles.inc"

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
} config;

layout(std140, set = 0, binding = 0) uniform UBO
{
    uint FrameCount;
    float FIELD_ODD;
    float TIMING_PROFILE;
    mat4 MVP;
    float SC_FREQ_FRAC6;
    float SC_FREQ_FRAC11;
    float PIXEL_CLOCK_FRAC6;
    float PIXEL_CLOCK_FRAC11;
} global;

