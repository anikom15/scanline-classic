import copy
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
from test_contract_timings import (
    CPP_HEADER, CPP_MAIN, FIELD_COUNTS, OUTPUT_MODES, REFERENCES, ROOT,
    cpp_shader_source, phase_distance,
)


class TimingProfileGenerationTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))

    def test_checked_in_shader_matches_catalog(self):
        generated = generate_source(self.data)
        actual = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        self.assertEqual(actual, generated)

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
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(top_blank_lines=-1),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(top_blank_lines=262),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(left_blank_cycles=1364),
            lambda data: data['profiles'][0]['modes'][0]['raster'].update(left_blank_cycles=1.5),
            lambda data: data['profiles'][0]['modes'][0]['field_lines']['interlaced'].update(even=0),
            lambda data: data['profiles'][0]['modes'][0]['field_lines']['progressive'].update(odd=True),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(line=263),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(clocks=0),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'][0].update(clocks=1361),
            lambda data: data['profiles'][0]['modes'][0]['line_overrides'].append(
                copy.deepcopy(data['profiles'][0]['modes'][0]['line_overrides'][0])),
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
            source = re.sub(r'(?<=\d)lf\b', '', generate_source(rules_data if custom_rules else data))
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
        for profile, width, height, fps in ((2, 256, 224, 60), (1, 0, 224, 60), (1, 256, 224, 0)):
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
                                exception = (241, -4)
                            elif odd and interlaced and region == 'pal':
                                exception = (312, 4)
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
        mode['line_overrides'].append({'scan': 'progressive', 'field': 'odd', 'line': 242, 'clocks': 1367})
        mode['field_clocks']['progressive']['odd'] += 3
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'multiple-lines.cpp'
            executable = Path(temp) / 'multiple-lines'
            source.write_text(CPP_HEADER + cpp_shader_source(generate_source(data)) + r'''
#include <stdexcept>
int main() {
    float width = 2047;
    vec2 first = timing_profile_line_range(1, 239, 1, 0, 240, width);
    vec2 second = timing_profile_line_range(1, 239, 1, 0, 241, width);
    vec2 third = timing_profile_line_range(1, 239, 1, 0, 242, width);
    if (first.x != 240*width || first.y != width-6 ||
        second.x != 241*width-6 || second.y != width+5 ||
        third.x != 242*width-1 || third.y != width)
        throw std::runtime_error("multiple line adjustments are not cumulative");
    vec2 at_second = timing_profile_raster_position(1, 239, 1, 0, second.x, width);
    vec2 at_third = timing_profile_raster_position(1, 239, 1, 0, third.x, width);
    if (at_second.x != 0 || at_second.y != 241 || at_third.x != 0 || at_third.y != 242 ||
        timing_profile_storage_length(1, 239, 1, 0, width, 262*width) != 262*width-1)
        throw std::runtime_error("multiple line positions or field length are incorrect");
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
    def test_sfc_pipeline_timing_passes_resolve_profiles(self):
        names = set()
        for preset_name in ('sfc-rgb', 'sfc-svideo', 'sfc-composite', 'snes-eu-composite'):
            path = ROOT / 'presetdata' / 'input' / 'professional' / f'{preset_name}.json'
            preset = json.loads(path.read_text(encoding='utf-8'))
            for pipeline_name in preset['pipelines']:
                pipeline = json.loads((ROOT / 'presetdata' / 'pipelines' / pipeline_name).read_text(encoding='utf-8'))
                names.update(pipeline['shaders'].values())

        def source_tree(path, seen):
            if path in seen:
                return ''
            seen.add(path)
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
            for name, result_name, expected in (
                ('sfc-rgb', 'sfc', {'TIMING_PROFILE': 1.0}),
                ('snes-eu-composite', 'snes-eu', {'TIMING_PROFILE': 1.0}),
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
                    if name != 'famicom-c1':
                        self.assertNotIn('H_FREQ', values)


if __name__ == '__main__':
    unittest.main()
