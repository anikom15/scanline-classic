import argparse
import numpy as np
import matplotlib.pyplot as plt


# Match constants and behavior in shaders/common.inc and shaders/sharpen.slang
PI = np.pi
FILTER_THRESHOLD_ANALOG = 0.01


def gaussian(x: np.ndarray, sigma: float) -> np.ndarray:
    if sigma <= 0.0:
        return np.where((x >= -0.5) & (x < 0.5), 1.0, 0.0)
    return np.exp(-(x * x) / (2.0 * sigma * sigma))


def gaussian_sigma(cutoff_freq_norm: float, cutoff_atten_db: float) -> float:
    if cutoff_freq_norm <= 0.0 or cutoff_atten_db <= 0.0:
        return 0.0
    return np.sqrt(0.1 * cutoff_atten_db * np.log(10.0)) / (2.0 * PI * cutoff_freq_norm)


def gaussian_decay_time(sigma: float, threshold: float) -> float:
    if sigma <= 0.0 or threshold >= 1.0:
        return 0.0
    return sigma * np.sqrt(-2.0 * np.log(threshold))


def tap_count_from_sigma(sigma: float, threshold: float = FILTER_THRESHOLD_ANALOG) -> int:
    radius = gaussian_decay_time(sigma, threshold)
    taps = int(2.0 * np.ceil(radius) + 1.0)
    return max(taps, 1)


def db_targets(sharpness_0_to_1: float) -> tuple[float, float]:
    s = np.clip(sharpness_0_to_1, 0.0, 1.0)
    t_low = np.clip(s / 0.5, 0.0, 1.0)
    t_high = np.clip((s - 0.5) / 0.5, 0.0, 1.0)

    if s < 0.5:
        db_primary = (1.0 - t_low) * (-6.0) + t_low * 3.0
        db_secondary = (1.0 - t_low) * (-2.0) + t_low * 3.0
    else:
        db_primary = (1.0 - t_high) * 3.0 + t_high * 8.0
        db_secondary = (1.0 - t_high) * 3.0 + t_high * 5.0

    return db_primary, db_secondary


def build_sharpener_kernel(sample_rate_mhz: float, sharpness_percent: float) -> tuple[np.ndarray, np.ndarray]:
    fs_hz = sample_rate_mhz * 1e6

    emphasis_center_hz = 3.0e6
    emphasis2_center_hz = 8.0e6

    # Exactly as in shader: gaussian_sigma(cutoff/Fs, atten_db)
    sigma1 = gaussian_sigma(emphasis_center_hz / fs_hz, 40.0)
    sigma2 = gaussian_sigma(2.0e6 / fs_hz, 40.0)

    taps1 = tap_count_from_sigma(sigma1, FILTER_THRESHOLD_ANALOG)
    taps2 = tap_count_from_sigma(sigma2, FILTER_THRESHOLD_ANALOG)

    center1 = (taps1 - 1) // 2
    center2 = (taps2 - 1) // 2

    n1 = np.arange(taps1) - center1
    n2 = np.arange(taps2) - center2

    phase1 = 2.0 * PI * emphasis_center_hz / fs_hz
    phase2 = 2.0 * PI * emphasis2_center_hz / fs_hz

    g1 = gaussian(n1.astype(float), sigma1)
    g2 = gaussian(n2.astype(float), sigma2)

    gain1 = np.sum(g1)
    gain2 = np.sum(g2)

    h1 = (g1 * np.cos(n1 * phase1)) / gain1
    h2 = (g2 * np.cos(n2 * phase2)) / gain2

    s = np.clip(sharpness_percent / 100.0, 0.0, 1.0)
    db_primary, db_secondary = db_targets(s)
    total_primary_gain = 10.0 ** (db_primary / 20.0)
    total_secondary_gain = 10.0 ** (db_secondary / 20.0)

    bp_primary_gain = total_primary_gain - 1.0
    bp_secondary_gain = total_secondary_gain - 1.0

    # Build one composite FIR: delta + k1*h1 + k2*h2
    half = max(center1, center2)
    n = np.arange(-half, half + 1)
    h = np.zeros_like(n, dtype=float)

    h[half] = 1.0

    i1_start = half - center1
    i1_end = i1_start + taps1
    h[i1_start:i1_end] += bp_primary_gain * h1

    i2_start = half - center2
    i2_end = i2_start + taps2
    h[i2_start:i2_end] += bp_secondary_gain * h2

    debug = np.array([
        sigma1, sigma2,
        taps1, taps2,
        db_primary, db_secondary,
        bp_primary_gain, bp_secondary_gain,
    ], dtype=float)
    return h, debug


def freq_response_db(h: np.ndarray, sample_rate_mhz: float, n_fft: int = 16384) -> tuple[np.ndarray, np.ndarray]:
    fs_hz = sample_rate_mhz * 1e6
    H = np.fft.rfft(h, n=n_fft)
    freqs_hz = np.fft.rfftfreq(n_fft, d=1.0 / fs_hz)
    mag_db = 20.0 * np.log10(np.maximum(np.abs(H), 1e-12))
    return freqs_hz / 1e6, mag_db


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot exact frequency response of shaders/sharpen.slang")
    parser.add_argument("--samplerate", type=float, default=32.0, help="Sample rate in MHz (default: 32)")
    parser.add_argument("--sharpness", type=float, default=50.0, help="Sharpness percent 0..100 (default: 50)")
    parser.add_argument("--nfft", type=int, default=16384, help="FFT size for response resolution")
    args = parser.parse_args()

    fig, ax = plt.subplots(figsize=(9, 5.5))

    # Always overlay endpoints for quick visual comparison with the selected value.
    values = [args.sharpness, 0.0, 100.0]
    values = list(dict.fromkeys(values))

    for s in values:
        h, dbg = build_sharpener_kernel(args.samplerate, s)
        f_mhz, mag_db = freq_response_db(h, args.samplerate, n_fft=args.nfft)
        db_p, db_s = db_targets(np.clip(s / 100.0, 0.0, 1.0))
        label = f"sharpness={s:.1f}% (target: primary={db_p:.2f} dB, secondary={db_s:.2f} dB)"
        ax.plot(f_mhz, mag_db, label=label)

        print(f"sharpness={s:.1f}%")
        print(f"  sigma1={dbg[0]:.6f}, sigma2={dbg[1]:.6f}")
        print(f"  taps1={int(dbg[2])}, taps2={int(dbg[3])}, threshold={FILTER_THRESHOLD_ANALOG}")
        print(f"  dB_primary={dbg[4]:.3f}, dB_secondary={dbg[5]:.3f}")
        print(f"  bp_primary_gain={dbg[6]:.6f}, bp_secondary_gain={dbg[7]:.6f}")

    ax.axvline(3.0, color="tab:orange", linestyle="--", linewidth=1.0, label="Primary center (3 MHz)")
    ax.axvline(8.0, color="tab:green", linestyle="--", linewidth=1.0, label="Secondary center (8 MHz)")

    ax.set_title(f"Sharpen Circuit Frequency Response (Fs={args.samplerate:.2f} MHz)")
    ax.set_xlabel("Frequency (MHz)")
    ax.set_ylabel("Magnitude (dB)")
    ax.set_xlim(0.0, args.samplerate * 0.5)
    ax.set_ylim(-24.0, 14.0)
    ax.grid(True, which="both", linestyle=":")
    ax.legend(loc="best")

    plt.tight_layout()
    plt.show()


if __name__ == "__main__":
    main()
