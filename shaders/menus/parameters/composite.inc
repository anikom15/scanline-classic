#pragma parameter COMPOSITE_HEADER " —— Service: Composite Input —— " 0.0 0.0 0.0 0.0

#pragma parameter DECODER_SETUP "Setup (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter DECODER_TYPE "Decoder type (YIQ, YPbPr, PAL)" 1.0 0.0 2.0 1.0

#pragma parameter BW_MODE "Monitor mode (off, BW, Y, C, Y+C)" 0.0 0.0 4.0 1.0

#pragma parameter COLOR_FILTER_MODE "Filter mode (notch, simple comb, adaptive comb)" 0.0 0.0 2.0 1.0

#pragma parameter BANDPASS_WIDTH "Chroma bandpass width (MHz)" 2.6 0.01 15.0 0.01
#pragma parameter BANDPASS_ATTEN_DB "Chroma bandpass attenuation (dB)" 2.0 0.0 20.0 0.1

#pragma parameter COMB_FILTER_LUMA_ADAPT "Comb filter luma correlation factor" 0.7 0.0 1.0 0.01
#pragma parameter COMB_FILTER_CHROMA_ADAPT "Comb filter chroma correlation factor" 0.5 0.0 1.0 0.01
#pragma parameter COMB_FILTER_2D "Comb filter type (1D, 2D)" 1.0 0.0 1.0 1.0

#pragma parameter DISPLAY_BANDWIDTH_Y "Display bandwidth Y (MHz)" 5.4 0.0 75.0 0.1
#pragma parameter DISPLAY_BANDWIDTH_C "Display bandwidth C (MHz)" 2.7 0.0 15.0 0.01

#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display cutoff attenuation Y (dB)" 12.5 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_C "Display cutoff attenuation C (dB)" 12.5 0.0 30.0 1.0
