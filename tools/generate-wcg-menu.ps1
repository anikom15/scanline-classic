# Generates WCG menu shaders from SDR menu shaders.
# Rules:
# - Output filename: replace "-sdr" with "-wcg".
# - Change pragma format to 10-bit: R10G10B10A2_UNORM.
# - For each include:
#   * Skip includes that end with -sdr or -hdr before extension.
#   * If a sibling include exists with -wcg appended before extension, use that instead.
#   * Otherwise keep the original include.

param(
    [string]$MenusDir = "${PSScriptRoot}\..\shaders\menus",
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'

function Get-WcgPath([string]$includePath) {
    # Insert -wcg before extension
    $dir = Split-Path $includePath -Parent
    $file = Split-Path $includePath -Leaf
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $ext = [System.IO.Path]::GetExtension($file)
    $wcgFile = ("{0}-wcg{1}" -f $name, $ext)
    if ([string]::IsNullOrWhiteSpace($dir)) { return $wcgFile }
    else { return (Join-Path $dir $wcgFile) }
}

function Should-SkipInclude([string]$includePath) {
    $file = Split-Path $includePath -Leaf
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    return ($name.EndsWith('-sdr') -or $name.EndsWith('-hdr'))
}

function Transform-Shader([string]$inputPath, [string]$outputPath) {
    if ($VerboseLog) { Write-Host "Transforming $inputPath -> $outputPath" }
    $lines = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 -ErrorAction Stop

    # Update pragma format to 10-bit
    $lines = ($lines -replace '(?m)^#pragma\s+format\s+\S+', '#pragma format R10G10B10A2_UNORM')

    # Rewrite includes (PowerShell 5.1-safe: use Regex.Replace with MatchEvaluator)
    $pattern = '^\s*#include\s+"([^"]+)"\s*$'
    $lines = [System.Text.RegularExpressions.Regex]::Replace(
        $lines,
        $pattern,
        { param($match)
            $inc = $match.Groups[1].Value
            if (Should-SkipInclude $inc) {
                if ($VerboseLog) { Write-Host "  Skipping include: $inc" }
                return ''
            }
            $wcg = Get-WcgPath $inc
            $inDir = Split-Path $inputPath -Parent
            if ([string]::IsNullOrWhiteSpace($wcg)) { return ('#include "{0}"' -f $inc) }
            $resolvedWcg = if ([string]::IsNullOrWhiteSpace($inDir)) { $wcg } else { Join-Path $inDir $wcg }
            if (-not [string]::IsNullOrWhiteSpace($resolvedWcg) -and (Test-Path -LiteralPath $resolvedWcg)) {
                if ($VerboseLog) { Write-Host "  Using WCG include: $wcg and original: $inc" }
                return (('#include "{0}"' + "`n" + '#include "{1}"') -f $wcg, $inc)
            } else {
                if ($VerboseLog) { Write-Host "  Keeping include: $inc (no WCG variant found)" }
                return ('#include "{0}"' -f $inc)
            }
        },
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    # Write output
    $outDir = Split-Path $outputPath -Parent
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    Set-Content -LiteralPath $outputPath -Value $lines -Encoding UTF8
}

# Discover SDR menu shaders
$inputs = Get-ChildItem -LiteralPath $MenusDir -Filter 'menu-*-sdr.slang' -File

if (-not $inputs) {
    Write-Warning "No SDR menu shaders found in $MenusDir"
    return
}

foreach ($file in $inputs) {
    $outName = $file.Name -replace '-sdr\.slang$', '-wcg.slang'
    $outPath = Join-Path $file.DirectoryName $outName
    Transform-Shader -inputPath $file.FullName -outputPath $outPath
}

Write-Host "WCG menu shader generation complete."