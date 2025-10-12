#version 450

/* Filename: scanline-advanced.slang

   Copyright (C) 2010 Team XBMC
   Copyright (C) 2011 Stefanos A.
   Copyright (C) 2023-2025 W. M. Martinez

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
#include "geometry.h"
#include "subpixel_masks.h"

layout(std140, set = 0, binding = 0) uniform UBO {
	mat4 MVP;
	vec4 OutputSize;
	vec4 OriginalSize;
	vec4 SourceSize;
	uint FrameCount;
} global;

layout(push_constant) uniform Push
{
	float H_FRONT;
	float H_BACK;
	float V_FRONT;
	float V_BACK;
	float COLOR_MODE;
	float SCAN_TYPE;
	float MAX_SCAN_RATE;
	float LINE_DOUBLER;
	float INTER_OFF;
	float FOCUS;
	float MASK_TYPE;
	float PIN_DISTORTION_TYPE;
	float DEFLECTION_ANGLE;
	float SCREEN_ANGLE_X;
	float SCREEN_ANGLE_Y;
	float X_COMP;
	float Y_COMP;
	float UNDERSCAN;
	float ZOOM;
	float COLOR_SPACE;
} config;

#pragma parameter H_FRONT "Horizontal front porch length (px)" 20.0 0.0 100.0 1.0
#pragma parameter H_BACK "Horizontal back porch length (px)" 40.0 0.0 100.0 1.0
#pragma parameter V_FRONT "Vertical front porch (lines)" 5.0 0.0 100.0 1.0
#pragma parameter V_BACK "Vertical back porch (lines)" 14.0 0.0 100.0 1.0
#pragma parameter COLOR_MODE "Chromaticity mode" 3.0 1.0 3.0 1.0
#pragma parameter SCAN_TYPE "Scan type" 1.0 1.0 2.0 1.0
#pragma parameter MAX_SCAN_RATE "Maximum active lines" 480.0 1.0 1200.0 1.0
#pragma parameter LINE_DOUBLER "Enable line-doubler" 0.0 0.0 1.0 1.0
#pragma parameter INTER_OFF "Interlace offset" 0.0 0.0 1.0 1.0
#pragma parameter FOCUS "Focus (%)" 0.50 0.0 1.0 0.01
#pragma parameter MASK_TYPE "Subpixel layout" 1.0 1.0 25.0 1.0
#pragma parameter PIN_DISTORTION_TYPE "Pincushion distortion type (electrostatic/magnetic)" 1.0 1.0 2.0 1.0
#pragma parameter DEFLECTION_ANGLE "CRT deflection angle (°)" 90.0 0.0 180.0 1.0
#pragma parameter SCREEN_ANGLE_X "CRT H. curvature angle (°)" 60.0 0.0 180.0 1.0
#pragma parameter SCREEN_ANGLE_Y "CRT V. curvature angle (°)" 30.0 0.0 180.0 1.0
#pragma parameter X_COMP "Horizontal distortion compensation" 0.0 -1.0 1.0 0.01
#pragma parameter Y_COMP "Vertical distortion compensation" 0.0 -1.0 1.0 0.01
#pragma parameter UNDERSCAN "Underscan (%)" 5.0 0.0 100.0 1.0
#pragma parameter ZOOM "Viewport zoom" 1.0 0.0 10.0 0.01
#pragma parameter COLOR_SPACE "Output color space" 1.0 1.0 4.0 1.0

#define H_FRONT config.H_FRONT
#define H_BACK config.H_BACK
#define V_FRONT config.V_FRONT
#define V_BACK config.V_BACK
#define COLOR_MODE config.COLOR_MODE
#define SCAN_TYPE config.SCAN_TYPE
#define MAX_SCAN_RATE config.MAX_SCAN_RATE
#define LINE_DOUBLER config.LINE_DOUBLER
#define INTER_OFF config.INTER_OFF
#define MASK_TYPE config.MASK_TYPE
#define FOCUS config.FOCUS
#define PIN_DISTORTION_TYPE config.PIN_DISTORTION_TYPE
#define DEFLECTION_ANGLE config.DEFLECTION_ANGLE
#define SCREEN_ANGLE_X config.SCREEN_ANGLE_X
#define SCREEN_ANGLE_Y config.SCREEN_ANGLE_Y
#define X_COMP config.X_COMP
#define Y_COMP config.Y_COMP
#define UNDERSCAN config.UNDERSCAN
#define ZOOM config.ZOOM
#define COLOR_SPACE config.COLOR_SPACE

vec3 mask(vec2 uv)
{
	return mask_weights(uv, 1.0, int(MASK_TYPE - 1.0));
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
			return mix(BLACK, texture(tex, vec2(x, y)).rgb, scanw);
		else
			return texture(tex, vec2(x, y)).rgb;
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
	float ar = global.OutputSize.x / global.OutputSize.y;
	float sar = global.OriginalSize.x / global.OriginalSize.y;
	float par = ar / sar;

	// Normal coordinates
	uv = 2.0 * (uv - 0.5);

	// Correction
	uv = ZOOM * correction(uv / ZOOM, X_COMP, Y_COMP); 

	// Scale picture to add some padding to consider non-active signal
	float hsize = par * (global.OriginalSize.x + H_FRONT + H_BACK);
	float vsize = global.OriginalSize.y + V_FRONT + V_BACK;
	float hscale = par * global.OriginalSize.x / hsize;
	float vscale = global.OriginalSize.y / vsize;

	ar = hsize / vsize;
	uv.x *= hscale;
	uv.y *= vscale;
	if (hsize > vsize)
		uv.y /= ar;
	else
		uv.x *= ar;
	if (DEFLECTION_ANGLE > 0.0) {
		if (PIN_DISTORTION_TYPE > 1.0)
			uv = ZOOM * pincushion_nl(uv / ZOOM,
			     PI / 2.0 * DEFLECTION_ANGLE / 180.0);
		else
			uv = ZOOM * pincushion(uv / ZOOM,
			     PI / 2.0 * DEFLECTION_ANGLE / 180.0);
	}
	if (SCREEN_ANGLE_X > 0.0)
		uv.x = ZOOM * barrel_x(uv / ZOOM,
		       PI / 2.0 * SCREEN_ANGLE_X / 180.0);
	if (SCREEN_ANGLE_Y > 0.0)
		uv.y = ZOOM * barrel_y(uv / ZOOM,
		       PI / 2.0 * SCREEN_ANGLE_Y / 180.0);
	// Compensate AR
	if (hsize > vsize)
		uv.y *= ar;
	else
		uv.x /= ar;
	uv.x /= hscale;
	uv.y /= vscale;
	uv *= 1.0 + tan(PI * UNDERSCAN / 200.0);
	uv /= ZOOM;

	uv = uv / 2.0 + 0.5;

	vec2 stepxy = 1.0 / global.SourceSize.xy;

	// Scale vertical for scanlines/interlacing
	if (SCAN_TYPE > 1.0 || global.OriginalSize.y < 1.7 * MAX_SCAN_RATE / 2.0)
		stepxy.y /= 2.0;

	if (LINE_DOUBLER > 0.0 && global.OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
		stepxy.y /= 2.0;

	// This prevents half-resolution video (e.g. 320 px) from being too blurry
	if (stepxy.y < stepxy.x)
		stepxy.x /= 2.0;

	vec2 pos = uv + stepxy / 2.0;
	vec2 f = fract(pos / stepxy);

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

	if (COLOR_MODE > 2.0)
		col *= mask(vTexCoord.xy * global.OutputSize.xy);

	col = clamp(col, 0.0, 1.0);
	col = crt_gamma(col);

	FragColor = vec4(col, 1.0);
}
