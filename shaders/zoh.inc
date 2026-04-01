// Filename: zoh.inc
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
// ZOH-based coefficient functions for convolution

#ifndef ZOH_INC
#define ZOH_INC

// Box kernel
float zoh_area(float dt, float Tin, float Tout)
{
    // Input ZOH interval: [dt, dt + Tin]
    // Output bin:          [0, Tout]
    float left = max(0.0f, dt);
    float right = min(Tout, dt + Tin);

    float overlap = max(0.0f, right - left);
    return overlap / Tout; // area average
}

// Triangle kernel (convolution of two box kernels)
float zoh_triangle(float dt, float Tin, float T)
{
    // Triangle support: (dt - T, dt + T)
    float x0 = max(0.0f, dt - T);
    float x1 = min(Tin, dt + T);

    if (x1 <= x0)
        return 0.0f;

    float d0 = dt - x0;
    float d1 = dt - x1;

    float term0 = abs(d0) * d0;
    float term1 = abs(d1) * d1;

    float coeff =
        (x1 - x0)
        - (term0 - term1) / (2.0f * T);

    return coeff;
}

#endif // ZOH_INC
