/* Filename: scanline-advanced.slang

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

#version 450

#include "common.h"
#include "color.h"
#include "filter.h"
#include "geometry.h"

layout(std140, set = 0, binding = 0) uniform UBO {
	mat4 MVP;
	vec4 OutputSize;
	vec4 OriginalSize;
	vec4 SourceSize;
	uint FrameCount;
} global;

layout(push_constant) uniform Push
{
	float ON_PIXELS;
	float OFF_PIXELS;
	float H_FRONT;
	float H_BACK;
	float V_FRONT;
	float V_BACK;
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
	float FOCUS;
	float HI_RES_THRES;
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

#pragma parameter ON_PIXELS "Line-on cycle (lines)" 1.0 0.0 100.0 1.0
#pragma parameter OFF_PIXELS "Line-off cycle (lines)" 1.0 0.0 100.0 1.0
#pragma parameter H_FRONT "Horizontal front porch length (px)" 20.0 0.0 100.0 1.0
#pragma parameter H_BACK "Horizontal back porch length (px)" 40.0 0.0 100.0 1.0
#pragma parameter V_FRONT "Vertical front porch (lines)" 5.0 0.0 100.0 1.0
#pragma parameter V_BACK "Vertical back porch (lines)" 14.0 0.0 100.0 1.0
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
#pragma parameter FOCUS "Focus (%)" 0.50 0.0 1.0 0.01
#pragma parameter HI_RES_THRES "Hi-res threshold (lines)" 400.0 0.0 720.0 1.0
#pragma parameter PIN_DISTORTION_TYPE "Pincushion distortion type (electrostatic/magnetic)" 1.0 1.0 2.0 1.0
#pragma parameter DEFLECTION_ANGLE "CRT deflection angle (°)" 90.0 0.0 180.0 1.0
#pragma parameter SCREEN_ANGLE_X "CRT H. curvature angle (°)" 60.0 0.0 180.0 1.0
#pragma parameter SCREEN_ANGLE_Y "CRT V. curvature angle (°)" 30.0 0.0 180.0 1.0
#pragma parameter X_COMP "Horizontal distortion compensation" 0.0 -1.0 1.0 0.01
#pragma parameter Y_COMP "Vertical distortion compensation" 0.0 -1.0 1.0 0.01
#pragma parameter UNDERSCAN "Underscan (%)" 5.0 0.0 100.0 1.0
#pragma parameter ZOOM "Viewport zoom" 1.0 0.0 10.0 0.01
#pragma parameter COLOR_SPACE "Output color space" 1.0 1.0 4.0 1.0

#define ON_PIXELS config.ON_PIXELS
#define OFF_PIXELS config.OFF_PIXELS
#define H_FRONT config.H_FRONT
#define H_BACK config.H_BACK
#define V_FRONT config.V_FRONT
#define V_BACK config.V_BACK
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
#define FOCUS config.FOCUS
#define HI_RES_THRES config.HI_RES_THRES
#define PIN_DISTORTION_TYPE config.PIN_DISTORTION_TYPE
#define DEFLECTION_ANGLE config.DEFLECTION_ANGLE
#define SCREEN_ANGLE_X config.SCREEN_ANGLE_X
#define SCREEN_ANGLE_Y config.SCREEN_ANGLE_Y
#define X_COMP config.X_COMP
#define Y_COMP config.Y_COMP
#define UNDERSCAN config.UNDERSCAN
#define ZOOM config.ZOOM
#define COLOR_SPACE config.COLOR_SPACE

float PIXELS = ON_PIXELS + OFF_PIXELS;

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

vec3 color(vec2 uv, sampler2D tex)
{
	vec3 col;
	float G = 1.0;

	if (TRANSFER_FUNCTION < 2.0)
		col = sdr_linear(texture(tex, uv).rgb);
	else
		col = srgb_linear(texture(tex, uv).rgb);

	if (COLOR_MODE < 2.0) {
		if (SCALE_W > 0.0) {
			vec3 maxrgb = color1(WHITE, CHROMA_A_X, CHROMA_A_Y, CHROMA_A_WEIGHT,
			                     LUMINANCE_WEIGHT_R, LUMINANCE_WEIGHT_G, LUMINANCE_WEIGHT_B);

			G = 1.0 / max(max(maxrgb.r, maxrgb.g), maxrgb.b);
		}
		col = G * color1(col, CHROMA_A_X, CHROMA_A_Y, CHROMA_A_WEIGHT,
		                 LUMINANCE_WEIGHT_R, LUMINANCE_WEIGHT_G, LUMINANCE_WEIGHT_B);
	} else if (COLOR_MODE < 3.0) {
		if (SCALE_W > 0.0) {
			vec3 maxrgb = color2(WHITE);

			G = 1.0 / max(max(maxrgb.r, maxrgb.g), maxrgb.b);
		}
		col = G * color2(col);
	} else {
		if (SCALE_W > 0.0) {
			vec3 maxrgb = colorrgb(WHITE);

			G = 1.0 / max(max(maxrgb.r, maxrgb.g), maxrgb.b);
		}
		col = G * colorrgb(col);
	}
	return col;
}

vec3 pixel(float x, float y, sampler2D tex)
{
	vec3 col;
	int t = global.OriginalSize.y > int(HI_RES_THRES) ?
	        int(global.FrameCount) % 2 : 0;
	int line = int(PIXELS * global.OriginalSize.y * float(y) + float(t));

	if (line % int(PIXELS) > int(ON_PIXELS) - 1 ||
	    any(lessThan(vec2(x, y), vec2(0.0, 0.0))) ||
	    any(greaterThan(vec2(x, y), vec2(1.0, 1.0))))
		return BLACK;
	else
		return color(vec2(x, y), tex);
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
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
	vec2 uv = vTexCoord.xy;
	float ar = global.OutputSize.x / global.OutputSize.y;
	float sar = global.SourceSize.x / global.SourceSize.y;
	float par = ar / sar;

	// Normal coordinates
	uv = 2.0 * (uv - 0.5);

	// Correction
	uv = ZOOM * correction(uv / ZOOM, X_COMP, Y_COMP); 

	// Scale picture to add some padding to consider non-active signal
	float hsize = par * (global.SourceSize.x + H_FRONT + H_BACK);
	float vsize = global.SourceSize.y + V_FRONT + V_BACK;
	float hscale = par * global.SourceSize.x / hsize;
	float vscale = global.SourceSize.y / vsize;

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

	stepxy.y /= PIXELS;

	vec2 pos = uv + stepxy / 2.0;

	if (OFF_PIXELS > 0.0)
		pos.y -= stepxy.y * ON_PIXELS / PIXELS;

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

	col = clamp(col, 0.0, 1.0);
	col = srgb_gamma(col);

	FragColor = vec4(col, 1.0);
}
