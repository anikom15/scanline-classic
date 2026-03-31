// Field service calibration settings for the RGB electron guns
//
// This is the the final stage in the voltage domain

#pragma parameter DISPLAY_RGB_HEADER " —— Service: RGB —— " 0.0 0.0 0.0 0.0

#pragma parameter DISPLAY_BIAS_R "Bias R (IRE)" 0.0 -30.0 30.0 0.5
#pragma parameter DISPLAY_BIAS_G "Bias G (IRE)" 0.0 -30.0 30.0 0.5
#pragma parameter DISPLAY_BIAS_B "Bias B (IRE)" 0.0 -30.0 30.0 0.5

#pragma parameter DISPLAY_GAIN_R "Drive R (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_GAIN_G "Drive G (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_GAIN_B "Drive B (dB)" 0.0 -30.0 30.0 0.1

#pragma parameter DISPLAY_CUTOFF "Cutoff frequency (MHz)" 6.5 1.0 7.0 0.1
#pragma parameter DISPLAY_STOPBAND "Stopband frequency (MHz)" 8.0 1.0 8.0 0.1
