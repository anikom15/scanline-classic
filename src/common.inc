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
    // Dirac-like impulse when sigma collapses: centered on [-0.5, 0.5)
    if (sigma <= 0.0)
        return (x >= -0.5 && x < 0.5) ? 1.0 : 0.0;

    // Normal Gaussian: exp(-x^2 / (2 σ^2))
    // Use EPS to avoid division by zero for tiny σ.
    float s = max(sigma, EPS);
    return exp(-sq(x) / (2.0 * sq(s)));
}

vec3 gaussian3(float x, vec3 sigma)
{
    // Component-wise Dirac handling when any channel’s sigma <= 0.
    float inSpan = (x >= -0.5 && x < 0.5) ? 1.0 : 0.0;

    vec3 impulseMask = vec3(
        sigma.r <= 0.0 ? 1.0 : 0.0,
        sigma.g <= 0.0 ? 1.0 : 0.0,
        sigma.b <= 0.0 ? 1.0 : 0.0
    );
    vec3 impulseVal = impulseMask * inSpan;

    // Gaussian for non-impulse channels
    vec3 s = max(sigma, vec3(EPS));
    vec3 k = -0.5 / (s * s);
    vec3 gaussVal = exp(k * x * x);

    // Use impulse where sigma <= 0, Gaussian otherwise
    return impulseVal + (vec3(1.0) - impulseMask) * gaussVal;
}

// Map normalized limited-range video signal to voltage
// IRE = Input * 100.0
// Voltage = IRE / 100.0 * 0.7143 V
// Output = Input * 0.7143 V
vec3 normlimit_to_voltage(const vec3 norm)
{
    return norm * 0.7143;
}

vec3 voltage_to_normlimit(const vec3 voltage)
{
    return voltage / 0.7143;
}

// Map normalized limited-range video signal to normalized full-range
// video level
//
// Voltage = Input * 0.7143 V
// Minimum voltage = 0.0 / 100.0 * 0.7143 = 0.0 V
// Maximum voltage = 133.0 / 100.0 * 0.7143 = 0.950019 V
// Voltage range = Maximum - Minimum = 0.950019 V
// Output = (Input * 0.7143 - Minimum) / Voltage range
//
// This is needed for shaders that expect full-range input, such as the
// scanline rasterizer.
vec3 normlimit_to_normfull(const vec3 norm)
{
    return norm * 0.7143 / 0.950019;
}

vec3 voltage_to_normfull(const vec3 voltage)
{
    return voltage / 0.950019;
}

// Map normalized full-range video signal to voltage
// Voltage = Input * Voltage range + Minimum voltage
vec3 normfull_to_voltage(const vec3 norm)
{
    return norm * 0.950019;
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
