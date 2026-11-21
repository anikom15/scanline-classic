import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

from scripts.generate_filter_taps import generate_filter_taps

# Paths
ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'out')
PRESETDATA = os.path.join(ROOT, 'presetdata')
PRESETS_OUT = os.path.join(OUT, 'presets')

# Files to copy to OUT
top_files = ['README.md', 'COPYING', 'NEWS']
top_dirs = ['share', 'doc', 'config', 'shaders']

def default_workers():
    count = os.cpu_count() or 4
    return max(1, min(32, count))

def prepare_out_folder(verbose=False):
    # Remove OUT first
    if os.path.exists(OUT):
        if verbose:
            print(f"Removing existing folder: {OUT}")
        shutil.rmtree(OUT)
    if verbose:
        print(f"Creating folder: {PRESETS_OUT}")
    os.makedirs(PRESETS_OUT, exist_ok=True)

    # Copy top-level directories that ship with the build output.
    for dirname in top_dirs:
        src = os.path.join(ROOT, dirname)
        dst = os.path.join(OUT, dirname)
        if os.path.exists(src):
            if verbose:
                print(f"Copying {src} to {dst}")
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            print(f"Warning: directory not found at {src}")

    # Copy top-level files
    for fname in top_files:
        src = os.path.join(ROOT, fname)
        if os.path.exists(src):
            if verbose:
                print(f"Copying {src} to {OUT}")
            shutil.copy2(src, OUT)
        else:
            print(f"Warning: {fname} not found.")

def get_python_executable():
    # Prefer .venv/Scripts/python.exe on Windows, .venv/bin/python on Unix
    venv_dir = os.path.join(ROOT, '.venv')
    if os.name == 'nt':
        venv_python = os.path.join(venv_dir, 'Scripts', 'python.exe')
    else:
        venv_python = os.path.join(venv_dir, 'bin', 'python')
    if os.path.exists(venv_python):
        return venv_python
    return 'python'

def run_presetgen(verbose=False, jobs=1):
    python_exec = get_python_executable()
    presetgen_config = os.path.join(PRESETDATA, 'presetgen.json')
    # Find all JSON files in presetdata/input/ and its subdirectories
    input_dir = os.path.join(PRESETDATA, 'input')
    input_files = []
    for root, dirs, files in os.walk(input_dir):
        for f in files:
            if f.lower().endswith('.json'):
                input_files.append(os.path.join(root, f))
    if not input_files:
        print(f"No input JSON files found in {input_dir}.")
        return

    input_files.sort()

    def run_one(infile):
        cmd = [
            python_exec, os.path.join(ROOT, 'external', 'presetgen', 'presetgen.py'),
            '--input', infile,
            '--output', OUT,
            '--config', presetgen_config,
        ]
        if verbose:
            cmd.append('-v')
            print(f"Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = {executor.submit(run_one, infile): infile for infile in input_files}
        for future in concurrent.futures.as_completed(futures):
            infile = futures[future]
            try:
                future.result()
            except Exception as exc:
                print(f"Error: presetgen failed for {infile}: {exc}")
                sys.exit(1)

def normalize_flat_preset_paths(verbose=False):
    presets_dir = PRESETS_OUT
    if not os.path.exists(presets_dir):
        return

    pattern = re.compile(r'\.\.[\\/]\.\.[\\/]\.\.[\\/](shaders|share)')
    updated_files = 0
    fixed_scale_type_files = 0

    for root, _, files in os.walk(presets_dir):
        for name in files:
            if not name.lower().endswith('.slangp'):
                continue
            path = os.path.join(root, name)
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
            fixed = pattern.sub(r'..\\..\\\1', content)

            lines = fixed.splitlines()
            shaders_count = None
            for line in lines:
                stripped = line.strip()
                if stripped.startswith('shaders') and '=' in stripped:
                    try:
                        shaders_count = int(stripped.split('=', 1)[1].strip())
                    except ValueError:
                        shaders_count = None
                    break

            removed_last_scale_type = False
            if shaders_count is not None and shaders_count > 0:
                last_index = shaders_count - 1
                remove_keys = {
                    f"scale_type{last_index}",
                    f"scale_type_x{last_index}",
                    f"scale_type_y{last_index}",
                }
                filtered_lines = []
                for line in lines:
                    if '=' in line:
                        key = line.split('=', 1)[0].strip()
                        if key in remove_keys:
                            removed_last_scale_type = True
                            continue
                    filtered_lines.append(line)
                fixed = '\n'.join(filtered_lines)
                if content.endswith('\n'):
                    fixed += '\n'

            if fixed != content:
                with open(path, 'w', encoding='utf-8') as f:
                    f.write(fixed)
                updated_files += 1
                if removed_last_scale_type:
                    fixed_scale_type_files += 1

    if verbose and updated_files:
        print(f"Normalized relative paths in {updated_files} preset file(s).")
    if verbose and fixed_scale_type_files:
        print(f"Removed final-pass scale_type entries in {fixed_scale_type_files} preset file(s).")

def run_shader_lint(verbose=False, strict_structure=False):
    python_exec = get_python_executable()
    cmd = [python_exec, os.path.join(ROOT, 'scripts', 'lint_shaders.py')]
    if strict_structure:
        cmd.append('--strict-structure')
    print(f"Running: {' '.join(cmd)}")
    try:
        subprocess.run(cmd, check=True)
    except Exception as exc:
        print(f"Error: shader lint failed: {exc}")
        sys.exit(1)

def parse_args():
    parser = argparse.ArgumentParser(description='Build scanline-classic output')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    parser.add_argument(
        '--lint-shaders',
        action='store_true',
        help='Run shader lint (scripts/lint_shaders.py) before build steps',
    )
    parser.add_argument(
        '--strict-structure',
        action='store_true',
        help='Use strict shader structure checks when running --lint-shaders',
    )
    return parser.parse_args()

def main():
    args = parse_args()
    verbose = args.verbose
    jobs = max(1, args.jobs)

    if args.strict_structure and not args.lint_shaders:
        print("Error: --strict-structure requires --lint-shaders")
        sys.exit(2)

    generate_filter_taps(ROOT)

    if args.lint_shaders:
        run_shader_lint(verbose=verbose, strict_structure=args.strict_structure)

    prepare_out_folder(verbose=verbose)
    run_presetgen(verbose=verbose, jobs=jobs)
    normalize_flat_preset_paths(verbose=verbose)

    print("Build complete. Output in 'out' folder.")

if __name__ == '__main__':
    main()
