// Filename: bandpass.inc
//
// Copyright (C) 2026 W. M. Martinez
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Shared Gaussian carrier-bandpass helpers.

float gaussian_carrier_kernel(float t, float sigma, float omega)
{
    return gaussian(t, sigma) * cos(omega * t);
}

float gaussian_inphase_bandpass_gain(float sigma, float omega, float taps)
{
    float gain = 0.0;
    float center = (taps - 1.0) / 2.0;
    for (int k = 0; k < int(taps); ++k) {
        float t = float(k) - center;
        float carrier = cos(omega * t);
        gain += gaussian(t, sigma) * carrier * carrier;
    }
    return max(gain, EPS);
}

vec2 gaussian_carrier_response(float sigma, float omega, float taps)
{
    float gain = 0.0;
    vec2 image = vec2(0.0);
    float center = (taps - 1.0) / 2.0;
    for (int k = 0; k < int(taps); ++k) {
        float t = float(k) - center;
        float h = gaussian(t, sigma);
        gain += h;
        image += h * vec2(cos(2.0 * omega * t), sin(2.0 * omega * t));
    }
    return vec2(gain + image.x, image.y);
}

float gaussian_carrier_bandpass_gain(float sigma, float omega, float taps)
{
    vec2 response = gaussian_carrier_response(sigma, omega, taps);
    return max(length(response) * 0.5, EPS);
}

float gaussian_dc_orthogonal_notch(
    float carrier_accum,
    float dc_accum,
    float weight,
    float carrier_cos,
    float carrier_square)
{
    if (weight <= EPS)
        return 0.0;

    float dc_mean = dc_accum / weight;
    float denominator = carrier_square
        - carrier_cos * (carrier_cos / weight);
    if (denominator <= EPS)
        return 0.0;

    return (carrier_accum - carrier_cos * dc_mean) / denominator;
}
