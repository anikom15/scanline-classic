// Parameters related to system video output timing

#pragma parameter TIMING_HEADER " —— System: Timing —— " 0.0 0.0 0.0 0.0

#pragma parameter V_FREQ_MODE "Vertical sync mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 0.0 0.0 3.0 1.0
#pragma parameter V_FREQ "Custom vertical sync rate (Hz)" 59.94 0.0 240.0 0.0001
#pragma parameter V_LINES_PER_FIELD "Vertical lines per field" 262.0 0.0 540.0 1.0
#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (0=Auto, 1=NTSC, 2=PAL, 3=Custom)" 1.0 0.0 3.0 1.0
#pragma parameter SC_FREQ "Custom subcarrier frequency (MHz)" 3.579545 0.0 10.0 0.000001
#pragma parameter H_BLANK_INACTIVE_LEN "Horizontal blank+inactive length" 138.0 0.0 1000.0 0.1
#pragma parameter H_BLANK_INACTIVE_UNIT "Horizontal blank+inactive unit (0=px, 1=µs, 2=% active)" 0.0 0.0 2.0 1.0
#pragma parameter FIELD_ORDER "Field order (0=odd first, 1=even first)" 0.0 0.0 2.0 1.0
#pragma parameter SHORTEN_ODD_FIELD_TIME "Shorten odd field time (0=Off, 1=On)" 0.0 0.0 1.0 1.0