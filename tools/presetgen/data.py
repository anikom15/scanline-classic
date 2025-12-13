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


class Preset:
    def __init__(self, filename):
        self.schema = load_schema('preset')
        try:
            with open(filename, 'r', encoding='utf-8') as f:
                self.data = json.load(f)
        except json.JSONDecodeError as e:
            raise ValueError(f"Malformed JSON in {filename}: {e}")
        try:
            validate(instance=self.data, schema=self.schema)
        except ValidationError as e:
            raise ValueError(f"Preset validation error: {e}")


class Pipeline:
    def __init__(self, filename):
        self.schema = load_schema('pipeline')
        try:
            with open(filename, 'r', encoding='utf-8') as f:
                self.data = json.load(f)
        except json.JSONDecodeError as e:
            raise ValueError(f"Malformed JSON in {filename}: {e}")
        try:
            validate(instance=self.data, schema=self.schema)
        except ValidationError as e:
            raise ValueError(f"Pipeline validation error: {e}")


class Params:
    def __init__(self, filename):
        self.schema = load_schema('params')
        try:
            with open(filename, 'r', encoding='utf-8') as f:
                self.data = json.load(f)
        except json.JSONDecodeError as e:
            raise ValueError(f"Malformed JSON in {filename}: {e}")
        try:
            validate(instance=self.data, schema=self.schema)
        except ValidationError as e:
            raise ValueError(f"Params validation error: {e}")
