#version 450

// Filename: display-component.slang
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
// Display-side component decoder
// ------------------------------
// Input: Real YPbPr voltage
// Output: Real RGB voltage
//
// Implements a polyphase decimator with Kaiser-windowed sinc low-pass prototypes,
// following the same sample-domain resampling model as `display-rgb.slang`.
// Separate filter designs are used for luma (Y) and chroma (Pb/Pr), based on the
// corresponding cutoff and stopband parameters in `display-component.inc`.
//
// After resampling/filtering in the YPbPr domain, component gain/bias are
// applied, the signal is decoded to RGB, and the final RGB amplifier plus
// blue-only toggle are applied.

#pragma name DisplayComponent
#pragma format R16G16B16A16_SFLOAT

#include "common.inc"
#include "color.inc"
#include "contract.inc"
#include "dsp.inc"
#include "window.inc"
#include "zoh.inc"

#include "menus/parameters/display-component.inc"
#include "menus/parameters/display-rgb-amp.inc"
#include "menus/parameters/sys-timing.inc"
#include "menus/parameters/user-uncommon.inc"

#pragma include_optional "../config/options.cfg"

#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_COMPONENT_HEADER " —— Debug Display Component —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_COMPONENT_BYPASS "Bypass display component stage" 0.0 0.0 1.0 1.0
#pragma parameter DISPLAY_COMPONENT_FILTER_BYPASS "Bypass display component filter" 0.0 0.0 1.0 1.0
#pragma parameter DESKEW_BYPASS "Bypass integrated deskew" 0.0 0.0 1.0 1.0
#endif  // OPTION_DEBUG

#define COMPONENT_INPUT

#include "display-component-filter.inc"
