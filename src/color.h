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

mat3 XYZ_TO_BT2020 = mat3(
	 1.716650, -0.66668,  -0.253366,
	-0.355671,  1.616481, -0.042771,
	-0.253366,  0.015769,  0.942103);

mat3 XYZ_TO_AdobeRGB = mat3(
	 2.04159, -0.96924,  0.01344,
	-0.56501,  1.87597, -0.11836,
	-0.34473,  0.04156,  1.01517);

mat3 XYZ_TO_DCIP3 = mat3(
	 2.493497, -0.829489, 0.035846,
	-0.931384,  1.762664, 0.023625,
	 0.035846, -0.076172, 0.956885);

mat3 colorspace_rgb(const float colorspace)
{
	if (colorspace == 0.0)
		return XYZ_TO_sRGB;
	else if (colorspace == 1.0)
		return XYZ_TO_BT2020;
	else if (colorspace == 2.0)
		return XYZ_TO_DCIP3;
	else
		return XYZ_TO_AdobeRGB;
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
