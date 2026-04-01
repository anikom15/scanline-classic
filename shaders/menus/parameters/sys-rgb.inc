// Parameters related to system RGB video output, i.e. the system RGB
// DAC+filter+amplifier stage

#pragma parameter SYS_RGB_HEADER " —— System: RGB —— " 0.0 0.0 0.0 0.0

#pragma parameter SYS_BIAS_R "Offset R (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_BIAS_G "Offset G (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_BIAS_B "Offset B (IRE)" 0.0 -30.0 30.0 0.1

#pragma parameter SYS_GAIN_R "Gain R (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_GAIN_G "Gain G (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_GAIN_B "Gain B (dB)" 0.0 -30.0 30.0 0.1

#pragma parameter SYS_FILTER_DECIMATION "Filter decimation factor" 1.0 1.0 16.0 0.1
#pragma parameter SYS_FILTER_ATTEN "Filter attenuation (dB)" 28.0 0.0 120.0 1.0

#pragma parameter COMPENSATE_SINC_ROLLOFF "Compensate sinc rolloff (off, on)" 1.0 0.0 1.0 1.0
