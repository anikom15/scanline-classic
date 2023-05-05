#version 450

/* Filename: scanline-basic.slang

   Copyright (C) 2010 Team XBMC
   Copyright (C) 2011 Stefanos A.
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
#include "filter.h"

layout(std140, set = 0, binding = 0) uniform UBO {
	mat4 MVP;
	vec4 OutputSize;
	vec4 OriginalSize;
	vec4 SourceSize;
	uint FrameCount;
} global;

layout(push_constant) uniform Push
{
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
	float SCAN_TYPE;
	float MAX_SCAN_RATE;
	float LINE_DOUBLER;
	float INTER_OFF;
	float FOCUS;
	float ZOOM;
	float COLOR_SPACE;
} config;

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
#pragma parameter SCAN_TYPE "Scan type" 1.0 1.0 2.0 1.0
#pragma parameter MAX_SCAN_RATE "Maximum active lines" 480.0 1.0 1200.0 1.0
#pragma parameter LINE_DOUBLER "Enable line-doubler" 0.0 0.0 1.0 1.0
#pragma parameter INTER_OFF "Interlace offset" 0.0 0.0 1.0 1.0
#pragma parameter FOCUS "Focus (%)" 0.50 0.0 1.0 0.01
#pragma parameter ZOOM "Viewport zoom" 1.0 0.0 10.0 0.01
#pragma parameter COLOR_SPACE "Output color space" 1.0 1.0 4.0 1.0

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
#define SCAN_TYPE config.SCAN_TYPE
#define MAX_SCAN_RATE config.MAX_SCAN_RATE
#define LINE_DOUBLER config.LINE_DOUBLER
#define INTER_OFF config.INTER_OFF
#define FOCUS config.FOCUS
#define ZOOM config.ZOOM
#define COLOR_SPACE config.COLOR_SPACE

vec3 Yrgb_to_RGB(mat3 toRGB, vec3 W, vec3 Yrgb)
{
	mat3 xyYrgb = mat3(CHROMA_A_X, CHROMA_A_Y, Yrgb.r,
	                   CHROMA_B_X, CHROMA_B_Y, Yrgb.g,
	                   CHROMA_C_X, CHROMA_C_Y, Yrgb.b);
	mat3 XYZrgb = mat3(xyY_to_XYZ(xyYrgb[0]),
	                   xyY_to_XYZ(xyYrgb[1]),
	                   xyY_to_XYZ(xyYrgb[2]));
	mat3 RGBrgb = mat3(toRGB * XYZrgb[0],
	                   toRGB * XYZrgb[1],
	                   toRGB * XYZrgb[2]);
	return vec3(dot(W, vec3(RGBrgb[0].r, RGBrgb[1].r, RGBrgb[2].r)),
	            dot(W, vec3(RGBrgb[0].g, RGBrgb[1].g, RGBrgb[2].g)),
	            dot(W, vec3(RGBrgb[0].b, RGBrgb[1].b, RGBrgb[2].b)));
} 

vec3 color(sampler2D tex, vec2 uv)
{
	vec3 rgb;
	vec3 Yrgb;

	if (TRANSFER_FUNCTION < 2.0)
		rgb = crt_linear(texture(tex, uv).rgb);
	else
		rgb = srgb_linear(texture(tex, uv).rgb);
	if (COLOR_MODE < 2.0) {
		vec3 Wrgb = vec3(LUMINANCE_WEIGHT_R,
		                 LUMINANCE_WEIGHT_G,
		                 LUMINANCE_WEIGHT_B);

		Yrgb.r = dot(Wrgb, rgb);
		Yrgb.g = 0.0;
		Yrgb.b = 0.0;
	} else if (COLOR_MODE < 3.0) {
		vec3 Wrgb = vec3(LUMINANCE_WEIGHT_R,
		                 LUMINANCE_WEIGHT_G,
		                 LUMINANCE_WEIGHT_B);
		Yrgb.r = dot(Wrgb, rgb);
		Yrgb.g = Yrgb.r;
		Yrgb.b = 0.0;
	} else {
		Yrgb.r = rgb.r;
		Yrgb.g = rgb.g;
		Yrgb.b = rgb.b;
	}

	mat3 toRGB = colorspace_rgb();
	vec3 W = vec3(CHROMA_A_WEIGHT, CHROMA_B_WEIGHT, CHROMA_C_WEIGHT);
	vec3 RGB = Yrgb_to_RGB(toRGB, W, Yrgb);

	if (SCALE_W > 0.0) {
		vec3 white = Yrgb_to_RGB(toRGB, W, WHITE);
		float G = 1.0 / max(max(white.r, white.g), white.b);

		RGB *= G;
	}
	return clamp(RGB, 0.0, 1.0); 
}

vec3 pixel(float x, float y, sampler2D tex)
{
	float yThres = (SCAN_TYPE < 2.0 && global.OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0)
	               ? global.OriginalSize.y / 2.0
	               : global.OriginalSize.y;
	float scanw;
	int line;

	if (LINE_DOUBLER > 0.0 && global.OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
		yThres *= 2.0;
	scanw = max(0.0, 2.0 * (yThres / MAX_SCAN_RATE - 0.5));
	if (SCAN_TYPE < 2.0 && global.OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0) {
		uint t = global.FrameCount % 2u;
		line = int(2.0 * yThres * y + float(t));
	} else
		line = int(2.0 * yThres * y);
	line += int(INTER_OFF);

	if (any(lessThan(vec2(x, y), vec2(0.0, 0.0))) ||
	    any(greaterThan(vec2(x, y), vec2(1.0, 1.0))))
		return BLACK;
	else {
		if (line % 2 > 0)
			return mix(BLACK, color(tex, vec2(x, y)), scanw);
		else
			return color(tex, vec2(x, y));
	}
}

vec3 render(float y, vec4 x, vec4 taps, sampler2D tex)
{
	return pixel(x.r, y, tex) * taps.r +
	       pixel(x.g, y, tex) * taps.g +
	       pixel(x.b, y, tex) * taps.b +
	       pixel(x.a, y, tex) * taps.a;
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

void main()
{
	vec2 uv = vTexCoord.xy;

	// Normal coordinates
	uv = 2.0 * (uv - 0.5);
	uv /= ZOOM;
	uv = uv / 2.0 + 0.5;

	vec2 stepxy = 1.0 / global.SourceSize.xy;

	// Scale vertical for scanlines/interlacing
	if (SCAN_TYPE > 1.0 || global.OriginalSize.y < 1.7 * MAX_SCAN_RATE / 2.0)
		stepxy.y /= 2.0;	

	vec2 pos = uv + stepxy / 2.0;
	vec2 f = fract(pos / stepxy);

	if (LINE_DOUBLER > 0.0 && global.OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
		stepxy.y /= 2.0;

	float C = -1.0 / 3.0 * sq(FOCUS) + 5.0 / 6.0 * FOCUS;
	float B = 1.0 - 2.0 * C;

	vec4 xtaps = kernel4(1.0 - f.x, B, C);
	vec4 ytaps = kernel4(1.0 - f.y, B, C);

	// Make sure all taps added together is exactly 1.0
	xtaps /= xtaps.r + xtaps.g + xtaps.b + xtaps.a;
	ytaps /= ytaps.r + ytaps.g + ytaps.b + ytaps.a;

	vec2 xystart = (-1.5 - f) * stepxy + pos;
	vec4 x = vec4(xystart.x,
	              xystart.x + stepxy.x,
	              xystart.x + stepxy.x * 2.0,
	              xystart.x + stepxy.x * 3.0);

	vec3 col = vec3(render(xystart.y, x, xtaps, Source) * ytaps.r +
	       render(xystart.y + stepxy.y, x, xtaps, Source) * ytaps.g +
	       render(xystart.y + stepxy.y * 2.0, x, xtaps, Source) * ytaps.b +
	       render(xystart.y + stepxy.y * 3.0, x, xtaps, Source) * ytaps.a);

	col = clamp(col, 0.0, 1.0);
	col = crt_gamma(col);

	FragColor = vec4(col, 1.0);
} 
