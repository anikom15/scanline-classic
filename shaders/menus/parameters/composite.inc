#pragma parameter S_VIDEO_HEADER " —— Service: Composite —— " 0.0 0.0 0.0 0.0

#pragma parameter BW_MODE "Monitor mode (off, BW, Y, C, Y+C)" 0.0 0.0 4.0 1.0

#pragma parameter COLOR_FILTER_MODE "Filter mode (notch, comb, notch+comb, off)" 0.0 0.0 3.0 1.0
#pragma parameter NOTCH_WIDTH "Notch band-stop width (MHz)" 2.6 0.01 10.0 0.01
#pragma parameter NOTCH_CENTER_ATTEN_DB "Notch center attenuation (dB)" 48.0 0.0 120.0 0.1
#pragma parameter NOTCH_EDGE_ATTEN_DB "Notch edge attenuation (dB)" 3.0 0.0 20.0 0.1
#pragma parameter NOTCH_Y_CORRECT "Notch Y correction" 1.18 0.0 10.0 0.01

#pragma parameter BANDPASS_WIDTH "Chroma band-pass width (MHz)" 2.6 0.01 15.0 0.01

#pragma parameter COMB_FILTER_TAPS "Comb filter taps" 1.0 1.0 3.0 1.0

#pragma parameter NOTCH_COMB_W "Notch-comb mix (%)" 50.0 0.0 100.0 1.0

#pragma parameter RAW_Y_CORRECT "Raw Y correction" 1.0 0.0 10.0 0.01
#pragma parameter RAW_C_CORRECT "Raw C correction" 1.0 0.0 10.0 0.01

#pragma parameter FEEDBACK_FILTER "Feedback filter (off,on)" 1.0 0.0 1.0 1.0

#pragma parameter FEEDBACK_NOTCH_Y_CORRECT "Feedback notch Y correction" 0.86 0.0 10.0 0.01
#pragma parameter FEEDBACK_RAW_Y_CORRECT "Feedback raw Y correction" 1.2 0.0 10.0 0.01

#pragma parameter DISPLAY_BANDWIDTH_Y "Display bandwidth Y (MHz)" 5.4 0.0 75.0 0.1
#pragma parameter DISPLAY_BANDWIDTH_C "Display bandwidth C (MHz)" 2.7 0.0 15.0 0.01

#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display cutoff attenuation Y (dB)" 12.5 0.0 30.0 1.0
#pragma parameter DISPLAY_CUTOFF_ATTEN_C "Display cutoff attenuation C (dB)" 12.5 0.0 30.0 1.0
