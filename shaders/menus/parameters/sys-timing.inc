// Parameters related to system video output timing

#pragma parameter TIMING_HEADER " —— System: Timing —— " 0.0 0.0 0.0 0.0

#pragma parameter SC_FREQ_MODE "Subcarrier frequency mode (auto, NTSC, PAL, PAL-M, custom, off)" 0.0 0.0 5.0 1.0
#pragma parameter SC_FREQ_WHOLE "Custom subcarrier frequency, whole MHz" 3.0 0.0 10.0 1.0
#pragma parameter SC_FREQ_FRAC6 "Custom subcarrier frequency, first 6 decimal digits" 579545.0 0.0 999999.0 1.0
#pragma parameter SC_FREQ_FRAC11 "Custom subcarrier frequency, next 5 decimal digits" 0.0 0.0 99999.0 1.0
#pragma parameter PIXEL_CLOCK_MODE "Pixel clock mode (fixed, multiple of subcarrier)" 0.0 0.0 1.0 1.0
#pragma parameter PIXEL_CLOCK_WHOLE "Pixel clock MHz / multiplier, whole part" 13.0 0.0 500.0 1.0
#pragma parameter PIXEL_CLOCK_FRAC6 "Pixel clock / multiplier, first 6 decimal digits" 500000.0 0.0 999999.0 1.0
#pragma parameter PIXEL_CLOCK_FRAC11 "Pixel clock / multiplier, next 5 decimal digits" 0.0 0.0 99999.0 1.0
#pragma parameter H_FREQ_MODE "Horizontal frequency mode (standard, PC divisor, custom)" 0.0 0.0 2.0 1.0
#pragma parameter H_FREQ "Custom horizontal frequency (kHz) / divisor" 15.734 0.0 4000.0 0.01
#pragma parameter V_FREQ_MODE "Vertical sync mode (auto, NTSC, PAL, H freq divisor, custom)" 0.0 0.0 4.0 1.0
#pragma parameter V_FREQ "Custom vertical sync rate (Hz) / divisor" 59.94 0.0 600.0 0.01
#pragma parameter H_BLANK_FUZZ "Horizontal blanking fuzz factor (%)" 82.8 0.0 100.0 0.1
#pragma parameter PHASE_ZERO "Initial phase offset (°) " 0.0 0.0 360.0 1.0
#pragma parameter FIELD_ODD "Reverse standard field order (off, on)" 0.0 0.0 1.0 1.0
#pragma parameter SHORTEN_ODD_FIELD_TIME "NES/SNES field time adjust (off, on)" 0.0 0.0 1.0 1.0

#pragma parameter BLANKING_COLOR_R "Frame blank color R" 0.0 0.0 1.0 0.01
#pragma parameter BLANKING_COLOR_G "Frame blank color G" 0.0 0.0 1.0 0.01
#pragma parameter BLANKING_COLOR_B "Frame blank color B" 0.0 0.0 1.0 0.01
