#pragma parameter COMPOSITE_HEADER " —— Service: Composite Input —— " 0.0 0.0 0.0 0.0

#pragma parameter DECODER_SETUP "Setup (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter DECODER_TYPE "Decoder type (NTSC, PAL)" 0.0 0.0 1.0 1.0
#pragma parameter PAL_DECODER_MODE "PAL Decoder Mode (simple, delay-line, adaptive)" 0.0 0.0 2.0 1.0

#pragma parameter BW_MODE "Monitor mode (off, Y, B-Y, R-Y, Y+B-Y, Y+R-Y, B-Y+R-Y)" 0.0 0.0 6.0 1.0

#pragma parameter COLOR_FILTER_MODE "Filter mode (notch, simple comb, adaptive comb)" 2.0 0.0 2.0 1.0

#pragma parameter DISPLAY_BANDPASS_WIDTH "Chroma bandpass width (MHz)" 1.3 0.3 3.0 0.01
#pragma parameter DISPLAY_BANDPASS_ATTEN_DB "Chroma bandpass attenuation (dB)" 3.0 0.0 20.0 0.1

#pragma parameter COMB_FILTER_LUMA_ADAPT "Comb filter luma correlation factor" 0.7 0.0 1.0 0.01
#pragma parameter COMB_FILTER_2D "Comb filter type (1D, 2D)" 1.0 0.0 1.0 1.0

#pragma parameter DISPLAY_BIAS_Y "Offset Y (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_BIAS_C "Offset C (IRE)" 0.0 -30.0 30.0 0.1

#pragma parameter DISPLAY_GAIN_Y "Gain Y (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter DISPLAY_GAIN_C "Gain C (dB)" 0.0 -30.0 30.0 0.1
