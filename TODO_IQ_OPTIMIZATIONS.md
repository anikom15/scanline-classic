# IQ Modulation/Demodulation Shader Optimization TODO

## Context
The IQ baseband VSB modulation/demodulation shaders (`iq-mod.slang` and `iq-demod.slang`) implement complex baseband representation of NTSC VSB (Vestigial Sideband) modulation. They use Blackman-Harris 4-term windowed-sinc filters for ~92 dB stopband rejection.

**Current architecture:**
- `iq-mod.slang`: Takes component RGB input → outputs complex IQ (R16G16_SFLOAT)
  - I channel: VSB-shaped composite via asymmetric bandpass filter
  - Q channel: Hilbert transform of composite, scaled by K_VSB for asymmetry
  - Optional RF noise dithering (-30 dB below signal)
- `iq-demod.slang`: Takes complex IQ → outputs recovered composite (R16_SFLOAT)
  - Matched lowpass filtering on both I and Q channels
  - Three demod modes: I-only, envelope detection, or linear (default)
- `window.inc`: Shared windowing functions (Blackman-Harris 4-term)
  - `blackman_harris_4term()`: 4-cosine window function
  - `sinc_lowpass_bh4()`: Lowpass windowed-sinc
  - `sinc_bandpass_bh4()`: Bandpass windowed-sinc

**Filter parameters:**
- Tap range: 20-48 taps (adaptive based on OutputSize.x ∈ [720, 1440])
- Blackman-Harris 4-term window: ~92 dB stopband, 8π/N mainlobe width
- VSB bandwidth: 4.95 MHz (0.75 MHz vestige + 4.2 MHz full sideband)

## Optimization Opportunities

### High Priority (Low Complexity, Good Payoff)

#### 1. iq-mod.slang: Hoist composite calculation (~25% loop reduction)
**Problem:** `compute_composite_baseband()` is called twice per tap iteration—once for I channel bandpass coefficient application, and again for Q channel Hilbert transform. This duplicates phase calculation, trig operations, and chroma mixing.

**Current code (lines ~252-285):**
```glsl
for (int n = 1; n <= 48; ++n) {
    // Right sample
    vec3 pixel_r = texture(Source, tex_r).rgb;
    float t_r = t0 + nf * tb.pixel_time_px;
    float composite_r = compute_composite_baseband(pixel_r, t_r, pal_phase_base);  // FIRST CALL
    
    float coeff_r_bp = sinc_bandpass_bh4(...);
    
    // Hilbert coefficient
    float hilbert_r = ...;
    
    // Left sample
    float composite_l = compute_composite_baseband(pixel_l, t_l, pal_phase_base);  // SECOND CALL
    
    i_signal += coeff_r_bp * composite_r + coeff_l_bp * composite_l;
    q_signal += hilbert_r * composite_r + hilbert_l * composite_l;  // REUSES composite_r
}
```

**Solution:** Compute composite once per tap, store, reuse for both channels.

**Expected gain:** ~25% reduction in loop body cost (eliminates duplicate phase calculations).

---

#### 2. iq-mod.slang: Simplify Hilbert FIR calculation (~10% speedup)
**Problem:** Current implementation computes `sin²(πn/2) / n` using two sin calls per tap:
```glsl
float sin_val = sin(PI * nf * 0.5);
hilbert_r = (2.0 / PI) * (sin_val * sin_val) / nf;
```

**Mathematical insight:** For odd n, `sin²(πn/2) = 1`, so Hilbert coefficients simplify to:
- h[n] = 2/(π·n) for odd n
- h[n] = 0 for even n (already handled by `if (ni % 2 == 1)`)

**Current location:** Lines ~266-269 in fragment shader

**Solution:** Replace with direct form:
```glsl
if (ni % 2 == 1) {
    hilbert_r = 2.0 / (PI * nf);  // Simplified from sin² form
}
```

**Expected gain:** ~10% speedup (removes sin + multiply per tap).

---

#### 3. iq-mod.slang: Cheaper noise dithering (~30% noise overhead reduction)
**Problem:** Current Box-Muller approximation uses:
- 2 hash function calls (dot product + sin + fract)
- 1 exp() call for dB→linear conversion
- Gaussian approximation via (hash - 0.5) scaling

**Current code (lines ~292-303):**
```glsl
float noise_amplitude = exp(-IQ_RF_NOISE_DB * 0.1151292546);
float hash_i = fract(sin(dot(seed, vec2(12.9898, 78.233))) * 43758.5453);
float hash_q = fract(sin(dot(seed + vec2(0.314, 0.271), vec2(12.9898, 78.233))) * 43758.5453);
float noise_i = (hash_i - 0.5) * noise_amplitude;
float noise_q = (hash_q - 0.5) * noise_amplitude;
```

**Solution:** Use triangular dither (2-hash sum approximates Gaussian):
```glsl
float noise_amplitude = exp(-IQ_RF_NOISE_DB * 0.1151292546);
float hash1 = fract(sin(dot(seed, vec2(12.9898, 78.233))) * 43758.5453);
float hash2 = fract(sin(dot(seed, vec2(24.7896, 51.132))) * 43758.5453);
float noise_i = (hash1 + hash2 - 1.0) * noise_amplitude * 0.866;  // √(2/3) scaling
// Similar for noise_q
```

**Expected gain:** ~30% reduction in noise generation overhead (removes one hash + simplifies distribution).

---

### Medium Priority (Moderate Complexity, Excellent Payoff)

#### 4. iq-demod.slang: Remove wsum accumulation (~5% speedup)
**Problem:** Currently accumulates window sum for normalization:
```glsl
float wsum = 0.0;
// ... in loop:
wsum += cr + cl;
// ... after loop:
float I = i_acc / max(wsum, EPS);
```

**Mathematical insight:** Blackman-Harris 4-term window sum is analytically known:
- For symmetric window of length N: sum ≈ N × a0 = N × 0.35875
- Exact for large N, <1% error for N≥20

**Solution:** Replace dynamic accumulation with analytical normalization:
```glsl
// After loop:
float norm_factor = 1.0 / (filter_taps * 0.35875);
float I = i_acc * norm_factor;
float Q = q_acc * norm_factor;
```

**Expected gain:** ~5% speedup (removes 2 adds per tap + division).

---

#### 5. Both shaders: Precompute window coefficients (vertex shader)
**Problem:** `blackman_harris_4term()` computes 4 cosines per tap, per pixel. For symmetric FIR, weights are identical for ±n taps—only sinc polarity differs.

**Current cost per tap:**
- 1 call to `blackman_harris_4term()`: 4× cos() + 3× multiply + 3× add/subtract
- Called twice per tap iteration (left + right)
- Total: ~8 cos() calls per tap pair

**Solution approach:**
1. **Vertex shader:** Precompute N/2 window weights for taps [0, N/2]
2. **Pass via varying array** (if supported) or encode into texture
3. **Fragment shader:** Look up weights instead of computing

**Complexity:** Requires extending vertex→fragment interface. May hit varying limits on some GPUs.

**Expected gain:** ~40% per-tap cost reduction (eliminates all cos() calls from fragment shader).

**Alternate approach:** Compute once at tap=0, store in local array, index in loop.

---

### Low Priority (Minor Gains)

#### 6. iq-demod.slang: Optimize texture fetches
**Current:** `vec2 iq_r = texture(Source, Tex_r).rg;` fetches both channels, good.

**Observation:** Already optimal for modern GPUs. No change needed.

---

#### 7. Both shaders: Loop unrolling hints
**Current:** Fixed MAX_TAPS=48 with dynamic break condition.

**Option:** Add `#pragma unroll` hints for common tap counts (20, 32, 48) if compiler doesn't auto-unroll.

**Expected gain:** Minimal (modern compilers already handle this well).

---

## Implementation Priority

**Phase 1 (Quick wins):**
1. Item #1: Hoist composite calculation in iq-mod.slang
2. Item #2: Simplify Hilbert FIR
3. Item #3: Cheaper noise dithering

**Phase 2 (Moderate effort):**
4. Item #4: Remove wsum in iq-demod.slang
5. Item #5: Precompute window coefficients (requires design decision on vertex/fragment interface)

**Phase 3 (Optional):**
- Benchmark Phase 1+2 improvements
- Decide if Phase 3 (item #5) complexity is justified by remaining performance needs

---

## Testing Requirements

After each optimization:
1. **Correctness:** Compare output with reference (pre-optimization) using image diff
2. **Unity gain:** Verify brightness preserved (input composite == output composite in bypass mode)
3. **VSB asymmetry:** Confirm K_VSB scaling still produces correct vestigial sideband shape
4. **Noise distribution:** If modifying dither, verify -30 dB noise floor via histogram
5. **Performance:** Measure frame time on target GPU (ideally 720p, 1024p, 1440p test cases)

---

## Notes for Future Implementation

- Both shaders already use `sinc_bandpass_bh4()` and `sinc_lowpass_bh4()` from `window.inc`
- Kaiser window support was removed (commit prior to this TODO)
- IF modulation shaders (`if-mod.slang`, `if-demod.slang`) use different approach (RF carrier + bandpass sampling) and were deemed impractical due to aliasing complexity
- Current IQ method is baseband-only, no aliasing concerns, numerically stable
- Target resolution range: 720-1440px (OutputSize.x)
- Sample rates: 11.3 MHz (720px) to 22.6 MHz (1440px) at 15.7 kHz NTSC line rate
