param([Parameter(Mandatory=$true)][string]$FfmpegHeaders,[string]$NvdecHeaders,[string]$VulkanHeaders,[switch]$InteropProbeOnly,[switch]$GpuExportOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$headerRoot = (Resolve-Path -LiteralPath $FfmpegHeaders).Path
$nvHeaders = if ($NvdecHeaders) { (Resolve-Path -LiteralPath $NvdecHeaders).Path } else { $null }
$vkHeaders = if ($VulkanHeaders) { (Resolve-Path -LiteralPath $VulkanHeaders).Path } else { $null }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsPath) { throw 'Visual Studio C++ tools are required.' }
$vcTools = Get-ChildItem (Join-Path $vsPath 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$sdkVersion = '10.0.26100.0'
$buildDir = Join-Path $projectRoot 'artifacts/video-worker'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$compiler = Join-Path $vcTools.FullName 'bin/Hostx64/x64/cl.exe'
$options = @('/nologo','/std:c++20','/EHsc','/W4','/WX','/O2','/MT','/utf-8',"/external:I$headerRoot",'/external:W0',
    "/I$($vcTools.FullName)/include", "/I$sdkRoot/Include/$sdkVersion/ucrt",
    "/I$sdkRoot/Include/$sdkVersion/um", "/I$sdkRoot/Include/$sdkVersion/shared")
Push-Location $buildDir
try {
    if ($InteropProbeOnly -or $GpuExportOnly) {
        if ($InteropProbeOnly -and $GpuExportOnly) { throw 'Choose one GPU worker mode.' }
        if (!$NvdecHeaders -or !$VulkanHeaders) { throw 'The interop probe requires NVDEC and Vulkan headers.' }
        $mode = if ($GpuExportOnly) { '/DNATIVEMAC_GPU_FRAME_EXPORT' } else { '/DNATIVEMAC_GPU_INTEROP_PROBE' }
        $output = if ($GpuExportOnly) { '/Fe:NativeMacNvdecGpuWorker.exe' } else { '/Fe:NativeMacNvdecInteropProbe.exe' }
        & $compiler @options "/external:I$nvHeaders" "/external:I$vkHeaders" $mode `
            (Join-Path $projectRoot 'native/VideoBridge/NvdecWorker.cpp') (Join-Path $projectRoot 'native/VideoBridge/GpuFrameInterop.cpp') `
            $output /link "/LIBPATH:$($vcTools.FullName)/lib/x64" `
            "/LIBPATH:$sdkRoot/Lib/$sdkVersion/um/x64" "/LIBPATH:$sdkRoot/Lib/$sdkVersion/ucrt/x64" kernel32.lib
        if ($LASTEXITCODE -ne 0) { throw 'GPU interop probe build failed.' }
        return
    }
    & $compiler @options (Join-Path $projectRoot 'native/VideoBridge/CodecWorker.cpp') /Fe:NativeMacCodecWorker.exe /link `
        "/LIBPATH:$($vcTools.FullName)/lib/x64" "/LIBPATH:$sdkRoot/Lib/$sdkVersion/um/x64" "/LIBPATH:$sdkRoot/Lib/$sdkVersion/ucrt/x64" kernel32.lib
    if ($LASTEXITCODE -ne 0) { throw 'Video worker build failed.' }
    if ($NvdecHeaders) {
        & $compiler @options "/external:I$nvHeaders" (Join-Path $projectRoot 'native/VideoBridge/NvdecWorker.cpp') /Fe:NativeMacNvdecWorker.exe /link `
            "/LIBPATH:$($vcTools.FullName)/lib/x64" "/LIBPATH:$sdkRoot/Lib/$sdkVersion/um/x64" "/LIBPATH:$sdkRoot/Lib/$sdkVersion/ucrt/x64" kernel32.lib
        if ($LASTEXITCODE -ne 0) { throw 'NVDEC worker build failed.' }
    }
} finally { Pop-Location }
