#version 450

// Filename: sys-yc.slang
//
// Copyright (C) 2026 W. M. Martinez

#pragma include_optional "../config/options.cfg"
#ifdef OPTION_DEBUG
#pragma parameter DEBUG_PAL "Force PAL phase alternation (off, on)" 0.0 0.0 1.0 1.0
#endif

#include "sys-component-yc-common.slang"
