#version 450

/* Filename: scanline-bandlimit.slang

   Copyright (C) 2020 guest(r) - guest.r@gmail.com
   Copyright (C) 2023 W. M. Martinez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include "common.h"
#include "color.h"

layout(push_constant) uniform Push
{
	vec4 SourceSize;
	vec4 OriginalSize;
	vec4 OutputSize;
	uint FrameCount;
	float TRANSFER_FUNCTION;
	float LUMA_CHROMA_MODEL;
	float SIGNAL_BANDWIDTH_A;
	float SIGNAL_BANDWIDTH_B;
	float SIGNAL_BANDWIDTH_C;
	float SIGNAL_SCALE_A;
	float SIGNAL_SCALE_B;
	float SIGNAL_SCALE_C;
	float FILTER_SIZE;
} config;

#pragma parameter TRANSFER_FUNCTION "Transfer function" 1.0 1.0 2.0 1.0
#define TRANSFER_FUNCTION config.TRANSFER_FUNCTION

#pragma parameter LUMA_CHROMA_MODEL "Luma-Chroma Color Model (0=YIQ, 1=YUV, 2=YPbPr, 3=YCbCr)" 0 0 3 1
#define LUMA_CHROMA_MODEL config.LUMA_CHROMA_MODEL

#pragma parameter SIGNAL_BANDWIDTH_A "Signal Bandwidth A (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_A config.SIGNAL_BANDWIDTH_A

#pragma parameter SIGNAL_BANDWIDTH_B "Signal Bandwidth B (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_B config.SIGNAL_BANDWIDTH_B

#pragma parameter SIGNAL_BANDWIDTH_C "Signal Bandwidth C (MHz)" 6.75 0.0 75.0 0.01
#define SIGNAL_BANDWIDTH_C config.SIGNAL_BANDWIDTH_C

#pragma parameter SIGNAL_SCALE_A "Signal Scale A" 1.0 0.0 10.0 0.1
#define SIGNAL_SCALE_A config.SIGNAL_SCALE_A

#pragma parameter SIGNAL_SCALE_B "Signal Scale B" 1.0 0.0 10.0 0.1
#define SIGNAL_SCALE_B config.SIGNAL_SCALE_B

#pragma parameter SIGNAL_SCALE_C "Signal Scale C" 1.0 0.0 10.0 0.1
#define SIGNAL_SCALE_C config.SIGNAL_SCALE_C

#pragma parameter FILTER_SIZE "Gaussian Filter Radius" 5.0 0.0 40.0 1.0
#define FILTER_SIZE config.FILTER_SIZE

layout(std140, set = 0, binding = 0) uniform UBO
{
	mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
   gl_Position = global.MVP * Position;
   vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

#define COMPAT_TEXTURE(c,d) texture(c,d)
#define SourceSize config.SourceSize

float gaussian(float x, float sigma)
{
	float invsqrsigma = 1.0/(2.0*sigma*sigma);

	return exp(-x*x*invsqrsigma);
}

void main()
{
	vec3 res = vec3(720.0 / 6.75 * SIGNAL_BANDWIDTH_A,
	                720.0 / 6.75 * SIGNAL_BANDWIDTH_B,
	                720.0 / 6.75 * SIGNAL_BANDWIDTH_C);

	float f = fract(SourceSize.x * vTexCoord.x);
	f = 0.5 - f;
	vec2 tex = floor(SourceSize.xy * vTexCoord)*SourceSize.zw + 0.5*SourceSize.zw;
	vec3 color = vec3(0.0);
	vec2 dx  = vec2(SourceSize.z, 0.0);

	vec3 w;
	vec3 wsum = vec3(0.0);
	vec3 pixel;
	float n = -FILTER_SIZE;
	vec3 sigma = vec3(1.0 / (2.0 * (res.x / SourceSize.x)),
	                  1.0 / (2.0 * (res.y / SourceSize.x)),
	                  1.0 / (2.0 * (res.z / SourceSize.x)));

	do
	{
		if (TRANSFER_FUNCTION < 2.0)
			pixel = crt_gamma(COMPAT_TEXTURE(Source, tex + n*dx).rgb);
		else
			pixel = srgb_gamma(COMPAT_TEXTURE(Source, tex + n*dx).rgb);
		if (LUMA_CHROMA_MODEL >= 0)
			pixel = RGB_TO_YPbPr * pixel;
		else
			pixel = RGB_TO_YIQ * pixel;
		pixel.r *= SIGNAL_SCALE_A;
		pixel.g *= SIGNAL_SCALE_B;
		pixel.b *= SIGNAL_SCALE_C;
		w = vec3(gaussian(n+f, sigma.x),
		         gaussian(n+f, sigma.y),
		         gaussian(n+f, sigma.z));
		color = color + w * pixel;
		wsum = wsum + w;
		n = n + 1.0;
	} while (n <= FILTER_SIZE);
	color = color / wsum;

	if (LUMA_CHROMA_MODEL >= 0)
		color = YPbPr_TO_RGB * color;
	else
		color = YIQ_TO_RGB * color;
	if (TRANSFER_FUNCTION < 2.0)
		color = crt_linear(color);
	else
		color = srgb_linear(color);
	color = clamp(color, 0.0, 1.0);
	FragColor = vec4(color, 1.0);
}
