# Filename: colormatrixcalc.R
#
# Copyright 2024 W. M. Martinez
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

sRGB <- matrix(c(0.4124, 0.3576, 0.1805,
                 0.2126, 0.7152, 0.0722,
                 0.0193, 0.1192, 0.9505),
               ncol = 3, nrow = 3, byrow = TRUE)
sRGB_inv <- matrix(c( 3.2406, -1.5372, -0.4986,
                     -0.9689,  1.8758,  0.0415,
                      0.0557, -0.2040,  1.0570),
                   ncol = 3, nrow = 3, byrow = TRUE)

r_x <- as.numeric(readline(prompt = "Enter red x coordinate: "))
r_y <- as.numeric(readline(prompt = "Enter red y coordinate: "))
g_x <- as.numeric(readline(prompt = "Enter green x coordinate: "))
g_y <- as.numeric(readline(prompt = "Enter green y coordinate: "))
b_x <- as.numeric(readline(prompt = "Enter blue x coordinate: "))
b_y <- as.numeric(readline(prompt = "Enter blue y coordinate: "))
w_x <- as.numeric(readline(prompt = "Enter white point x coordinate: "))
w_y <- as.numeric(readline(prompt = "Enter white point y coordinate: "))

r_xyz <- c(r_x, r_y, 1 - r_x - r_y)
g_xyz <- c(g_x, g_y, 1 - g_x - g_y)
b_xyz <- c(b_x, b_y, 1 - b_x - b_y)
w_xyz <- c(w_x, w_y, 1 - w_x - w_y)

w_XYZ <- 1 / w_xyz[2] * w_xyz
A <- matrix(c(r_xyz, g_xyz, b_xyz), nrow = 3, ncol = 3)
b <- solve(A) %*% w_XYZ
M <- A %*% diag(as.vector(b), 3, 3)
options(scipen=999)
print("RGB to XYZ Matrix")
print(M, digits = 5)
print("XYZ to RGB Matrix")
print(solve(M), digits = 5)
print("sRGB to RGB Matrix")
print(solve(M) %*% sRGB, digits = 5)
print("RGB to sRGB Matrix")
print(sRGB_inv %*% M, digits = 5)
