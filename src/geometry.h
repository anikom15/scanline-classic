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

vec2 pincushion(vec2 uv, const float THETA)
{
	float T = THETA / (PI / 2.0);

	uv.x = atan(T * uv.x * cos(T * uv.y));
	uv.y = atan(T * uv.y * cos(T * uv.x));
	return uv / T;
}

vec2 pincushion_nl(vec2 uv, const float THETA)
{
	float T = THETA / (PI / 2.0);

	uv.x = sin(atan(T * uv.x * cos(T * uv.y)));
	uv.y = sin(atan(T * uv.y * cos(T * uv.x)));
	return uv / T;
}

vec2 barrel(vec2 uv, const float THETA)
{
	uv *= THETA;
	uv.x = tan(uv.x) / cos(uv.y);
	uv.y = tan(uv.y) / cos(uv.y);
	return uv / THETA;
}

float barrel_x(vec2 uv, const float THETA)
{
	uv *= THETA;
	uv.x = tan(uv.x) / cos(uv.y);
	return uv.x / THETA;
}

float barrel_y(vec2 uv, const float THETA)
{
	uv *= THETA;
	uv.y = tan(uv.y) / cos(uv.x);
	return uv.y / THETA;
}

vec2 correction(vec2 uv, const float K1, const float K2)
{
	uv.x *= 1.0 - K1 * uv.y * uv.y;
	uv.y *= 1.0 - K2 * uv.x * uv.x;
	return uv;
}
