param(
    [ValidateSet('Release','Debug')][string]$Configuration='Release',
    [string]$Output='artifacts\win-x64'
)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src\MusicPlayerWin.App\MusicPlayerWin.App.csproj'
$outputDir = Join-Path $root $Output

$targetExeName = 'FLACintosh.exe'
$projectExeName = 'MusicPlayerWin.App.exe'

dotnet publish $project `
    -c $Configuration `
    -p:Platform=x64 `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:UseAppHost=true `
    -p:EnableMsixTooling=true `
    -o $outputDir

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$projectExePath = Join-Path $outputDir $projectExeName
if (Test-Path $projectExePath) {
    $standaloneExe = Join-Path $outputDir $targetExeName
    Copy-Item $projectExePath $standaloneExe -Force
    Write-Host "Standalone EXE created: $standaloneExe"
}

Write-Host "Published to $outputDir"
