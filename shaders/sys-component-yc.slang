#version 450

// Filename: sys-component-yc.slang
//
// Copyright (C) 2026 W. M. Martinez

#pragma include_optional "../config/options.cfg"
#ifdef OPTION_DEBUG
#pragma parameter DEBUG_PAL "Force PAL phase alternation (off, on)" 0.0 0.0 1.0 1.0
#endif

#define SYS_COMPONENT_YC_MODE
#include "sys-component-yc-common.slang"
