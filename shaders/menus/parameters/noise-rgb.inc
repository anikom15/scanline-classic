#pragma parameter RGB_NOISE_HEADER " —— RGB Noise —— " 0.0 0.0 0.0 0.0

#pragma parameter RGB_NOISE_PRESET "Noise grade (custom, professional, consumer, degraded)" 2.0 0.0 3.0 1.0

#pragma parameter RGB_NOISE_AWGN_DB "Noise budget (dB)" -50.0 -96.0 24.0 1.0
#pragma parameter RGB_NOISE_RG_XTALK_DB "Red-Green crosstalk (dB rel. AWGN)" 30.0 0.0 96.0 1.0
#pragma parameter RGB_NOISE_BG_XTALK_DB "Blue-Green crosstalk (dB rel. AWGN)" 30.0 0.0 96.0 1.0
#pragma parameter RGB_NOISE_CLOCK_DB "Ground bounce (dB rel. AWGN)" 6.0 -48.0 48.0 1.0
#pragma parameter RGB_NOISE_CLOCK_HARMONIC "Ground bounce fundamental (× H freq)" 3.0 1.0 512.0 1.0
#pragma parameter RGB_NOISE_YCROSSTALK_DB "Subcarrier-Blue crosstalk (dB rel. AWGN)" 10.0 -48.0 48.0 1.0
#pragma parameter RGB_NOISE_JITTER_UI "Jitter (% UI RMS)" 6.0 0.0 50.0 1.0
