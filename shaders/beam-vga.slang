#version 450

// Filename: beam-vga.slang

#include "menus/parameters/vga-dsp.inc"
#pragma include_optional "../config/options.cfg"
#ifdef OPTION_DEBUG
#pragma parameter DEBUG_BEAM_HEADER " —— Debug Beam —— " 0.0 0.0 0.0 0.0
#pragma parameter GEOMETRY_BYPASS "Bypass beam geometry" 0.0 0.0 1.0 1.0
#pragma parameter BEAM_FILTER_TYPE "Beam filter type (fast, accurate, bilinear)" 0.0 0.0 2.0 1.0
#endif

#define VGA_RATE_DOMAIN
#include "beam.inc"
