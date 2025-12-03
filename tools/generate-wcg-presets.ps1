# Generates WCG presets from SDR presets.
# Rules:
# - Scan uhd-4k-sdr for all .slangp files recursively.
# - Replace any shader path containing `-sdr.slang` with `-wcg.slang`.
# - Verify the replaced shader file exists and warn if not found.
# - Write outputs to uhd-4k-wcg with matching directory structure and filenames.

param(
    [string]$SdrPresetsDir = "${PSScriptRoot}\..\presets\uhd-4k-sdr",
    [string]$WcgPresetsDir = "${PSScriptRoot}\..\presets\uhd-4k-wcg",
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'

function Transform-Preset([string]$inputPath, [string]$outputPath) {
    if ($VerboseLog) { Write-Host "Transforming $inputPath -> $outputPath" }
    $lines = Get-Content -LiteralPath $inputPath -Encoding UTF8 -ErrorAction Stop
    
    $transformedLines = @()
    $inputDir = Split-Path $inputPath -Parent
    
    foreach ($line in $lines) {
        # Match lines like: shader0 = ../../../shaders/menus/menu-sdr.slang
        if ($line -match '^(\s*shader\d+\s*=\s*)(.+)$') {
            $prefix = $matches[1]
            $shaderPath = $matches[2].Trim()
            
            if ($shaderPath -match '-sdr\.slang$') {
                $wcgPath = $shaderPath -replace '-sdr\.slang$', '-wcg.slang'
                
                # Resolve the path relative to the input file to verify existence
                $resolvedWcg = Join-Path $inputDir $wcgPath
                $resolvedWcg = [System.IO.Path]::GetFullPath($resolvedWcg)
                
                if (Test-Path -LiteralPath $resolvedWcg) {
                    if ($VerboseLog) { Write-Host "  Replaced: $shaderPath -> $wcgPath" }
                    $transformedLines += "$prefix$wcgPath"
                } else {
                    Write-Warning "WCG shader not found: $resolvedWcg (referenced in $inputPath)"
                    if ($VerboseLog) { Write-Host "  Keeping original: $shaderPath (WCG not found)" }
                    $transformedLines += $line
                }
            } else {
                $transformedLines += $line
            }
        } else {
            $transformedLines += $line
        }
    }
    
    # Write output (UTF-8 without BOM)
    $outDir = Split-Path $outputPath -Parent
    if (-not (Test-Path -LiteralPath $outDir)) { 
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null 
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($outputPath, $transformedLines, $utf8NoBom)
}

# Discover all .slangp files in SDR presets
if (-not (Test-Path -LiteralPath $SdrPresetsDir)) {
    Write-Error "SDR presets directory not found: $SdrPresetsDir"
    return
}

$inputs = Get-ChildItem -LiteralPath $SdrPresetsDir -Filter '*.slangp' -File -Recurse

if (-not $inputs) {
    Write-Warning "No .slangp presets found in $SdrPresetsDir"
    return
}

foreach ($file in $inputs) {
    # Calculate relative path from SDR root
    $sdrDirNormalized = [System.IO.Path]::GetFullPath($SdrPresetsDir)
    $relativePath = $file.FullName.Substring($sdrDirNormalized.Length).TrimStart('\', '/')
    $outPath = Join-Path $WcgPresetsDir $relativePath
    Transform-Preset -inputPath $file.FullName -outputPath $outPath
}

Write-Host "WCG preset generation complete."
