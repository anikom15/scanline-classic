import contextlib
import io
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import build
from scripts.generate_filter_taps import (
    _butterworth_taps,
    _gaussian_taps,
    _kaiser_taps,
    _sigma,
    calculate_filter_taps,
    generate_filter_taps,
)


class FilterTapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / 'shaders', self.root / 'shaders')

    def results(self):
        return {name: designs for name, _, designs in calculate_filter_taps(self.root)}

    def test_reference_designs(self):
        sigma = _sigma(0.6e6, 30.0)
        self.assertEqual(_gaussian_taps(sigma, 32.0e6, 0.01), 137)
        self.assertEqual(_butterworth_taps(
            0.6e6, 30.0, 32.0e6, 0.01, 1.19209289551e-7,
            guarded_sigma=True, clamp_cutoff=False), 124)
        self.assertEqual(_kaiser_taps(32.0e6, 0.5e6, 40.0), 143)

    def test_generated_include_is_current(self):
        with contextlib.redirect_stdout(io.StringIO()):
            generate_filter_taps(self.root)
        generated = (self.root / 'shaders' / 'filter-taps.inc').read_text(encoding='utf-8')
        self.assertEqual(generated, (ROOT / 'shaders' / 'filter-taps.inc').read_text(encoding='utf-8'))

    def test_sys_yc_filter_supports_svideo_output_mode(self):
        shader = (ROOT / 'shaders' / 'sys-yc-filter.slang').read_text(encoding='utf-8')
        self.assertIn('#include "menus/parameters/sys-encode.inc"', shader)
        self.assertRegex(shader, r'float\s+SVIDEO\s*;')
        self.assertIn('vec2 cv = vec2(yc.r + yc.g, 0.0);', shader)
        self.assertIn('yc = mix(cv, yc, SVIDEO);', shader)

    def test_sys_yc_filter_supports_notch_trap(self):
        shader = (ROOT / 'shaders' / 'sys-yc-filter.slang').read_text(encoding='utf-8')
        menu = (ROOT / 'shaders' / 'menus' / 'parameters' / 'sys-yc-filter.inc').read_text(encoding='utf-8')
        self.assertIn('#pragma parameter SYS_YC_TRAP', menu)
        self.assertRegex(shader, r'float\s+SYS_YC_TRAP\s*;')
        self.assertIn('config.SYS_YC_TRAP > 0.5', shader)
        self.assertIn('yc.x -= luma_band;', shader)
        self.assertIn('luma_band_accum += h.y * carrier * y;', shader)
        self.assertIn('luma_band_weight += h.y;', shader)
        self.assertIn('2.0 * luma_band_accum / luma_band_weight', shader)
        self.assertIn('config.SYS_CUTOFF_ATTEN_C > 0.0', shader)
        self.assertIn('accum.y += h.y * cos(ChromaFrequency * t) * chroma;', shader)
        self.assertIn('FilterGain = vec2(max(gain.x, EPS), max(length(carrier_response) * 0.5, EPS));', shader)
        self.assertIn('flat out float ChromaDelay;', shader)
        self.assertIn('chroma = mix(c0, c1, fract(chroma_index));', shader)

    def test_threshold_and_transition_width_change_caps(self):
        original = self.results()
        common = self.root / 'shaders' / 'common.inc'
        text = common.read_text(encoding='utf-8')
        text, count = re.subn(r'(FILTER_THRESHOLD_ANALOG\s*=\s*)[^;]+;',
                              r'\g<1>0.000001;', text)
        self.assertEqual(count, 1)
        common.write_text(text, encoding='utf-8')
        changed = self.results()
        self.assertGreater(changed['sys-component.slang']['Gaussian'],
                           original['sys-component.slang']['Gaussian'])
        self.assertGreater(changed['sys-bandlimit.slang']['Butterworth'],
                           original['sys-bandlimit.slang']['Butterworth'])
        window = self.root / 'shaders' / 'window.inc'
        text = window.read_text(encoding='utf-8')
        text, count = re.subn(r'(DISPLAY_MIN_TRANSITION_WIDTH_HZ\s*=\s*)[^;]+;',
                              r'\g<1>10.0e6;', text)
        self.assertEqual(count, 1)
        window.write_text(text, encoding='utf-8')
        self.assertLess(self.results()['display-rgb-filter.slang']['Kaiser'],
                        original['display-rgb-filter.slang']['Kaiser'])

    def test_ui_range_changes_system_cap(self):
        menu = self.root / 'shaders' / 'menus' / 'parameters' / 'sys-rgb.inc'
        text = menu.read_text(encoding='utf-8')
        pattern = r'(#pragma parameter SYS_FILTER_DECIMATION\s+"[^"]+"\s+)[^\n]+'
        text, count = re.subn(pattern, r'\g<1>1.0 1.0 16.0 0.1', text)
        self.assertEqual(count, 1)
        menu.write_text(text, encoding='utf-8')
        wider = self.results()['sys-bandlimit.slang']['Gaussian']
        menu.write_text(text.replace('1.0 1.0 16.0 0.1', '1.0 1.0 8.0 0.1'),
                        encoding='utf-8')
        self.assertLess(self.results()['sys-bandlimit.slang']['Gaussian'], wider)

    def test_shader_threshold_selection_and_invalid_threshold(self):
        shader = self.root / 'shaders' / 'sys-yc-filter.slang'
        original = self.results()['sys-yc-filter.slang']
        text = shader.read_text(encoding='utf-8')
        shader.write_text(text.replace('FILTER_THRESHOLD_ANALOG', 'FILTER_THRESHOLD_DIGITAL'),
                          encoding='utf-8')
        changed = self.results()['sys-yc-filter.slang']
        self.assertGreater(changed['Gaussian'], original['Gaussian'])
        self.assertGreater(changed['Butterworth'], original['Butterworth'])
        shader.write_text(text.replace('FILTER_THRESHOLD_ANALOG', '0.001'), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Invalid truncation threshold'):
            self.results()

    def test_sharpener_caps_follow_each_design_and_threshold(self):
        shader = self.root / 'shaders' / 'sharpen.slang'
        original = self.results()['sharpen.slang']
        self.assertEqual(original, {'primary Gaussian': 33, 'secondary Gaussian': 49})
        text = shader.read_text(encoding='utf-8')
        shader.write_text(text.replace(
            'SHARPNESS_PRIMARY_BANDWIDTH_HZ = 3.0e6',
            'SHARPNESS_PRIMARY_BANDWIDTH_HZ = 1.5e6'), encoding='utf-8')
        changed = self.results()['sharpen.slang']
        self.assertGreater(changed['primary Gaussian'], original['primary Gaussian'])
        self.assertEqual(changed['secondary Gaussian'], original['secondary Gaussian'])
        switched = text.replace(
            'gaussian_decay_time(emphasis2_sigma, FILTER_THRESHOLD_ANALOG)',
            'gaussian_decay_time(emphasis2_sigma, FILTER_THRESHOLD_DIGITAL)')
        shader.write_text(switched, encoding='utf-8')
        changed = self.results()['sharpen.slang']
        self.assertEqual(changed['primary Gaussian'], original['primary Gaussian'])
        self.assertGreater(changed['secondary Gaussian'], original['secondary Gaussian'])
        first = 'gaussian_decay_time(emphasis_sigma, FILTER_THRESHOLD_ANALOG)'
        second = 'gaussian_decay_time(emphasis2_sigma, FILTER_THRESHOLD_DIGITAL)'
        swapped = switched.replace(first, 'TEMPORARY_CALL').replace(second, first)
        shader.write_text(swapped.replace('TEMPORARY_CALL', second), encoding='utf-8')
        self.assertEqual(self.results()['sharpen.slang'], changed)
        shader.write_text(text.replace(
            'gaussian_decay_time(emphasis2_sigma, FILTER_THRESHOLD_ANALOG)',
            'gaussian_decay_time(emphasis2_sigma, 0.001)'), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Invalid truncation threshold'):
            self.results()

    def test_sharpener_cap_uses_working_not_display_reference(self):
        baseline = self.results()['sharpen.slang']
        with patch('scripts.generate_filter_taps.DISPLAY_DSP_HZ', 16.0e6):
            self.assertEqual(self.results()['sharpen.slang'], baseline)
        with patch('scripts.generate_filter_taps.SYSTEM_DSP_HZ', 16.0e6):
            changed = self.results()['sharpen.slang']
        self.assertLess(changed['primary Gaussian'], baseline['primary Gaussian'])
        self.assertLess(changed['secondary Gaussian'], baseline['secondary Gaussian'])

    def test_composite_cap_tracks_width_and_working_rate(self):
        baseline = self.results()['display-composite.slang']['Gaussian']
        self.assertEqual(baseline, _gaussian_taps(_sigma(0.15e6, 20.0), 32.0e6, 0.01))
        menu = self.root / 'shaders' / 'menus' / 'parameters' / 'display-composite.inc'
        text = menu.read_text(encoding='utf-8')
        menu.write_text(text.replace('1.3 0.3 3.0 0.01', '1.3 0.2 3.0 0.01'),
                        encoding='utf-8')
        self.assertGreater(self.results()['display-composite.slang']['Gaussian'], baseline)
        menu.write_text(text, encoding='utf-8')
        with patch('scripts.generate_filter_taps.SYSTEM_DSP_HZ', 16.0e6):
            self.assertLess(self.results()['display-composite.slang']['Gaussian'], baseline)

    def test_rejects_unstable_system_bandwidth_range(self):
        menu = self.root / 'shaders' / 'menus' / 'parameters' / 'sys-component.inc'
        text = menu.read_text(encoding='utf-8')
        text, count = re.subn(
            r'(#pragma parameter SYS_BANDWIDTH_Y\s+"[^"]+"\s+)[^\n]+',
            r'\g<1>5.4 3.0 32.0 0.1', text)
        self.assertEqual(count, 1)
        menu.write_text(text, encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'below Nyquist'):
            self.results()

    def test_build_generates_before_copy_and_reports_caps(self):
        output = self.root / 'out'
        log = io.StringIO()
        with patch.object(build, 'ROOT', str(self.root)), \
                patch.object(build, 'OUT', str(output)), \
                patch.object(build, 'PRESETS_OUT', str(output / 'presets')), \
                patch.object(build, 'top_dirs', ['shaders']), \
                patch.object(build, 'top_files', []), \
                patch.object(build, 'run_presetgen'), \
                patch.object(build, 'normalize_flat_preset_paths'), \
                patch.object(sys, 'argv', ['build.py']), \
                contextlib.redirect_stdout(log):
            build.main()
        source = self.root / 'shaders' / 'filter-taps.inc'
        self.assertEqual(source.read_text(encoding='utf-8'),
                         (output / 'shaders' / 'filter-taps.inc').read_text(encoding='utf-8'))
        for shader, designs in self.results().items():
            self.assertIn(f'{shader}: {max(designs.values())}', log.getvalue())
        self.assertIn('display-component.slang and display-svideo-filter.slang', log.getvalue())
        self.assertIn('sharpen.slang: 49 (primary Gaussian 33, secondary Gaussian 49)',
                      log.getvalue())


if __name__ == '__main__':
    unittest.main()
