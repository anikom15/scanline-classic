/* Filename: common.h

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

const vec3 TEN = vec3(10.0, 10.0, 10.0);
const vec3 TWENTY = vec3(20.0, 20.0, 20.0);
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

float gaussian(float x, float sigma)
{
    return exp(-sq(x) * 1.0 / (2.0 * sq(sigma)));
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

// DCI-P3 also uses sRGB's gamma functions.
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

float adobe_linear(const float x)
{
	return pow(x, 563.0 / 256.0);
}

vec3 adobe_linear(const vec3 x)
{
	return vec3(adobe_linear(x.r), adobe_linear(x.g), adobe_linear(x.b));
}

float adobe_gamma(const float x)
{
	return pow(x, 256.0 / 563.0);
}

vec3 adobe_gamma(const vec3 x)
{
	return vec3(adobe_gamma(x.r), adobe_gamma(x.g), adobe_gamma(x.b));
}
