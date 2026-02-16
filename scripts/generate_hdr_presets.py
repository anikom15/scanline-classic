"""
Generates HDR presets from SDR presets.
Rules:
- Scan uhd-4k-sdr for all .slangp files recursively.
- Replace any shader path containing `-sdr.slang` with `-hdr.slang`.
- Verify the replaced shader file exists and warn if not found.
- Write outputs to uhd-4k-hdr with matching directory structure and filenames.
"""
import concurrent.futures
import os
import sys
from pathlib import Path
import argparse

def default_workers():
    count = os.cpu_count() or 4
    return max(1, min(32, count))

def transform_preset(input_path: Path, output_path: Path, root_dir: Path, verbose=False):
    if verbose:
        print(f"Transforming {input_path} -> {output_path}")
    lines = input_path.read_text(encoding='utf-8').splitlines()
    # RetroArch HDR bug: final pass scale_type can break preset recognition.
    # We remove scale_type for the last pass (index shaders_count - 1).
    shaders_count = None
    for line in lines:
        if line.strip().startswith('shaders') and '=' in line:
            _, value = line.split('=', 1)
            try:
                shaders_count = int(value.strip())
            except ValueError:
                shaders_count = None
            break
    last_scale_type_key = None
    if shaders_count is not None and shaders_count > 0:
        last_scale_type_key = f"scale_type{shaders_count - 1}"
    transformed_lines = []
    for line in lines:
        if last_scale_type_key and '=' in line:
            key, _ = line.split('=', 1)
            if key.strip() == last_scale_type_key:
                if verbose:
                    print(f"  Removed: {last_scale_type_key} (RetroArch HDR workaround)")
                continue
        if line.strip().startswith('shader') and '=' in line:
            prefix, shader_path = line.split('=', 1)
            shader_path = shader_path.strip()
            if shader_path.endswith('-sdr.slang'):
                hdr_path = shader_path.replace('-sdr.slang', '-hdr.slang')
                # Always resolve relative to root_dir/shaders
                hdr_path_norm = Path(hdr_path)
                # Remove leading ..\ or ../
                hdr_path_parts = []
                found_shaders = False
                for part in hdr_path_norm.parts:
                    if part == '..':
                        continue
                    if not found_shaders and part.lower() == 'shaders':
                        found_shaders = True
                        continue
                    if found_shaders:
                        hdr_path_parts.append(part)
                hdr_rel = Path(*hdr_path_parts)
                resolved_hdr = (root_dir / 'shaders' / hdr_rel).resolve()
                if resolved_hdr.exists():
                    if verbose:
                        print(f"  Replaced: {shader_path} -> {hdr_path}")
                    transformed_lines.append(f"{prefix.strip()} = {hdr_path}")
                else:
                    print(f"Warning: HDR shader not found: {resolved_hdr} (referenced in {input_path})")
                    if verbose:
                        print(f"  Keeping original: {shader_path} (HDR not found)")
                    transformed_lines.append(line)
            else:
                transformed_lines.append(line)
        else:
            transformed_lines.append(line)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(transformed_lines) + '\n', encoding='utf-8')

def main():
    parser = argparse.ArgumentParser(description='Generate HDR presets from SDR presets')
    parser.add_argument('--root-dir', type=Path, required=True, help='Root directory containing shaders and presets')
    parser.add_argument('--input-dir', type=Path, required=True, help='Input directory for SDR presets')
    parser.add_argument('--output-dir', type=Path, required=True, help='Output directory for HDR presets')
    parser.add_argument('-v','--verbose', action='store_true')
    parser.add_argument('--jobs', type=int, default=default_workers())
    args = parser.parse_args()

    sdr_dir = args.input_dir
    hdr_dir = args.output_dir
    root_dir = args.root_dir
    jobs = max(1, args.jobs)
    sdr_presets = list(sdr_dir.rglob('*.slangp'))

    def run_one(sdr_preset: Path):
        rel_path = sdr_preset.relative_to(sdr_dir)
        hdr_preset = hdr_dir / rel_path
        transform_preset(sdr_preset, hdr_preset, root_dir=root_dir, verbose=args.verbose)

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(run_one, sdr_preset) for sdr_preset in sdr_presets]
        for future in concurrent.futures.as_completed(futures):
            future.result()

if __name__ == '__main__':
    main()
