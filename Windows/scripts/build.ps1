param([ValidateSet('Release','Debug')][string]$Configuration='Release')
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
dotnet restore (Join-Path $root 'MusicPlayerWin.sln')
dotnet build (Join-Path $root 'MusicPlayerWin.sln') -c $Configuration
