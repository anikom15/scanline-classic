"""
Generates HDR menu shaders from SDR menu shaders.
Rules:
- Output filename: replace "-sdr" with "-hdr".
- For each include:
  * Skip includes that end with -sdr or -wcg before extension.
  * If a sibling include exists with -hdr appended before extension, use that instead.
  * Otherwise keep the original include.
"""
import concurrent.futures
import os
import re
import sys
from pathlib import Path

import argparse

def default_workers():
    count = os.cpu_count() or 4
    return max(1, min(32, count))

def normalize_include_path(include_path: str) -> str:
    return include_path.replace('\\', '/')

def get_hdr_path(include_path: Path) -> Path:
    return include_path.with_name(include_path.stem + '-hdr' + include_path.suffix)

def should_skip_include(include_path: Path) -> bool:
    return include_path.stem.endswith('-sdr') or include_path.stem.endswith('-wcg')

def transform_shader(input_path: Path, output_path: Path, verbose=False):
    if verbose:
        print(f"Transforming {input_path} -> {output_path}")
    lines = input_path.read_text(encoding='utf-8').splitlines(keepends=True)
    input_dir = input_path.parent

    pattern = re.compile(r'^\s*#include\s+"([^"]+)"\s*$', re.MULTILINE)
    out_lines = []
    for line in lines:
        m = pattern.match(line)
        if m:
            inc = normalize_include_path(m.group(1))
            inc_path = Path(inc)
            if should_skip_include(inc_path):
                if verbose:
                    print(f"  Skipping include: {inc}")
                continue  # skip this line, do not add blank
            hdr_path = get_hdr_path(inc_path)
            resolved_hdr = (input_dir / hdr_path).resolve()
            if resolved_hdr.exists():
                if verbose:
                    print(f"  Using HDR include: {hdr_path} and original: {inc}")
                out_lines.append(f'#include "{inc}"\n#include "{hdr_path.as_posix()}"\n')
            else:
                if verbose:
                    print(f"  Keeping include: {inc} (no HDR variant found)")
                out_lines.append(f'#include "{inc}"\n')
        else:
            out_lines.append(line)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(''.join(out_lines), encoding='utf-8')

def main():
    parser = argparse.ArgumentParser(description='Generate HDR menu shaders from SDR menu shaders')
    parser.add_argument('--menus-dir', type=Path, default=Path(__file__).parent.parent / 'shaders' / 'menus')
    parser.add_argument('--out-dir', type=Path, default=None, help='Output root directory for generated content')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    args = parser.parse_args()

    sdr_dir = args.menus_dir
    if args.out_dir:
        out_root = Path(args.out_dir)
        # Output menus go in out_root/shaders/menus, mirroring SDR structure
        hdr_base = out_root / 'shaders' / 'menus'
    else:
        hdr_base = sdr_dir

    jobs = max(1, args.jobs)
    sdr_shaders = list(sdr_dir.rglob('*.slang'))

    def run_one(sdr_shader: Path):
        rel_path = sdr_shader.relative_to(sdr_dir)
        hdr_shader = hdr_base / rel_path
        hdr_shader = hdr_shader.with_name(hdr_shader.stem.replace('-sdr', '-hdr') + hdr_shader.suffix)
        transform_shader(sdr_shader, hdr_shader, args.verbose)

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(run_one, sdr_shader) for sdr_shader in sdr_shaders]
        for future in concurrent.futures.as_completed(futures):
            future.result()

if __name__ == '__main__':
    main()
