#!/usr/bin/env python3
"""Analyze deskew carry precision in float32, matching GLSL computation."""

import numpy as np

f32 = np.float32


def main():
    # Exact shader constants for PSX NTSC 256px
    NTSC_FSC = f32(3.579545e6)
    PIXEL_CLOCK_MULT = f32(15.0)
    H_FREQ_DIVISOR = f32(3413.0)
    H_BLANK_FUZZ = f32(78.4)
    ORIGINAL_WIDTH = f32(256.0)

    # Compute timing chain in f32 (matching GLSL)
    pixel_clock = f32(NTSC_FSC * PIXEL_CLOCK_MULT)
    h_freq = f32(pixel_clock / H_FREQ_DIVISOR)
    clocks_per_line = f32(np.round(f32(pixel_clock / h_freq)))
    fuzz_frac = f32(H_BLANK_FUZZ / f32(100.0))
    clock_factor = f32(np.round(f32(f32(clocks_per_line * fuzz_frac) / ORIGINAL_WIDTH)))
    line_carry_clocks = f32(clocks_per_line % max(clock_factor, f32(1.0)))

    print(f"pixel_clock     = {float(pixel_clock):.1f} Hz")
    print(f"h_freq          = {float(h_freq):.6f} Hz")
    print(f"clocks_per_line = {float(clocks_per_line):.1f}")
    print(f"clock_factor    = {float(clock_factor):.1f}")
    print(f"line_carry      = {float(line_carry_clocks):.1f}")
    print()

    # Three sample_ratio scenarios
    fs_original = pixel_clock
    scenarios = [
        ("passthrough (sr=1)", fs_original),
        ("sys-bandlimit (32MHz)", f32(32.0e6)),
        ("display-bandlimit (16MHz)", f32(16.0e6)),
    ]

    for name, fs_current in scenarios:
        sr = f32(fs_current / max(fs_original, f32(1e-6)))
        carry_per_line = f32(line_carry_clocks * sr)
        cycle_width = f32(max(f32(clock_factor * sr), f32(1e-6)))

        print(f"=== {name} ===")
        print(f"  sample_ratio      = {float(sr):.10f}")
        print(f"  CarryShiftPerLine = {float(carry_per_line):.10f}")
        print(f"  CarryCycleWidth   = {float(cycle_width):.10f}")
        print()

        # Show lines 0-20, then around 128-152
        lines = list(range(21)) + list(range(125, 156))

        hdr = (
            f"  {'y':>5s}  {'acc_shift':>14s}  {'acc/cycle':>14s}  "
            f"{'floor':>8s}  {'unsigned_mod':>14s}  {'int_carry':>9s}  "
            f"{'int_scaled':>14s}  {'error':>14s}"
        )
        print(hdr)

        for y in lines:
            yf = f32(float(y))
            acc = f32(yf * carry_per_line)
            ratio = f32(acc / cycle_width)
            fl = f32(np.floor(ratio))
            # GLSL mod: x - y * floor(x/y)
            glsl_mod = f32(acc - f32(cycle_width * fl))

            # Integer-domain ground truth
            int_carry = (y * 3) % 10
            int_mod_scaled = f32(f32(float(int_carry)) * sr)

            error = float(glsl_mod) - float(int_mod_scaled)

            marker = " ***" if abs(error) > 0.01 else ""
            print(
                f"  {y:5d}  {float(acc):14.6f}  {float(ratio):14.6f}  "
                f"{float(fl):8.1f}  {float(glsl_mod):14.6f}  {int_carry:9d}  "
                f"{float(int_mod_scaled):14.6f}  {error:14.8f}{marker}"
            )

        print()


if __name__ == "__main__":
    main()
