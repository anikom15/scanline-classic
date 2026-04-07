/* Filename: subframe.inc

   Copyright (C) 2026 W. M. Martinez

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

// Shared multi-subframe helpers.
// These are intentionally separate from `contract.inc` so fragment shaders can
// reuse the repo's common 4-bit temporal packing without depending on the full
// timing-contract API.

uint temporal_frame_index(
    uint frame_count,
    uint current_subframe,
    uint total_subframes)
{
    if (total_subframes <= 1u)
        return frame_count;

    // PERF: keep the common power-of-two paths explicit to avoid an integer
    // divide on the usual multi-subframe counts.
    uint subframe4;
    if (total_subframes == 2u)
        subframe4 = current_subframe << 3;
    else if (total_subframes == 4u)
        subframe4 = current_subframe << 2;
    else if (total_subframes == 8u)
        subframe4 = current_subframe << 1;
    else if (total_subframes == 16u)
        subframe4 = current_subframe;
    else
        subframe4 = (current_subframe << 4) / max(total_subframes, 1u);

    return (frame_count << 4) + min(subframe4, 15u);
}
