"""
Generates Steam Deck presets from UHD-4K presets.
Rules:
- steamdeck-lcd: Source from uhd-4k-sdr, cap TVL to 400
- steamdeck-oled-native: Source from uhd-4k-wcg, cap TVL to 400, add GAMUT_SELECT = 1.0
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


def transform_preset(input_path: Path, output_path: Path, add_gamut_select=False, verbose=False):
    """Transform a UHD preset to Steam Deck by capping TVL and optionally adding GAMUT_SELECT."""
    if verbose:
        print(f"Transforming {input_path} -> {output_path}")
    
    lines = input_path.read_text(encoding='utf-8').splitlines()
    transformed_lines = []
    gamut_select_added = False
    
    for line in lines:
        # Check if this line sets a parameter
        if '=' in line:
            key, value = line.split('=', 1)
            key = key.strip()
            value = value.strip().strip('"')
            
            # Cap TVL to 400 if it's greater
            if key == 'TVL':
                try:
                    tvl_value = float(value)
                    if tvl_value > 400.0:
                        if verbose:
                            print(f"  Capped: TVL = {tvl_value} -> 400.0")
                        transformed_lines.append('TVL = "400.0"')
                    else:
                        transformed_lines.append(line)
                except ValueError:
                    # If we can't parse as float, keep the line as is
                    transformed_lines.append(line)
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
    
    # Add GAMUT_SELECT = 1.0 for OLED presets (insert before the first shader line or at the end)
    if add_gamut_select:
        # Find the position to insert GAMUT_SELECT (before first shader line)
        insert_pos = len(transformed_lines)
        for i, line in enumerate(transformed_lines):
            if line.strip().startswith('shader'):
                insert_pos = i
                break
        
        # Check if GAMUT_SELECT already exists
        has_gamut_select = any('GAMUT_SELECT' in line for line in transformed_lines)
        
        if not has_gamut_select:
            if verbose:
                print(f"  Added: GAMUT_SELECT = 1.0")
            transformed_lines.insert(insert_pos, 'GAMUT_SELECT = "1.0"')
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(transformed_lines) + '\n', encoding='utf-8')


def process_preset_folder(input_dir: Path, output_dir: Path, add_gamut_select=False, verbose=False, jobs=1):
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
        transform_preset(preset, output_path, add_gamut_select=add_gamut_select, verbose=verbose)
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(run_one, preset) for preset in presets]
        for future in concurrent.futures.as_completed(futures):
            future.result()


def main():
    parser = argparse.ArgumentParser(description='Generate Steam Deck presets from UHD-4K presets')
    parser.add_argument('--root-dir', type=Path, required=True, help='Root directory containing presets')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    args = parser.parse_args()
    
    root_dir = args.root_dir
    jobs = max(1, args.jobs)
    
    # Define input and output directories
    tasks = [
        (root_dir / 'presets' / 'uhd-4k-sdr', root_dir / 'presets' / 'steamdeck-lcd', False),
        (root_dir / 'presets' / 'uhd-4k-wcg', root_dir / 'presets' / 'steamdeck-oled-native', True),
    ]
    
    for input_dir, output_dir, add_gamut_select in tasks:
        if not input_dir.exists():
            print(f"Warning: Input directory not found: {input_dir}")
            continue
        
        print(f"Processing {input_dir.name} -> {output_dir.name}")
        process_preset_folder(input_dir, output_dir, add_gamut_select=add_gamut_select, 
                             verbose=args.verbose, jobs=jobs)
    
    print("Steam Deck preset generation complete.")


if __name__ == '__main__':
    main()
