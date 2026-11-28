"""Calculate the reference-domain tap caps used by the packaged shaders."""

import ast
import math
import operator
import re
from pathlib import Path


PIXEL_CLOCK_HZ = 64.0e6
SYSTEM_DSP_HZ = 32.0e6
DISPLAY_DSP_HZ = 32.0e6

_OPERATORS = {ast.Add: operator.add, ast.Sub: operator.sub,
              ast.Mult: operator.mul, ast.Div: operator.truediv}


def _number_expression(text):
    def evaluate(node):
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            return float(node.value)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = evaluate(node.operand)
            return value if isinstance(node.op, ast.UAdd) else -value
        if isinstance(node, ast.BinOp) and type(node.op) in _OPERATORS:
            return _OPERATORS[type(node.op)](evaluate(node.left), evaluate(node.right))
        raise ValueError(f"Unsupported numeric expression: {text}")

    return evaluate(ast.parse(text.strip(), mode='eval').body)


def _constant(path, name):
    text = path.read_text(encoding='utf-8')
    matches = re.findall(r'^\s*const\s+float\s+' + re.escape(name) + r'\s*=\s*([^;]+);',
                         text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one {name} constant in {path}")
    return _number_expression(matches[0])


def _parameter(path, name):
    text = path.read_text(encoding='utf-8')
    pattern = (r'^\s*#pragma\s+parameter\s+' + re.escape(name) +
               r'\s+"[^"]*"\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)')
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one {name} parameter in {path}")
    default, minimum, maximum, step = map(float, matches[0])
    if not minimum <= default <= maximum or step <= 0:
        raise ValueError(f"Invalid {name} range in {path}")
    return minimum, maximum


def _sigma(cutoff_hz, attenuation_db):
    if cutoff_hz <= 0.0:
        raise ValueError("Filter cutoff must be positive")
    if attenuation_db <= 0.0:
        return 0.0
    return math.sqrt(0.1 * attenuation_db * math.log(10.0)) / (2.0 * math.pi * cutoff_hz)


def _gaussian_taps(sigma_seconds, sample_rate_hz, threshold):
    radius = sigma_seconds * sample_rate_hz * math.sqrt(-2.0 * math.log(threshold))
    return 2 * math.ceil(radius) + 1


def _butterworth_taps(cutoff_hz, attenuation_db, sample_rate_hz, threshold, eps,
                      *, guarded_sigma, clamp_cutoff, bypass_zero=True):
    if bypass_zero and attenuation_db <= 0.0:
        return 1
    if attenuation_db > 3.0:
        denominator = 2.0 * math.pi * _sigma(cutoff_hz, attenuation_db)
        if guarded_sigma:
            denominator = max(denominator, eps)
        cutoff_hz = math.sqrt(math.log(2.0)) / denominator
    normalized_cutoff = cutoff_hz / sample_rate_hz
    if clamp_cutoff:
        normalized_cutoff = min(max(normalized_cutoff, 0.0), 0.25)
    elif not 0.0 < normalized_cutoff < 0.5:
        raise ValueError("Butterworth cutoff must be below Nyquist at the reference rate")
    k = math.tan(math.pi * normalized_cutoff)
    alpha = max((1.0 - k) / (1.0 + k), eps)
    if alpha >= 1.0:
        raise ValueError("Butterworth impulse response does not decay")
    return max(1, math.ceil(math.log(threshold) / math.log(alpha)))


def _kaiser_taps(sample_rate_hz, transition_hz, attenuation_db):
    if transition_hz <= 0.0 or attenuation_db <= 8.0:
        raise ValueError("Kaiser design needs positive transition width and attenuation above 8 dB")
    delta_omega = 2.0 * math.pi * transition_hz / sample_rate_hz
    return math.ceil((attenuation_db - 8.0) / (2.285 * delta_omega)) | 1


def _iq_coefficients(threshold):
    # Use the common analog attenuation and a 1 MHz transition to size both
    # kernels. Blackman suppresses finite-length Hilbert ripple.
    taps = _kaiser_taps(SYSTEM_DSP_HZ, 1.0e6, max(40.0, -20.0 * math.log10(threshold)))
    radius = ((taps - 1) // 2) | 1
    h = {}
    for k in range(-radius, radius + 1, 2):
        x = math.pi * k / (radius + 1)
        h[k] = 2.0 / (math.pi * k) * (0.42 + 0.5 * math.cos(x) + 0.08 * math.cos(2.0 * x))

    # Interpolate the even phase with a Hamming-windowed halfband kernel.
    # The 1 MHz design transition provides margin for the 6 MHz passband.
    p = {}
    for k in range(-radius, radius + 1, 2):
        x = math.pi * k / (radius + 1)
        p[k] = 2.0 * math.sin(math.pi * k / 2.0) / (math.pi * k) * (0.54 + 0.46 * math.cos(x))
    gain = sum(p.values())
    p = {k: value / gain for k, value in p.items()}

    hh = {}
    for a, x in h.items():
        for b, y in h.items():
            hh[a + b] = hh.get(a + b, 0.0) + x * y
    c = dict(p)
    # Synthesis combines the inverse Hilbert phase with an even-phase
    # interpolation of the residual, preserving DC when the Hilbert gain
    # approaches zero.
    for a, x in p.items():
        for b, y in hh.items():
            c[a + b] = c.get(a + b, 0.0) + x * y
    return h, c


def _minimum_transition(menu, cutoff_name, stopband_name, enforced_minimum):
    cutoff_max = _parameter(menu, cutoff_name)[1]
    stopband_min = _parameter(menu, stopband_name)[0]
    return max(enforced_minimum, (stopband_min - cutoff_max) * 1.0e6)


def _gaussian_thresholds(path, thresholds):
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(encoding='utf-8'), flags=re.DOTALL)
    calls = re.findall(r'gaussian_decay_time\s*\(([^\n]*),\s*([^,\s()]+)\s*\)', text)
    for _, name in calls:
        if name not in thresholds:
            raise ValueError(f"Invalid truncation threshold {name} in {path}; use a common threshold")
    return [(sigma.strip(), thresholds[name]) for sigma, name in calls]


def _truncation_thresholds(path, thresholds):
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(encoding='utf-8'), flags=re.DOTALL)
    gaussian = _gaussian_thresholds(path, thresholds)
    butterworth = re.findall(r'log\s*\(\s*([^()\s]+)\s*\)\s*/\s*log\s*\(', text)
    if len(gaussian) != 1 or len(butterworth) != 1:
        raise ValueError(f"Cannot identify Gaussian and Butterworth truncation thresholds in {path}")
    if butterworth[0] not in thresholds:
        raise ValueError(f"Invalid truncation threshold {butterworth[0]} in {path}; use a common threshold")
    return gaussian[0][1], thresholds[butterworth[0]]


def calculate_filter_taps(root):
    shaders = Path(root) / 'shaders'
    menus = shaders / 'menus' / 'parameters'
    common = shaders / 'common.inc'
    thresholds = {name: _constant(common, name)
                  for name in ('FILTER_THRESHOLD_ANALOG', 'FILTER_THRESHOLD_DIGITAL')}
    eps = _constant(common, 'EPS')
    if any(not 0.0 < threshold < 1.0 for threshold in thresholds.values()) or eps <= 0.0:
        raise ValueError("Invalid filter threshold or EPS")
    rgb_gaussian_threshold, rgb_butterworth_threshold = _truncation_thresholds(
        shaders / 'sys-bandlimit.inc', thresholds)
    component_gaussian_threshold, component_butterworth_threshold = _truncation_thresholds(
        shaders / 'sys-component.slang', thresholds)
    yc_gaussian_threshold, yc_butterworth_threshold = _truncation_thresholds(
        shaders / 'sys-yc-filter.slang', thresholds)
    composite_calls = _gaussian_thresholds(shaders / 'display-composite.slang', thresholds)
    if len(composite_calls) != 1:
        raise ValueError("Expected one Gaussian truncation threshold in display-composite.slang")
    composite_threshold = composite_calls[0][1]

    rgb_menu = menus / 'sys-rgb.inc'
    decimation = _parameter(rgb_menu, 'SYS_FILTER_DECIMATION')[1]
    attenuation = _parameter(rgb_menu, 'SYS_FILTER_ATTEN')[1]
    compensation = _parameter(rgb_menu, 'COMPENSATE_SINC_ROLLOFF')[0]
    if decimation < 1.0 or compensation < 0.0:
        raise ValueError("Invalid system RGB filter parameter range")
    cutoff = 0.5 * PIXEL_CLOCK_HZ / decimation
    ratio = cutoff / PIXEL_CLOCK_HZ
    zoh_gain_db = 20.0 * math.log10(abs(math.sin(math.pi * ratio) / (math.pi * ratio)))
    attenuation += zoh_gain_db * compensation
    rgb_gaussian = _gaussian_taps(_sigma(cutoff, attenuation), PIXEL_CLOCK_HZ,
                                  rgb_gaussian_threshold)
    rgb_butterworth = _butterworth_taps(cutoff, attenuation, PIXEL_CLOCK_HZ,
                                        rgb_butterworth_threshold, eps,
                                        guarded_sigma=False, clamp_cutoff=False,
                                        bypass_zero=False)
    if _parameter(rgb_menu, 'SYS_FILTER_ATTEN')[0] + zoh_gain_db * compensation <= 3.0:
        rgb_butterworth = max(rgb_butterworth, _butterworth_taps(
            cutoff, 3.0, PIXEL_CLOCK_HZ, rgb_butterworth_threshold, eps,
            guarded_sigma=False, clamp_cutoff=False, bypass_zero=False))

    component_menu = menus / 'sys-component.inc'
    component_gaussian = []
    yc_gaussian = []
    component_butterworth = []
    yc_butterworth = []
    for channel in ('Y', 'C'):
        bandwidth_min, bandwidth_max = _parameter(component_menu, 'SYS_BANDWIDTH_' + channel)
        attenuation = _parameter(component_menu, 'SYS_CUTOFF_ATTEN_' + channel)[1]
        if bandwidth_min <= 0.0 or bandwidth_max * 1.0e6 >= SYSTEM_DSP_HZ * 0.5:
            raise ValueError(f"System {channel} bandwidth range must be positive and below Nyquist")
        cutoff = bandwidth_min * 1.0e6
        component_gaussian.append(_gaussian_taps(_sigma(cutoff, attenuation), SYSTEM_DSP_HZ,
                                                component_gaussian_threshold))
        yc_gaussian.append(_gaussian_taps(_sigma(cutoff, attenuation), SYSTEM_DSP_HZ,
                                          yc_gaussian_threshold))
        component_butterworth.append(_butterworth_taps(
            cutoff, attenuation, SYSTEM_DSP_HZ, component_butterworth_threshold, eps,
            guarded_sigma=True, clamp_cutoff=False))
        yc_butterworth.append(_butterworth_taps(
            cutoff, attenuation, SYSTEM_DSP_HZ, yc_butterworth_threshold, eps,
            guarded_sigma=True, clamp_cutoff=True))
        if _parameter(component_menu, 'SYS_CUTOFF_ATTEN_' + channel)[0] <= 3.0 and attenuation > 0.0:
            component_butterworth.append(_butterworth_taps(
                cutoff, min(attenuation, 3.0), SYSTEM_DSP_HZ, component_butterworth_threshold, eps,
                guarded_sigma=True, clamp_cutoff=False))
            yc_butterworth.append(_butterworth_taps(
                cutoff, min(attenuation, 3.0), SYSTEM_DSP_HZ, yc_butterworth_threshold, eps,
                guarded_sigma=True, clamp_cutoff=True))

    composite_menu = menus / 'display-composite.inc'
    bandwidth_min = _parameter(composite_menu, 'DISPLAY_BANDPASS_WIDTH')[0]
    attenuation_max = _parameter(composite_menu, 'DISPLAY_BANDPASS_ATTEN_DB')[1]
    if bandwidth_min <= 0.0:
        raise ValueError("Display bandpass width range must be positive")
    composite_gaussian = _gaussian_taps(
        _sigma(0.5e6 * bandwidth_min, attenuation_max),
        SYSTEM_DSP_HZ, composite_threshold)

    min_transition = _constant(shaders / 'window.inc', 'DISPLAY_MIN_TRANSITION_WIDTH_HZ')
    display_component = shaders / 'display-component-filter.inc'
    display_rgb = shaders / 'display-rgb-filter.inc'
    component_transition = min(
        _minimum_transition(menus / menu, 'DISPLAY_CUTOFF_' + channel,
                            'DISPLAY_STOPBAND_' + channel, min_transition)
        for menu in ('display-component.inc', 'display-svideo.inc')
        for channel in ('Y', 'C'))
    rgb_transition = _minimum_transition(menus / 'display-rgb-filter.inc',
                                         'DISPLAY_CUTOFF', 'DISPLAY_STOPBAND', min_transition)
    component_kaiser = _kaiser_taps(DISPLAY_DSP_HZ, component_transition,
                                    _constant(display_component, 'KAISER_ATTEN_DB'))
    rgb_kaiser = _kaiser_taps(DISPLAY_DSP_HZ, rgb_transition,
                              _constant(display_rgb, 'KAISER_ATTEN_DB'))
    sharpener = shaders / 'sharpen.slang'
    sharpener_calls = _gaussian_thresholds(sharpener, thresholds)
    sharpener_thresholds = dict(sharpener_calls)
    if len(sharpener_calls) != 2 or set(sharpener_thresholds) != {'emphasis_sigma', 'emphasis2_sigma'}:
        raise ValueError(f"Expected two Gaussian truncation thresholds in {sharpener}")
    sharpener_attenuation = _constant(sharpener, 'SHARPNESS_ATTEN_DB')
    primary = _gaussian_taps(
        _sigma(_constant(sharpener, 'SHARPNESS_PRIMARY_BANDWIDTH_HZ'), sharpener_attenuation),
        SYSTEM_DSP_HZ, sharpener_thresholds['emphasis_sigma'])
    secondary = _gaussian_taps(
        _sigma(_constant(sharpener, 'SHARPNESS_SECONDARY_BANDWIDTH_HZ'), sharpener_attenuation),
        SYSTEM_DSP_HZ, sharpener_thresholds['emphasis2_sigma'])
    iq_h, iq_c = _iq_coefficients(thresholds['FILTER_THRESHOLD_ANALOG'])

    return [
        ('sys-bandlimit.slang', 'SYS_BANDLIMIT_MAX_TAPS',
         {'Gaussian': rgb_gaussian, 'Butterworth': rgb_butterworth}),
        ('sys-component.slang', 'SYS_COMPONENT_MAX_TAPS',
         {'Gaussian': max(component_gaussian), 'Butterworth': max(component_butterworth)}),
        ('sys-yc-filter.slang', 'SYS_YC_FILTER_MAX_TAPS',
         {'Gaussian': max(yc_gaussian), 'Butterworth': max(yc_butterworth)}),
        ('display-composite.slang', 'DISPLAY_COMPOSITE_MAX_TAPS',
         {'Gaussian': composite_gaussian}),
        ('display-component-filter.inc', 'DISPLAY_COMPONENT_FILTER_MAX_TAPS',
         {'Kaiser': component_kaiser}),
        ('display-rgb-filter.slang', 'DISPLAY_RGB_FILTER_MAX_TAPS',
         {'Kaiser': rgb_kaiser}),
        ('sharpen.slang', 'SHARPEN_MAX_TAPS',
         {'primary Gaussian': primary, 'secondary Gaussian': secondary}),
        ('cv-iq.slang', 'CV_IQ_MAX_TAPS', {'Hilbert polyphase': len(iq_h)}),
        ('iq-cv.slang', 'IQ_CV_MAX_TAPS', {'synthesis I polyphase': len(iq_c)}),
    ]


def generate_filter_taps(root, output_dir=None):
    results = calculate_filter_taps(root)
    lines = ['// Generated by scripts/generate_filter_taps.py; do not edit.',
             '// Caps are based on the documented reference-domain sample rates.']
    print("Reference filter tap caps:", flush=True)
    for shader, symbol, designs in results:
        cap = max(designs.values())
        detail = ', '.join(f'{name} {count}' for name, count in designs.items())
        if shader == 'display-component-filter.inc':
            detail += '; display-component.slang and display-svideo-filter.slang'
        print(f"  {shader}: {cap} ({detail})", flush=True)
        lines.append(f'const int {symbol} = {cap};')
    threshold = _constant(Path(root) / 'shaders' / 'common.inc', 'FILTER_THRESHOLD_ANALOG')
    iq_h, iq_c = _iq_coefficients(threshold)
    for name, coeffs in (('CV_IQ_H', iq_h), ('IQ_CV_I', iq_c)):
        values = ', '.join(f'{coeffs[k]:.12e}' for k in sorted(coeffs))
        lines.append(f'const float {name}[{len(coeffs)}] = float[]({values});')
    output_dir = Path(output_dir) if output_dir is not None else Path(root) / 'out' / 'shaders'
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / 'filter-taps.inc'
    content = '\n'.join(lines) + '\n'
    if not output.exists() or output.read_text(encoding='utf-8') != content:
        output.write_text(content, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    generate_filter_taps(Path(__file__).resolve().parent.parent)
