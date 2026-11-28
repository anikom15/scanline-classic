#version 450

// Filename: sys-bandlimit-vga.slang

#pragma include_optional "../config/options.cfg"
#ifdef OPTION_DEBUG
#pragma parameter DEBUG_SYS_BANDLIMIT_HEADER " —— Debug Sys Bandlimit —— " 0.0 0.0 0.0 0.0
#pragma parameter SYS_RGB_BANDLIMIT_BYPASS "System RGB bandlimit bypass" 0.0 0.0 1.0 1.0
#endif

#define VGA_RATE_DOMAIN
#include "sys-bandlimit.inc"
