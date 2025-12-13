# PresetGen

PresetGen is a Python tool for generating RetroArch slang preset files from structured JSON descriptions. It is designed to help shader authors and advanced users automate the creation of complex preset files, ensuring consistency and maintainability.

## Features
- Compose presets from modular pipeline and parameter set JSON files
- Automatic shader index assignment and option handling
- Handles per-shader and global parameters
- Outputs well-formatted `.slangp` files with comments and documentation
- Validates all input files against JSON schemas

## Usage

```
python presetgen.py [-o OUTPUT_DIR] [-v] <preset.json>
```

- `-o OUTPUT_DIR` : Output directory (default: `out` in the script directory)
- `-v` : Verbose output (shows details about file loading and processing)
- `<preset.json>` : Input preset description file

Example:
```
python presetgen.py -v example_preset.json
```

## Project Structure
- `presetgen.py` : Main generation script
- `data.py` : Classes for loading and validating JSON files
- `validate_preset.py` : Standalone validation tool
- `pipelines/` : Pipeline JSON files and schema
- `params/` : Parameter set JSON files and schema
- `preset.schema.json` : Preset JSON schema
- `requirements.txt` : Python dependencies

## License

This project is licensed under the Apache License, Version 2.0. See the [COPYING](COPYING) file for details.
