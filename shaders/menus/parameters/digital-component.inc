#pragma DIGITAL_COMPONENT_HEADER " —— System: Digital Video —— " 0.0 0.0 0.0 0.0

#pragma parameter YCBCR_MODEL "System color space (601, 709)" 0.0 0.0 2.0 1.0
#pragma parameter CHROMA_SUBSAMPLE "Chroma subsampling (auto, 4:4:4, 4:2:2, 4:2:0)" 0.0 0.0 3.0 1.0
#pragma parameter UPSAMPLER_INPUT "Resampler input type (RGB, YCbCr)" 0.0 0.0 1.0 1.0
#pragma parameter GAMMA_CORRECT_BLENDING "Use gamma correct blending (off, fast, accurate)" 0.0 0.0 2.0 1.0
#pragma parameter DIGITAL_YC_FILTER_DECIMATION "Chroma bandwidth decimation" 4.0 1.0 16.0 1.0

#pragma DAC_HEADER " —— System: Digital to Analog Converter —— " 0.0 0.0 0.0 0.0

#pragma parameter ENCODER_SETUP "Setup (off, on)" 1.0 0.0 1.0 1.0
#pragma parameter VIDEO_MODE "Output mode (Composite, S-Video, Component)" 0.0 0.0 2.0 1.0

#pragma parameter SYS_BIAS_Y "Offset Y (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_BIAS_U "Offset C/Pb (IRE)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_BIAS_V "Offset Pr (IRE)" 0.0 -30.0 30.0 0.1

#pragma parameter SYS_GAIN_Y "Gain Y (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_GAIN_U "Gain C/Pb (dB)" 0.0 -30.0 30.0 0.1
#pragma parameter SYS_GAIN_V "Gain Pr (dB)" 0.0 -30.0 30.0 0.1