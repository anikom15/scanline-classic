#pragma parameter S_VIDEO_HEADER " —— Service: S-Video Input —— " 0.0 0.0 0.0 0.0

#pragma parameter DECODER_SETUP "Setup (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter DECODER_TYPE "Decoder type (NTSC, PAL)" 0.0 0.0 1.0 1.0
#pragma parameter PAL_DECODER_MODE "PAL Decoder Mode (simple, delay-line, adaptive)" 1.0 0.0 2.0 1.0

#pragma parameter BW_MODE "Monitor mode (off, Y, B-Y, R-Y, Y+B-Y, Y+R-Y, B-Y+R-Y)" 0.0 0.0 6.0 1.0

#pragma parameter DISPLAY_BIAS_Y "Offset Y (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_BIAS_C "Offset C (IRE)" 0.0 -30.0 30.0 0.1

#pragma parameter DISPLAY_GAIN_Y "Gain Y (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_GAIN_C "Gain C (dB)" 0.0 -30.0 30.0 0.1

#pragma parameter DISPLAY_CUTOFF_Y "Display cutoff frequency Y (MHz)" 5.4 1.0 7.0 0.1
#pragma parameter DISPLAY_CUTOFF_C "Display cutoff frequency C (MHz)" 1.3 0.6 1.8 0.1

#pragma parameter DISPLAY_STOPBAND_Y "Stopband frequency Y (MHz)" 8.0 1.0 8.0 0.1
#pragma parameter DISPLAY_STOPBAND_C "Stopband frequency C (MHz)" 4.0 0.5 8.0 0.1
