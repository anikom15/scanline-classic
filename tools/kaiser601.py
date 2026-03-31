import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import freqz


def design_kaiser_fir(cutoff_mhz, stopband_mhz, sample_rate_mhz, atten_db=40, taps_override=None):
    """
    Design a lowpass FIR filter using a Kaiser window.
    cutoff_mhz: cutoff frequency in MHz (passband edge)
    stopband_mhz: stopband frequency in MHz (start of stopband)
    sample_rate_mhz: sampling rate in MHz
    beta: Kaiser window beta (default 4.5 for ~40 dB, ignored if precise)
    precise: if True, use the more precise Kaiser formula for N and beta
    atten_db: desired stopband attenuation (only used if precise=True)
    Returns: (taps, h, beta)
    """
    trans_width = max(stopband_mhz - cutoff_mhz, 1e-6)
    if taps_override is not None:
        taps = int(taps_override)
        if taps % 2 == 0:
            taps += 1
    else:
        # Precise method only
        # Compute beta from attenuation
        if atten_db <= 21:
            beta = 0.0
        elif atten_db < 50:
            beta = 0.5842 * (atten_db - 21) ** 0.4 + 0.07886 * (atten_db - 21)
        else:
            beta = 0.1102 * (atten_db - 8.7)
        # Transition width in radians/sample for precise Kaiser formula
        delta_omega = 2 * np.pi * trans_width / sample_rate_mhz
        taps = int(np.ceil((atten_db - 8) / (2.285 * delta_omega)) + 1)
        if taps % 2 == 0:
            taps += 1
    cutoff_rel = cutoff_mhz / sample_rate_mhz
    n = np.arange(taps)
    h = 2 * cutoff_rel * np.sinc(2 * cutoff_rel * (n - (taps - 1) / 2))
    h *= np.kaiser(taps, beta)
    h /= np.sum(h)
    return taps, h, beta

def plot_response(cutoff_mhz, stopband_mhz, sample_rate_mhz):
    taps, h, beta_used = design_kaiser_fir(
        cutoff_mhz, stopband_mhz, sample_rate_mhz,
        atten_db=args.attenuation, taps_override=getattr(args, 'taps', None))
    w, response = freqz(h, worN=2048, fs=sample_rate_mhz)
    response_db = 20 * np.log10(np.abs(response) + 1e-12)

    print(f"Taps: {taps}")
    print(f"Transition width (MHz): {stopband_mhz - cutoff_mhz}")
    print(f"Beta used: {beta_used}")

    # Combined plot: impulse response (top), frequency response (bottom)
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 7), gridspec_kw={'height_ratios': [1, 2]})

    # Impulse response
    ax1.stem(np.arange(taps), h, basefmt=" ")
    ax1.set_title("Impulse Response (h[n])")
    ax1.set_xlabel("n")
    ax1.set_ylabel("h[n]")
    ax1.grid(True, which='both', ls=':')

    # Frequency response
    ax2.plot(w, response_db, label="Kaiser FIR")
    ax2.axvline(cutoff_mhz, color='g', linestyle='--', label=f"Cutoff ({cutoff_mhz} MHz)")
    ax2.axvline(stopband_mhz, color='r', linestyle='--', label=f"Stopband ({stopband_mhz} MHz)")
    ax2.axhline(-0.1, color='g', linestyle=':', label="-0.1 dB (passband)")
    ax2.axhline(-40, color='r', linestyle=':', label="-40 dB (stopband)")
    ax2.axhline(-12, color='orange', linestyle=':', label="-12 dB (transition)")

    # Mark -3 dB point for manual
    idx_3db = np.where(response_db <= -3)[0]
    if len(idx_3db) > 0:
        freq_3db = w[idx_3db[0]]
        ax2.axvline(freq_3db, color='b', linestyle=':', label=f"-3 dB ({freq_3db:.2f} MHz)")
        print(f"-3 dB point: {freq_3db:.2f} MHz")

    # Mark first frequency at -12 dB
    idx_12db = np.where(response_db <= -12)[0]
    if len(idx_12db) > 0:
        freq_12db = w[idx_12db[0]]
        ax2.axvline(freq_12db, color='purple', linestyle='--', label=f"First -12 dB ({freq_12db:.2f} MHz)")
        print(f"First -12 dB point: {freq_12db:.2f} MHz")

    # Mark last frequency at -0.1 dB
    idx_0db = np.where(response_db >= -0.1)[0]
    if len(idx_0db) > 0:
        freq_0db = w[idx_0db[-1]]
        ax2.axvline(freq_0db, color='brown', linestyle='--', label=f"Last >= -0.1 dB ({freq_0db:.2f} MHz)")
        print(f"Last >= -0.1 dB point: {freq_0db:.2f} MHz")

    ax2.set_title(f"Kaiser FIR Lowpass Filter (cutoff={cutoff_mhz} MHz, stopband={stopband_mhz} MHz, fs={sample_rate_mhz} MHz, taps={taps})")
    ax2.set_xlabel("Frequency (MHz)")
    ax2.set_ylabel("Magnitude (dB)")
    ax2.set_ylim(-60, 2)
    ax2.set_xlim(0, sample_rate_mhz / 2)
    ax2.grid(True, which='both', ls=':')
    ax2.legend(loc='best')

    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Prototype Kaiser FIR filter for scanline-classic shader")
    parser.add_argument('--cutoff', type=float, default=6.5, help='Cutoff frequency (MHz)')
    parser.add_argument('--stopband', type=float, default=8.0, help='Stopband frequency (MHz)')
    parser.add_argument('--samplerate', type=float, default=16.0, help='Sampling rate (MHz)')
    parser.add_argument('--attenuation', type=float, default=40.0, help='Desired stopband attenuation in dB')
    parser.add_argument('--taps', type=int, default=None, help='Override number of taps (forces odd)')
    args = parser.parse_args()
    plot_response(args.cutoff, args.stopband, args.samplerate)
