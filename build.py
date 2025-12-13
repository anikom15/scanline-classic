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

def run_presetgen(verbose=False):
    python_exec = get_python_executable()
    # Find all files in presetdata (no subdirectories)
    input_files = [
        os.path.join(PRESETDATA, f)
        for f in os.listdir(PRESETDATA)
        if os.path.isfile(os.path.join(PRESETDATA, f))
    ]
    if not input_files:
        print("No input files found in presetdata.")
        return
    # Call presetgen.py for each input file
    for infile in input_files:
        cmd = [
            python_exec, os.path.join(ROOT, 'external', 'presetgen', 'presetgen.py'),
            '--input', infile,
            '--output', PRESETS_OUT
        ]
        if verbose:
            print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, check=True, capture_output=not verbose, text=True)
        if not verbose:
            if result.stdout:
                print(result.stdout, end='')
            if result.stderr:
                print(result.stderr, end='', file=sys.stderr)

def main():
    verbose = '--verbose' in sys.argv
    prepare_out_folder(verbose=verbose)
    run_presetgen(verbose=verbose)

    # Run generate_wcg_menu.py and generate_wcg_presets.py on the out folder
    scripts_dir = os.path.join(ROOT, 'scripts')
    python_exec = get_python_executable()

    def run_script(script_name, extra_args=None):
        cmd = [python_exec, os.path.join(scripts_dir, script_name)]
        if verbose:
            cmd.append('--verbose')
        if extra_args:
            cmd.extend(extra_args)
        print(f"Running: {' '.join(str(x) for x in cmd)}")
        subprocess.run(cmd, check=True)

    # Run menu script as before
    run_script('generate_wcg_menu.py', ['--out-dir', OUT])

    # Run presets script with explicit root/input/output dirs
    run_script('generate_wcg_presets.py', [
        '--root-dir', OUT,
        '--input-dir', os.path.join(OUT, 'presets', 'uhd-4k-sdr'),
        '--output-dir', os.path.join(OUT, 'presets', 'uhd-4k-wcg')
    ])

    print("Build complete. Output in 'out' folder.")

if __name__ == '__main__':
    main()
