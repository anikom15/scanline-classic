#version 450

// Filename: display-rgb-filter.slang

#pragma include_optional "../config/options.cfg"
#ifdef OPTION_DEBUG
#pragma parameter DEBUG_DISPLAY_RGB_BANDLIMIT_HEADER " —— Debug Display RGB Bandlimit —— " 0.0 0.0 0.0 0.0
#pragma parameter DISPLAY_RGB_FILTER_BYPASS "Bypass display RGB filter" 0.0 0.0 1.0 1.0
#pragma parameter DESKEW_BYPASS "Bypass integrated deskew" 0.0 0.0 1.0 1.0
#endif

#include "display-rgb-filter.inc"
