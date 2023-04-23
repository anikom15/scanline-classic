# Filename: phosphorweights.R
#
# Copyright 2023 W. M. Martinez
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

b <- 1 / w_xyz[2] * w_xyz
A <- cbind(r_xyz, g_xyz, b_xyz)
x <- solve(A) %*% b

Y <- c(r_y, g_y, b_y) * x
cat(sprintf("Luminance Weights\nRed:   %f\nGreen: %f\nBlue:  %f\n", Y[1], Y[2], Y[3]))
