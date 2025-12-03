# Tools

## generate-wcg-menu.ps1
Generates WCG menu shaders from existing SDR menu shaders.

- Input: files matching `shaders/menus/menu-*-sdr.slang`
- Output: corresponding `menu-*-wcg.slang` alongside inputs
- Changes:
  - Sets `#pragma format` to `R10G10B10A2_UNORM` (10-bit)
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
