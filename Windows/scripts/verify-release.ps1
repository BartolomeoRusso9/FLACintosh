param([string]$Configuration='Release')
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$solution = Join-Path $root 'MusicPlayerWin.sln'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'dotnet SDK not found. Install .NET 8 SDK before building.' }
& dotnet --info | Select-Object -First 18
& dotnet restore $solution
& dotnet build $solution -c $Configuration --no-restore -p:Platform=x64
& dotnet test (Join-Path $root 'tests/MusicPlayerWin.Core.Tests/MusicPlayerWin.Core.Tests.csproj') -c $Configuration --no-restore
