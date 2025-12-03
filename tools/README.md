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
