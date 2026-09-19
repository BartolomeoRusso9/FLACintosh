param(
    [ValidateSet('Release','Debug')][string]$Configuration='Release',
    [string]$Output='artifacts\win-x64'
)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src\MusicPlayerWin.App\MusicPlayerWin.App.csproj'
dotnet publish $project -c $Configuration -r win-x64 --self-contained true -p:PublishSingleFile=false -o (Join-Path $root $Output)
Write-Host "Published to $(Join-Path $root $Output)"
