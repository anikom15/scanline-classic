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


def append_fhd_suffix_to_image(path_value: str):
    """Append -fhd before .png/.jpg extension if not already present."""
    lower = path_value.lower()
    for ext in ('.png', '.jpg'):
        if lower.endswith(ext):
            base = path_value[:-len(ext)]
            if base.lower().endswith('-fhd'):
                return path_value, False
            return f"{base}-fhd{path_value[-len(ext):]}", True
    return path_value, False


def is_share_path(path_value: str):
    normalized = path_value.replace('\\', '/').lower()
    return normalized.startswith('share/') or '/share/' in normalized

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
            elif key == 'BORDER' and is_share_path(value):
                new_value, changed = append_fhd_suffix_to_image(value)
                new_value_exists = (input_path.parent / Path(new_value)).exists()
                if changed and new_value_exists:
                    if verbose:
                        print(f"  Replaced: BORDER = {value} -> {new_value}")
                    transformed_lines.append(f'BORDER = "{new_value}"')
                else:
                    if verbose and changed and not new_value_exists:
                        print(f"  Skipped: BORDER FHD resource not found: {new_value}")
                    transformed_lines.append(line)
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
