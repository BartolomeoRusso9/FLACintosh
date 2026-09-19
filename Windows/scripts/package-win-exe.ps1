param(
    [string]$Version = '0.1.0',
    [ValidateSet('Release','Debug')][string]$Configuration = 'Release',
    [string]$Output = 'artifacts\win-x64'
)

$ErrorActionPreference = 'Stop'
$Version = $Version -replace '^[vV]', ''

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$artifactDir = Join-Path $root $Output
$zipPath = Join-Path $dist "MusicPlayerWin-$Version-win-x64.zip"

Write-Host "==> Publishing Windows x64 build"
& (Join-Path $root 'scripts\publish-win-x64.ps1') -Configuration $Configuration -Output $Output

if (-not (Test-Path $artifactDir)) {
    throw "Expected build output at $artifactDir but it was not created."
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path (Join-Path $artifactDir '*') -DestinationPath $zipPath -Force

Write-Host "==> ZIP created: $zipPath"
