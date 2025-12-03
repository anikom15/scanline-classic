# Master script to generate all WCG content (menus and presets) in one step.
# This runs both generate-wcg-menu.ps1 and generate-wcg-presets.ps1 sequentially.

param(
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

Write-Host "=== Generating WCG Menu Shaders ===" -ForegroundColor Cyan
$menuArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDir 'generate-wcg-menu.ps1'))
if ($VerboseLog) { $menuArgs += '-VerboseLog' }
& powershell @menuArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "WCG menu generation failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "`n=== Generating WCG Presets ===" -ForegroundColor Cyan
$presetArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDir 'generate-wcg-presets.ps1'))
if ($VerboseLog) { $presetArgs += '-VerboseLog' }
& powershell @presetArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "WCG preset generation failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "`n=== All WCG content generation complete ===" -ForegroundColor Green
