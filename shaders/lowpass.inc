// Filename: lowpass.inc
//
// Copyright (C) 2026 W. M. Martinez
//
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

float gaussian_lowpass_gain(float sigma, float taps)
{
    float gain = 0.0;
    for (int k = 0; k < int(taps); ++k) {
        float t = float(k) - (taps - 1.0) / 2.0;
        gain += gaussian(t, sigma);
    }
    return max(gain, EPS);
}

vec3 gaussian_lowpass_gain(vec3 sigma, float taps)
{
    vec3 gain = vec3(0.0);
    for (int k = 0; k < int(taps); ++k) {
        float t = float(k) - (taps - 1.0) / 2.0;
        gain += vec3(
            gaussian(t, sigma.x),
            gaussian(t, sigma.y),
            gaussian(t, sigma.z));
    }
    return max(gain, vec3(EPS));
}

float butterworth_matched_cutoff(float cutoff, float attenuation, float sigma, float min_denominator)
{
    if (attenuation <= 3.0)
        return cutoff;
    return sqrt(log(2.0)) / max(2.0 * PI * sigma, min_denominator);
}

float butterworth_alpha_from_prewarp(float k)
{
    return (1.0 - k) / (1.0 + k);
}

vec2 butterworth_alpha_from_prewarp(vec2 k)
{
    return (1.0 - k) / (1.0 + k);
}
