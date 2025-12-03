# Tools

## generate-wcg-menu.ps1
Generates WCG menu shaders from existing SDR menu shaders, and a base WCG menu from `menu-sdr.slang` or `menu.slang`.

- Input:
  - Files matching `shaders/menus/menu-*-sdr.slang`
  - Base file `shaders/menus/menu-sdr.slang` (preferred) or `shaders/menus/menu.slang`
- Output:
  - Corresponding `menu-*-wcg.slang` alongside inputs
  - `shaders/menus/menu-wcg.slang` generated from the base menu file
- Changes:
  - Sets `#pragma format` to `A2B10G10R10_UNORM_PACK32` (10-bit packed) for all WCG outputs
  - Processes `#include "..."` lines:
    - Skips includes ending with `-sdr` or `-hdr`
    - If a `-wcg` variant exists, includes both the `-wcg` file and the original
    - Otherwise keeps the original include

### Usage
From the repository root (PowerShell):

```powershell
# Standard run
./tools/generate-wcg-menu.ps1

# Verbose logging
./tools/generate-wcg-menu.ps1 -VerboseLog

# Custom menus directory (optional)
./tools/generate-wcg-menu.ps1 -MenusDir "${PWD}\shaders\menus"
```

### Notes
- The script is compatible with Windows PowerShell 5.1.
- Outputs are written next to their SDR counterparts in `shaders/menus/`.
- Generated files are ignored by Git via `.gitignore` entry `shaders/menus/*-wcg.slang`.

## generate-wcg-presets.ps1
Generates WCG preset files from existing SDR preset files.

- Input: all `.slangp` files in `presets/uhd-4k-sdr/` (recursively)
- Output: corresponding `.slangp` files in `presets/uhd-4k-wcg/` with matching directory structure and filenames
- Changes:
  - Replaces shader paths ending with `-sdr.slang` with `-wcg.slang`
  - Verifies that the WCG shader file exists and warns if not found
  - Preserves all other preset content unchanged

### Usage
From the repository root (PowerShell):

```powershell
# Standard run
./tools/generate-wcg-presets.ps1

# Verbose logging
./tools/generate-wcg-presets.ps1 -VerboseLog

# Custom directories (optional)
./tools/generate-wcg-presets.ps1 -SdrPresetsDir "${PWD}\presets\uhd-4k-sdr" -WcgPresetsDir "${PWD}\presets\uhd-4k-wcg"
```

### Notes
- The script is compatible with Windows PowerShell 5.1.
- Outputs preserve the exact directory structure and filenames from the SDR source.
- If a WCG shader file is not found, a warning is displayed and the original SDR shader path is kept.
