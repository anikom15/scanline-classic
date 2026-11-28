import copy
import contextlib
import io
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path

import test_contract_timings as contract_timings
from scripts.generate_timing_profiles import generate_source, generate_timing_profiles
from scripts.generate_filter_taps import generate_filter_taps
from test_contract_timings import (
    CPP_HEADER, CPP_MAIN, FIELD_COUNTS, OUTPUT_MODES, REFERENCES, ROOT,
    cpp_profile_source, cpp_shader_source, phase_distance,
)
from test_dyadic_pyramid import shader_function, timing_profile_source


class TimingProfileGenerationTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))

    def test_shader_is_generated_in_output_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'out' / 'shaders'
            generate_timing_profiles(ROOT, output)
            self.assertEqual((output / 'timing-profiles.inc').read_text(encoding='utf-8'),
                             generate_source(self.data))

    def test_sfc_timing_modes_cover_reference_output_modes(self):
        profile = self.data['profiles'][0]
        for region in REFERENCES:
            sizes = {
                tuple(output['size'])
                for output in profile['output_modes'] if region in output['timing_modes']
            }
            with self.subTest(timing_mode=region):
                self.assertEqual(sizes, set(OUTPUT_MODES))

    def test_sfc_field_lines_match_reference_parities(self):
        for mode in self.data['profiles'][0]['modes']:
            reference = REFERENCES[mode['name']]
            for interlaced, scan in ((False, 'progressive'), (True, 'interlaced')):
                first, second = reference['lines'][interlaced]
                expected = {'even': first, 'odd': second}
                if mode['first_field'] == 'odd':
                    expected = {'odd': first, 'even': second}
                with self.subTest(mode=mode['name'], scan=scan):
                    self.assertEqual(mode['field_lines'][scan], expected)
                    for parity in ('even', 'odd'):
                        overrides = [entry for entry in mode['line_overrides']
                                     if entry['scan'] == scan and entry['field'] == parity]
                        stored = mode['clocks_per_line'] * expected[parity] + sum(
                            entry['clocks'] - mode['clocks_per_line'] for entry in overrides)
                        self.assertEqual(stored, mode['field_clocks'][scan][parity])

    def test_invalid_profiles_are_rejected(self):
        mutations = (
            lambda data: data['profiles'].append(copy.deepcopy(data['profiles'][0])),
            *(lambda data, value=value: data['profiles'][0]['modes'][0].update(pixel_clock_multiplier=value)
              for value in ([0, 1], [1, 0], [-1, 1], [True, 1], [1, 1.0], [1], [1, 2, 3],
                            [501, 1], [2**24 + 1, 65537], [1, 2**24 + 1])),
            lambda data: data['profiles'][0]['rules'][0].update(mode='missing'),
            lambda data: data['profiles'][0]['rules'].append(
                {'priority': 1, 'mode': 'ntsc', 'min_fps': 60}),
            lambda data: data['profiles'][0]['remaps'][0].update(to='missing'),
            lambda data: data['profiles'][0]['modes'][0].update(initial_phase_degrees=1),
            lambda data: data['profiles'][0]['output_modes'][0].update(timing_modes=['missing']),
            lambda data: data['profiles'][0]['modes'][0]['field_clocks']['progressive'].update(even=[1, 0]),
            lambda data: data['profiles'][0]['modes'][0]['field_clocks']['progressive'].update(even=1.5),
            lambda data: data['profiles'][0]['modes'][0]['field_clocks']['interlaced'].update(odd=[1, 1048577]),
            lambda data: data['profiles'][0]['modes'][0]['field_clocks']['interlaced'].update(odd=2**52),
            lambda data: data['profiles'][0]['modes'][0].update(first_field='unknown'),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(interlace_height_threshold=0),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(vertical_sync_lines=-1),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(vertical_back_porch_lines=259),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(horizontal_back_porch_cycles=1264),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(horizontal_sync_cycles=1.5),
            lambda data: data['profiles'][0]['modes'][0]['field_lines']['interlaced'].update(even=0),
            lambda data: data['profiles'][0]['modes'][0]['field_lines']['progressive'].update(odd=True),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(line=263),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(clocks=0),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(clocks=252),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(clocks=1361),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'].append(
                copy.deepcopy(data['profiles'][0]['modes'][0]['line_overrides'][0])),
            lambda data: data['profiles'][1]['modes'][0].update(line_clocks={'odd': 3412}),
            lambda data: data['profiles'][1]['modes'][0]['line_clocks'].update(odd=0),
            lambda data: data['profiles'][1]['modes'][0]['line_clocks'].update(even=3414),
            lambda data: data['profiles'][1]['modes'][0]['field_clocks']['progressive'].update(even=897488),
            lambda data: data['profiles'][1]['modes'][0]['raster'].update(horizontal_back_porch_cycles=100),
            lambda data: data['profiles'][1]['modes'][0]['raster']['horizontal_modes'][0].update(clock_factor=20),
        )
        for mutate in mutations:
            data = copy.deepcopy(self.data)
            mutate(data)
            with self.subTest(mutation=mutate):
                with self.assertRaises(ValueError):
                    generate_source(data)

    def test_clock_multiplier_is_reduced_and_sfc_ratios_match_reference(self):
        modes = self.data['profiles'][0]['modes']
        for mode in modes:
            with self.subTest(mode=mode['name']):
                self.assertEqual(Fraction(*mode['pixel_clock_multiplier']),
                                 1 / REFERENCES[mode['name']]['carrier_per_clock'])
        modes[0]['pixel_clock_multiplier'] = [14, 6]
        source = generate_source(self.data)
        self.assertIn('return 7.0 / 3.0;', source)
        self.assertIn('return dvec2(7.0lf, 3.0lf);', source)
        modes[0]['pixel_clock_multiplier'] = [2**24, 65537]
        self.assertIn('return dvec2(16777216.0lf, 65537.0lf);', generate_source(self.data))

    def test_build_rejects_unknown_remap_option(self):
        self.data['profiles'][0]['remaps'][0]['option'] = 'OPTION_NOT_DEFINED'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'presetdata').mkdir()
            (root / 'config').mkdir()
            (root / 'presetdata' / 'timing-profiles.json').write_text(json.dumps(self.data), encoding='utf-8')
            shutil.copy2(ROOT / 'config' / 'options.skel.cfg', root / 'config')
            with self.assertRaisesRegex(ValueError, 'Unknown timing profile option'):
                generate_timing_profiles(root)


class TimingProfileRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('g++')
        if compiler is None:
            raise unittest.SkipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        data['profiles'][0]['modes'][2]['initial_phase_degrees'] = 37
        rules_data = copy.deepcopy(data)
        rules_data['profiles'][0]['rules'] = [
            {'priority': 1, 'mode': 'pal', 'min_width': 500, 'max_area': 300000},
            {'priority': 2, 'mode': 'palm', 'min_height': 200},
        ]
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.executables = {}
        for palm, custom_rules in ((False, False), (True, False), (False, True)):
            source = re.sub(r'(?<=\d)lf\b', '', cpp_profile_source(generate_source(rules_data if custom_rules else data)))
            define = '#define OPTION_REPLACE_NTSC_PALM\n' if palm else ''
            cpp = Path(temporary.name) / f'profile-{palm}-{custom_rules}.cpp'
            executable = Path(temporary.name) / f'profile-{palm}-{custom_rules}'
            cpp.write_text(CPP_HEADER + define + source + r'''
int main() {
    float profile, width, height, fps;
    while (std::cin >> profile >> width >> height >> fps) {
        int mode = timing_profile_select(profile, vec2{width, height}, fps);
        std::cout << mode << ' ' << timing_profile_initial_phase(mode, 12.0f)
                  << ' ' << timing_profile_pal(mode, 0.25f) << '\n';
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(cpp), '-o', str(executable)], check=True)
            cls.executables[(palm, custom_rules)] = executable

    def run_selection(self, profile, width, height, fps, palm=False, custom_rules=False):
        result = subprocess.run(
            [str(self.executables[(palm, custom_rules)])], input=f'{profile} {width} {height} {fps}\n',
            text=True, capture_output=True, check=True,
        )
        return tuple(float(value) for value in result.stdout.split())

    def test_override_and_relative_initial_phase(self):
        self.assertEqual(self.run_selection(1, 256, 224, 60), (1, 0, 0))
        self.assertEqual(self.run_selection(1, 256, 224, 60, palm=True), (3, 37, 1))
        self.assertEqual(self.run_selection(1, 512, 478, 50, palm=True), (2, 0, 1))

    def test_legacy_and_invalid_inputs(self):
        self.assertEqual(self.run_selection(0, 0, 0, 0), (0, 12, 0.25))
        for profile, width, height, fps in ((3, 256, 224, 60), (1, 0, 224, 60), (1, 256, 224, 0)):
            mode, phase, pal = self.run_selection(profile, width, height, fps)
            with self.subTest(profile=profile, width=width, fps=fps):
                self.assertEqual(mode, -1)
                self.assertNotEqual(phase, phase)
                self.assertNotEqual(pal, pal)

    def test_size_area_rules_and_explicit_priority(self):
        for width, height, expected in ((512, 224, 2), (256, 224, 3), (640, 480, 3), (256, 100, 1)):
            with self.subTest(width=width, height=height):
                mode, _, _ = self.run_selection(1, width, height, 60, custom_rules=True)
                self.assertEqual(mode, expected)

    def test_psx_selection(self):
        self.assertEqual(self.run_selection(2, 320, 240, 60), (4, 0, 0))
        self.assertEqual(self.run_selection(2, 320, 288, 50, palm=True), (5, 0, 1))

    def test_signal_standard_tracks_profile_refresh_and_debug_override(self):
        compiler = shutil.which('g++')
        profiles = timing_profile_source()
        standard = (ROOT / 'shaders' / 'signal-standard.inc').read_text(encoding='utf-8')
        source = re.sub(r'(?<=\d)lf\b', '', cpp_profile_source(profiles))
        function = shader_function(standard, 'float signal_pal(')
        checks = r'''
int main() {
    float profile, fps, debug_pal;
    while (std::cin >> profile >> fps >> debug_pal) {
        int mode = timing_profile_select(profile, vec2{320, 240}, fps);
        std::cout << signal_pal(mode, fps, debug_pal) << '\n';
    }
}
'''
        cases = (
            (1, 60, 0, 0, 1),
            (1, 50, 0, 1, 1),
            (1, 55, 0, 1, 1),
            (1, 55.01, 0, 0, 1),
            (2, 60, 0, 0, 0),
            (2, 50, 0, 1, 1),
            (0, 60, 0, 0, 0),
            (0, 50, 0, 1, 1),
            (0, 55, 0, 1, 1),
            (0, 55.01, 0, 0, 0),
            (0, 60, 1, 1, 1),
            (2, 60, 1, 1, 1),
            (3, 60, 0, math.nan, math.nan),
            (3, 60, 1, math.nan, math.nan),
        )
        with tempfile.TemporaryDirectory() as temp:
            for palm in (False, True):
                cpp = Path(temp) / f'decoder-{palm}.cpp'
                executable = Path(temp) / f'decoder-{palm}'
                define = '#define OPTION_REPLACE_NTSC_PALM\n' if palm else ''
                cpp.write_text(CPP_HEADER + define + source + function + checks, encoding='utf-8')
                subprocess.run([compiler, '-std=c++17', '-O2', str(cpp), '-o', str(executable)], check=True)
                for profile, fps, debug_pal, normal, replaced in cases:
                    with self.subTest(palm=palm, profile=profile, fps=fps, debug_pal=debug_pal):
                        result = subprocess.run(
                            [str(executable)], input=f'{profile} {fps} {debug_pal}\n',
                            text=True, capture_output=True, check=True,
                        )
                        actual = float(result.stdout)
                        expected = replaced if palm else normal
                        if math.isnan(expected):
                            self.assertTrue(math.isnan(actual))
                        else:
                            self.assertEqual(actual, expected)

    def test_psx_geometry_and_exact_phase(self):
        compiler = shutil.which('g++')
        settings = contract_timings.load_sfc_timing_parameters('sfc-rgb.json')
        settings['TIMING_PROFILE'] = 2
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'psx-contract.cpp'
            executable = Path(temp) / 'psx-contract'
            source.write_text(CPP_HEADER + cpp_shader_source() + CPP_MAIN, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            for region, fps, lines, durations, ratio, first_odd in (
                ('ntsc', 60, ((263, 263), (263, 262)),
                 ((897487, 897487), (897487, 894075)), 15, False),
                ('pal', 50, ((314, 314), (313, 312)),
                 ((1069170, 1069170), (1065765, 1062360)), 12, True),
            ):
                for interlaced in (False, True):
                    size = (320, (480 if interlaced else 240) if region == 'ntsc'
                            else (576 if interlaced else 288))
                    even, odd = durations[interlaced]
                    for reverse in (False, True):
                        for geometry_field in (0, 1):
                            values = contract_timings.SfcContractTimingTests.run_case(
                                region, size, reverse=reverse, fps=fps, executable=executable,
                                parameters=settings, geometry_field=geometry_field)
                            parity = (geometry_field + first_odd + reverse) % 2
                            average = 3412.5 if region == 'ntsc' else 3405
                            self.assertAlmostEqual(values[3], values[1] / average, delta=0.01)
                            self.assertEqual(values[4], 3413 if region == 'ntsc' else 3405)
                            self.assertEqual(values[5], 3413 if region == 'ntsc' else 3405)
                            self.assertEqual(values[6], lines[interlaced][parity])
                            self.assertEqual(values[8], float(interlaced))
                            first = odd if first_odd != reverse else even
                            for index, field in enumerate(FIELD_COUNTS):
                                elapsed = (field // 2) * (even + odd) + (field % 2) * first
                                self.assertLessEqual(
                                    phase_distance(values[9 + 3 * index], float(Fraction(elapsed, ratio) % 1)),
                                    1 / 360)
                                self.assertEqual(values[11 + 3 * index], (field + first_odd + reverse) % 2)

    def test_psx_periodic_lines_and_overrides(self):
        compiler = shutil.which('g++')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][1]['modes'][0]
        mode['line_overrides'] = [
            {'scan': 'interlaced', 'field': 'odd', 'line': 10, 'clocks': 3409},
            {'scan': 'interlaced', 'field': 'odd', 'line': 13, 'clocks': 3415},
        ]
        mode['field_clocks']['interlaced']['odd'] -= 1
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'psx-raster.cpp'
            executable = Path(temp) / 'psx-raster'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + r'''
#include <stdexcept>
int main() {
    for (int mode : {4, 5}) {
        int widths[] = {200, 256, 319, 320, 367, 368, 511, 512, 639, 640, 700};
        int nominal[] = {256, 256, 256, 320, 320, 368, 368, 512, 512, 640, 640};
        int factors[] = {10, 10, 10, 8, 8, 7, 7, 5, 5, 4, 4};
        for (int i=0; i<11; ++i) {
            if (timing_profile_nominal_width(mode, widths[i], 0) != nominal[i] ||
                timing_profile_clock_factor(mode, widths[i], 0) != factors[i])
                throw std::runtime_error("PSX horizontal mode inference mismatch");
            float first = timing_profile_active_left(mode, mode == 4 ? 3412 : 3405, widths[i], factors[i], 0);
            float second = timing_profile_active_left(mode, mode == 4 ? 3413 : 3405, widths[i], factors[i], 0);
            if (first != second)
                throw std::runtime_error("PSX active placement changes with line length");
        }
        if (timing_profile_vertical_sync_lines(mode, 0) != 1 ||
            timing_profile_horizontal_sync_cycles(mode, 0) != 100 ||
            timing_profile_active_top(mode, mode == 4 ? 240 : 288, 0) != 12)
            throw std::runtime_error("PSX sync or picture origin mismatch");
    }
    float picture_start = timing_profile_active_left(4, 3412, 640, 4, 0);
    if (picture_start != 752 || timing_profile_active_left(4, 3412.5f, 640, 4, 0) != 752 ||
        3412 - (picture_start + 640*4) != 100 ||
        3413 - (picture_start + 640*4) != 101)
        throw std::runtime_error("PSX picture or front porch timing mismatch");
    for (int mode : {4, 5}) for (int interlaced : {0, 1})
    for (int frame : {0, 1}) for (int reverse : {0, 1})
    for (int width : {2047, 3405, 3413, 4096}) {
        int odd = (frame + reverse + (mode == 5)) % 2;
        int height = interlaced ? (mode == 4 ? 480 : 576) : (mode == 4 ? 240 : 288);
        int lines = mode == 4 ? (interlaced && odd ? 262 : 263)
                              : (interlaced ? (odd ? 312 : 313) : 314);
        int scale = mode == 4 ? 3413 : 3405;
        auto boundary = [=](int line) {
            long long clocks = mode == 4 ? (line / 2) * 6825LL + (line % 2) * 3412LL
                                         : line * 3405LL;
            if (mode == 4 && interlaced && odd) {
                if (line >= 10) clocks -= 4;
                if (line >= 13) clocks += 3;
            }
            return int((clocks * width + scale - 1) / scale);
        };
        int length = boundary(lines);
        if (timing_profile_storage_length(mode, height, frame, reverse, width, width * lines) != length)
            throw std::runtime_error("PSX field length mismatch");
        for (int line = 0; line < lines; ++line) {
            int start = boundary(line), end = boundary(line + 1);
            vec2 range = timing_profile_line_range(mode, height, frame, reverse, line, width);
            if (range.x != start || range.y != end - start)
                throw std::runtime_error("PSX line range mismatch");
            for (int index : {start, end - 1}) {
                vec2 pos = timing_profile_raster_position(mode, height, frame, reverse, index, width);
                if (pos.x != index - start || pos.y != line)
                    throw std::runtime_error("PSX line boundary mismatch");
            }
        }
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_selected_raster_mapping_matches_existing_boundaries(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][1]['modes'][0]
        mode['line_overrides'] = [
            {'scan': 'interlaced', 'field': 'odd', 'line': 10, 'clocks': 3409},
            {'scan': 'interlaced', 'field': 'odd', 'line': 13, 'clocks': 3415},
        ]
        mode['field_clocks']['interlaced']['odd'] -= 1
        mapping = (ROOT / 'shaders' / 'raster-mapping.inc').read_text(encoding='utf-8')
        mapping = re.sub(r'(?<=\d)lf\b', '', mapping)
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'selected-raster.cpp'
            executable = Path(temp) / 'selected-raster'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + mapping + r'''
#include <stdexcept>
int main() {
    const double clocks[] = {1, 21477270, 21281370, 21453666, 53693175, 53203425};
    for (int mode : {0, 1, 2, 3, 4, 5}) for (int interlaced : {0, 1})
    for (uint frame : {0u, 1u}) for (float reverse : {0.0f, 1.0f}) {
        float height = interlaced ? 576 : 240;
        float scale = mode == 4 ? 3413 : mode == 5 ? 3405 : 1364;
        float lines = mode == 0 ? 262 : timing_profile_v_freq(mode, height, frame, reverse, 262);
        vec4 pattern(0); ivec2 span(0, 0);
        timing_profile_raster_descriptor(mode, height, frame, reverse, pattern, span);
        double widths[] = {double(scale), 2047.125,
                           mode == 0 ? 1025.498 : double(scale) * 16000000.0 / clocks[mode],
                           mode == 0 ? 2050.996 : double(scale) * 32000000.0 / clocks[mode], 1.125};
        for (int rate = 0; rate < 5; ++rate) {
            double width = widths[rate];
            float length = timing_profile_storage_length(mode, height, frame, reverse, width, width * lines);
            for (int line = 0; line < int(ceil(lines)); ++line) {
                vec2 expected = timing_profile_line_range(mode, height, frame, reverse, line, width);
                vec2 actual = raster_line_range(pattern, span, line, width);
                if (actual.x != expected.x || actual.y != expected.y)
                    throw std::runtime_error("selected line range differs");
                if (mode > 0) {
                    bool odd = (frame + int(reverse) + (mode == 2 || mode == 5)) % 2;
                    auto boundary = [&](int n) {
                        long long c = mode == 4 ? (n / 2) * 6825LL + (n % 2) * 3412LL
                                                : n * static_cast<long long>(scale);
                        if ((mode == 1 || mode == 3) && !interlaced && odd && n >= 259) c -= 4;
                        if (mode == 2 && interlaced && odd && n >= 18) c += 4;
                        if (mode == 4 && interlaced && odd) {
                            if (n >= 10) c -= 4;
                            if (n >= 13) c += 3;
                        }
                        long long numerator = rate == 0 ? 1 : rate == 1 ? 16377
                                                     : rate == 2 ? 16000000 : rate == 3 ? 32000000 : 9;
                        long long denominator = rate == 0 ? 1 : (rate == 1 || rate == 4) ? 8 * static_cast<long long>(scale)
                                                                                       : static_cast<long long>(clocks[mode]);
                        return (c * numerator + denominator - 1) / denominator;
                    };
                    long long start = boundary(line), end = boundary(line + 1);
                    if (actual.x != start || actual.y != end - start)
                        throw std::runtime_error("selected line range differs from rational reference");
                }
                for (float index : {expected.x - 1, expected.x, expected.x + expected.y - 1,
                                    expected.x + expected.y}) {
                    if (index < 0 || index >= length) continue;
                    vec2 reference = timing_profile_raster_position(mode, height, frame, reverse, index, width);
                    vec2 position = raster_position(pattern, span, index, width);
                    if (position.x != reference.x || position.y != reference.y)
                        throw std::runtime_error("selected sample position differs");
                }
            }
        }
    }
    vec4 pattern(0); ivec2 span(0, 0);
    timing_profile_raster_descriptor(-1, 240, 0, 0, pattern, span);
    vec2 invalid = raster_position(pattern, span, 0, 1364);
    if (!std::isnan(invalid.x) || !std::isnan(invalid.y))
        throw std::runtime_error("invalid profile did not propagate");
    timing_profile_raster_descriptor(4, 480, 1, 0, pattern, span);
    pattern.w = 262.5f;
    vec2 partial = raster_line_range(pattern, span, 262, 3413);
    vec2 position = raster_position(pattern, span, partial.x, 3413);
    if (position.x != 0 || position.y != 262)
        throw std::runtime_error("fractional field mapping differs");
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_exceptional_line_locations_and_field_lengths(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'raster.cpp'
            executable = Path(temp) / 'raster'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + r'''
int main() {
    int mode;
    float height, odd, width, lines, index;
    uint frame;
    while (std::cin >> mode >> height >> frame >> odd >> width >> lines >> index) {
        float length = timing_profile_storage_length(mode, height, frame, odd, width, width * lines);
        vec2 position = timing_profile_raster_position(mode, height, frame, odd, index, width);
        vec2 range = timing_profile_line_range(mode, height, frame, odd, position.y, width);
        std::cout << length << ' ' << position.x << ' ' << position.y
                  << ' ' << range.x << ' ' << range.y << '\n';
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            cases = []
            expected = []
            for mode, region in enumerate(('ntsc', 'pal', 'palm'), 1):
                for interlaced, height in ((False, 239), (True, 478)):
                    for frame in (0, 1):
                        for reverse in (0, 1):
                            odd = (frame + reverse + (region == 'pal')) % 2
                            line_count = REFERENCES[region]['lines'][interlaced][
                                frame % 2 ^ reverse]
                            exception = None
                            if odd and not interlaced and region in ('ntsc', 'palm'):
                                exception = (259, -4)
                            elif odd and interlaced and region == 'pal':
                                exception = (18, 4)
                            for width in (1364, 2047):
                                delta = math.ceil(Fraction((exception or (0, 0))[1] * width, 1364))
                                length = width * line_count + delta
                                points = {0, length - 1}
                                if exception:
                                    line, _ = exception
                                    start = (line - 1) * width
                                    end = line * width + delta
                                    points.update((start - 1, start, end - 1))
                                    if end < length:
                                        points.add(end)
                                for index in sorted(points):
                                    if exception and index >= exception[0] * width + delta:
                                        x, y = (index - delta) % width, (index - delta) // width
                                    elif exception and index >= (exception[0] - 1) * width:
                                        x, y = index - (exception[0] - 1) * width, exception[0] - 1
                                    else:
                                        x, y = index % width, index // width
                                    cases.append(f'{mode} {height} {frame} {reverse} {width} {line_count} {index}\n')
                                    line_start = y * width
                                    line_length = width
                                    if exception:
                                        if y == exception[0] - 1:
                                            line_length += delta
                                        elif y >= exception[0]:
                                            line_start += delta
                                    expected.append((length, x, y, line_start, line_length))
            result = subprocess.run([str(executable)], input=''.join(cases),
                                    text=True, capture_output=True, check=True)
            actual = [tuple(map(int, row.split())) for row in result.stdout.splitlines()]
            self.assertEqual(actual, expected)

    def test_multiple_line_overrides_accumulate_at_resampled_rate(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][0]['modes'][0]
        mode['line_overrides'].append({'scan': 'progressive', 'field': 'odd', 'line': 260, 'clocks': 1367})
        mode['field_clocks']['progressive']['odd'] += 3
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'multiple-lines.cpp'
            executable = Path(temp) / 'multiple-lines'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + r'''
#include <stdexcept>
int main() {
    float width = 2047;
    vec2 first = timing_profile_line_range(1, 239, 1, 0, 258, width);
    vec2 second = timing_profile_line_range(1, 239, 1, 0, 259, width);
    vec2 third = timing_profile_line_range(1, 239, 1, 0, 260, width);
    if (first.x != 258*width || first.y != width-6 ||
        second.x != 259*width-6 || second.y != width+5 ||
        third.x != 260*width-1 || third.y != width)
        throw std::runtime_error("multiple line adjustments are not cumulative");
    vec2 at_second = timing_profile_raster_position(1, 239, 1, 0, second.x, width);
    vec2 at_third = timing_profile_raster_position(1, 239, 1, 0, third.x, width);
    if (at_second.x != 0 || at_second.y != 259 || at_third.x != 0 || at_third.y != 260 ||
        timing_profile_storage_length(1, 239, 1, 0, width, 262*width) != 262*width-1)
        throw std::runtime_error("multiple line positions or field length are incorrect");
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_presentation_capacity_includes_exceptional_lines(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'presentation.cpp'
            executable = Path(temp) / 'presentation'
            source.write_text(CPP_HEADER + cpp_shader_source() + r'''
#include <stdexcept>
int main() {
    auto fits = [](int mode, float height, uint frame, float width, float lines, float x, float y) {
        return timing_profile_presentation_fits(mode, height, frame, 0, width,
                                                mode == 4 ? 3413 : 1364, lines, vec2{x,y});
    };
    if (!fits(2, 478, 0, 1364, 312, 1368, 312) ||
        fits(2, 478, 0, 1364, 312, 1367, 312) ||
        fits(2, 478, 0, 1364, 312, 1368, 311) ||
        !fits(1, 239, 1, 1364, 262, 1364, 262) ||
        !fits(4, 480, 1, 3413, 262, 3413, 262) ||
        fits(0, 224, 0, 1025.5, 262, 1025, 512) ||
        !fits(0, 224, 0, 1025.5, 262, 1026, 512) ||
        fits(-1, 224, 0, 1024, 262, 2048, 512))
        throw std::runtime_error("presentation capacity check mismatch");
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_presentation_capacity_matches_all_line_ranges(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'presentation-all-lines.cpp'
            executable = Path(temp) / 'presentation-all-lines'
            source.write_text(CPP_HEADER + cpp_shader_source() + r'''
#include <stdexcept>
int main() {
    for (int mode : {0, 1, 2, 3, 4, 5}) for (int interlaced : {0, 1})
    for (uint frame : {0u, 1u}) for (int reverse : {0, 1}) {
        float height = interlaced ? 576 : 240;
        float base = mode == 4 ? 3413 : mode == 5 ? 3405 : 1364;
        float lines = mode == 0 ? 262 : timing_profile_v_freq(mode, height, frame, reverse, 262);
        for (double width : {double(base), 1025.498, 2047.125}) {
            double maximum = 0;
            for (int line = 0; line < int(ceil(lines)); ++line) {
                vec2 range = timing_profile_line_range(mode, height, frame, reverse, line, base);
                maximum = std::max(maximum, double(range.y) * width / double(base));
            }
            float required = float(ceil(maximum));
            for (float capacity : {required-1, required, required+1}) {
                bool actual = timing_profile_presentation_fits(mode, height, frame, reverse,
                    width, base, lines, vec2{capacity, ceil(lines)});
                if (actual != (capacity >= required))
                    throw std::runtime_error("presentation capacity differs from line scan");
            }
        }
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_presentation_capacity_accounts_for_all_overridden_long_lines(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][1]['modes'][0]
        mode['line_overrides'] = [
            {'scan': 'interlaced', 'field': 'odd', 'line': line, 'clocks': 3410}
            for line in range(2, 263, 2)
        ]
        mode['field_clocks']['interlaced']['odd'] -= 3 * len(mode['line_overrides'])
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'presentation-overrides.cpp'
            executable = Path(temp) / 'presentation-overrides'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + r'''
#include <stdexcept>
int main() {
    if (!timing_profile_presentation_fits(4, 480, 1, 0, 3413, 3413, 262, vec2{3412,262}) ||
        timing_profile_presentation_fits(4, 480, 1, 0, 3413, 3413, 262, vec2{3411,262}) ||
        !timing_profile_presentation_fits(2, 478, 0, 0, 1364, 1364, 10, vec2{1364,10}))
        throw std::runtime_error("incorrect maximum or partial-field fallback");
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_fractional_widths_use_cumulative_boundaries(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'fractional-raster.cpp'
            executable = Path(temp) / 'fractional-raster'
            source.write_text(CPP_HEADER + cpp_shader_source() + r'''
#include <stdexcept>
int main() {
    for (int mode : {0, 1, 2, 4, 5}) for (int frame : {0, 1}) {
        float width = 1025.498f;
        int lines = mode == 0 ? 262 : int(timing_profile_v_freq(mode, 478, frame, 0, 262));
        float height = mode == 0 ? 224 : 478;
        auto boundary = [=](int line) {
            double clocks = line * (mode == 4 ? 3413.0 : mode == 5 ? 3405.0 : 1364.0);
            if (mode == 4) {
                clocks = (line / 2) * 6825.0 + (line % 2) * 3412.0;
            }
            if (mode == 2 && frame == 0 && line >= 18) clocks += 4;
            double scale = mode == 4 ? 3413.0 : mode == 5 ? 3405.0 : 1364.0;
            return std::ceil(clocks * double(width) / scale);
        };
        float length = timing_profile_storage_length(mode, height, frame, 0, width, width * lines);
        if (length != boundary(lines)) {
            std::cerr << "mode " << mode << " frame " << frame << " length "
                      << length << " expected " << boundary(lines) << '\n';
            throw std::runtime_error("fractional field length mismatch");
        }
        for (int line = 0; line < lines; ++line) {
            float start = float(boundary(line)), end = float(boundary(line+1));
            vec2 range = timing_profile_line_range(mode, height, frame, 0, line, width);
            if (range.x != start || range.y != end - start)
                throw std::runtime_error("fractional line range mismatch");
            for (float index : {start, end - 1}) {
                vec2 pos = timing_profile_raster_position(mode, height, frame, 0, index, width);
                if (pos.y != line || pos.x != index - start)
                    throw std::runtime_error("fractional raster position mismatch");
            }
        }
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_fixed_rates_follow_exact_profile_clocks(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
        functions = '\n'.join(shader_function(contract, signature) for signature in (
            'double contract_working_frame_width(', 'double contract_output_frame_width(',
            'float contract_working_sample_rate(', 'float contract_output_sample_rate(',
        ))
        functions = re.sub(r'(?<![\w.])(\d+\.\d+(?:[eE][+-]?\d+)?)(lf)?\b',
                           lambda m: m.group(1) + ('' if m.group(2) else 'f'), functions)
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'fixed-rates.cpp'
            executable = Path(temp) / 'fixed-rates'
            source.write_text(CPP_HEADER + cpp_shader_source() + functions + r'''
#include <stdexcept>
int main() {
    const double clocks[] = {0, 21477270, 21281370, 21453666, 53693175, 53203425};
    for (int mode = 1; mode <= 5; ++mode) {
        float sc_mode = timing_profile_sc_mode(mode, 0), pc_mode = timing_profile_pixel_mode(mode, 0);
        float pc = timing_profile_pixel_value(mode, 0), h_mode = timing_profile_h_mode(mode, 0);
        float h = timing_profile_h_freq(mode, 0);
        float base = contract_frame_width(60, sc_mode, 0, pc_mode, pc, h_mode, h);
        if (contract_working_sample_rate(60, sc_mode, 0, pc_mode, pc, h_mode, h, 32) != 32000000 ||
            contract_output_sample_rate(60, sc_mode, 0, pc_mode, pc, h_mode, h, 32, 16) != 16000000)
            throw std::runtime_error("sample rate changed");
        for (int rate : {16, 32}) {
            double width = rate == 32
                ? contract_working_frame_width(60, sc_mode, 0, pc_mode, pc, h_mode, h, 32)
                : contract_output_frame_width(60, sc_mode, 0, pc_mode, pc, h_mode, h, 32, 16);
            width = timing_profile_rate_width(mode, width, float(rate));
            if (mode == 2 && rate == 16 &&
                (!timing_profile_presentation_fits(mode, 478, 0, 0, width, 1364, 312, vec2{1029,512}) ||
                  timing_profile_presentation_fits(mode, 478, 0, 0, width, 1364, 312, vec2{1028,512})))
                throw std::runtime_error("PAL extended line requires 1029 presentation pixels");
            for (int line = 0; line < 260; ++line) {
                double line_clock = mode == 4 ? (line / 2) * 6825.0 + (line % 2) * 3412.0
                                               : line * double(base);
                double expected = std::ceil(line_clock * (rate * 1000000.0) / clocks[mode]);
                vec2 range = timing_profile_line_range(mode, 239, 0, 0, line, width);
                if (range.x != expected) {
                    std::cerr << "mode " << mode << " rate " << rate << " line " << line
                              << " got " << range.x << " expected " << expected << '\n';
                    throw std::runtime_error("incorrect physical sample boundary");
                }
            }
        }
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


class ExplicitFieldTimingTests(unittest.TestCase):
    def test_shader_rejects_invalid_profile_clock_ratios(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'invalid-ratio.cpp'
            executable = Path(temp) / 'invalid-ratio'
            source.write_text(CPP_HEADER + cpp_shader_source() + r'''
int main() {
    double numerator, denominator;
    while (std::cin >> numerator >> denominator) {
        float phase = contract_initial_subcarrier_phase_frac(
            vec2{256, 224}, 60, 1, 1, 6, 1, 0, 1, 1364, 5, 262, 1, 0,
            vec3(6, 0, 0), vec3(0, 0, 0), dvec2(numerator, denominator), 0,
            dvec4(357368, 357364, 358732, 357368), dvec4(1), 0);
        std::cout << std::setprecision(17) << phase << '\n';
    }
}
''', encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            ratios = ((7, 3), (0, 1), (1, 0), (-1, 1), (1.5, 1),
                      (1, 1.5), (2**24 + 1, 65537), (1, 2**24 + 1), (501, 1))
            result = subprocess.run(
                [str(executable)], input=''.join(f'{a} {b}\n' for a, b in ratios),
                text=True, capture_output=True, check=True,
            )
            phases = [float(value) for value in result.stdout.split()]
            self.assertEqual(len(phases), len(ratios))
            self.assertLessEqual(phase_distance(phases[0], float((357368 * Fraction(3, 7)) % 1)), 1 / 360)
            for ratio, phase in zip(ratios[1:], phases[1:]):
                with self.subTest(ratio=ratio):
                    self.assertTrue(math.isnan(phase))

    def test_nonterminating_clock_ratio_with_fractional_fields(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][0]['modes'][0]
        mode['line_overrides'] = []
        mode['field_clocks']['progressive'] = {'even': [1072105, 3], 'odd': [1072097, 3]}
        mode['field_clocks']['interlaced'] = {'even': [1074151, 3], 'odd': [1790251, 5]}
        with tempfile.TemporaryDirectory() as temp:
            for multiplier in ((7, 3), (2**24, 65537), (1, 2**24)):
                mode['pixel_clock_multiplier'] = list(multiplier)
                source = Path(temp) / 'rational.cpp'
                executable = Path(temp) / 'rational'
                source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + CPP_MAIN, encoding='utf-8')
                subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
                for interlaced, size in ((False, (256, 224)), (True, (256, 478))):
                    clocks = mode['field_clocks']['interlaced' if interlaced else 'progressive']
                    even, odd = (Fraction(*clocks[key]) for key in ('even', 'odd'))
                    for reverse in (False, True):
                        values = contract_timings.SfcContractTimingTests.run_case(
                            'ntsc', size, reverse=reverse, fps=60, executable=executable,
                            parameters=contract_timings.load_sfc_timing_parameters('sfc-rgb.json'))
                        clock = 3_579_545 * Fraction(*multiplier)
                        self.assertAlmostEqual(values[1], float(clock), delta=max(2, float(clock) * 1e-6))
                        first = odd if reverse else even
                        for index, field in enumerate(FIELD_COUNTS):
                            with self.subTest(multiplier=multiplier, interlaced=interlaced,
                                              reverse=reverse, field=field):
                                elapsed = (field // 2) * (even + odd) + (field % 2) * first
                                expected = float((elapsed / Fraction(*multiplier)) % 1)
                                self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1 / 360)

    def test_field_clocks_and_order_are_independent_of_raster(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        mode = data['profiles'][0]['modes'][0]
        mode['line_overrides'] = []
        mode['first_field'] = 'odd'
        mode['field_lines']['progressive'] = {'even': 270, 'odd': 270}
        mode['field_lines']['interlaced'] = {'even': 262.5, 'odd': 262.5}
        mode['field_clocks']['progressive'] = {'even': [1072105, 3], 'odd': [1072097, 3]}

        with tempfile.TemporaryDirectory() as temp:
            for interlaced_clocks in (
                {'even': 358050, 'odd': 358050},
                {'even': [1074151, 3], 'odd': [1790251, 5]},
            ):
                mode['field_clocks']['interlaced'] = interlaced_clocks
                source = Path(temp) / 'explicit.cpp'
                executable = Path(temp) / 'explicit'
                source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + CPP_MAIN, encoding='utf-8')
                subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
                for interlaced, size in ((False, (256, 224)), (True, (256, 478))):
                    clocks = mode['field_clocks']['interlaced' if interlaced else 'progressive']
                    even, odd = (Fraction(*clocks[key]) if isinstance(clocks[key], list)
                                 else Fraction(clocks[key]) for key in ('even', 'odd'))
                    for reverse in (False, True):
                        values = contract_timings.SfcContractTimingTests.run_case(
                            'ntsc', size, reverse=reverse, fps=60, executable=executable,
                            parameters=contract_timings.load_sfc_timing_parameters('sfc-rgb.json'))
                        self.assertEqual(values[6], 262.5 if interlaced else 270)
                        self.assertEqual(values[8], float(interlaced))
                        first = even if reverse else odd
                        for index, field in enumerate(FIELD_COUNTS):
                            with self.subTest(clocks=clocks, reverse=reverse, field=field):
                                elapsed = (field // 2) * (even + odd) + (field % 2) * first
                                expected = float((elapsed * Fraction(1, 6)) % 1)
                                self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1 / 360)
                                self.assertEqual(values[11 + 3 * index], (field + 1 + reverse) % 2)


class TimingProfilePresetTests(unittest.TestCase):
    def prepare_generated_includes(self, output):
        with contextlib.redirect_stdout(io.StringIO()):
            generate_filter_taps(ROOT, output / 'shaders')
        generate_timing_profiles(ROOT, output / 'shaders')

    def test_vga_rates_are_exposed_only_to_vga_presets(self):
        cases = (
            ('professional', 'sfc-rgb', 'sfc', None),
            ('computer', 'teradrive', 'teradrive', 30.0),
            ('computer', 'pckd863g', 'pckd863g', 25.0),
        )
        with tempfile.TemporaryDirectory() as temp:
            for category, name, result_name, expected in cases:
                output = Path(temp) / name
                self.prepare_generated_includes(output)
                command = [
                    sys.executable, str(ROOT / 'external' / 'presetgen' / 'presetgen.py'),
                    '--input', str(ROOT / 'presetdata' / 'input' / category / f'{name}.json'),
                    '--output', str(output), '--config', str(ROOT / 'presetdata' / 'presetgen.json'),
                ]
                subprocess.run(command, capture_output=True, text=True, check=True)
                menu = next((output / 'shaders' / 'menus').glob(f'menu-{result_name}-*.slang'))
                menu_text = menu.read_text(encoding='utf-8')
                preset = (output / 'presets' / category / f'{result_name}.slangp').read_text(encoding='utf-8')
                values = {
                    key.strip(): value.strip().strip('"')
                    for line in preset.splitlines() if '=' in line
                    for key, value in [line.split('=', 1)]
                }
                with self.subTest(preset=name):
                    self.assertEqual('parameters/vga-dsp.inc' in menu_text, expected is not None)
                    self.assertNotIn('DSP_WORKING_FS', values)
                    self.assertNotIn('DSP_OUTPUT_FS', values)
                    if expected is not None:
                        self.assertNotIn('VGA_INPUT_FS', values)
                        self.assertEqual(float(values['VGA_OUTPUT_FS']), expected)

    def test_signal_shaders_use_shared_standard_and_debug_parameter(self):
        for name in ('display-svideo-demod.slang', 'composite-demod.slang',
                     'composite-mod.slang', 'digital-svideo.slang', 'famicom-special.slang'):
            source = (ROOT / 'shaders' / name).read_text(encoding='utf-8')
            with self.subTest(shader=name):
                self.assertIn('#pragma parameter DEBUG_PAL ', source)
                self.assertIn('signal_pal(TIMING_PROFILE_MODE, config.OriginalFPS, ', source)
                self.assertNotRegex(source, r'\b(?:config|global)\.PAL\b')
                vertex, fragment = source.split('#pragma stage vertex', 1)[1].split('#pragma stage fragment', 1)
                self.assertIn('signal_pal(', vertex)
                self.assertNotIn('signal_pal(', fragment)
        common = (ROOT / 'shaders' / 'sys-component-yc-common.slang').read_text(encoding='utf-8')
        self.assertIn('signal_pal(TIMING_PROFILE_MODE, config.OriginalFPS, ', common)
        vertex, fragment = common.split('#pragma stage vertex', 1)[1].split('#pragma stage fragment', 1)
        self.assertIn('signal_pal(', vertex)
        self.assertNotIn('signal_pal(', fragment)
        for name in ('sys-yc.slang', 'sys-component-yc.slang'):
            source = (ROOT / 'shaders' / name).read_text(encoding='utf-8')
            self.assertIn('#pragma parameter DEBUG_PAL ', source)

    def test_profile_selection_is_once_per_vertex_not_per_fragment(self):
        for path in (ROOT / 'shaders').iterdir():
            if path.suffix not in ('.slang', '.inc'):
                continue
            source = path.read_text(encoding='utf-8')
            if '#define TIMING_PROFILE_MODE ' not in source:
                continue
            with self.subTest(shader=path.name):
                vertex, fragment = source.split('#pragma stage vertex', 1)[1].split('#pragma stage fragment', 1)
                self.assertEqual(len(re.findall(r'\btiming_profile_select\s*\(', source)), 1)
                self.assertIn('timing_profile_select(', vertex)
                self.assertNotIn('timing_profile_select(', fragment)
                self.assertNotIn('#define TIMING_PROFILE_MODE timing_profile_select', source)

    def test_fragment_raster_mapping_uses_selected_descriptors(self):
        for path in (ROOT / 'shaders').iterdir():
            if path.suffix not in ('.slang', '.inc'):
                continue
            source = path.read_text(encoding='utf-8')
            if '#pragma stage fragment' not in source:
                continue
            vertex, fragment = source.split('#pragma stage vertex', 1)[1].split('#pragma stage fragment', 1)
            with self.subTest(shader=path.name):
                self.assertNotIn('timing_profile_raster_position(', fragment)
                self.assertNotIn('timing_profile_line_range(', fragment)
                if 'raster_position(' in fragment or 'raster_line_range(' in fragment:
                    self.assertIn('timing_profile_raster_descriptor(', vertex)

    def test_unprofiled_palm_parameter_sets_fall_back_to_ntsc(self):
        for system in ('sfc', 'md'):
            root = ROOT / 'presetdata' / 'params' / 'sys' / system
            with self.subTest(system=system):
                ntsc = json.loads((root / 'ntsc.json').read_text(encoding='utf-8'))
                palm = json.loads((root / 'palm.json').read_text(encoding='utf-8'))
                self.assertEqual(palm, ntsc)

    def test_profile_pipeline_timing_passes_resolve_profiles(self):
        names = set()
        for preset_name in ('sfc-rgb', 'sfc-svideo', 'sfc-composite', 'snes-eu-composite', 'psx-rgb'):
            path = ROOT / 'presetdata' / 'input' / 'professional' / f'{preset_name}.json'
            preset = json.loads(path.read_text(encoding='utf-8'))
            for pipeline_name in preset['pipelines']:
                pipeline = json.loads((ROOT / 'presetdata' / 'pipelines' / pipeline_name).read_text(encoding='utf-8'))
                names.update(pipeline['shaders'].values())

        def source_tree(path, seen):
            if path in seen:
                return ''
            seen.add(path)
            if path == ROOT / 'shaders' / 'timing-profiles.inc':
                return timing_profile_source()
            if path == ROOT / 'shaders' / 'filter-taps.inc':
                return ''
            source = path.read_text(encoding='utf-8')
            includes = re.findall(r'^\s*#include\s+"([^"]+)"', source, re.MULTILINE)
            return source + '\n' + '\n'.join(source_tree(path.parent / name, seen) for name in includes)

        fields = re.compile(
            r'\b(?:config|global)\.(?:SC_FREQ_MODE|PIXEL_CLOCK_MODE|H_FREQ_MODE|H_FREQ|'
            r'V_FREQ_MODE|V_FREQ|SHORTEN_ODD_FIELD_TIME)\b'
        )
        for name in sorted(names):
            source = source_tree(ROOT / 'shaders' / f'{name}.slang', set())
            uses = [line for line in source.splitlines() if fields.search(line)]
            if not uses:
                continue
            with self.subTest(shader=name):
                self.assertIn('timing_profile_select(global.TIMING_PROFILE', source)
                self.assertTrue(all('timing_profile_' in line for line in uses), uses)
                clock_parts = [
                    line for line in source.splitlines()
                    if 'timing_decimal_value' in line
                    and re.search(r'vec3\((?:config|global)\.PIXEL_CLOCK_WHOLE\b', line)
                ]
                self.assertTrue(all('timing_profile_pixel_value' in line for line in clock_parts), clock_parts)

    def test_generated_presets_select_profile_and_preserve_legacy_famicom(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            shutil.copytree(ROOT / 'shaders', output / 'shaders')
            self.prepare_generated_includes(output)
            for name, result_name, expected in (
                ('sfc-rgb', 'sfc', {'TIMING_PROFILE': 1.0}),
                ('snes-eu-composite', 'snes-eu', {'TIMING_PROFILE': 1.0}),
                ('psx-rgb', 'psx', {'TIMING_PROFILE': 2.0}),
                ('3do-eu-svideo', '3do-eu', {}),
                ('famicom-c1', 'famicom-c1', {'H_FREQ': 1364.0, 'SHORTEN_ODD_FIELD_TIME': 1.0}),
            ):
                command = [
                    sys.executable, str(ROOT / 'external' / 'presetgen' / 'presetgen.py'),
                    '--input', str(ROOT / 'presetdata' / 'input' / 'professional' / f'{name}.json'),
                    '--output', str(output), '--config', str(ROOT / 'presetdata' / 'presetgen.json'),
                ]
                subprocess.run(command, capture_output=True, text=True, check=True)
                preset = (output / 'presets' / 'professional' / f'{result_name}.slangp').read_text(encoding='utf-8')
                values = {
                    key.strip(): value.strip().strip('"')
                    for line in preset.splitlines() if '=' in line
                    for key, value in [line.split('=', 1)]
                }
                with self.subTest(preset=name):
                    for key, value in expected.items():
                        self.assertEqual(float(values[key]), value)
                    self.assertNotIn('DECODER_TYPE', values)
                    self.assertNotIn('PAL', values)
                    if name in ('sfc-rgb', 'snes-eu-composite'):
                        self.assertNotIn('H_FREQ', values)


if __name__ == '__main__':
    unittest.main()
