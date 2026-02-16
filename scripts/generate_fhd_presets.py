"""
Generates FHD (1080p) presets from UHD-4K presets.
Rules:
- Scan uhd-4k-sdr and uhd-4k-hdr for all .slangp files recursively.
- Replace MASK_DIFFUSION = 2.0 with MASK_DIFFUSION = 3.0.
- Write outputs to fhd-sdr and fhd-hdr with matching directory structure and filenames.
"""
import concurrent.futures
import os
from pathlib import Path
import argparse

def default_workers():
    count = os.cpu_count() or 4
    return max(1, min(32, count))

def transform_preset(input_path: Path, output_path: Path, verbose=False):
    """Transform a UHD preset to FHD by adjusting MASK_DIFFUSION."""
    if verbose:
        print(f"Transforming {input_path} -> {output_path}")
    
    lines = input_path.read_text(encoding='utf-8').splitlines()
    transformed_lines = []
    
    for line in lines:
        # Check if this line sets MASK_DIFFUSION
        if '=' in line:
            key, value = line.split('=', 1)
            key = key.strip()
            value = value.strip().strip('"')
            
            if key == 'MASK_DIFFUSION' and value == '2.0':
                if verbose:
                    print(f"  Replaced: MASK_DIFFUSION = 2.0 -> MASK_DIFFUSION = 3.0")
                transformed_lines.append('MASK_DIFFUSION = "3.0"')
            else:
                transformed_lines.append(line)
        else:
            transformed_lines.append(line)
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(transformed_lines) + '\n', encoding='utf-8')

def process_preset_folder(input_dir: Path, output_dir: Path, verbose=False, jobs=1):
    """Process all presets in a folder."""
    presets = list(input_dir.rglob('*.slangp'))
    
    if not presets:
        print(f"No presets found in {input_dir}")
        return
    
    if verbose:
        print(f"Found {len(presets)} preset(s) in {input_dir}")
    
    def run_one(preset: Path):
        rel_path = preset.relative_to(input_dir)
        output_path = output_dir / rel_path
        transform_preset(preset, output_path, verbose=verbose)
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(run_one, preset) for preset in presets]
        for future in concurrent.futures.as_completed(futures):
            future.result()

def main():
    parser = argparse.ArgumentParser(description='Generate FHD presets from UHD-4K presets')
    parser.add_argument('--root-dir', type=Path, required=True, help='Root directory containing presets')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    args = parser.parse_args()
    
    root_dir = args.root_dir
    jobs = max(1, args.jobs)
    
    # Define input and output directories
    tasks = [
        (root_dir / 'presets' / 'uhd-4k-sdr', root_dir / 'presets' / 'fhd-sdr'),
        (root_dir / 'presets' / 'uhd-4k-hdr', root_dir / 'presets' / 'fhd-hdr'),
    ]
    
    for input_dir, output_dir in tasks:
        if not input_dir.exists():
            print(f"Warning: Input directory not found: {input_dir}")
            continue
        
        print(f"Processing {input_dir.name} -> {output_dir.name}")
        process_preset_folder(input_dir, output_dir, verbose=args.verbose, jobs=jobs)
    
    print("FHD preset generation complete.")

if __name__ == '__main__':
    main()
