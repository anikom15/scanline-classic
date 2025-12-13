"""
Generates WCG presets from SDR presets.
Rules:
- Scan uhd-4k-sdr for all .slangp files recursively.
- Replace any shader path containing `-sdr.slang` with `-wcg.slang`.
- Verify the replaced shader file exists and warn if not found.
- Write outputs to uhd-4k-wcg with matching directory structure and filenames.
"""
import sys
from pathlib import Path
import argparse

def transform_preset(input_path: Path, output_path: Path, root_dir: Path, verbose=False):
    if verbose:
        print(f"Transforming {input_path} -> {output_path}")
    lines = input_path.read_text(encoding='utf-8').splitlines()
    transformed_lines = []
    for line in lines:
        if line.strip().startswith('shader') and '=' in line:
            prefix, shader_path = line.split('=', 1)
            shader_path = shader_path.strip()
            if shader_path.endswith('-sdr.slang'):
                wcg_path = shader_path.replace('-sdr.slang', '-wcg.slang')
                # Always resolve relative to root_dir/shaders
                wcg_path_norm = Path(wcg_path)
                # Remove leading ..\ or ../
                wcg_path_parts = []
                found_shaders = False
                for part in wcg_path_norm.parts:
                    if part == '..':
                        continue
                    if not found_shaders and part.lower() == 'shaders':
                        found_shaders = True
                        continue
                    if found_shaders:
                        wcg_path_parts.append(part)
                wcg_rel = Path(*wcg_path_parts)
                resolved_wcg = (root_dir / 'shaders' / wcg_rel).resolve()
                if resolved_wcg.exists():
                    if verbose:
                        print(f"  Replaced: {shader_path} -> {wcg_path}")
                    transformed_lines.append(f"{prefix.strip()} = {wcg_path}")
                else:
                    print(f"Warning: WCG shader not found: {resolved_wcg} (referenced in {input_path})")
                    if verbose:
                        print(f"  Keeping original: {shader_path} (WCG not found)")
                    transformed_lines.append(line)
            else:
                transformed_lines.append(line)
        else:
            transformed_lines.append(line)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(transformed_lines) + '\n', encoding='utf-8')

def main():
    parser = argparse.ArgumentParser(description='Generate WCG presets from SDR presets')
    parser.add_argument('--root-dir', type=Path, required=True, help='Root directory containing shaders and presets')
    parser.add_argument('--input-dir', type=Path, required=True, help='Input directory for SDR presets')
    parser.add_argument('--output-dir', type=Path, required=True, help='Output directory for WCG presets')
    parser.add_argument('-v','--verbose', action='store_true')
    args = parser.parse_args()

    sdr_dir = args.input_dir
    wcg_dir = args.output_dir
    root_dir = args.root_dir
    for sdr_preset in sdr_dir.rglob('*.slangp'):
        rel_path = sdr_preset.relative_to(sdr_dir)
        wcg_preset = wcg_dir / rel_path
        transform_preset(sdr_preset, wcg_preset, root_dir=root_dir, verbose=args.verbose)

if __name__ == '__main__':
    main()
