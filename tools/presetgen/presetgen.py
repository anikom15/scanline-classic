"""
Copyright 2025 W. M. Martinez

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""
import os
import sys
import argparse
import json
from data import Preset, Pipeline, Params

def wrap_comment(text, width=72):
    import textwrap
    return ['# ' + line for line in textwrap.wrap(text, width)]


def main():
    parser = argparse.ArgumentParser(description="Generate preset output file.")
    parser.add_argument('input', help='Input preset JSON file')
    parser.add_argument('-o', '--output-dir', default=None, help='Output directory (default: out in script dir)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    args = parser.parse_args()

    def vprint(*a, **k):
        if args.verbose:
            print(*a, **k)

    vprint(f"Loading Preset: {args.input}")
    preset = Preset(args.input)
    preset_data = preset.data
    vprint("Preset loaded:", json.dumps(preset_data, indent=2))

    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.normpath(args.output_dir) if args.output_dir else os.path.join(script_dir, 'out')
    output_subdir = os.path.normpath(preset_data['type'])
    base_filename = os.path.splitext(os.path.normpath(preset_data['filename']))[0]
    output_filename = base_filename + '.slangp'
    output_path = os.path.normpath(os.path.join(output_dir, output_subdir))
    os.makedirs(output_path, exist_ok=True)
    output_file = os.path.normpath(os.path.join(output_path, output_filename))

    lines = []
    # Title comment
    lines.append(f"# {preset_data['title']}")
    lines.append('')
    # Description comment, wrapped
    lines.extend(wrap_comment(preset_data['description']))
    lines.append('')


    # --- State options: Load pipelines and parameter sets ---
    pipeline_root = os.path.normpath(preset_data.get('pipeline_root', 'pipelines'))
    parameter_root = os.path.normpath(preset_data.get('parameter_root', 'params'))
    vprint(f"Pipeline root: {pipeline_root}")
    vprint(f"Parameter root: {parameter_root}")

    # Load all pipelines
    pipeline_objs = []
    for pipeline_file in preset_data.get('pipelines', []):
        pipeline_path = os.path.normpath(os.path.join(script_dir, pipeline_root, pipeline_file))
        vprint(f"Loading Pipeline: {pipeline_path}")
        pipeline_obj = Pipeline(pipeline_path)
        vprint("Pipeline loaded:", json.dumps(pipeline_obj.data, indent=2))
        pipeline_objs.append(pipeline_obj)

    # Add shader count after comments and after pipeline_objs is loaded
    shader_count = sum(len(p.data.get('shaders', {})) for p in pipeline_objs)
    lines.append(f"shaders = {shader_count}")
    lines.append('')

    # --- State options: Load pipelines and parameter sets ---
    pipeline_root = os.path.normpath(preset_data.get('pipeline_root', 'pipelines'))
    parameter_root = os.path.normpath(preset_data.get('parameter_root', 'params'))
    vprint(f"Pipeline root: {pipeline_root}")
    vprint(f"Parameter root: {parameter_root}")

    # Load all pipelines
    pipeline_objs = []
    for pipeline_file in preset_data.get('pipelines', []):
        pipeline_path = os.path.normpath(os.path.join(script_dir, pipeline_root, pipeline_file))
        vprint(f"Loading Pipeline: {pipeline_path}")
        pipeline_obj = Pipeline(pipeline_path)
        vprint("Pipeline loaded:", json.dumps(pipeline_obj.data, indent=2))
        pipeline_objs.append(pipeline_obj)

    # Load all parameter sets
    param_objs = []
    for param_file in preset_data.get('parameter_sets', []):
        param_path = os.path.normpath(os.path.join(script_dir, parameter_root, param_file))
        vprint(f"Loading Params: {param_path}")
        param_obj = Params(param_path)
        vprint("Params loaded:", json.dumps(param_obj.data, indent=2))
        param_objs.append(param_obj)

    # Assign unique numbers to shader stages across all pipelines
    shader_stage_map = {}  # (pipeline_idx, stage_key) -> unique_number
    shader_stage_counter = 0
    for pidx, pipeline in enumerate(pipeline_objs):
        root_path = pipeline.data.get('root_path', '')
        shaders = pipeline.data.get('shaders', {})
        vprint(f"Pipeline {pidx} root_path: {root_path}")
        vprint(f"Pipeline {pidx} shaders: {json.dumps(shaders, indent=2)}")
        for stage_key in shaders:
            shader_stage_map[(pidx, stage_key)] = shader_stage_counter
            vprint(f"Assigning shader stage {stage_key} in pipeline {pidx} to {shader_stage_counter}")
            shader_stage_counter += 1

    if args.verbose:
        print("Shader stage map:")
        for (pidx, stage_key), num in shader_stage_map.items():
            print(f"  Pipeline {pidx}, stage '{stage_key}': {num}")


    # --- Write shaders and options ---
    for pidx, pipeline in enumerate(pipeline_objs):
        root_path = pipeline.data.get('root_path', '')
        shaders = pipeline.data.get('shaders', {})
        options = pipeline.data.get('options', {})
        for stage_key, shader_file in shaders.items():
            idx = shader_stage_map[(pidx, stage_key)]
            # Shader line
            lines.append(f"shader{idx} = {os.path.normpath(os.path.join(root_path, shader_file))}")
            # Options for this shader stage
            opts = options.get(stage_key, {})

            # filter_linear: default false
            filter_linear_val = opts.get('filter_linear', False)
            lines.append(f"filter_linear{idx} = {str(filter_linear_val).lower()}")

            # scale_type: default 'source', handle array
            scale_type_val = opts.get('scale_type', ['source'])
            if not isinstance(scale_type_val, list):
                scale_type_val = [scale_type_val]
            if len(scale_type_val) == 1:
                lines.append(f"scale_type{idx} = {scale_type_val[0]}")
            elif len(scale_type_val) == 2:
                lines.append(f"scale_type_x{idx} = {scale_type_val[0]}")
                lines.append(f"scale_type_y{idx} = {scale_type_val[1]}")

            # scale: handle array
            if 'scale' in opts:
                opt_val = opts['scale']
                if isinstance(opt_val, list):
                    if len(opt_val) == 1:
                        lines.append(f"scale{idx} = {opt_val[0]}")
                    elif len(opt_val) == 2:
                        lines.append(f"scale_x{idx} = {opt_val[0]}")
                        lines.append(f"scale_y{idx} = {opt_val[1]}")
                else:
                    lines.append(f"scale{idx} = {opt_val}")

            # Other options
            for opt_key, opt_val in opts.items():
                if opt_key in ('filter_linear', 'scale_type', 'scale'):
                    continue
                lines.append(f"{opt_key}{idx} = {opt_val}")
            lines.append("")  # Separate each shader index group with a blank line


    # --- Write pipeline parameters (from each pipeline's parameters object) ---
    for pipeline in pipeline_objs:
        pipeline_params = pipeline.data.get('parameters', {})
        for k, v in pipeline_params.items():
            lines.append(f"{k} = {v}")
    if pipeline_objs:
        lines.append("")

    # --- Write parameters from parameter set JSON files ---
    for param_obj in param_objs:
        params = param_obj.data.get('parameters', {})
        for k, v in params.items():
            lines.append(f"{k} = {v}")
    lines.append("")

    # Remove multiple blank lines
    pretty_lines = []
    last_blank = False
    for line in lines:
        if line.strip() == "":
            if not last_blank:
                pretty_lines.append("")
            last_blank = True
        else:
            pretty_lines.append(line)
            last_blank = False

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(pretty_lines))

    print(f"Generated: {output_file}")

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"Generated: {output_file}")

if __name__ == "__main__":
    main()