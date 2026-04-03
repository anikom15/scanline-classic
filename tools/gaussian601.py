import numpy as np
import matplotlib.pyplot as plt

# Gaussian sigma calculation as in common.inc
# samplerate in MHz, cutoff_freq in MHz, attenuation in dB
def gaussian_sigma(samplerate, cutoff_freq, cutoff_atten_db):
    PI = np.pi
    LN10 = np.log(10)
    # Normalized cutoff frequency
    f_c = min(cutoff_freq / max(samplerate, 1e-12), 1.0)
    if f_c <= 0.0 or cutoff_atten_db <= 0.0:
        return 0.0
    factor = (cutoff_atten_db * LN10) * 0.1
    sigma = np.sqrt(factor) / (2.0 * PI * f_c)
    return sigma

# Gaussian tap count as in common.inc
def gaussian_taps(sigma, threshold):
    if sigma <= 0.0 or threshold >= 1.0:
        return 0
    x = 2.0 * np.sqrt(-2.0 * sigma * sigma * np.log(threshold))
    taps = int(np.ceil(x)) | 1  # Next odd integer
    return taps

# Gaussian kernel
def gaussian_kernel(sigma, taps):
    center = taps // 2
    x = np.arange(taps) - center
    kernel = np.exp(-x**2 / (2 * sigma**2))
    kernel /= np.sum(kernel)
    return kernel

def plot_response(samplerate, cutoff_freq, cutoff_atten_db, threshold=0.01):
    # Compute ZOH gain at cutoff
    zoh_samplerate = 2 * cutoff_freq
    zoh_gain_at_cutoff = np.abs(np.sinc(cutoff_freq / zoh_samplerate))
    zoh_gain_db_at_cutoff = 20 * np.log10(zoh_gain_at_cutoff + 1e-12)

    # Adjust Gaussian attenuation by ZOH gain at cutoff
    adjusted_gaussian_atten = cutoff_atten_db + zoh_gain_db_at_cutoff

    # Frequency response
    from scipy.signal import freqz
    # Use adjusted attenuation for Gaussian kernel
    sigma_adj = gaussian_sigma(samplerate, cutoff_freq, adjusted_gaussian_atten)
    taps_adj = gaussian_taps(sigma_adj, threshold)
    kernel_adj = gaussian_kernel(sigma_adj, taps_adj)
    w, response = freqz(kernel_adj, worN=2048, fs=samplerate)

    # ZOH reference: sample rate = 2x cutoff
    zoh_freqs = w
    zoh_response = np.abs(np.sinc(zoh_freqs / zoh_samplerate))
    zoh_response_db = 20 * np.log10(zoh_response + 1e-12)

    # Real Gaussian FIR response: ZOH * Gaussian
    real_response = zoh_response * np.abs(response)
    real_response_db = 20 * np.log10(real_response + 1e-12)

    print(f"Sigma: {sigma_adj:.6f}")
    print(f"Taps: {taps_adj}")
    print(f"Threshold: {threshold}")
    print(f"ZOH gain at cutoff: {zoh_gain_db_at_cutoff:.2f} dB")
    print(f"Adjusted Gaussian attenuation: {adjusted_gaussian_atten:.2f} dB")


    # Ideal Gaussian response (ignores ZOH, uses original attenuation)
    sigma_ideal = gaussian_sigma(samplerate, cutoff_freq, cutoff_atten_db)
    taps_ideal = gaussian_taps(sigma_ideal, threshold)
    kernel_ideal = gaussian_kernel(sigma_ideal, taps_ideal)
    w_ideal, response_ideal = freqz(kernel_ideal, worN=2048, fs=samplerate)
    response_ideal_db = 20 * np.log10(np.abs(response_ideal) + 1e-12)

    # Plot impulse and frequency response
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 7), gridspec_kw={'height_ratios': [1, 2]})
    ax1.stem(np.arange(taps_adj), kernel_adj, basefmt=" ")
    ax1.set_title("Impulse Response (h[n])")
    ax1.set_xlabel("n")
    ax1.set_ylabel("h[n]")
    ax1.grid(True, which='both', ls=':')

    ax2.plot(w, real_response_db, label="Gaussian FIR (ZOH × Gaussian)")
    ax2.plot(w_ideal, response_ideal_db, label="Ideal Gaussian FIR", linestyle='-.', color='purple')
    ax2.plot(zoh_freqs, zoh_response_db, label=f"ZOH (fs={zoh_samplerate:.2f} MHz)", linestyle='--', color='gray')
    ax2.axvline(cutoff_freq, color='g', linestyle='--', label=f"Cutoff ({cutoff_freq} MHz)")
    # Keep attenuation limit line at original attenuation for visualization
    ax2.axhline(-cutoff_atten_db, color='r', linestyle=':', label=f"-{cutoff_atten_db} dB (atten)")
    ax2.set_title(f"Gaussian FIR Lowpass (cutoff={cutoff_freq} MHz, fs={samplerate} MHz, taps={taps_adj})")
    ax2.set_xlabel("Frequency (MHz)")
    ax2.set_ylabel("Magnitude (dB)")
    ax2.set_ylim(-60, 2)
    ax2.set_xlim(0, samplerate / 2)
    ax2.grid(True, which='both', ls=':')
    ax2.legend(loc='best')
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Prototype Gaussian FIR filter for scanline-classic shader")
    parser.add_argument('--samplerate', type=float, default=32.0, help='Sampling rate (MHz)')
    parser.add_argument('--cutoff', type=float, default=6.75, help='Cutoff frequency (MHz)')
    parser.add_argument('--attenuation', type=float, default=12.0, help='Desired attenuation at cutoff (dB)')
    parser.add_argument('--threshold', type=float, default=0.01, help='Tail threshold for tap count')
    args = parser.parse_args()
    plot_response(args.samplerate, args.cutoff, args.attenuation, args.threshold)
