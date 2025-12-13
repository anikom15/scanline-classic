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
import json
import sys
import os
from jsonschema import validate, ValidationError

SCHEMA_PATHS = {
    'preset': os.path.join(os.path.dirname(__file__), 'preset.schema.json'),
    'pipeline': os.path.join(os.path.dirname(__file__), 'pipelines', 'pipeline.schema.json'),
    'params': os.path.join(os.path.dirname(__file__), 'params', 'params.schema.json'),
}

def load_schema(schema_type):
    schema_path = SCHEMA_PATHS.get(schema_type)
    if not schema_path or not os.path.exists(schema_path):
        raise ValueError(f"Schema for type '{schema_type}' not found at {schema_path}")
    with open(schema_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def validate_json(json_path, schema_type):
    schema = load_schema(schema_type)
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    try:
        validate(instance=data, schema=schema)
        print("Validation successful.")
    except ValidationError as e:
        print("Validation error:", e)
        sys.exit(1)

def main():
    if len(sys.argv) != 3:
        print("Usage: python validate_preset.py <schema_type> <file.json>")
        print("schema_type: preset | pipeline | params")
        sys.exit(1)
    schema_type = sys.argv[1]
    json_path = sys.argv[2]
    if schema_type not in SCHEMA_PATHS:
        print(f"Unknown schema_type '{schema_type}'. Must be one of: {', '.join(SCHEMA_PATHS.keys())}")
        sys.exit(1)
    validate_json(json_path, schema_type)

if __name__ == "__main__":
    main()
