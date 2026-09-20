param(
    [string]$Version = '0.1.0',
    [ValidateSet('Release','Debug')][string]$Configuration = 'Release',
    [string]$Output = 'artifacts\win-x64'
)

$ErrorActionPreference = 'Stop'
$Version = $Version -replace '^[vV]', ''

$root = Split-Path -Parent $PSScriptRoot
$artifactDir = Join-Path $root $Output
$exePath = Join-Path $artifactDir 'FLACintosh.exe'

Write-Host "==> Publishing Windows x64 EXE build"
& (Join-Path $root 'scripts\publish-win-x64.ps1') -Configuration $Configuration -Output $Output

if (-not (Test-Path $artifactDir)) {
    throw "Expected build output at $artifactDir but it was not created."
}

$sourceExe = Join-Path $artifactDir 'FLACintosh.exe'
if (-not (Test-Path $sourceExe)) {
    throw "Expected EXE at $sourceExe but it was not created."
}

Copy-Item $sourceExe $exePath -Force
Write-Host "==> EXE created: $exePath"
