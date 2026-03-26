"""
Generates WCG menu shaders from SDR menu shaders.
Rules:
- Output filename: replace "-sdr" with "-wcg".
- For each include:
  * Skip includes that end with -hdr before extension.
    * If include ends with -sdr and a sibling -wcg variant exists, replace it.
    * If include ends with -sdr and no -wcg variant exists, skip it.
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

def get_wcg_path(include_path: Path) -> Path:
    if include_path.stem.endswith('-sdr'):
        wcg_stem = include_path.stem[:-4] + '-wcg'
    else:
        wcg_stem = include_path.stem + '-wcg'
    return include_path.with_name(wcg_stem + include_path.suffix)

def should_skip_include(include_path: Path) -> bool:
    # Skip HDR includes; we don't want them in WCG output
    return include_path.stem.endswith('-hdr')

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
            
            # Check if this is an SDR include that needs WCG replacement
            if inc_path.stem.endswith('-sdr'):
                wcg_path = get_wcg_path(inc_path)
                resolved_wcg = (input_dir / wcg_path).resolve()
                if resolved_wcg.exists():
                    if verbose:
                        print(f"  Replacing: {inc} -> {wcg_path.as_posix()}")
                    out_lines.append(f'#include "{wcg_path.as_posix()}"\n')
                else:
                    if verbose:
                        print(f"  Skipping SDR include (WCG not found): {inc}")
                    continue
            else:
                if verbose:
                    print(f"  Keeping include: {inc}")
                out_lines.append(f'#include "{inc}"\n')
        else:
            out_lines.append(line)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(''.join(out_lines), encoding='utf-8')

def main():
    parser = argparse.ArgumentParser(description='Generate WCG menu shaders from SDR menu shaders')
    parser.add_argument('--menus-dir', type=Path, default=Path(__file__).parent.parent / 'shaders' / 'menus')
    parser.add_argument('--out-dir', type=Path, default=None, help='Output root directory for generated content')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    args = parser.parse_args()

    sdr_dir = args.menus_dir
    if args.out_dir:
        out_root = Path(args.out_dir)
        # Output menus go in out_root/shaders/menus, mirroring SDR structure
        wcg_base = out_root / 'shaders' / 'menus'
    else:
        wcg_base = sdr_dir

    jobs = max(1, args.jobs)
    sdr_shaders = list(sdr_dir.rglob('*.slang'))

    def run_one(sdr_shader: Path):
        rel_path = sdr_shader.relative_to(sdr_dir)
        wcg_shader = wcg_base / rel_path
        wcg_shader = wcg_shader.with_name(wcg_shader.stem.replace('-sdr', '-wcg') + wcg_shader.suffix)
        transform_shader(sdr_shader, wcg_shader, args.verbose)

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(run_one, sdr_shader) for sdr_shader in sdr_shaders]
        for future in concurrent.futures.as_completed(futures):
            future.result()

if __name__ == '__main__':
    main()
