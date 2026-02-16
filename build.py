import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys

# Paths
ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'out')
PRESETDATA = os.path.join(ROOT, 'presetdata')
PRESETS_OUT = os.path.join(OUT, 'presets', 'uhd-4k-sdr')

# Files to copy to OUT
top_files = ['README.md', 'COPYING', 'NEWS']

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

    # Copy share directory
    share_src = os.path.join(ROOT, 'share')
    share_dst = os.path.join(OUT, 'share')
    if os.path.exists(share_src):
        if verbose:
            print(f"Copying {share_src} to {share_dst}")
        shutil.copytree(share_src, share_dst, dirs_exist_ok=True)
    else:
        print(f"Warning: share directory not found at {share_src}")

    # Copy doc directory
    doc_src = os.path.join(ROOT, 'doc')
    doc_dst = os.path.join(OUT, 'doc')
    if os.path.exists(doc_src):
        if verbose:
            print(f"Copying {doc_src} to {doc_dst}")
        shutil.copytree(doc_src, doc_dst, dirs_exist_ok=True)
    else:
        print(f"Warning: doc directory not found at {doc_src}")

    # Copy top-level files
    for fname in top_files:
        src = os.path.join(ROOT, fname)
        if os.path.exists(src):
            if verbose:
                print(f"Copying {src} to {OUT}")
            shutil.copy2(src, OUT)
        else:
            print(f"Warning: {fname} not found.")

    # Copy shaders directory
    shaders_src = os.path.join(ROOT, 'shaders')
    shaders_dst = os.path.join(OUT, 'shaders')
    if os.path.exists(shaders_src):
        if verbose:
            print(f"Copying {shaders_src} to {shaders_dst}")
        shutil.copytree(shaders_src, shaders_dst, dirs_exist_ok=True)
    else:
        print(f"Warning: shaders directory not found at {shaders_src}")

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
            '--output', PRESETS_OUT,
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

def parse_args():
    parser = argparse.ArgumentParser(description='Build scanline-classic output')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    return parser.parse_args()

def main():
    args = parse_args()
    verbose = args.verbose
    jobs = max(1, args.jobs)

    prepare_out_folder(verbose=verbose)
    run_presetgen(verbose=verbose, jobs=jobs)

    # Only run generate_wcg_menu.py and generate_wcg_presets.py on the 'out' folder
    scripts_dir = os.path.join(ROOT, 'scripts')
    python_exec = get_python_executable()

    def run_script(script_name, extra_args=None):
        cmd = [python_exec, os.path.join(scripts_dir, script_name)]
        if verbose:
            cmd.append('--verbose')
        cmd.extend(['--jobs', str(jobs)])
        if extra_args:
            cmd.extend(extra_args)
        print(f"Running: {' '.join(str(x) for x in cmd)}")
        subprocess.run(cmd, check=True)

    menu_tasks = [
        ('generate_wcg_menu.py', ['--out-dir', OUT]),
        ('generate_hdr_menu.py', ['--out-dir', OUT]),
    ]

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(menu_tasks))) as executor:
        futures = {executor.submit(run_script, name, args): name for name, args in menu_tasks}
        for future in concurrent.futures.as_completed(futures):
            script_name = futures[future]
            try:
                future.result()
            except Exception as exc:
                print(f"Error: {script_name} failed: {exc}")
                sys.exit(1)

    preset_tasks = [
        ('generate_wcg_presets.py', [
            '--root-dir', OUT,
            '--input-dir', os.path.join(OUT, 'presets', 'uhd-4k-sdr'),
            '--output-dir', os.path.join(OUT, 'presets', 'uhd-4k-wcg')
        ]),
        ('generate_hdr_presets.py', [
            '--root-dir', OUT,
            '--input-dir', os.path.join(OUT, 'presets', 'uhd-4k-sdr'),
            '--output-dir', os.path.join(OUT, 'presets', 'uhd-4k-hdr')
        ]),
    ]

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(preset_tasks))) as executor:
        futures = {executor.submit(run_script, name, args): name for name, args in preset_tasks}
        for future in concurrent.futures.as_completed(futures):
            script_name = futures[future]
            try:
                future.result()
            except Exception as exc:
                print(f"Error: {script_name} failed: {exc}")
                sys.exit(1)

    # Generate FHD presets after HDR presets are ready
    run_script('generate_fhd_presets.py', ['--root-dir', OUT])

    print("Build complete. Output in 'out' folder.")

if __name__ == '__main__':
    main()
