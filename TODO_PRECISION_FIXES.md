# IF Modulation/Demodulation Precision Issues TODO

## Completed (2025-11-26)
- ✅ **Issue #1: IF Carrier Phase Accumulation**
  - Fixed phase normalization before scaling in both shaders
  - Applied `fract()` to field phase before frequency ratio multiplication
  - Prevents precision loss from large phase values
  
- ✅ **Issue #5: Time Calculation Redundancy**
  - Pre-compute phase increment per pixel (`if_phase_inc_per_px`, `sc_phase_inc_per_px`)
  - Use direct phase increments in loops instead of recalculating time
  - Added phase normalization: `mod(phase + PI, 2.0 * PI) - PI`
  - Eliminates additive precision loss in filter taps
  - **Applied to:**
    - `if-mod.slang`: IF carrier and subcarrier phase increments
    - `if-demod.slang`: IF carrier phase increments (both Nyquist and I/Q modes)
    - `composite-demod.slang`: Subcarrier phase increments
    - `composite-mod-prefilter.slang`: Subcarrier phase increments (horizontal loop)
    - `svideo.slang`: Subcarrier phase increments
  - **Benefits:** Improved precision, reduced `compute_carrier_phase()` calls in loops, eliminated unused time variable calculations
  - **Performance impact:** ~240+ `compute_carrier_phase()` calls eliminated per frame across all shaders

## High Priority Issues

### Issue #4: Mixer Loss Compensation Mismatch
**Location:** `if-demod.slang` lines 244-245, 197; `if-mod.slang` line 283

**Problem:**
- Modulator outputs raw bandpass filter result (unnormalized, line 283 comment)
- Demodulator divides by `lp_wsum` then multiplies by 2× for mixer compensation
- Net gain depends on filter coefficient sums, which vary with sample rate
- Signal amplitude unstable across different resolutions

**Options to fix:**
1. Normalize modulator bandpass output by coefficient sum
2. Skip demodulator `lp_wsum` normalization, only apply 2× mixer compensation
3. Empirically measure and match gains

**Testing needed:** Color bars at multiple sample rates to verify amplitude consistency

---

### Issue #7: Nyquist VSB Filter Design Flaw
**Location:** `if-demod.slang` lines 109-161 (entire VSB mode branch)

**Problem:**
- Modulator uses **symmetric** bandpass filter (±2.725 MHz from 45.475 MHz center)
- Demodulator assumes **vestigial sideband** transmission (asymmetric)
- VSB "correction" filter inverts a filter that doesn't exist
- `correction_scale = 1.5` is undocumented tuning parameter

**Impact:** Image quality degradation when `IF_DEMOD_USE_NYQUIST = 1`

**Options to fix:**
1. Make modulator truly VSB (asymmetric bandpass) - requires filter redesign
2. Remove VSB correction from demodulator (use plain I/Q demod only)
3. Document that Nyquist mode is experimental/incorrect and disable by default

**Recommended:** Option 2 or 3 until proper VSB implementation is designed

---

## Medium Priority Issues

### Issue #3: Filter Coefficient Sum Handling (VSB mode)
**Location:** `if-demod.slang` line 161

**Problem:**
- Inverted bandpass coefficients may have different DC gain
- Sum `vsb_wsum` may approach zero or become negative
- Current code uses `max(abs(vsb_wsum), EPS)` which is partial fix

**Fix:** If keeping VSB mode, document that normalization is questionable for inverted bandpass filters

---

### Issue #8: Magic Numbers
**Locations:** Multiple

**Undocumented constants:**
- `correction_scale = 1.5` (if-demod.slang line 150): Empirical VSB tuning
- `KAISER_BETA = 2.5` (both shaders): Comment says "~25 dB stopband" but formula suggests β ≈ 1.8 for 25dB
  - Formula: `β ≈ 0.1102 * (A - 8.7)` where A is stopband attenuation in dB
  - For A = 25 dB: `β ≈ 0.1102 * 16.3 ≈ 1.8`
  - Current β = 2.5 corresponds to ~30.6 dB stopband

**Fix:** 
- Either correct comment to say "~31 dB stopband" 
- Or change `KAISER_BETA` to 1.8 for true 25 dB design
- Document `correction_scale` purpose or remove if VSB mode is removed

---

### Issue #9: Loop Bounds Documentation
**Location:** Both shaders, filter convolution loops

**Problem:**
- Hardcoded `for (int n = 1; n <= 30; ++n)` with `break` at `int(filter_taps)`
- Magic number 30 is undocumented

**Fix:** Add comment explaining worst-case tap count, or use const:
```glsl
const int MAX_FILTER_TAPS = 30;  // Maximum for highest sample rates
for (int n = 1; n <= MAX_FILTER_TAPS; ++n) {
```

---

## Low Priority / Info Only

### Issue #2: Denominator Safety Check
**Location:** Both shaders, phase calculation blocks

**Current:** `max(tb.sc_freq_hz, EPS)` where `EPS` from common.inc

**Note:** `1e-9` Hz is physically meaningless (subcarrier ~3.58MHz). Should use realistic minimum like 1MHz, but current implementation is safe, just unclear.

**Optional fix:** Use `max(tb.sc_freq_hz, 1.0e6)` with comment explaining it's safety guard

---

### Issue #6: Parameter Value Precision
**Source:** `shaders/menus/parameters/sys-timing.inc`

**Current:** `SC_FREQ` parameter limited to 6 decimal places (3.579545)

**True value:** NTSC FSC = 3.579545454545... MHz (315/88 MHz exactly)

**Impact:** 
- Frequency error: ~0.5 µHz (negligible for normal runtime)
- Phase drift over 1M frames (~4.6 hours): ~0.14° accumulated error

**Status:** Already handled correctly in `shaders/modulation.inc` line 18 with full precision constant when `SC_FREQ_MODE = 1` (NTSC standard)

**Action:** No fix needed, parameter is for manual override only

---

## Testing Recommendations

1. **Color bars test** at multiple resolutions (480p, 720p, 1080p, 4K)
   - Verify consistent amplitude across sample rates
   - Check for phase drift over extended runtime (30+ min)

2. **Sweep tone test** (if available)
   - Verify frequency response matches expected bandpass/lowpass characteristics
   - Check for asymmetry that would indicate VSB issues

3. **Long runtime test** (2-4 hours continuous)
   - Monitor for phase drift accumulation
   - Verify fixed phase calculation prevents precision loss

4. **Comparison test**
   - `IF_DEMOD_USE_NYQUIST = 0` (I/Q mode) vs `= 1` (VSB mode)
   - Document visible differences to validate Issue #7 assessment

---

## Notes
- GLSL lint errors are expected (linter doesn't understand multi-stage shader pragmas)
- All immediate precision fixes have been applied (phase accumulation, time calculation)
- Remaining issues require design decisions and empirical testing
