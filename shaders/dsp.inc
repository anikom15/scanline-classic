// Filename: dsp.inc
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
// Functions for 1D analog-modeled DSP

// Samples a packed 2D grid of stored samples as a 1D stream
//
// Parameters:
//   - `source`: the input texture containing the packed sample grid
//   - `source_size`: the dimensions of the input texture in pixels
//   - `sample_index`: the 0-based index of the sample to fetch in the 1D stream
//   - `frame_width`: the number of samples per line in the packed grid
//   - `input_data_limit`: the total number of valid samples in the input stream;
//     out-of-range indices are clamped to the valid range with repeat-edge behavior
//
// Returns: the RGBA sample value at the requested index
vec4 fetch_input_sample(sampler2D source, vec2 source_size, float sample_index, float frame_width, float input_data_limit)
{
    int frame_width_i = max(int(frame_width + 0.5), 1);
    int input_data_limit_i = max(int(input_data_limit + 0.5), 0);
    int clamped_index_i = clamp(int(floor(clamp(sample_index, 0.0, input_data_limit))),
        0, input_data_limit_i);
    int texel_y = clamped_index_i / frame_width_i;
    int texel_x = clamped_index_i - texel_y * frame_width_i;

    texel_x = clamp(texel_x, 0, max(int(source_size.x) - 1, 0));
    texel_y = clamp(texel_y, 0, max(int(source_size.y) - 1, 0));

    return texelFetch(source, ivec2(texel_x, texel_y), 0);
}

// Reconstructs the absolute wrapped carrier phase at a given sample index
// Parameters:
//   - `sample_index`: the 0-based index of the sample in the 1D stream
//   - `phase_rel_sample`: the fractional sample offset
//   - `f`: the carrier frequency in Hz
//   - `Fs`: the sampling frequency in Hz
//   - `phi`: the initial carrier phase in radians at sample index 0
//
// Returns: the normalized carrier phase wrapped to [0, 1)
float carrier_phase(float sample_index, float phase_rel_sample, float f, float Fs, float phi)
{
    return fract(f / Fs * (sample_index + phase_rel_sample) + phi / (2.0 * PI));
}
