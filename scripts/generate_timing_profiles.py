"""Validate timing profile data and generate shared shader selection code."""

import json
import math
import re
from fractions import Fraction
from pathlib import Path


STANDARDS = {
    'ntsc': (1, 3_579_545),
    'pal': (2, 4_433_618.75),
    'palm': (3, 3_575_611),
}
RULE_INPUTS = {
    'fps': 'fps',
    'width': 'size.x',
    'height': 'size.y',
    'area': '(size.x * size.y)',
}


def _number(value, name, minimum=None):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f'{name} must be finite')
    if minimum is not None and value < minimum:
        raise ValueError(f'{name} must be at least {minimum}')
    return value


def _glsl(value):
    text = str(value)
    return text if '.' in text or 'e' in text.lower() else text + '.0'


def _field_clocks(value, name):
    if type(value) is int:
        numerator, denominator = value, 1
    elif isinstance(value, list) and len(value) == 2:
        numerator, denominator = value
    else:
        raise ValueError(f'{name} must be an integer or [numerator, denominator]')
    if (type(numerator) is not int or type(denominator) is not int or
            numerator <= 0 or denominator <= 0):
        raise ValueError(f'{name} must be a positive rational')
    fraction = Fraction(numerator, denominator)
    if fraction.numerator >= 2**52 or fraction.denominator > 2**20:
        raise ValueError(f'{name} exceeds exact shader arithmetic limits')
    return fraction


def generate_source(data):
    profiles = data['profiles']
    if not isinstance(profiles, list) or not profiles:
        raise ValueError('At least one timing profile is required')
    ids = set()
    names = set()
    mode_indices = {}
    modes = []
    for profile in profiles:
        profile_id = profile['id']
        name = profile['name']
        if type(profile_id) is not int or not 1 <= profile_id <= 16_777_216 or profile_id in ids:
            raise ValueError(f'Invalid or duplicate profile ID: {profile_id}')
        if not isinstance(name, str) or not re.fullmatch(r'[a-z][a-z0-9_]*', name) or name in names:
            raise ValueError(f'Invalid or duplicate profile name: {name}')
        ids.add(profile_id)
        names.add(name)
        local_names = set()
        if not isinstance(profile['modes'], list) or not profile['modes']:
            raise ValueError(f'{name} must contain at least one mode')
        for mode in profile['modes']:
            mode_name = mode['name']
            if not isinstance(mode_name, str) or not re.fullmatch(r'[a-z][a-z0-9_]*', mode_name) or mode_name in local_names:
                raise ValueError(f'Invalid or duplicate mode name in {name}: {mode_name}')
            local_names.add(mode_name)
            standard = mode['standard']
            if standard not in STANDARDS or mode['subcarrier_hz'] != STANDARDS[standard][1]:
                raise ValueError(f'Invalid standard or subcarrier for {name}/{mode_name}')
            parts = mode['pixel_clock_multiplier']
            if (not isinstance(parts, list) or len(parts) != 2 or
                    any(type(part) is not int or part <= 0 for part in parts)):
                raise ValueError(f'Invalid clock multiplier for {name}/{mode_name}')
            multiplier = Fraction(*parts)
            if multiplier > 500 or multiplier.numerator > 2**24 or multiplier.denominator > 2**24:
                raise ValueError(f'Clock multiplier exceeds shader limits for {name}/{mode_name}')
            if type(mode['clocks_per_line']) is not int or mode['clocks_per_line'] <= 0:
                raise ValueError(f'Invalid clocks_per_line for {name}/{mode_name}')
            raster = mode['raster']
            if _number(raster['interlace_height_threshold'], f'{name}/{mode_name} interlace height threshold') <= 0:
                raise ValueError(f'Invalid interlace height threshold for {name}/{mode_name}')
            for key in ('vertical_sync_lines', 'vertical_back_porch_lines',
                        'horizontal_sync_cycles', 'horizontal_back_porch_cycles'):
                if type(raster[key]) is not int or raster[key] < 0:
                    raise ValueError(f'Invalid {key} for {name}/{mode_name}')
            left_blank = raster['horizontal_sync_cycles'] + raster['horizontal_back_porch_cycles']
            top_blank = raster['vertical_sync_lines'] + raster['vertical_back_porch_lines']
            if left_blank >= mode['clocks_per_line']:
                raise ValueError(f'Left blanking exceeds line length for {name}/{mode_name}')
            for scan in ('progressive', 'interlaced'):
                for parity in ('even', 'odd'):
                    if _number(mode['field_lines'][scan][parity], f'{name}/{mode_name} {scan} {parity} lines') <= 0:
                        raise ValueError(f'Invalid field lines for {name}/{mode_name}')
                    if top_blank >= mode['field_lines'][scan][parity]:
                        raise ValueError(f'Top blanking exceeds field length for {name}/{mode_name}')
                    _field_clocks(mode['field_clocks'][scan][parity], f'{name}/{mode_name} {scan} {parity}')
            overrides = mode.get('line_overrides', [])
            if not isinstance(overrides, list):
                raise ValueError(f'Invalid line overrides for {name}/{mode_name}')
            seen_lines = set()
            for override in overrides:
                if not isinstance(override, dict) or set(override) != {'scan', 'field', 'line', 'clocks'}:
                    raise ValueError(f'Invalid line override for {name}/{mode_name}')
                scan, parity, line, clocks = (override[key] for key in ('scan', 'field', 'line', 'clocks'))
                if (scan not in ('progressive', 'interlaced') or parity not in ('even', 'odd')
                        or type(line) is not int or type(clocks) is not int
                        or line <= 0 or line > mode['field_lines'][scan][parity]
                        or not left_blank < clocks <= 2**24 or (scan, parity, line) in seen_lines):
                    raise ValueError(f'Invalid line override for {name}/{mode_name}')
                seen_lines.add((scan, parity, line))
            for scan in ('progressive', 'interlaced'):
                for parity in ('even', 'odd'):
                    changes = [entry for entry in overrides if entry['scan'] == scan and entry['field'] == parity]
                    if changes:
                        expected = mode['clocks_per_line'] * mode['field_lines'][scan][parity]
                        expected += sum(entry['clocks'] - mode['clocks_per_line'] for entry in changes)
                        if _field_clocks(mode['field_clocks'][scan][parity], 'field clocks') != expected:
                            raise ValueError(f'Line overrides contradict field clocks for {name}/{mode_name}')
            if mode['first_field'] not in ('even', 'odd'):
                raise ValueError(f'Invalid first field for {name}/{mode_name}')
            if type(mode['field_adjustment']) is not bool:
                raise ValueError(f'Invalid field adjustment for {name}/{mode_name}')
            _number(mode['initial_phase_degrees'], 'initial phase')
            modes.append(mode)
            mode_indices[(name, mode_name)] = len(modes)
        if profile['default'] not in local_names:
            raise ValueError(f'Missing default mode in {name}')
        if profile['primary'] not in local_names:
            raise ValueError(f'Missing primary mode in {name}')
        primary = next(mode for mode in profile['modes'] if mode['name'] == profile['primary'])
        if primary['initial_phase_degrees'] != 0:
            raise ValueError(f'Primary mode in {name} must start at zero phase')
        output_modes = set()
        for output in profile['output_modes']:
            size = output['size']
            targets = output['timing_modes']
            if (not isinstance(size, list) or len(size) != 2 or
                    any(type(value) is not int or value <= 0 for value in size) or
                    type(output['interlaced']) is not bool or
                    not isinstance(targets, list) or not targets or
                    any(not isinstance(target, str) for target in targets) or
                    len(set(targets)) != len(targets) or not set(targets) <= local_names):
                raise ValueError(f'Invalid output mode in {name}')
            for target in targets:
                mode = next(mode for mode in profile['modes'] if mode['name'] == target)
                if output['interlaced'] != (size[1] > mode['raster']['interlace_height_threshold']):
                    raise ValueError(f'Output mode contradicts {name}/{target} field capacity')
                key = (target, *size)
                if key in output_modes:
                    raise ValueError(f'Duplicate output mode in {name}: {key}')
                output_modes.add(key)
        if {key[0] for key in output_modes} != local_names:
            raise ValueError(f'Each timing mode in {name} needs an output mode')
        priorities = set()
        for rule in profile['rules']:
            if rule['mode'] not in local_names or type(rule['priority']) is not int or rule['priority'] in priorities:
                raise ValueError(f'Invalid mode or ambiguous priority in {name}')
            priorities.add(rule['priority'])
            conditions = set(rule) - {'mode', 'priority'}
            if not conditions or not conditions <= {f'{bound}_{key}' for key in RULE_INPUTS for bound in ('min', 'max')}:
                raise ValueError(f'Invalid selection conditions in {name}')
            for key in RULE_INPUTS:
                lower = rule.get(f'min_{key}')
                upper = rule.get(f'max_{key}')
                if lower is not None:
                    _number(lower, f'min_{key}', 0)
                if upper is not None:
                    _number(upper, f'max_{key}', 0)
                if lower is not None and upper is not None and lower > upper:
                    raise ValueError(f'Inverted {key} bounds in {name}')
        remapped_modes = set()
        for remap in profile['remaps']:
            if (remap['from'] not in local_names or remap['to'] not in local_names or
                    remap['from'] in remapped_modes or
                    not re.fullmatch(r'OPTION_[A-Z0-9_]+', remap['option'])):
                raise ValueError(f'Invalid option remap in {name}')
            remapped_modes.add(remap['from'])

    lines = [
        '// Generated by scripts/generate_timing_profiles.py; do not edit.',
        '// Mode 0 retains legacy parameters; -1 is invalid.',
        'int timing_profile_select(float profile_id, vec2 size, float fps)',
        '{',
        '    if (profile_id == 0.0)',
        '        return 0;',
        '    if (!(size.x > 0.0 && size.y > 0.0 && fps > 0.0)',
        '        || isinf(size.x) || isinf(size.y) || isinf(fps))',
        '        return -1;',
    ]
    for profile in profiles:
        name = profile['name']
        lines += [f"    if (profile_id == {_glsl(profile['id'])}) {{",
                  f"        int mode = {mode_indices[(name, profile['default'])]};"]
        for rule in sorted(profile['rules'], key=lambda item: item['priority'], reverse=True):
            conditions = []
            for key, expression in RULE_INPUTS.items():
                for bound, op in (('min', '>='), ('max', '<=')):
                    if f'{bound}_{key}' in rule:
                        conditions.append(f'{expression} {op} {_glsl(rule[f"{bound}_{key}"])}')
            lines += [f"        if ({' && '.join(conditions)})",
                      f"            mode = {mode_indices[(name, rule['mode'])]};"]
        for remap in profile['remaps']:
            lines += [f"#ifdef {remap['option']}",
                      f"        if (mode == {mode_indices[(name, remap['from'])]})",
                      f"            mode = {mode_indices[(name, remap['to'])]};",
                      '#endif']
        lines += ['        return mode;', '    }']
    lines += ['    return -1;', '}', '']

    properties = (
        ('sc_mode', lambda mode: _glsl(STANDARDS[mode['standard']][0])),
        ('pixel_mode', lambda mode: '1.0'),
        ('h_mode', lambda mode: '1.0'),
        ('h_freq', lambda mode: _glsl(mode['clocks_per_line'])),
        ('top_blank_lines', lambda mode: _glsl(mode['raster']['vertical_sync_lines'] + mode['raster']['vertical_back_porch_lines'])),
        ('left_blank_cycles', lambda mode: _glsl(mode['raster']['horizontal_sync_cycles'] + mode['raster']['horizontal_back_porch_cycles'])),
        ('vertical_sync_lines', lambda mode: _glsl(mode['raster']['vertical_sync_lines'])),
        ('horizontal_sync_cycles', lambda mode: _glsl(mode['raster']['horizontal_sync_cycles'])),
        ('field_adjustment', lambda mode: '1.0' if mode['field_adjustment'] else '0.0'),
        ('first_field_odd', lambda mode: '1.0' if mode['first_field'] == 'odd' else '0.0'),
        ('initial_phase', lambda mode: _glsl(mode['initial_phase_degrees'])),
        ('pal', lambda mode: '0.0' if mode['standard'] == 'ntsc' else '1.0'),
    )
    for prop, value in properties:
        lines += [f'float timing_profile_{prop}(int mode, float legacy)', '{',
                  '    if (mode == 0)', '        return legacy;']
        for index, mode in enumerate(modes, 1):
            lines += [f'    if (mode == {index})', f'        return {value(mode)};']
        lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    lines += ['float timing_profile_v_mode(int mode, float height, float legacy)', '{',
              '    if (mode == 0)', '        return legacy;']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        lines += [f'    if (mode == {index})', f'        return height > {threshold} ? 6.0 : 5.0;']
    lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    lines += ['float timing_profile_v_freq(int mode, float height, uint frame_count, float field_odd, float legacy)', '{',
              '    if (mode == 0)', '        return legacy;']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        first = 1 if mode['first_field'] == 'odd' else 0
        prog = mode['field_lines']['progressive']
        inter = mode['field_lines']['interlaced']
        lines += [f'    if (mode == {index}) {{',
                  f'        bool odd = ((frame_count % 2u + {first}u + (field_odd > 0.5 ? 1u : 0u)) % 2u) != 0u;',
                  f"        return height > {threshold} ? (odd ? {_glsl(inter['odd'])} : {_glsl(inter['even'])})",
                  f"            : (odd ? {_glsl(prog['odd'])} : {_glsl(prog['even'])});", '    }']
    lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    lines += ['float timing_profile_full_frame_height(int mode, float height, float legacy)', '{',
              '    if (mode == 0)', '        return legacy;']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        inter = mode['field_lines']['interlaced']
        lines += [f'    if (mode == {index})',
                  f"        return height > {threshold} ? {_glsl(inter['even'] + inter['odd'])} : legacy;"]
    lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    for part in ('numerators', 'denominators'):
        lines += [f'dvec4 timing_profile_field_clock_{part}(int mode)', '{',
                  '    if (mode == 0)', '        return dvec4(-1.0lf);']
        for index, mode in enumerate(modes, 1):
            fractions = [
                _field_clocks(mode['field_clocks'][scan][parity], 'field clocks')
                for scan in ('progressive', 'interlaced') for parity in ('even', 'odd')
            ]
            values = [fraction.numerator if part == 'numerators' else fraction.denominator
                      for fraction in fractions]
            args = ', '.join(f'{value}.0lf' for value in values)
            lines += [f'    if (mode == {index})', f'        return dvec4({args});']
        lines += ['    return dvec4(double(uintBitsToFloat(0x7fc00000u)));', '}', '']
    lines += ['float timing_profile_pixel_value(int mode, float legacy)', '{',
              '    if (mode == 0)', '        return legacy;']
    for index, mode in enumerate(modes, 1):
        ratio = Fraction(*mode['pixel_clock_multiplier'])
        lines += [f'    if (mode == {index})',
                  f'        return {_glsl(ratio.numerator)} / {_glsl(ratio.denominator)};']
    lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    lines += ['float timing_profile_storage_length(int mode, float height, uint frame_count, float field_odd,',
              '    float width, float legacy)', '{', '    if (mode == 0)', '        return legacy;']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        first = 1 if mode['first_field'] == 'odd' else 0
        lines += [f'    if (mode == {index}) {{',
                  f'        bool odd = ((frame_count % 2u + {first}u + (field_odd > 0.5 ? 1u : 0u)) % 2u) != 0u;']
        for scan, parity in (('progressive', 'even'), ('progressive', 'odd'),
                             ('interlaced', 'even'), ('interlaced', 'odd')):
            delta = sum(entry['clocks'] - mode['clocks_per_line'] for entry in mode.get('line_overrides', [])
                        if entry['scan'] == scan and entry['field'] == parity)
            if delta:
                condition = f"height {'>' if scan == 'interlaced' else '<='} {threshold} && {'odd' if parity == 'odd' else '!odd'}"
                lines += [f'        if ({condition})',
                          f"            return legacy + ceil({_glsl(delta)} * width / {_glsl(mode['clocks_per_line'])});"]
        lines += ['        return legacy;', '    }']
    lines += ['    return uintBitsToFloat(0x7fc00000u);', '}', '']
    lines += ['vec2 timing_profile_raster_position(int mode, float height, uint frame_count, float field_odd,',
              '    float sample_index, float width)', '{']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        first = 1 if mode['first_field'] == 'odd' else 0
        lines += [f'    if (mode == {index}) {{',
                  f'        bool odd = ((frame_count % 2u + {first}u + (field_odd > 0.5 ? 1u : 0u)) % 2u) != 0u;']
        for scan, parity in (('progressive', 'even'), ('progressive', 'odd'),
                             ('interlaced', 'even'), ('interlaced', 'odd')):
            changes = sorted((entry for entry in mode.get('line_overrides', [])
                              if entry['scan'] == scan and entry['field'] == parity),
                             key=lambda entry: entry['line'])
            if not changes:
                continue
            condition = f"height {'>' if scan == 'interlaced' else '<='} {threshold} && {'odd' if parity == 'odd' else '!odd'}"
            lines += [f'        if ({condition}) {{']
            cumulative = 0
            for entry in changes:
                line = entry['line'] - 1
                delta = entry['clocks'] - mode['clocks_per_line']
                scale = _glsl(mode['clocks_per_line'])
                start = f'{_glsl(line)} * width + ceil({_glsl(cumulative)} * width / {scale})'
                end = f'{_glsl(line + 1)} * width + ceil({_glsl(cumulative + delta)} * width / {scale})'
                lines += [f'            if (sample_index < {start}) {{',
                          f'                float index = sample_index - ceil({_glsl(cumulative)} * width / {scale});',
                          '                float y = floor(index / width);',
                          '                return vec2(index - y * width, y);', '            }',
                          f'            if (sample_index < {end})',
                          f'                return vec2(sample_index - ({start}), {_glsl(line)});']
                cumulative += delta
            lines += [f'            float index = sample_index - ceil({_glsl(cumulative)} * width / {scale});',
                      '            float y = floor(index / width);',
                      '            return vec2(index - y * width, y);', '        }']
        lines += ['        float y = floor(sample_index / width);',
                  '        return vec2(sample_index - y * width, y);', '    }']
    lines += ['    if (mode == 0) {', '        float y = floor(sample_index / width);',
              '        return vec2(sample_index - y * width, y);', '    }',
              '    return vec2(uintBitsToFloat(0x7fc00000u));', '}', '']
    lines += ['vec2 timing_profile_line_range(int mode, float height, uint frame_count, float field_odd,',
              '    float line, float width)', '{']
    for index, mode in enumerate(modes, 1):
        threshold = _glsl(mode['raster']['interlace_height_threshold'])
        first = 1 if mode['first_field'] == 'odd' else 0
        lines += [f'    if (mode == {index}) {{',
                  f'        bool odd = ((frame_count % 2u + {first}u + (field_odd > 0.5 ? 1u : 0u)) % 2u) != 0u;',
                  '        float start = line * width;', '        float length = width;']
        for scan, parity in (('progressive', 'even'), ('progressive', 'odd'),
                             ('interlaced', 'even'), ('interlaced', 'odd')):
            changes = sorted((entry for entry in mode.get('line_overrides', [])
                              if entry['scan'] == scan and entry['field'] == parity),
                             key=lambda entry: entry['line'])
            if not changes:
                continue
            condition = f"height {'>' if scan == 'interlaced' else '<='} {threshold} && {'odd' if parity == 'odd' else '!odd'}"
            lines += [f'        if ({condition}) {{']
            cumulative = 0
            for entry in changes:
                line = entry['line'] - 1
                delta = entry['clocks'] - mode['clocks_per_line']
                scale = _glsl(mode['clocks_per_line'])
                difference = (f'(ceil({_glsl(cumulative + delta)} * width / {scale})'
                              f' - ceil({_glsl(cumulative)} * width / {scale}))')
                lines += [f'            if (line > {_glsl(line)})', f'                start += {difference};',
                          f'            else if (line == {_glsl(line)})', f'                length += {difference};']
                cumulative += delta
            lines += ['        }']
        lines += ['        return vec2(start, length);', '    }']
    lines += ['    if (mode == 0)', '        return vec2(line * width, width);',
              '    return vec2(uintBitsToFloat(0x7fc00000u));', '}', '']
    lines += ['dvec2 timing_profile_pixel_ratio(int mode)', '{',
              '    if (mode == 0)', '        return dvec2(-1.0lf, 1.0lf);']
    for index, mode in enumerate(modes, 1):
        ratio = Fraction(*mode['pixel_clock_multiplier'])
        lines += [f'    if (mode == {index})',
                  f'        return dvec2({ratio.numerator}.0lf, {ratio.denominator}.0lf);']
    lines += ['    return dvec2(double(uintBitsToFloat(0x7fc00000u)));', '}', '']
    return '\n'.join(lines)


def generate_timing_profiles(root):
    root = Path(root)
    data = json.loads((root / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
    options = (root / 'config' / 'options.skel.cfg').read_text(encoding='utf-8')
    valid_options = set(re.findall(r'^\s*(?://\s*)?#\s*define\s+(OPTION_[A-Z0-9_]+)\b', options, re.MULTILINE))
    for profile in data['profiles']:
        for remap in profile['remaps']:
            if remap['option'] not in valid_options:
                raise ValueError(f"Unknown timing profile option: {remap['option']}")
    output = root / 'shaders' / 'timing-profiles.inc'
    output.write_text(generate_source(data), encoding='utf-8', newline='\n')


if __name__ == '__main__':
    generate_timing_profiles(Path(__file__).resolve().parent.parent)
