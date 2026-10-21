param([switch]$Publish)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $projectRoot 'src\TahoeVm\TahoeVm.csproj'
if ($Publish) {
    dotnet publish $project -c Release -r win-x64 --self-contained true -o (Join-Path $projectRoot 'artifacts\app')
} else {
    dotnet build $project -c Debug -p:Platform=x64
}
if ($LASTEXITCODE -ne 0) { throw "Build failed: $LASTEXITCODE" }
