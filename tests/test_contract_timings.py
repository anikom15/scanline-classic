import json
import math
import re
import shutil
import subprocess
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path

from test_dyadic_pyramid import shader_function


ROOT = Path(__file__).resolve().parent.parent
TIMING_PARAMETERS = (
    'SC_FREQ_MODE', 'SC_FREQ_WHOLE', 'SC_FREQ_FRAC6', 'SC_FREQ_FRAC11',
    'PIXEL_CLOCK_MODE', 'PIXEL_CLOCK_WHOLE', 'PIXEL_CLOCK_FRAC6', 'PIXEL_CLOCK_FRAC11',
    'H_FREQ_MODE', 'H_FREQ', 'V_FREQ_MODE', 'V_FREQ',
    'SHORTEN_ODD_FIELD_TIME', 'FIELD_ODD', 'PHASE_ZERO',
)

# https://www.scanlineclassic.com/theory/timings.html, SFC/SNES.
# Field lengths are ordered by the reference's first field: NTSC even, PAL odd.
REFERENCES = {
    'ntsc': {
        'preset': 'sfc-rgb.json',
        'subcarrier_hz': Fraction(3_579_545),
        'clock_hz': 21_477_270,
        'carrier_per_clock': Fraction(1, 6),
        'field_clocks': {False: (357_368, 357_364), True: (358_732, 357_368)},
        'lines': {False: (262, 262), True: (263, 262)},
    },
    'pal': {
        'preset': 'snes-eu-composite.json',
        'subcarrier_hz': Fraction(17_734_475, 4),
        'clock_hz': 21_281_370,
        'carrier_per_clock': Fraction(5, 24),
        'field_clocks': {False: (425_568, 425_568), True: (425_572, 426_932)},
        'lines': {False: (312, 312), True: (312, 313)},
    },
}
NORMAL_LINE_CLOCKS = 1364
FIELD_COUNTS = (0, 1, 2, 3, 7, 100, 10_000, 16_777_216, 16_777_217, 4_294_967_295)
PHASE_OFFSETS = (0, 90)
MODES = ((256, 224), (256, 239), (512, 224), (512, 239),
         (256, 448), (256, 478), (512, 448), (512, 478))


def load_sfc_timing_parameters(preset_name):
    preset_path = ROOT / 'presetdata' / 'input' / 'professional' / preset_name
    preset = json.loads(preset_path.read_text(encoding='utf-8'))
    defaults = (ROOT / 'shaders' / 'menus' / 'parameters' / 'sys-timing.inc').read_text(encoding='utf-8')
    parameters = {}
    for name in TIMING_PARAMETERS:
        match = re.search(r'^#pragma parameter ' + name + r' "[^"]*" (\S+)', defaults, re.MULTILINE)
        if match is None:
            raise ValueError(f'Missing shader default for {name}')
        parameters[name] = float(match.group(1))

    frame_shaders = []
    for pipeline_name in preset['pipelines']:
        pipeline = json.loads((ROOT / 'presetdata' / 'pipelines' / pipeline_name).read_text(encoding='utf-8'))
        frame_shaders.extend(shader for stage, shader in pipeline['shaders'].items() if stage == 'frame')
        parameters.update({k: v for k, v in pipeline.get('parameters', {}).items() if k in parameters})
    if not frame_shaders or frame_shaders[0] != 'frameh':
        raise ValueError(f'Unexpected SFC frame shader: {frame_shaders}')

    for parameter_set in preset['parameter_sets']:
        data = json.loads((ROOT / 'presetdata' / 'params' / parameter_set).read_text(encoding='utf-8'))
        parameters.update({k: v for k, v in data['parameters'].items() if k in parameters})
    if preset.get('parameter_overrides'):
        raise ValueError('SFC parameter overrides require explicit preset-generator handling')
    return parameters


def cpp_shader_source():
    common = (ROOT / 'shaders' / 'common.inc').read_text(encoding='utf-8')
    modulation = (ROOT / 'shaders' / 'modulation.inc').read_text(encoding='utf-8')
    contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
    declarations = []
    for source, name in (
        (common, 'EPS'), (modulation, 'NTSC_FSC'), (modulation, 'PAL_FSC'),
        (modulation, 'PAL_M_FSC'), (modulation, 'NTSC_H_FREQ'),
        (modulation, 'PAL_H_FREQ'), (modulation, 'PAL_M_H_FREQ'),
    ):
        match = re.search(r'^(?:const float |#define )' + name + r'\b[^\n]*', source, re.MULTILINE)
        if match is None:
            raise ValueError(f'Missing shader declaration for {name}')
        declarations.append(match.group())

    functions = [
        shader_function(modulation, signature)
        for signature in (
            'void compute_subcarrier_freq(', 'float compute_pixel_clock(',
            'float compute_h_freq(', 'void compute_v_lines_per_field(',
        )
    ]
    functions.extend(
        shader_function(contract, signature)
        for signature in (
            'bool timing_valid_parts(', 'double timing_decimal_ticks(', 'double timing_add_mod(',
            'double timing_remainder(', 'double timing_multiply_mod(',
            'double timing_fractional_clock_phase(',
            'float contract_subcarrier_freq_hz(', 'float contract_pixel_clock(',
            'float contract_fs_original(', 'float contract_h_frequency(',
            'float contract_clocks_per_line(', 'float contract_frame_width(',
            'float contract_frame_height(', 'float contract_full_frame_height(',
            'float contract_is_interlaced(', 'float contract_field_parity(',
            'float contract_initial_field_phase_frac(',
            'float contract_initial_subcarrier_phase_frac(',
        )
    )
    source = '\n'.join(declarations + functions)
    source = re.sub(r'\bout (float|int|bool)\s+(\w+)', r'\1& \2', source)
    # GLSL decimal literals are float unless explicitly suffixed with lf.
    return re.sub(
        r'(?<![\w.])(\d+\.\d+(?:[eE][+-]?\d+)?)(lf)?\b',
        lambda match: match.group(1) + ('' if match.group(2) else 'f'),
        source,
    )


CPP_HEADER = r'''
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
using std::max;
using std::round;
using std::ceil;
using std::floor;
using uint = unsigned int;
struct vec2 { float x, y; };
struct vec3 { float x, y, z; };
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
float fract(float x) { return x - std::floor(x); }
double fract(double x) { return x - std::floor(x); }
'''

CPP_MAIN = r'''
int main() {
    float width, height, fps, sc_mode, pc_mode, h_mode, h, v_mode, v, shorten, field_odd, phase;
    vec3 sc_parts, pc_parts;
    if (!(std::cin >> width >> height >> fps >> sc_mode >> sc_parts.x >> sc_parts.y >> sc_parts.z
                   >> pc_mode >> pc_parts.x >> pc_parts.y >> pc_parts.z
                   >> h_mode >> h >> v_mode >> v >> shorten >> field_odd >> phase)) return 1;
    float sc = sc_parts.x + sc_parts.y * 1.0e-6f + sc_parts.z * 1.0e-11f;
    float pc = pc_parts.x + pc_parts.y * 1.0e-6f + pc_parts.z * 1.0e-11f;
    vec2 size{width, height};
    std::cout << std::setprecision(17)
        << contract_subcarrier_freq_hz(fps, sc_mode, sc) << ' '
        << contract_pixel_clock(pc_mode, pc, sc_mode, sc, fps) << ' '
        << contract_fs_original(fps, sc_mode, sc, pc_mode, pc) << ' '
        << contract_h_frequency(fps, sc_mode, sc, pc_mode, pc, h_mode, h) << ' '
        << contract_clocks_per_line(fps, sc_mode, sc, pc_mode, pc, h_mode, h) << ' '
        << contract_frame_width(fps, sc_mode, sc, pc_mode, pc, h_mode, h) << ' '
        << contract_frame_height(size, fps, v_mode, v, sc_mode, sc, pc_mode, pc, h_mode, h) << ' '
        << contract_full_frame_height(size, fps, v_mode, v, sc_mode, sc, pc_mode, pc, h_mode, h) << ' '
        << contract_is_interlaced(size, fps, v_mode, v, sc_mode, sc, pc_mode, pc, h_mode, h);
    uint field;
    while (std::cin >> field) {
        std::cout << ' ' << contract_initial_subcarrier_phase_frac(
            size, fps, field, pc_mode, pc, sc_mode, sc, h_mode, h, v_mode, v, shorten, field_odd,
            pc_parts, sc_parts, phase)
            << ' ' << contract_initial_field_phase_frac(
            size, fps, field, pc_mode, pc, sc_mode, sc, h_mode, h, v_mode, v, phase)
            << ' ' << contract_field_parity(field, field_odd, fps, sc_mode, sc);
    }
    std::cout << '\n';
}
'''


def reference_phase(region, interlaced, field_count, phase_zero=0, reverse=False, shorten=True):
    reference = REFERENCES[region]
    first, second = reference['field_clocks'][interlaced]
    if not shorten:
        if region == 'ntsc' and not interlaced:
            second += 4
        if region == 'pal' and interlaced:
            first -= 4
    if reverse:
        first, second = second, first
    clocks = (field_count // 2) * (first + second) + (field_count % 2) * first
    return (float((clocks * reference['carrier_per_clock']) % 1) + phase_zero / 360) % 1


def phase_distance(actual, expected):
    return abs((actual - expected + 0.5) % 1.0 - 0.5)


class SfcContractTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('g++')
        if compiler is None:
            raise unittest.SkipTest('g++ is required to exercise shader functions')
        cls.parameters = {
            region: load_sfc_timing_parameters(reference['preset'])
            for region, reference in REFERENCES.items()
        }
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        source = Path(temporary.name) / 'contract.cpp'
        cls.executable = Path(temporary.name) / 'contract-test'
        source.write_text(CPP_HEADER + cpp_shader_source() + CPP_MAIN, encoding='utf-8')
        subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(cls.executable)], check=True)

        cls.results = {}
        for region in REFERENCES:
            for mode in MODES:
                for offset in PHASE_OFFSETS:
                    for reverse in (False, True):
                        cls.results[(region, mode, offset, reverse)] = cls.run_case(region, mode, offset, reverse)

    @classmethod
    def run_case(cls, region, mode, offset=0, reverse=False, parameters=None):
        reference = REFERENCES[region]
        interlaced = mode[1] > 300
        fps = 2 * reference['clock_hz'] / sum(reference['field_clocks'][interlaced])
        settings = dict(cls.parameters[region] if parameters is None else parameters)
        settings['PHASE_ZERO'] = (settings['PHASE_ZERO'] + offset) % 360
        settings['FIELD_ODD'] = float(reverse)
        inputs = [*mode, fps]
        inputs.extend(settings[name] for name in TIMING_PARAMETERS)
        inputs.extend(FIELD_COUNTS)
        output = subprocess.run(
            [str(cls.executable)], input=' '.join(map(str, inputs)), text=True,
            capture_output=True, check=True,
        ).stdout
        values = [float(value) for value in output.split()]
        if len(values) != 9 + 3 * len(FIELD_COUNTS):
            raise ValueError(f'Unexpected contract output for {region} {mode}: {output!r}')
        return values

    def test_sfc_clocks_and_geometry(self):
        for (region, mode, offset, reverse), values in self.results.items():
            with self.subTest(region=region, mode=mode, offset=offset, reverse=reverse):
                reference = REFERENCES[region]
                subcarrier, clock, fs, horizontal, clocks, frame_width = values[:6]
                self.assertAlmostEqual(subcarrier, float(reference['subcarrier_hz']), delta=0.5)
                self.assertAlmostEqual(clock, reference['clock_hz'], delta=2.0)
                self.assertAlmostEqual(fs, reference['clock_hz'], delta=2.0)
                self.assertAlmostEqual(horizontal, reference['clock_hz'] / NORMAL_LINE_CLOCKS, delta=0.01)
                self.assertEqual(clocks, NORMAL_LINE_CLOCKS)
                self.assertEqual(frame_width, NORMAL_LINE_CLOCKS)

    def test_reference_phase_sequences(self):
        examples = {
            ('ntsc', False): (0, Fraction(1, 3), 0, Fraction(1, 3)),
            ('ntsc', True): (0, Fraction(2, 3), 0, Fraction(2, 3)),
            ('pal', False): (0, 0, 0, 0),
            ('pal', True): (0, Fraction(5, 6), 0, Fraction(5, 6)),
        }
        for (region, interlaced), phases in examples.items():
            for field, expected in enumerate(phases):
                with self.subTest(region=region, interlaced=interlaced, field=field):
                    self.assertAlmostEqual(reference_phase(region, interlaced, field), float(expected))
        for region, interlaced, expected in (
            ('ntsc', False, Fraction(2, 3)), ('ntsc', True, Fraction(1, 3)),
            ('pal', False, 0), ('pal', True, Fraction(1, 6)),
        ):
            with self.subTest(region=region, interlaced=interlaced, reverse=True):
                self.assertAlmostEqual(reference_phase(region, interlaced, 1, reverse=True), float(expected))

    def test_initial_field_phase(self):
        for (region, mode, offset, reverse), values in self.results.items():
            phase_zero = (self.parameters[region]['PHASE_ZERO'] + offset) % 360
            for index, field in enumerate(FIELD_COUNTS):
                with self.subTest(region=region, mode=mode, offset=offset, reverse=reverse, field=field):
                    actual = values[10 + 3 * index]
                    self.assertLessEqual(phase_distance(actual, phase_zero / 360), 1e-5)

    def test_field_parity(self):
        for (region, mode, offset, reverse), values in self.results.items():
            for index, field in enumerate(FIELD_COUNTS):
                with self.subTest(region=region, mode=mode, offset=offset, reverse=reverse, field=field):
                    expected = (field % 2 + (region == 'pal') + reverse) % 2
                    self.assertEqual(values[11 + 3 * index], expected)

    def test_interlace_detection_uses_field_capacity(self):
        for region in REFERENCES:
            for height, expected in ((256, 0), (320, 1)):
                with self.subTest(region=region, height=height):
                    values = self.run_case(region, (256, height))
                    self.assertEqual(values[8], expected)

    def test_field_adjustment_can_be_disabled(self):
        for region, mode in (('ntsc', (256, 224)), ('pal', (256, 478))):
            for reverse in (False, True):
                parameters = dict(self.parameters[region])
                parameters['SHORTEN_ODD_FIELD_TIME'] = 0
                values = self.run_case(region, mode, reverse=reverse, parameters=parameters)
                for index, field in enumerate(FIELD_COUNTS):
                    with self.subTest(region=region, reverse=reverse, field=field):
                        expected = reference_phase(region, mode[1] > 300, field, reverse=reverse, shorten=False)
                        self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1e-5)

    def test_famicom_progressive_timing(self):
        parameters = load_sfc_timing_parameters('famicom-c1.json')
        for height in (224, 240):
            for reverse in (False, True):
                values = self.run_case('ntsc', (256, height), reverse=reverse, parameters=parameters)
                for index, field in enumerate(FIELD_COUNTS):
                    with self.subTest(height=height, reverse=reverse, field=field):
                        expected = reference_phase('ntsc', False, field, reverse=reverse)
                        self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1e-5)

    def test_phase_wraps_at_nonzero_offset(self):
        for region in REFERENCES:
            for mode in ((256, 224), (256, 478)):
                for reverse in (False, True):
                    values = self.run_case(region, mode, 359, reverse)
                    for index, field in enumerate(FIELD_COUNTS[:4]):
                        with self.subTest(region=region, mode=mode, reverse=reverse, field=field):
                            expected = reference_phase(region, mode[1] > 300, field, 359, reverse)
                            self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1e-5)

    def test_fixed_pixel_clock_uses_physical_field_lengths(self):
        parameters = dict(self.parameters['pal'])
        parameters['PIXEL_CLOCK_MODE'] = 0
        parameters['PIXEL_CLOCK_WHOLE'] = 21
        parameters['PIXEL_CLOCK_FRAC6'] = 281370
        parameters['PIXEL_CLOCK_FRAC11'] = 0
        for reverse in (False, True):
            values = self.run_case('pal', (256, 478), reverse=reverse, parameters=parameters)
            ratio = Fraction(5, 24)
            first, second = REFERENCES['pal']['field_clocks'][True]
            if reverse:
                first, second = second, first
            for index, field in enumerate(FIELD_COUNTS):
                clocks = (field // 2) * (first + second) + (field % 2) * first
                expected = float((clocks * ratio) % 1)
                with self.subTest(reverse=reverse, field=field):
                    self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1e-5)

    def test_other_presets_use_their_declared_rational_clocks(self):
        cases = (
            ('pal', ('n64', 'base'), ('n64', 'pal'), Fraction(5, 56), 3178, 313),
            ('pal', ('md', 'base'), ('md', 'pal'), Fraction(443361866667, 5320342400000), 3420, 313),
            ('ntsc', ('3do', 'base'), ('3do', 'ntsc'), Fraction(357954500, 2454545454), 1560, 262),
        )
        for standard, base, preset, ratio, width, lines in cases:
            parameters = dict(self.parameters[standard])
            for parts in (base, preset):
                path = ROOT.joinpath('presetdata', 'params', 'sys', *parts).with_suffix('.json')
                parameters.update(json.loads(path.read_text(encoding='utf-8'))['parameters'])
            parameters.update(V_FREQ_MODE=3, V_FREQ=lines, SHORTEN_ODD_FIELD_TIME=0)
            for reverse in (False, True):
                for interlaced in (False, True):
                    values = self.run_case(
                        standard, (256, 478 if interlaced else 224), reverse=reverse, parameters=parameters
                    )
                    self.assertEqual(values[4], width)
                    if interlaced:
                        first = lines - 1 if standard == 'pal' else lines + 1
                        second = lines
                        if reverse:
                            first, second = second, first
                    else:
                        first = second = lines
                    for index, field in enumerate(FIELD_COUNTS):
                        clocks = width * ((field // 2) * (first + second) + field % 2 * first)
                        expected = float((clocks * ratio) % 1)
                        with self.subTest(system=base[0], reverse=reverse, interlaced=interlaced, field=field):
                            self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1e-5)

    def test_fractional_clock_field_length(self):
        parameters = dict(self.parameters['pal'])
        parameters.update(V_FREQ_MODE=3, V_FREQ=312.125, SHORTEN_ODD_FIELD_TIME=0)
        values = self.run_case('pal', (256, 224), parameters=parameters)
        for index, field in enumerate(FIELD_COUNTS):
            expected = float((field * Fraction(312125, 1000) * 1364 * Fraction(5, 24)) % 1)
            with self.subTest(field=field):
                self.assertLessEqual(phase_distance(values[9 + 3 * index], expected), 1 / 360)

    def test_fractional_clock_phase_with_large_carrier_ratio(self):
        source = self.executable.with_name('fractional-phase.cpp')
        executable = self.executable.with_name('fractional-phase')
        source.write_text(CPP_HEADER + cpp_shader_source() + r'''
int main() {
    double numerator, denominator, fraction;
    uint fields;
    while (std::cin >> numerator >> denominator >> fraction >> fields)
        std::cout << std::setprecision(17)
                  << fract(timing_fractional_clock_phase(fraction, numerator, denominator) * double(fields)) << '\n';
}
''', encoding='utf-8')
        subprocess.run([shutil.which('g++'), '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
        cases = (
            (100000000000, 3, Fraction(1, 8), 4_294_967_295),
            (443361866667, 5320342400000, Fraction(32767, 32768), 4_294_967_295),
        )
        inputs = ''.join(f'{num} {den} {float(fraction)} {fields}\n' for num, den, fraction, fields in cases)
        result = subprocess.run([str(executable)], input=inputs, text=True, capture_output=True, check=True)
        for (num, den, fraction, fields), actual in zip(cases, result.stdout.split(), strict=True):
            expected = float((Fraction(num, den) * fraction * fields) % 1)
            self.assertLessEqual(phase_distance(float(actual), expected), 1 / 360)

    def test_invalid_clock_parts_produce_invalid_phase(self):
        for overrides in (
            dict(PIXEL_CLOCK_MODE=0, PIXEL_CLOCK_WHOLE=0, PIXEL_CLOCK_FRAC6=0, PIXEL_CLOCK_FRAC11=0),
            dict(PIXEL_CLOCK_FRAC6=1.5),
            dict(SC_FREQ_MODE=4, SC_FREQ_WHOLE=0, SC_FREQ_FRAC6=0, SC_FREQ_FRAC11=0),
        ):
            parameters = dict(self.parameters['pal'])
            parameters.update(overrides)
            with self.subTest(overrides=overrides):
                values = self.run_case('pal', (256, 224), parameters=parameters)
                self.assertTrue(math.isnan(values[9]))

    def test_disabled_subcarrier_preserves_initial_phase(self):
        for region in REFERENCES:
            parameters = dict(self.parameters[region])
            parameters['SC_FREQ_MODE'] = 5
            for reverse in (False, True):
                values = self.run_case(region, (256, 478), 90, reverse, parameters)
                for index, field in enumerate(FIELD_COUNTS):
                    with self.subTest(region=region, reverse=reverse, field=field):
                        self.assertLessEqual(phase_distance(values[9 + 3 * index], 0.25), 1e-5)
                        self.assertEqual(values[11 + 3 * index], (field % 2 + (region == 'pal') + reverse) % 2)


def make_phase_test(region, mode, offset, reverse, field):
    def test_phase(self):
        actual = self.results[(region, mode, offset, reverse)][9 + 3 * FIELD_COUNTS.index(field)]
        phase_zero = (self.parameters[region]['PHASE_ZERO'] + offset) % 360
        expected = reference_phase(region, mode[1] > 300, field, phase_zero, reverse)
        distance = phase_distance(actual, expected)
        self.assertLessEqual(
            distance, 1e-5,
            f'{region} {mode[0]}x{mode[1]}, field {field}: expected phase {expected}, got {actual}',
        )
    return test_phase


def make_geometry_test(region, mode, index):
    def test_geometry(self):
        interlaced = mode[1] > 300
        lines = REFERENCES[region]['lines'][interlaced]
        expected = (sum(lines) / 2, sum(lines) if interlaced else lines[0], float(interlaced))
        actual = self.results[(region, mode, 0, False)][6 + index]
        self.assertEqual(actual, expected[index], f'{region} {mode}: geometry property {index}')
    return test_geometry


for region in REFERENCES:
    for mode in MODES:
        for index, name in enumerate(('field_height', 'full_height', 'interlaced')):
            test = make_geometry_test(region, mode, index)
            setattr(SfcContractTimingTests, f'test_{name}_{region}_{mode[0]}x{mode[1]}', test)
        for offset in PHASE_OFFSETS:
            for reverse in (False, True):
                for field in FIELD_COUNTS:
                    test = make_phase_test(region, mode, offset, reverse, field)
                    setattr(
                        SfcContractTimingTests,
                        f'test_phase_{region}_{mode[0]}x{mode[1]}_offset_{offset}_reverse_{int(reverse)}_field_{field}',
                        test,
                    )


if __name__ == '__main__':
    unittest.main()
