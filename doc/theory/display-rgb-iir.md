# Display RGB IIR Filter Design

This note captures the initial design exploration for replacing the display-side Gaussian RGB lowpass with an IIR-like filter in the combined RGB bandlimit stage.

## Scope

- Focus only on the DISPLAY half of [shaders/sys-display-rgb-bandlimit.slang](shaders/sys-display-rgb-bandlimit.slang).
- Treat the SYS half as passthrough for this design exercise.
- Target a causal digital lowpass as the first candidate.

## Design Targets

- Stopband attenuation: at least 40 dB starting at 8.00 MHz.
- Passband ripple: at most 0.1 dB through 5.75 MHz.
- Transition-band check: at least 12 dB attenuation by 6.75 MHz.
- Relative passband group-delay ripple target: 2 ns at 1 kHz rising to 6 ns at 5.75 MHz.

## Working Assumption

- Evaluation sample rate: 27.0 MHz (initial), treated as a convenient engineering reference.

This was used for the first numerical filter searches and coefficient generation. It was later found that 27 MHz is not an optimal operating point for this filter. Lower rates in the 17 to 22 MHz range give better tradeoffs between order and group-delay variation. If the effective sampling model changes, the design should be re-derived instead of reusing these coefficients blindly.

## Result Summary

- A compact causal IIR can satisfy the magnitude targets.
- The best magnitude-compliant design found in the initial sweep was a 6th-order elliptic lowpass, implemented as 3 biquads.
- Standard causal IIR families that satisfied the magnitude spec did not satisfy the nanosecond-scale relative group-delay target.
- Reducing the filter to 2 biquads (4th order) did not produce any design that satisfied all magnitude targets at 27 MHz, but 2-biquad designs do become feasible below roughly 20 MHz (see sample-rate tradeoff section).

## Preferred Magnitude-Compliant Candidate

Family and order:

- Elliptic lowpass, 6th order, 3 biquads.

Design settings:

- Passband ripple setting: 0.05 dB.
- Stopband setting: 40 dB.
- Critical frequency used for the design search: about 6.240678 MHz.

Measured response:

- Passband ripple through 5.75 MHz: about 0.05 dB.
- Attenuation at 6.75 MHz: about 12.56 dB.
- Attenuation at 8.00 MHz: about 50.01 dB.

Second-order sections, each written as `[b0, b1, b2, 1, a1, a2]`:

```text
[0.07505868949008583, 0.12634786238024373, 0.07505868949008583, 1.0, -0.4316482983791915, 0.14003757240267653]
[1.0, 0.6424873443375914, 0.9999999999999997, 1.0, -0.24048379111799964, 0.5611805213261848]
[1.0, 0.238753533126947, 1.0000000000000002, 1.0, -0.12436077025266937, 0.8826270945022383]
```

Transfer function form:

```text
H(z) = prod_k (b0_k + b1_k z^-1 + b2_k z^-2) / (1 + a1_k z^-1 + a2_k z^-2)
```

## Group Delay Finding

Magnitude was achievable, but the group-delay target was not.

Observed behavior from the initial search:

- Butterworth, Chebyshev I, Chebyshev II, and elliptic designs that met the magnitude spec all exceeded the passband relative group-delay ripple target by a large margin.
- Digital Bessel designs improved delay behavior, but could not simultaneously meet the passband-ripple and stopband-attenuation requirements.

Conclusion:

- If the group-delay target remains firm, a strictly causal single-rate IIR is not a good fit.
- If only the magnitude target matters for the first implementation, the 3-biquad elliptic design is a viable reference point.

## Two-Biquad Feasibility Check

A direct 4th-order search was run at 27 MHz across Butterworth, Chebyshev I, Chebyshev II, and elliptic families.

Outcome at 27 MHz:

- No 2-biquad design met all three magnitude requirements.

Best near-miss at 27 MHz:

- 4th-order elliptic.
- Passband ripple through 5.75 MHz: about 0.10 dB.
- Attenuation at 6.75 MHz: about 6.57 dB.
- Attenuation at 8.00 MHz: about 26.17 dB.

Outcome at lower sample rates:

- 4th-order elliptic designs do meet all magnitude requirements at sample rates of roughly 17.0 to 20.0 MHz. The 6.75 MHz attenuation check becomes achievable because the same frequency occupies a larger fraction of Nyquist, which steepens the normalized transition band.
- The minimum feasible sample rate for a 2-biquad design was found at about 17 MHz, though margin there is thin once higher-order and the 6.75 MHz check compete.

Interpretation:

- Two biquads are not enough at 27 MHz.
- At approximately 17 to 20 MHz, 2 biquads are sufficient for the magnitude spec.
- At 27 MHz, a minimum of 5 poles is required just to clear the elliptic stopband, and 6 poles gave useful margin at 6.75 MHz.

## Search Notes

Initial numerical searches covered these families:

- Butterworth
- Chebyshev I
- Chebyshev II
- Elliptic
- Bessel

The 4th-order feasibility pass explicitly searched Butterworth, Chebyshev I, Chebyshev II, and elliptic parameter ranges rather than inferring from the 6th-order result.

## Sample Rate Tradeoff

The group-delay metric was updated from the original relative-to-1-kHz formulation to a span metric: the maximum minus minimum passband group delay over 1 kHz to 5.75 MHz. A fixed-offset compensation can remove any constant delay, so only the peak-to-peak variation matters.

Key observation: a lower sample rate moves the 5.75 MHz to 8.0 MHz transition band to a wider normalized position relative to Nyquist. That reduces the required filter order for the same magnitude spec, and a lower-order elliptic filter tends to have lower passband group-delay variation.

Measured best-feasible elliptic candidates (minimum order, tuned for minimum delay span while meeting all magnitude specs):

| fs (MHz) | Order | Biquads | Att 6.75 MHz (dB) | Att 8.0 MHz (dB) | Delay span (ns) |
|----------|-------|---------|-------------------|------------------|-----------------|
| 17.0     | 4     | 2       | 18.4              | 54.1             | 238             |
| 18.0     | 4     | 2       | 13.2              | 42.4             | 198             |
| 18.25    | 4     | 2       | 12.3              | 41.0             | 191             |
| 20.0     | 4     | 2       | 12.4              | 40.9             | 203             |
| 21.0     | 5     | 3       | 12.5              | 44.9             | 173             |
| 22.0     | 5     | 3       | 12.1              | 41.9             | 173             |
| 24.0     | 5     | 3       | 12.4              | 40.1             | 182             |
| 27.0     | 5     | 3       | 12.1              | 40.8             | 190             |
| 54.0     | 5     | 3       | 12.2              | 47.9             | 210             |

Higher sample rates at the same order monotonically worsen delay span because the same poles produce more absolute group-delay variation as the sample interval shrinks.

Conclusions:

- 27 MHz is not optimal under either the minimum-order or minimum-delay-span objective.
- The best 2-biquad region (minimum order, still meeting all magnitude specs) is roughly 17 to 20 MHz, with 18.0 to 18.5 MHz the most comfortable window.
- The best delay-span result at 5th order was around 21 to 22 MHz, where the span was about 173 ns versus about 190 ns at 27 MHz.
- 54 MHz is strictly worse than 27 MHz in both order and delay span for this spec.
- Going below about 17 MHz causes 3rd-order designs to fail the 6.75 MHz check, and 4th-order designs lose margin quickly.

## FIR Implementation Approach

### Sample Rate Agnosticism

The Kaiser window FIR design is essentially rate-agnostic. All candidate rates from 16.875 to 27 MHz (Nyquist 8.4 to 13.5 MHz) converge to the same design parameters: cutoff fc = 6.5 MHz and window shape parameter β = 4.0. Only the tap count changes, because the transition band from 5.75 to 8.0 MHz occupies a larger normalized fraction of Nyquist at lower rates. The constraint is that the sample rate must exceed 16 MHz so that the 8.0 MHz stopband edge lies below Nyquist.

Minimum tap counts meeting all magnitude specs at each candidate rate:

| fs (MHz) | Scale (× 13.5) | NTSC width | PAL width | Min taps N | Taps each side |
|----------|---------------|------------|-----------|------------|----------------|
| 16.875   | 1.25×         | 1073       | 1080      | 31         | 15             |
| 18.0     | 4/3×          | 1144       | 1152      | 33         | 16             |
| 20.25    | 1.5×          | 1287       | 1296      | 37         | 18             |
| 22.5     | 5/3×          | 1430       | 1440      | 41         | 20             |
| 27.0     | 2×            | 1716       | 1728      | 49         | 24             |

All entries use fc = 6.5 MHz, β = 4.0. The measured response is consistently: passband ripple ≈ 0.07 dB through 5.75 MHz, attenuation ≈ 12.2 dB at 6.75 MHz, attenuation ≈ 50–59 dB at 8.0 MHz.

20.25 MHz (1.5×) is a practical sweet spot: it gives exact integer NTSC and PAL widths, a shader `scale_x` of 1.5, and 24% fewer texture reads than 27 MHz.

### Why Parks-McClellan Fails for This Spec

An equiripple (Parks-McClellan) design was attempted before settling on Kaiser. It consistently failed the 12 dB at 6.75 MHz check regardless of tap count or weight ratio. The reason is geometric: 6.75 MHz is exactly the midpoint of the 5.75–8.0 MHz transition band, and Parks-McClellan leaves the transition band completely unconstrained. The resulting response has a shallow shoulder early in the transition that drops sharply only near the stopband edge. With correct equal-ripple weights (δpb/δsb ≈ 1.15), the attenuation at 6.75 MHz stays near 4–5 dB even at N = 71. Increasing the stopband weight to 100:1 shifts energy toward the stopband but still only reaches about 7–10 dB at 6.75 MHz. This is a fundamental property of the PM transition band shape for this geometry, not a tuning issue. The Kaiser window produces a more gradual rolloff shape that naturally reaches 12 dB at the mid-transition point with a cutoff of 6.5 MHz.

### True IIR Is Not Possible in a Shader

Fragment shaders execute all output pixels in parallel. Every invocation reads from the same input texture and produces its output independently; there is no mechanism for one pixel's output to become another pixel's input within a single pass. IIR filtering requires feedback — output sample n depends on output samples n-1 and n-2 from the same pass. This dependency cannot be expressed in a fragment shader. A multi-pass recursive approach could propagate state across passes, but each pass covers only one sample per row, making an IIR of any useful order impractical.

### Truncated IIR Impulse Response vs Kaiser FIR

A truncated IIR impulse response (TIIR FIR) is a conceptually natural alternative: compute the impulse response of the IIR filter, truncate it at some finite length L, and use those L coefficients as a standard FIR. The resulting frequency response approximates the IIR's response within the truncation error.

The problem for this spec is that the required IIR poles are close to the unit circle. The 5th-order elliptic at 27 MHz has its outermost pole pair at radius approximately √0.8826 ≈ 0.939 (from the biquad coefficient a2 = 0.8826 in the third section). The impulse response of that pole pair decays as 0.939^n per sample from its peak. To reach −40 dB truncation error, the required length is approximately:

    L = −40/20 × ln(10) / ln(0.939) ≈ 74 taps

For −60 dB: approximately 111 taps. These are one-sided (causal) lengths. To center the truncated response (zero-phase FIR), the window must cover L samples ahead and L samples behind the peak, yielding about 2L + 1 taps total for the same attenuation.

Compared to the Kaiser FIR at the same rate:

| Rate    | Kaiser N | TIIR N (−40 dB) | TIIR N (−60 dB) |
|---------|----------|-----------------|-----------------|
| 27 MHz  | 49       | ~75 odd-symmetric | ~111 odd-symmetric |
| 20.25 MHz | 37     | ~60 (poles are slightly closer to unit circle at lower fs) | ~90 |

The TIIR approach is strictly less efficient than Kaiser for this spec. It also carries additional complexity: the impulse response of a cascade of biquads does not simplify to a symmetric shape, so the frequency-domain properties of the truncated version require separate verification after every design change.

### Causal TIIR Reference Design

If the implementation goal is to preserve the general one-sided character of the IIR rather than only its magnitude response, the more relevant TIIR form is the causal truncation itself:

```text
y[n] = sum_{k=0}^{N-1} h[k] x[n-k]
```

where `h[k]` is the sampled impulse response of the chosen IIR and `N` is selected from a truncation criterion. For later reference, a simple amplitude-envelope rule was evaluated here:

```text
truncate at first n such that |h[n]| <= 0.05
```

This threshold corresponds to about -26.0 dB relative to the impulse peak. Ignoring any per-line reset behavior and using the dominant pole magnitude as the envelope approximation, the required causal length is:

```text
N_causal = ceil(ln(0.05) / ln(r))
```

For the 27 MHz elliptic reference design above, the dominant pole magnitude is approximately:

```text
r_27 = sqrt(0.8826270945) ≈ 0.93948
```

If the same analog-equivalent decay is reinterpreted at a different output sample rate `fs`, the corresponding dominant digital pole magnitude is:

```text
r(fs) = r_27^(27 MHz / fs)
```

Using that mapping, the causal TIIR lengths for practical output rates are:

| fs (MHz) | Scale (× 13.5) | NTSC width | Dominant r(fs) | Causal TIIR taps N |
|----------|---------------|------------|----------------|--------------------|
| 16.875   | 1.25×         | 1072       | 0.90494        | 30                 |
| 18.0     | 4/3×          | 1144       | 0.91061        | 32                 |
| 20.25    | 1.5×          | 1287       | 0.92014        | 36                 |
| 22.5     | 5/3×          | 1430       | 0.92783        | 40                 |
| 27.0     | 2×            | 1716       | 0.93948        | 48                 |

Interpretation:

- The minimum valid output sample rate is still just above 16 MHz, because the final decimated output must place the 8.0 MHz stopband edge below Nyquist.
- Lower output rates reduce the required causal TIIR tap count because the same decay constant occupies fewer samples.
- Internal oversampling before decimation does not reduce the required tap count for a given final output rate under this criterion. For example, 54 MHz decimated by 2 still corresponds to the 27 MHz row above.
- These counts are for the causal one-sided kernel only. They preserve the asymmetric IIR-like impulse shape, phase lag, and startup transient much better than a centered symmetric FIR.
- Texture boundary handling for this causal TIIR form should not clamp or mirror at the left edge. Instead, when the tap history walks past the start of the current line, sampling wraps to the opposite horizontal edge and then steps one texel row upward. Conceptually, the raster is treated as a single continuous scan path where the sample immediately preceding `(x = 0, y)` is `(x = width - 1, y - 1)`. This preserves continuity of the causal history across line boundaries and avoids injecting an artificial zero-state transient at every line start.

### Shader Implementation with Kaiser FIR

The existing Gaussian horizontal convolution in `bandlimit_convolve_gaussian_x` (see `shaders/bandlimit.inc`) already provides the pattern the FIR replacement would follow: a loop over integer offsets from the center pixel, two symmetric texture reads per iteration, a weighted accumulation. The key differences for a fixed Kaiser FIR:

- Weights are constants. The Gaussian computes per-channel per-iteration weights from sigma; the Kaiser FIR uses a fixed coefficient array precomputed offline. In GLSL this is an array literal or a `const float` array.
- No per-channel variation. The Gaussian uses a different sigma per color channel (from `DISPLAY_BANDLIMIT_R/G/B`). A fixed FIR applies the same kernel to all channels. Separate per-channel FIRs are possible but require three independent coefficient sets.
- No weight normalization. The Gaussian normalizes by dividing by `wsum` because the Gaussian is not pre-normalized for arbitrary sigma. The Kaiser FIR is designed with unit DC gain (coefficients sum to 1.0), so accumulation without normalization is correct.
- Fixed loop count. The Gaussian exits early when weights fall below a threshold. The FIR loop runs exactly M = (N−1)/2 iterations unconditionally, which avoids divergent branching across a warp.

The coefficient array has (N−1)/2 + 1 entries: one center coefficient h[0] and M symmetric outer coefficients h[1] through h[M]. The convolution is:

```
output = h[0] * tex(x)
for k = 1 to M:
    output += h[k] * (tex(x + k*dx) + tex(x - k*dx))
```

where `dx = vec2(OutputSize.z, 0.0)` steps by one texel at the FIR's operating resolution.

The symmetric structure halves the number of distinct multiplications: an N-tap symmetric FIR requires only (N+1)/2 multiplications and N−1 additions (or N texture reads, which dominates).

The (N−1)/2 texel lookahead ahead of the current pixel is inherent to zero-phase FIR. It represents a fixed group delay of (N−1)/2 × T_s samples, which is a constant offset the pipeline can absorb. For N = 37 at 20.25 MHz: 18 samples × (1/20.25 MHz) ≈ 889 ns — about one sample per period, well within the normal range for inter-pass pipeline latency.

One pipeline ordering requirement: the shader must operate on a texture that is already at the FIR's target resolution. Upscaling to 1.5× or 2× width must happen in an earlier pass; this shader cannot simultaneously upscale and filter in one step (it would be sampling at the original 13.5 MHz rate while trying to apply a 20.25 MHz filter).

## Next-Step Options

If implementation work resumes later, the main branches are:

- Use the 3-biquad elliptic design as the magnitude reference and accept that it is not group-delay compliant.
- Approximate the target with a mixed architecture, such as a lower-order IIR plus a short FIR assist.
- Use a non-causal or forward-backward style method if phase behavior matters more than strict causal implementation.
- Implement a fixed Kaiser FIR at 1.5× or 2× output resolution (37 or 49 taps respectively), replacing the variable-sigma Gaussian loop in `bandlimit_convolve_gaussian_x`.