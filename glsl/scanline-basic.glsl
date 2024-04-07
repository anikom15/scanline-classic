/* Filename: scanline-basic.glsl

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

const float EPS = 1.19209289551e-7;
const float PI = 3.14159265359;
const vec3 BLACK = vec3(0.0, 0.0, 0.0);
const vec3 WHITE = vec3(1.0, 1.0, 1.0);
const vec3 RED = vec3(1.0, 0.0, 0.0);
const vec3 YELLOW = vec3(1.0, 1.0, 0.0);
const vec3 GREEN = vec3(0.0, 1.0, 0.0);
const vec3 BLUE = vec3(0.0, 1.0, 1.0);
const vec3 INDIGO = vec3(0.0, 0.0, 1.0);
const vec3 VIOLET = vec3(1.0, 0.0, 1.0);

float sq(const float x)
{
	return x * x;
}

float cb(const float x)
{
	return x * x * x;
}

float crt_linear(const float x)
{
	return pow(x, 2.4);
}

vec3 crt_linear(const vec3 x)
{
	return vec3(crt_linear(x.r), crt_linear(x.g), crt_linear(x.b));
}

float crt_gamma(const float x)
{
	return pow(x, 1.0 / 2.4);
}

vec3 crt_gamma(const vec3 x)
{
	return vec3(crt_gamma(x.r), crt_gamma(x.g), crt_gamma(x.b));
}

float sdr_linear(const float x)
{
	return x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1.0 / 0.45);
}

vec3 sdr_linear(const vec3 x)
{
	return vec3(sdr_linear(x.r), sdr_linear(x.g), sdr_linear(x.b));
}

float sdr_gamma(const float x)
{
	return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099;
}

vec3 sdr_gamma(const vec3 x)
{
	return vec3(sdr_gamma(x.r), sdr_gamma(x.g), sdr_gamma(x.b));
}

float srgb_linear(const float x)
{
	return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

vec3 srgb_linear(const vec3 x)
{
	return vec3(srgb_linear(x.r), srgb_linear(x.g), srgb_linear(x.b));
}

float srgb_gamma(const float x)
{
	return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

vec3 srgb_gamma(const vec3 x)
{
	return vec3(srgb_gamma(x.r), srgb_gamma(x.g), srgb_gamma(x.b));
}

mat3 XYZ_TO_sRGB = mat3(
	 3.2406255, -0.9689307,  0.0557101,
	-1.5372080,  1.8758561, -0.2040211,
	-0.4986286,  0.0415175,  1.0569959);

mat3 colorspace_rgb()
{
	return XYZ_TO_sRGB;
}

vec3 RGB_to_xyY(const float x, const float y, const vec3 Y, const vec3 RGB)
{
	return vec3(x, y, dot(Y, RGB));
}

vec3 xyY_to_XYZ(const vec3 xyY)
{
	float x = xyY.x;
	float y = xyY.y;
	float Y = xyY.z;
	float z = 1.0 - x - y;

	return vec3(Y * x / y, Y, Y * z / y);
}

float kernel(const float x, const float B, const float C)
{
	float dx = abs(x);

	if (dx < 1.0) {
		float P1 = 2.0 - 3.0 / 2.0 * B - C;
		float P2 = -3.0 + 2.0 * B + C;
		float P3 = 1.0 - 1.0 / 3.0 * B;

		return P1 * cb(dx) + P2 * sq(dx) + P3;
	} else if ((dx >= 1.0) && (dx < 2.0)) {
		float P1 = -1.0 / 6.0 * B - C;
		float P2 = B + 5.0 * C;
		float P3 = -2.0 * B - 8.0 * C;
		float P4 = 4.0 / 3.0 * B + 4.0 * C;

		return P1 * cb(dx) + P2 * sq(dx) + P3 * dx + P4;
	} else
		return 0.0;
}

vec4 kernel4(const float x, const float B, const float C)
{
	return vec4(kernel(x - 2.0, B, C),
	            kernel(x - 1.0, B, C),
	            kernel(x, B, C),
	            kernel(x + 1.0, B, C));
}

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

#if defined(VERTEX)

#if __VERSION__ >= 130
#define COMPAT_VARYING out
#define COMPAT_ATTRIBUTE in
#define COMPAT_TEXTURE texture
#else
#define COMPAT_VARYING varying
#define COMPAT_ATTRIBUTE attribute
#define COMPAT_TEXTURE texture2D
#endif

#ifdef GL_ES
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

COMPAT_ATTRIBUTE vec4 VertexCoord;
COMPAT_ATTRIBUTE vec4 COLOR;
COMPAT_ATTRIBUTE vec4 TexCoord;
COMPAT_VARYING vec4 COL0;
COMPAT_VARYING vec4 TEX0;

uniform mat4 MVPMatrix;
uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;

#define vTexCoord TEX0.xy
#define SourceSize vec4(TextureSize, 1.0 / TextureSize)
#define OriginalSize vec4(InputSize, 1.0 / InputSize)
#define OutputSize vec4(OutputSize, 1.0 / OutputSize)

void main()
{
	gl_Position = MVPMatrix * VertexCoord;
	TEX0.xy = TexCoord.xy;
}

#elif defined(FRAGMENT)

#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

#if __VERSION__ >= 130
#define COMPAT_VARYING in
#define COMPAT_TEXTURE texture
out COMPAT_PRECISION vec4 FragColor;
#else
#define COMPAT_VARYING varying
#define FragColor gl_FragColor
#define COMPAT_TEXTURE texture2D
#endif

uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;
uniform sampler2D Texture;
COMPAT_VARYING vec4 TEX0;

#define Source Texture
#define vTexCoord TEX0.xy

#define SourceSize vec4(TextureSize, 1.0 / TextureSize)
#define OriginalSize vec4(InputSize, 1.0 / InputSize)
#define OutputSize vec4(OutputSize, 1.0 / OutputSize)

#ifdef PARAMETER_UNIFORM
uniform COMPAT_PRECISION float TRANSFER_FUNCTION;
uniform COMPAT_PRECISION float COLOR_MODE;
uniform COMPAT_PRECISION float LUMINANCE_WEIGHT_R;
uniform COMPAT_PRECISION float LUMINANCE_WEIGHT_G;
uniform COMPAT_PRECISION float LUMINANCE_WEIGHT_B;
uniform COMPAT_PRECISION float CHROMA_A_X;
uniform COMPAT_PRECISION float CHROMA_A_Y;
uniform COMPAT_PRECISION float CHROMA_B_X;
uniform COMPAT_PRECISION float CHROMA_B_Y;
uniform COMPAT_PRECISION float CHROMA_C_X;
uniform COMPAT_PRECISION float CHROMA_C_Y;
uniform COMPAT_PRECISION float CHROMA_A_WEIGHT;
uniform COMPAT_PRECISION float CHROMA_B_WEIGHT;
uniform COMPAT_PRECISION float CHROMA_C_WEIGHT;
uniform COMPAT_PRECISION float SCALE_W;
uniform COMPAT_PRECISION float SCAN_TYPE;
uniform COMPAT_PRECISION float MAX_SCAN_RATE;
uniform COMPAT_PRECISION float LINE_DOUBLER;
uniform COMPAT_PRECISION float INTER_OFF;
uniform COMPAT_PRECISION float FOCUS;
uniform COMPAT_PRECISION float ZOOM;
uniform COMPAT_PRECISION float COLOR_SPACE;
#else
#define TRANSFER_FUNCTION 1.0
#define COLOR_MODE 3.0
#define LUMINANCE_WEIGHT_R 0.2124
#define LUMINANCE_WEIGHT_G 0.7011
#define LUMINANCE_WEIGHT_B 0.0866
#define CHROMA_A_X 0.630
#define CHROMA_A_Y 0.340
#define CHROMA_B_X 0.310
#define CHROMA_B_Y 0.595
#define CHROMA_C_X 0.155
#define CHROMA_C_Y 0.070
#define CHROMA_A_WEIGHT 0.2124
#define CHROMA_B_WEIGHT 0.7011
#define CHROMA_C_WEIGHT 0.0866
#define SCALE_W 1.0
#define SCAN_TYPE 1.0
#define MAX_SCAN_RATE 480.0
#define LINE_DOUBLER 0.0
#define INTER_OFF 0.0
#define FOCUS 0.5
#define ZOOM 1.0
#define COLOR_SPACE 1.0
#endif

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
		rgb = crt_linear(COMPAT_TEXTURE(tex, uv).rgb);
	else
		rgb = srgb_linear(COMPAT_TEXTURE(tex, uv).rgb);
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
	float yThres = (SCAN_TYPE < 2.0 && OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0)
	               ? OriginalSize.y / 2.0
	               : OriginalSize.y;
	float scanw;
	int line;

	if (LINE_DOUBLER > 0.0 && OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
		yThres *= 2.0;
	scanw = max(0.0, 2.0 * (yThres / MAX_SCAN_RATE - 0.5));
	if (SCAN_TYPE < 2.0 && OriginalSize.y > 1.7 * MAX_SCAN_RATE / 2.0) {
		int t = FrameCount % 2;
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

void main()
{
	vec2 uv = vTexCoord.xy;

	// Normal coordinates
	uv = 2.0 * (uv - 0.5);
	uv /= ZOOM;
	uv = uv / 2.0 + 0.5;

	vec2 stepxy = 1.0 / SourceSize.xy;

	// Scale vertical for scanlines/interlacing
	if (SCAN_TYPE > 1.0 || OriginalSize.y < 1.7 * MAX_SCAN_RATE / 2.0)
		stepxy.y /= 2.0;	

	vec2 pos = uv + stepxy / 2.0;
	vec2 f = fract(pos / stepxy);

	if (LINE_DOUBLER > 0.0 && OriginalSize.y <= MAX_SCAN_RATE / 2.0 + EPS)
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
#endif
