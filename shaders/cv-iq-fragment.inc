// Filename: cv-iq-fragment.inc
// Copyright (C) 2026 W. M. Martinez
// SPDX-License-Identifier: GPL-3.0-or-later

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in float CVLength;
layout(location = 2) flat in float IQLength;
layout(location = 3) flat in float CVWidth;
layout(location = 4) flat in float IQWidth;
layout(location = 5) flat in float TextureFits;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 1) uniform sampler2D Source;
