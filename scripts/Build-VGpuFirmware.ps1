param([string]$Source = (Join-Path $env:USERPROFILE '.cache/nativemac-reims-whp'))
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$clang = Join-Path $projectRoot 'backend/llvm-22.1.8/bin/clang.exe'
$linker = Join-Path $projectRoot 'backend/llvm-22.1.8/bin/lld-link.exe'
$outputDir = Join-Path $projectRoot 'artifacts/vgpu-firmware'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$objects = @()
foreach ($name in @('ReimsVgpu','GraphicsOutput','ComponentName')) {
    $object = Join-Path $outputDir "$name.obj"
    & $clang --target=x86_64-unknown-windows -Os -ffreestanding -fshort-wchar -funsigned-char `
        -fno-ms-extensions -fno-stack-protector -mno-stack-arg-probe -mno-red-zone -mno-implicit-float `
        -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections `
        -ftrap-function=undefined_behavior_has_been_optimized_away_by_clang -Wall -Wextra -Werror -Wno-unused-parameter `
        -c (Join-Path $Source "firmware/src/$name.c") -o $object
    if ($LASTEXITCODE -ne 0) { throw "Firmware compilation failed: $name" }
    $objects += $object
}
& $linker /nologo /nodefaultlib /dll /driver /base:0 /machine:x64 /subsystem:efi_boot_service_driver `
    /entry:ReimsVgpuEntryPoint /opt:ref /align:32 /filealign:32 /Brepro "/out:$outputDir/ReimsVgpu.efi" @objects
if ($LASTEXITCODE -ne 0) { throw 'Firmware linking failed' }
