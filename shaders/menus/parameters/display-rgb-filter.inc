// Field service calibration settings for the RGB electron guns
//
// This is the the final stage in the voltage domain

#pragma parameter DISPLAY_RGB_FILTER_HEADER " —— Service: RGB Filter —— " 0.0 0.0 0.0 0.0

#pragma parameter BW_MODE "Monitor mode (off, R, G, B, RG, RB, GB)" 0.0 0.0 6.0 1.0

#pragma parameter DISPLAY_CUTOFF "Cutoff frequency (MHz)" 6.5 1.0 7.0 0.1
#pragma parameter DISPLAY_STOPBAND "Stopband frequency (MHz)" 8.0 1.0 8.0 0.1
