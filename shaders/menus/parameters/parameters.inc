#pragma parameter USER_SETTINGS_HEADER "==== User Settings ====" 0.0 0.0 0.0 0.0

#pragma parameter USER_PICTURE "User: Picture" 0.5 0.0 1.0 0.01
#pragma parameter USER_BRIGHTNESS "User: Brightness" 0.5 0.0 1.0 0.01
#pragma parameter USER_COLOR "User: Color" 0.5 0.0 1.0 0.01
#pragma parameter USER_TINT "User: Tint" 0.5 0.0 1.0 0.01
#pragma parameter USER_SHARPNESS "User: Sharpness" 0.0 0.0 1.0 0.1

#pragma parameter COMPOSITE_DEMOD_HEADER " ==== Composite Video Demod. Parameters ==== " 0.0 0.0 0.0 0.0

#pragma parameter BYPASS_COMPOSITE_DEMOD "Bypass Composite demodulation (0=Off, 1=On)" 0.0 0.0 1.0 1.0

#pragma parameter V_LINES_PER_FIELD "Video lines per field" 262.5 0.0 540.0 0.5
#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#pragma parameter SC_FREQ "Custom subcarrier frequency (MHz)" 3.579545 0.0 10.0 0.000001
#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank inactive length" 138.0 0.0 1000.0 0.1
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0

#pragma parameter COLOR_FILTER_MODE "Filter mode (0=Notch,1=Comb,2=Notch+Comb,3=Off)" 0.0 0.0 3.0 1.0

#pragma parameter DISPLAY_BANDWIDTH_Y "Display Luma (Y) bandwidth (MHz)" 5.4 0.0 75.0 0.01
#pragma parameter DISPLAY_BANDWIDTH_C "Display Chroma (C) bandwidth (MHz)" 2.7 0.0 15.0 0.01

#pragma parameter DISPLAY_CUTOFF_ATTEN_Y "Display Y cutoff attenuation (dB)" 12.5 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_Y config.DISPLAY_CUTOFF_ATTEN_Y
#pragma parameter DISPLAY_CUTOFF_ATTEN_C "Display C cutoff attenuation (dB)" 12.5 0.0 30.0 1.0
#define DISPLAY_CUTOFF_ATTEN_C config.DISPLAY_CUTOFF_ATTEN_C

#pragma parameter FEEDBACK_FILTER_MODE "Feedback filter (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#define FEEDBACK_FILTER_MODE config.FEEDBACK_FILTER_MODE

#pragma parameter FEEDBACK_NOTCH_Y_CORRECT "Feedback Notch Y Correction" 0.86 0.0 10.0 0.01
#define FEEDBACK_NOTCH_Y_CORRECT config.FEEDBACK_NOTCH_Y_CORRECT

#pragma parameter FEEDBACK_RAW_Y_CORRECT "Feedback Raw Y Correction" 1.2 0.0 10.0 0.01
#define FEEDBACK_RAW_Y_CORRECT config.FEEDBACK_RAW_Y_CORRECT

#pragma parameter BW_MODE "Monitor mode (0=Off, 1=BW, 2=Y, 3=C, 4=Y+C)" 0 0 4 1
#define BW_MODE config.BW_MODE