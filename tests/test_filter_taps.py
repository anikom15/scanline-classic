import contextlib
import cmath
import io
import math
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import build
from test_dyadic_pyramid import shader_function
from scripts.generate_filter_taps import (
    _butterworth_taps,
    _gaussian_taps,
    _kaiser_taps,
    _iq_coefficients,
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

    def test_sd_display_filter_rejects_output_nyquist(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        window = (ROOT / 'shaders' / 'window.inc').read_text(encoding='utf-8')
        shader = (ROOT / 'shaders' / 'display-rgb-filter.inc').read_text(encoding='utf-8')
        self.assertIn('kfilt.fc_norm = cutoff / WorkingSampleRate;', shader)
        self.assertIn('cutoff, stopband, WorkingSampleRate, KAISER_ATTEN_DB', shader)
        functions = '\n'.join(shader_function(window, signature) for signature in (
            'float sinc(', 'float kaiser_i0(', 'float kaiser(', 'float kaiser_beta_from_atten(',
            'float display_transition_width_hz(', 'float display_kaiser_taps(', 'float kaiser_sinc_gain(',
        ))
        functions = re.sub(r'(?<![\w.])(\d+\.\d+(?:[eE][+-]?\d+)?)\b', r'\1f', functions)
        source = self.root / 'response.cpp'
        executable = self.root / 'response'
        source.write_text(r'''
#include <algorithm>
#include <cmath>
#include <stdexcept>
using std::abs; using std::ceil; using std::cos; using std::exp;
using std::max; using std::min; using std::pow; using std::sin; using std::sqrt;
const float PI = 3.14159265358979323846f;
const float EPS = 1.19209289551e-7f;
const float DISPLAY_MIN_TRANSITION_WIDTH_HZ = 0.5e6f;
''' + functions + r'''
int main() {
    float fs = 32.0e6f, cutoff = 6.5e6f, stop = 8.0e6f;
    float beta = kaiser_beta_from_atten(40), norm = cutoff / fs;
    int taps = int(display_kaiser_taps(cutoff, stop, fs, 40, 143));
    int center = (taps - 1) / 2;
    double response = 0;
    for (int n = -center; n <= center; ++n)
        response += sinc(float(n), norm) * kaiser(float(n), float(taps), beta)
                    * std::cos(2 * double(PI) * 8.0e6 / fs * n);
    response /= kaiser_sinc_gain(norm, float(taps), beta);
    if (20 * std::log10(std::abs(response)) > -40)
        throw std::runtime_error("insufficient output-Nyquist attenuation");
}
''', encoding='utf-8')
        subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)

    def test_generated_include_is_written_to_output(self):
        with contextlib.redirect_stdout(io.StringIO()):
            generate_filter_taps(self.root)
        generated = (self.root / 'out' / 'shaders' / 'filter-taps.inc').read_text(encoding='utf-8')
        for _, symbol, designs in calculate_filter_taps(self.root):
            self.assertIn(f'const int {symbol} = {max(designs.values())};', generated)
        self.assertFalse((self.root / 'shaders' / 'filter-taps.inc').exists())

    def test_iq_round_trip_response_and_quadrature(self):
        h, c = _iq_coefficients(0.01)
        for khz in range(0, 6001, 10):
            omega = math.pi * khz / 16000
            hilbert = sum(v * cmath.exp(-1j * omega * k) for k, v in h.items())
            residual = sum(v * cmath.exp(-1j * omega * k) for k, v in c.items())
            # At odd samples the two polyphase branches reconstruct C - H^2.
            self.assertLess(abs(residual - hilbert * hilbert - 1), 0.01, khz)
        omega = math.pi * 4 / 16
        hilbert = sum(v * cmath.exp(-1j * omega * k) for k, v in h.items())
        self.assertLess(abs(hilbert + 1j), 0.01)
        self.assertAlmostEqual(sum(h.values()), 0.0, places=12)

    def test_iq_generated_coefficients_and_packing(self):
        with contextlib.redirect_stdout(io.StringIO()):
            generate_filter_taps(self.root)
        include = (self.root / 'out' / 'shaders' / 'filter-taps.inc').read_text(encoding='utf-8')
        h, c = _iq_coefficients(0.01)
        for name, coeffs in (('CV_IQ_H', h), ('IQ_CV_I', c)):
            match = re.search(rf'const float {name}\[(\d+)\] = float\[\]\(([^;]+)\);', include)
            self.assertIsNotNone(match)
            values = [float(value) for value in match.group(2).split(',')]
            self.assertEqual(int(match.group(1)), len(coeffs))
            for value, offset in zip(values, sorted(coeffs)):
                self.assertAlmostEqual(value, coeffs[offset], places=11)
        shader = (ROOT / 'shaders' / 'cv-iq-vertex.inc').read_text(encoding='utf-8')
        self.assertIn('IQLength = ceil(CVLength * (DSP_SD_IQ_WORKING_FS / DSP_SD_WORKING_FS));', shader)
        self.assertIn('IQWidth = contract_pixel_packed_width(IQLength);', shader)

    def test_iq_shader_round_trip_on_packed_stream(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        h, c = _iq_coefficients(0.01)
        arrays = '\n'.join(
            f'const int {count} = {len(coeffs)}; const float {name}[] = {{'
            + ','.join(f'{coeffs[k]:.12e}f' for k in sorted(coeffs)) + '};'
            for count, name, coeffs in (
                ('CV_IQ_MAX_TAPS', 'CV_IQ_H', h), ('IQ_CV_MAX_TAPS', 'IQ_CV_I', c)))
        analysis = shader_function((ROOT / 'shaders' / 'cv-iq.slang').read_text(encoding='utf-8'),
                                   'void main(').replace('void main(', 'void analyse(')
        synthesis = shader_function((ROOT / 'shaders' / 'iq-cv.slang').read_text(encoding='utf-8'),
                                    'void main(').replace('void main(', 'void synthesise(')
        harness = r'''
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>
using std::floor;
struct vec2 {
    float x,y;
    vec2(float x, float y): x(x), y(y) {}
};
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
vec2 floor(vec2 a) { return {floor(a.x),floor(a.y)}; }
struct vec4 {
    float r,g,b,a;
    vec4(): r(0),g(0),b(0),a(0) {}
    vec4(float v): r(v),g(v),b(v),a(v) {}
    vec4(float r,float g,float b,float a): r(r),g(g),b(b),a(a) {}
};
struct Size { vec2 xy{64,64}; };
struct Config { Size OutputSize,SourceSize; } config;
vec2 vTexCoord(0,0);
float CVLength=2001,IQLength=1001,CVWidth=64,IQWidth=32,TextureFits=1;
vec4 FragColor;
int Source;
std::vector<vec4> input;
int source_width=64;
float mod(float a,float b) { return a-b*floor(a/b); }
vec4 fetch_input_sample(int,vec2,float index,float width,float limit) {
    if (int(width)!=source_width) throw std::runtime_error("incorrect packed stride");
    return input[std::clamp(int(floor(index)),0,int(limit))];
}
'''
        checks = r'''
int main() {
    const double pi=3.14159265358979323846;
    for (double mhz : {0.0,0.1,2.0,4.0,6.0}) {
        std::vector<vec4> original(2001), iq(1001);
        for (int n=0;n<2001;++n)
            original[n]=vec4(float(std::cos(2*pi*mhz*n/32+0.37)),0,0,1);
        input=original;
        source_width=64;
        for (int n=0;n<1001;++n) {
            vTexCoord=vec2((n%32+0.5f)/64,(n/32+0.5f)/64);
            analyse();
            iq[n]=FragColor;
        }
        input=iq;
        source_width=32;
        for (int n=200;n<1800;++n) {
            vTexCoord=vec2((n%64+0.5f)/64,(n/64+0.5f)/64);
            synthesise();
            if (std::abs(FragColor.r-original[n].r)>0.01)
                throw std::runtime_error("IQ round trip exceeds 1% error");
        }
        if (mhz==4.0) {
            int n=501;
            vTexCoord=vec2((n%64+0.5f)/64,(n/64+0.5f)/64);
            synthesise();
            float with_q=FragColor.r;
            for (auto& sample: input) sample.g=0;
            synthesise();
            if (std::abs(with_q-FragColor.r)<0.1)
                throw std::runtime_error("quadrature channel does not contribute");
        }
        if (mhz==0.0) {
            for (int n : {0,1,1999,2000}) {
                vTexCoord=vec2((n%64+0.5f)/64,(n/64+0.5f)/64);
                synthesise();
                if (std::abs(FragColor.r-original[n].r)>0.01)
                    throw std::runtime_error("DC field edge reconstruction failed");
            }
            vTexCoord=vec2((2001%64+0.5f)/64,(2001/64+0.5f)/64);
            synthesise();
            if (FragColor.r!=0) throw std::runtime_error("padding is not cleared");
            TextureFits=0;
            synthesise();
            if (FragColor.r!=1) throw std::runtime_error("undersized texture not flagged");
            TextureFits=1;
        }
    }
}
'''
        source = self.root / 'iq-round-trip.cpp'
        executable = self.root / 'iq-round-trip'
        source.write_text(harness + arrays + analysis + synthesis + checks, encoding='utf-8')
        subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)

    def test_sys_yc_filter_supports_svideo_output_mode(self):
        shader = (ROOT / 'shaders' / 'sys-yc-filter.slang').read_text(encoding='utf-8')
        self.assertIn('#include "menus/parameters/sys-encode.inc"', shader)
        self.assertRegex(shader, r'float\s+SVIDEO\s*;')
        self.assertIn('vec2 cv = vec2(yc.r + yc.g, 0.0);', shader)
        self.assertIn('yc = mix(cv, yc, SVIDEO);', shader)

    def test_display_composite_uses_carrier_amplitude_scale(self):
        shader = (ROOT / 'shaders' / 'display-composite.slang').read_text(encoding='utf-8')
        self.assertIn('composite - notch_component', shader)
        self.assertIn('gaussian_dc_orthogonal_notch(', shader)
        self.assertIn('#include "bandpass.inc"', shader)

    def test_sys_yc_filter_supports_notch_trap(self):
        shader = (ROOT / 'shaders' / 'sys-yc-filter.slang').read_text(encoding='utf-8')
        menu = (ROOT / 'shaders' / 'menus' / 'parameters' / 'sys-yc-filter.inc').read_text(encoding='utf-8')
        self.assertIn('#pragma parameter SYS_YC_TRAP', menu)
        self.assertRegex(shader, r'float\s+SYS_YC_TRAP\s*;')
        self.assertIn('config.SYS_YC_TRAP > 0.5', shader)
        self.assertIn('yc.x -= luma_band;', shader)
        self.assertIn('luma_band_accum += h.y * carrier * y;', shader)
        self.assertIn('luma_band_gain += h.y * carrier * carrier;', shader)
        self.assertIn('gaussian_dc_orthogonal_notch(', shader)
        self.assertIn('#include "bandpass.inc"', shader)
        self.assertIn('config.SYS_CUTOFF_ATTEN_C > 0.0', shader)
        self.assertIn('gaussian_carrier_kernel(t, FilterParam.y, ChromaFrequency)', shader)
        self.assertIn('FilterGain = vec2(max(gain.x, EPS), max(length(carrier_response) * 0.5, EPS));', shader)
        self.assertIn('flat out float ChromaDelay;', shader)
        self.assertIn('chroma = mix(c0, c1, fract(chroma_index));', shader)

    def test_individual_debug_bypass_controls_exist(self):
        sys_shader = (ROOT / 'shaders' / 'sys-yc-filter.slang').read_text(encoding='utf-8')
        display_shader = (ROOT / 'shaders' / 'display-composite.slang').read_text(encoding='utf-8')
        self.assertIn('SYS_YC_NOTCH_BYPASS "Bypass Y notch filter"', sys_shader)
        self.assertIn('SYS_YC_BANDPASS_BYPASS "Bypass Y/C bandpass filtering"', sys_shader)
        self.assertIn('config.SYS_YC_NOTCH_BYPASS < 0.5', sys_shader)
        self.assertIn('config.SYS_YC_BANDPASS_BYPASS > 0.5', sys_shader)
        self.assertIn('DISPLAY_NOTCH_BYPASS "Bypass display luma notch"', display_shader)
        self.assertIn('DISPLAY_BANDPASS_BYPASS "Bypass display chroma bandpass"', display_shader)
        self.assertIn('config.DISPLAY_NOTCH_BYPASS < 0.5', display_shader)
        self.assertIn('config.DISPLAY_BANDPASS_BYPASS > 0.5', display_shader)

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

    def test_build_generates_in_output_and_reports_caps(self):
        output = self.root / 'out'
        catalog = self.root / 'presetdata' / 'timing-profiles.json'
        catalog.parent.mkdir()
        shutil.copy2(ROOT / 'presetdata' / 'timing-profiles.json', catalog)
        (self.root / 'config').mkdir()
        shutil.copy2(ROOT / 'config' / 'options.skel.cfg', self.root / 'config')
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
        self.assertTrue((output / 'shaders' / 'filter-taps.inc').is_file())
        self.assertTrue((output / 'shaders' / 'timing-profiles.inc').is_file())
        self.assertFalse((self.root / 'shaders' / 'filter-taps.inc').exists())
        self.assertFalse((self.root / 'shaders' / 'timing-profiles.inc').exists())
        for shader, designs in self.results().items():
            self.assertIn(f'{shader}: {max(designs.values())}', log.getvalue())
        self.assertIn('display-component.slang and display-svideo-filter.slang', log.getvalue())
        self.assertIn('sharpen.slang: 49 (primary Gaussian 33, secondary Gaussian 49)',
                      log.getvalue())


if __name__ == '__main__':
    unittest.main()
