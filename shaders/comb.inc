// Filename: comb.inc
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
//
// Shared line-comb sampling and phase helpers.

float fetch_comb_line_sample(
    sampler2D source,
    vec2 source_size,
    float x,
    vec2 line_range,
    float frame_width,
    float data_length,
    int channel)
{
    float sample_x = clamp(x, 0.0, max(line_range.y - 1.0, 0.0));
    float x0 = floor(sample_x);
    float index = line_range.x + x0;
    float index_next = line_range.x + min(x0 + 1.0, line_range.y - 1.0);
    float a = fetch_input_sample(
        source, source_size, index, frame_width, data_length - 1.0)[channel];
    float b = fetch_input_sample(
        source, source_size, index_next, frame_width, data_length - 1.0)[channel];
    return mix(a, b, fract(sample_x));
}

float comb_point_correlation(float ref, float cmp)
{
    float diff = abs(ref - cmp);
    return 1.0 - diff / max(ref + cmp, EPS);
}

float comb_system_phase_shift(float subcarrier_frequency, float horizontal_frequency)
{
    if (subcarrier_frequency <= 0.0 || horizontal_frequency <= EPS) {
        return 0.0;
    }

    float phase = 2.0 * PI * fract(subcarrier_frequency / horizontal_frequency);
    return phase > PI ? phase - 2.0 * PI : phase;
}

float comb_phase_offset(float target_phase, float system_phase_shift, float phase_inc_per_sample)
{
    if (abs(phase_inc_per_sample) <= EPS) {
        return 0.0;
    }

    float phase_offset = (target_phase - system_phase_shift) / phase_inc_per_sample;
    float period = 2.0 * PI / phase_inc_per_sample;
    return phase_offset - round(phase_offset / period) * period;
}
