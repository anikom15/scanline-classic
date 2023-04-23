/* Filename: color.h

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

mat3 XYZ_TO_sRGB = mat3(
	 3.2406255, -0.9689307,  0.0557101,
	-1.5372080,  1.8758561, -0.2040211,
	-0.4986286,  0.0415175,  1.0569959);

mat3 colorspace_rgb()
{
	return XYZ_TO_sRGB;
}

vec3
color1(const vec3 col, const float x, const float y, const float scale,
       const float Yr, const float Yg, const float Yb)
{
	mat3 RGB = colorspace_rgb();
	float z = 1.0 - x - y;
	float Y = Yr * col.r + Yg * col.g + Yb * col.b;
	float X = Y * x / y;
	float Z = Y * z / y;
	vec3 XYZ = vec3(X, Y, Z);

	return scale * RGB * XYZ;
} 
