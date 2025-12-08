#pragma parameter SYS_YC_HEADER " —— System: Y/C Processing —— " 0.0 0.0 0.0 0.0

#pragma parameter LUMA_LOWPASS_CUTOFF "Y lowpass cutoff (MHz)" 6.75 0.1 10.0 0.1
#pragma parameter LUMA_LOWPASS_ATTEN "Y lowpass attenuation (dB)" 0.0 0.0 24.0 0.1

#pragma parameter LUMA_NOTCH_ENABLE "Y notch filter (off, on)" 0.0 0.0 1.0 1.0

#pragma parameter CHROMA_BANDPASS_WIDTH "Chroma bandpass width (MHz)" 2.6 0.1 6.0 0.1
#pragma parameter CHROMA_EDGE_ATTEN_DB "Chroma edge attenuation (dB)" 3.0 0.0 24.0 0.1

#pragma parameter YC_MONITOR "Y/C monitor mode (off, Y only, C only, Y+C)" 0.0 0.0 3.0 1.0