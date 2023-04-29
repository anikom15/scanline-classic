#version 450

/* Filename: scanline-advanced.slang
   Version 2.0

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

layout(std140, set = 0, binding = 0) uniform UBO {
	mat4 MVP;
	vec4 SourceSize;
	vec4 PassFeedbackSize0;
} global;

layout(push_constant) uniform Push
{
	float V_FREQ;
	float TRANSFER_FUNCTION;
	float COLOR_MODE;
	float LUMINANCE_WEIGHT_R;
	float LUMINANCE_WEIGHT_G;
	float LUMINANCE_WEIGHT_B;
	float CHROMA_A_X;
	float CHROMA_A_Y;
	float CHROMA_B_X;
	float CHROMA_B_Y;
	float CHROMA_C_X;
	float CHROMA_C_Y;
	float CHROMA_A_WEIGHT;
	float CHROMA_B_WEIGHT;
	float CHROMA_C_WEIGHT;
	float SCALE_W;
	float PHOSPHORESCENSE_A;
	float PHOSPHORESCENSE_B;
	float PHOSPHORESCENSE_C; 
	float PHOS_EXP_A;
	float PHOS_EXP_B;
	float PHOS_EXP_C;
	float PHOS_TRAP_A;
	float PHOS_TRAP_B;
	float PHOS_TRAP_C;
} config;

#pragma parameter V_FREQ "Vertical Frequency (Hz)" 59.94 0.0 240.0 0.01
#pragma parameter TRANSFER_FUNCTION "Transfer function" 1.0 1.0 2.0 1.0
#pragma parameter COLOR_MODE "Chromaticity mode" 3.0 1.0 3.0 1.0
#pragma parameter LUMINANCE_WEIGHT_R "Red channel luminance weight" 0.2124 0.0 1.0 0.01
#pragma parameter LUMINANCE_WEIGHT_G "Green channel luminance weight" 0.7011 0.0 1.0 0.01
#pragma parameter LUMINANCE_WEIGHT_B "Blue channel luminance weight" 0.0866 0.0 1.0 0.01
#pragma parameter CHROMA_A_X "Chromaticity A x" 0.630 0.0 1.0 0.001
#pragma parameter CHROMA_A_Y "Chromaticity A y" 0.340 0.0 1.0 0.001
#pragma parameter CHROMA_B_X "Chromaticity B x" 0.310 0.0 1.0 0.001
#pragma parameter CHROMA_B_Y "Chromaticity B y" 0.595 0.0 1.0 0.001
#pragma parameter CHROMA_C_X "Chromaticity C x" 0.155 0.0 1.0 0.001
#pragma parameter CHROMA_C_Y "Chromaticity C y" 0.070 0.0 1.0 0.001
#pragma parameter CHROMA_A_WEIGHT "Chromaticity A luminance weight" 0.2124 0.0 1.0 0.01
#pragma parameter CHROMA_B_WEIGHT "Chromaticity B luminance weight" 0.7011 0.0 1.0 0.01
#pragma parameter CHROMA_C_WEIGHT "Chromaticity C luminance weight" 0.0866 0.0 1.0 0.01
#pragma parameter SCALE_W "Scale white point" 1.0 0.0 1.0 1.0
#pragma parameter PHOSPHORESCENSE_A "Phosphorescense decay rate A (1/s)" 9.0 0.0 100.0 1.0
#pragma parameter PHOSPHORESCENSE_B "Phosphorescense decay rate B (1/s)" 9.0 0.0 100.0 1.0
#pragma parameter PHOSPHORESCENSE_C "Phosphorescense decay rate C (1/s)" 9.0 0.0 100.0 1.0
#pragma parameter PHOS_EXP_A "Decay rate EE A" 5.0 0.0 10.0 1.0
#pragma parameter PHOS_EXP_B "Decay rate EE B" 5.0 0.0 10.0 1.0
#pragma parameter PHOS_EXP_C "Decay rate EE C" 5.0 0.0 10.0 1.0
#pragma parameter PHOS_TRAP_A "Decay escape degree A" 1.25 0.5 2.0 0.01
#pragma parameter PHOS_TRAP_B "Decay escape degree B" 1.25 0.5 2.0 0.01
#pragma parameter PHOS_TRAP_C "Decay escape degree C" 1.25 0.5 2.0 0.01

#define V_FREQ config.V_FREQ
#define TRANSFER_FUNCTION config.TRANSFER_FUNCTION
#define COLOR_MODE config.COLOR_MODE
#define LUMINANCE_WEIGHT_R config.LUMINANCE_WEIGHT_R
#define LUMINANCE_WEIGHT_G config.LUMINANCE_WEIGHT_G
#define LUMINANCE_WEIGHT_B config.LUMINANCE_WEIGHT_B
#define CHROMA_A_X config.CHROMA_A_X
#define CHROMA_A_Y config.CHROMA_A_Y
#define CHROMA_B_X config.CHROMA_B_X
#define CHROMA_B_Y config.CHROMA_B_Y
#define CHROMA_C_X config.CHROMA_C_X
#define CHROMA_C_Y config.CHROMA_C_Y
#define CHROMA_A_WEIGHT config.CHROMA_A_WEIGHT
#define CHROMA_B_WEIGHT config.CHROMA_B_WEIGHT
#define CHROMA_C_WEIGHT config.CHROMA_C_WEIGHT
#define SCALE_W config.SCALE_W
#define PHOSPHORESCENSE_A config.PHOSPHORESCENSE_A
#define PHOSPHORESCENSE_B config.PHOSPHORESCENSE_B
#define PHOSPHORESCENSE_C config.PHOSPHORESCENSE_C
#define PHOS_EXP_A config.PHOS_EXP_A
#define PHOS_EXP_B config.PHOS_EXP_B
#define PHOS_EXP_C config.PHOS_EXP_C
#define PHOS_TRAP_A config.PHOS_TRAP_A
#define PHOS_TRAP_B config.PHOS_TRAP_B
#define PHOS_TRAP_C config.PHOS_TRAP_C

vec3 color2(const vec3 col)
{
	return color1(col, CHROMA_A_X, CHROMA_A_Y, CHROMA_A_WEIGHT,
	              LUMINANCE_WEIGHT_R, LUMINANCE_WEIGHT_G, LUMINANCE_WEIGHT_B) +
	       color1(col, CHROMA_B_X, CHROMA_B_Y, CHROMA_B_WEIGHT,
	              LUMINANCE_WEIGHT_R, LUMINANCE_WEIGHT_G, LUMINANCE_WEIGHT_B);
}

vec3 colorrgb(const vec3 col)
{
	return color1(col, CHROMA_A_X, CHROMA_A_Y, CHROMA_A_WEIGHT, 1.0, 0.0, 0.0) +
	       color1(col, CHROMA_B_X, CHROMA_B_Y, CHROMA_B_WEIGHT, 0.0, 1.0, 0.0) +
	       color1(col, CHROMA_C_X, CHROMA_C_Y, CHROMA_C_WEIGHT, 0.0, 0.0, 1.0);
}

vec3 color(vec3 col)
{
	if (COLOR_MODE < 2.0)
		col = color1(col, CHROMA_A_X, CHROMA_A_Y, CHROMA_A_WEIGHT,
		             LUMINANCE_WEIGHT_R, LUMINANCE_WEIGHT_G, LUMINANCE_WEIGHT_B);
	else if (COLOR_MODE < 3.0)
		col = color2(col);
	else
		col = colorrgb(col);
	return col;
}

vec3 blend(vec3 col1, vec3 col2)
{
	return vec3(max(col1.r, col2.r), max(col1.g, col2.g), max(col1.b, col2.b));
}

float phosphor_inv_pow(float col, float gamma, float n)
{
	float y = pow(gamma * 1.0 / V_FREQ + pow(1.0 / col, 1.0 / n), -n);

	return max(0.0, min(y, col - EPS));
}

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
layout(set = 0, binding = 1) uniform sampler2D Source;
layout(set = 0, binding = 2) uniform sampler2D PassFeedback0;

void main()
{
	vec2 uv = floor(global.PassFeedbackSize0.xy * vTexCoord);
	vec3 col;

	uv = (uv + 0.5) * global.PassFeedbackSize0.zw;
	if (TRANSFER_FUNCTION < 2.0)
		col = crt_linear(texture(Source, uv).rgb);
	else
		col = srgb_linear(texture(Source, uv).rgb); 
	col = color(col);
	if (SCALE_W > 0.0) {
		vec3 maxrgb = color(WHITE);
		float G = 1.0 / max(max(maxrgb.r, maxrgb.g), maxrgb.b);

		col = G * col;
	}
	col = clamp(col, 0.0, 1.0);

	vec3 col1 = texture(PassFeedback0, uv).rgb;

	col1.r = phosphor_inv_pow(col1.r,
	                          PHOSPHORESCENSE_A * pow(10.0, PHOS_EXP_A),
	                          PHOS_TRAP_A);
	col1.g = phosphor_inv_pow(col1.g,
	                          PHOSPHORESCENSE_B * pow(10.0, PHOS_EXP_B),
	                          PHOS_TRAP_B);
	col1.b = phosphor_inv_pow(col1.b,
	                          PHOSPHORESCENSE_C * pow(10.0, PHOS_EXP_C),
	                          PHOS_TRAP_C);
	col = blend(col, col1);
	FragColor = vec4(col, 1.0);
}
