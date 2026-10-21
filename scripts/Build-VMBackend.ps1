param([switch]$RestorePackages, [switch]$DebugBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$backend = Join-Path $projectRoot 'backend/openvmm'
$pins = Get-Content (Join-Path $projectRoot 'vm/dependencies.json') -Raw | ConvertFrom-Json
if (!(Test-Path -LiteralPath $backend)) {
    & git clone --no-checkout $pins.openvmm.repository $backend
    if ($LASTEXITCODE -ne 0) { throw 'OpenVMM clone failed' }
    & git -C $backend checkout --detach $pins.openvmm.commit
    if ($LASTEXITCODE -ne 0) { throw 'OpenVMM checkout failed' }
}
$revision = & git -C $backend rev-parse HEAD
if ($revision -ne $pins.openvmm.commit) { throw "Unexpected OpenVMM revision: $revision" }
$patch = Join-Path $projectRoot $pins.openvmm.patch
& git -C $backend apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $backend apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch does not match this checkout; local changes were preserved.' }
    & git -C $backend apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'OpenVMM patch failed' }
}
$gpuCrate = Join-Path $backend 'vm/devices/nativemac_vgpu'
New-Item -ItemType Directory -Path $gpuCrate -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'native/VGpuPci/Cargo.openvmm.toml') -Destination (Join-Path $gpuCrate 'Cargo.toml')
Push-Location $backend
try {
    if ($RestorePackages) {
        & cargo xflowey restore-packages
        if ($LASTEXITCODE -ne 0) { throw 'Package restore failed' }
    }
    $buildOptions = @('build','-p','openvmm','--no-default-features','--features','virt_whp,net_consomme')
    if (!$DebugBuild) { $buildOptions += '--release' }
    & cargo @buildOptions
    if ($LASTEXITCODE -ne 0) { throw 'OpenVMM build failed; stop this workspace VM before relinking.' }
} finally { Pop-Location }
