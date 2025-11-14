#pragma parameter MASK_HEADER " —— Factory: Shadow Mask —— " 0.0 0.0 0.0 0.0

#pragma parameter TVL "TVL" 525.0 1.0 1600.0 1.0
#pragma parameter MASK_TYPE "Mask type (0=aperture, 1=slot, 2=shadow)" 1.0 0.0 2.0 1.0
#pragma parameter MASK_INTENSITY "Mask intensity (0=none, 100=full)" 50.0 0.0 100.0 1.0
#pragma parameter MASK_MONOCHROME "Grayscale mask (0=Off, 1=On)" 0.0 0.0 1.0 1.0
#pragma parameter MASK_DIFFUSION "Mask diffusion" 0.5 0.0 1.0 0.01

// Aspect framing for mask/output
// 0 = Full frame (4:3), 1 = Widescreen (16:9), 2 = Workstation (5:4), 3 = Wide workstation (16:10)
#pragma parameter MASK_ASPECT "Display aspect ratio (0=4:3, 1=16:9, 2=5:4, 3=16:10)" 0.0 0.0 3.0 1.0
// When enabled, areas outside the frame are shown as 50% gray instead of black
#pragma parameter MASK_FRAME_DEBUG "Mask frame debug (0=Off, 1=On)" 0.0 0.0 1.0 1.0