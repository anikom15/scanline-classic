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
     1.716650, -0.66668,   0.01764,
    -0.355671,  1.616481, -0.042771,
    -0.253366,  0.015769,  0.942103);

mat3 XYZ_TO_AdobeRGB = mat3(
     2.04159, -0.96924,  0.01344,
    -0.56501,  1.87597, -0.11836,
    -0.34473,  0.04156,  1.01517);

mat3 XYZ_TO_DCIP3 = mat3(
     2.493497, -0.829489,  0.035846,
    -0.931384,  1.762664, -0.076172,
    -0.402711,  0.023625,  0.956885);

mat3 sRGB_TO_XYZ = mat3(
    0.4124, 0.2126, 0.0193,
    0.3576, 0.7152, 0.1192,
    0.1805, 0.0722, 0.9505);

mat3 RGB_TO_YIQ = mat3(
    0.30,  0.599,   0.213,
    0.59, -0.2773, -0.5251,
    0.11, -0.3217,  0.3121);

mat3 YIQ_TO_RGB = mat3(
    1.0,     1.0,      1.0,
    0.9496, -0.27848, -1.1000,
    0.6236, -0.6357,   1.7000);

mat3 RGB_TO_YUV = mat3(
    0.299, -0.14713, 0.615,
    0.587, -0.28886, -0.51499,
    0.114,  0.436,   -0.10001);

mat3 YUV_TO_RGB = mat3(
    1.0,    1.0,      1.0,
    0.0,   -0.39465,  2.03211,
    1.13983, -0.58060,  0.0);

mat3 RGB_TO_YPbPr = mat3(
    0.299, -0.168736,  0.5,
    0.587, -0.331264, -0.418688,
    0.114,  0.5,      -0.081312);

mat3 YPbPr_TO_RGB = mat3(
    1.0,    1.0,      1.0,
    0.0,   -0.344136, 1.772,
    1.402, -0.714136, 0.0);

mat3 RGB_TO_YCbCr = mat3(
    0.2126, -0.1146,  0.5,
    0.7152, -0.3854, -0.4542,
    0.0722,  0.5,    -0.0458);

mat3 YCbCr_TO_RGB = mat3(
    1.0,    1.0,      1.0,
    0.0,   -0.1873,   1.8556,
    1.5748, -0.4681,   0.0);
    

mat3 colorspace_rgb(const float colorspace)
{
    if (colorspace == 1.0)
        return XYZ_TO_sRGB;
    else if (colorspace == 2.0)
        return XYZ_TO_BT2020;
    else if (colorspace == 3.0)
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

vec3 XYZ_to_CIE_LUV(vec3 XYZ) {
    const float Yn = 1.0;
    const float Un = (4.0 * 0.95047) / (0.95047 + 15.0 * Yn + 3.0 * 1.08883);
    const float Vn = (9.0 * Yn) / (0.95047 + 15.0 * Yn + 3.0 * 1.08883);

    float Y = XYZ.y / Yn;
    float L = (Y > 0.008856) ? (116.0 * pow(Y, 1.0 / 3.0) - 16.0) : (903.3 * Y);

    float denom = XYZ.x + 15.0 * XYZ.y + 3.0 * XYZ.z;
    float u = (denom > 0.0) ? (4.0 * XYZ.x) / denom : 0.0;
    float v = (denom > 0.0) ? (9.0 * XYZ.y) / denom : 0.0;

    float U = 13.0 * L * (u - Un);
    float V = 13.0 * L * (v - Vn);

    return vec3(L, U, V);
}

vec3 CIE_LUV_to_XYZ(vec3 LUV) {
    const float Yn = 1.0;
    const float Un = (4.0 * 0.95047) / (0.95047 + 15.0 * Yn + 3.0 * 1.08883);
    const float Vn = (9.0 * Yn) / (0.95047 + 15.0 * Yn + 3.0 * 1.08883);

    float L = LUV.x;
    float U = LUV.y;
    float V = LUV.z;

    float u = Un + U / (13.0 * L);
    float v = Vn + V / (13.0 * L);

    float Y = (L > 8.0) ? pow((L + 16.0) / 116.0, 3.0) : (L / 903.3);
    float X = Y * 9.0 * u / (4.0 * v);
    float Z = Y * (12.0 - 3.0 * u - 20.0 * v) / (4.0 * v);

    return vec3(X, Y, Z);
}
