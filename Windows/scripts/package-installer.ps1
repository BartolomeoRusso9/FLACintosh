param(
    [ValidateSet('Release','Debug')][string]$Configuration='Release',
    [string]$Iscc='ISCC.exe'
)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'scripts\publish-win-x64.ps1') -Configuration $Configuration
$iss = Join-Path $root 'installer\MusicPlayerWin.iss'
& $Iscc $iss
Write-Host "Installer created under $root\artifacts\installer"
