param([string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'Visual Studio C++ x64 build tools are required.' }
$vcTools = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkVersion = '10.0.26100.0'
$compiler = Join-Path $vcTools.FullName 'bin\Hostx64\x64\cl.exe'
$buildDir = Join-Path $projectRoot 'artifacts\native'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$common = @('/nologo', '/std:c++20', '/EHsc', '/W4', '/O2', '/MT', '/utf-8',
    "/I$($vcTools.FullName)\include", "/I$sdkRoot\Include\$sdkVersion\ucrt",
    "/I$sdkRoot\Include\$sdkVersion\um", "/I$sdkRoot\Include\$sdkVersion\shared",
    "/I$sdkRoot\Include\$sdkVersion\winrt")
$libs = @("/LIBPATH:$($vcTools.FullName)\lib\x64", "/LIBPATH:$sdkRoot\Lib\$sdkVersion\um\x64",
    "/LIBPATH:$sdkRoot\Lib\$sdkVersion\ucrt\x64")
Push-Location $buildDir
try {
    & $compiler @common /LD (Join-Path $projectRoot 'native\NativeMac.WHP\Engine.cpp') (Join-Path $projectRoot 'native\NativeMac.WHP\Gpu.cpp') /Fe:NativeMac.WHP.dll /link @libs WinHvPlatform.lib d3d11.lib dxgi.lib d3dcompiler.lib
    if ($LASTEXITCODE -ne 0) { throw "Native engine build failed: $LASTEXITCODE" }
    & $compiler @common (Join-Path $projectRoot 'native\NativeMac.WHP\ProbeMain.cpp') /Fe:native-probe.exe /link @libs NativeMac.WHP.lib
    if ($LASTEXITCODE -ne 0) { throw "Native probe build failed: $LASTEXITCODE" }
} finally { Pop-Location }
