$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
dotnet test (Join-Path $root 'tests\MusicPlayerWin.Core.Tests\MusicPlayerWin.Core.Tests.csproj') -c Release
