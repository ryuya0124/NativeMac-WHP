param(
    [ValidateRange(1,24)][int]$MemoryGiB = 12,
    [ValidateRange(1,8)][int]$Processors = 8,
    [switch]$FirmwareOnly,
    [switch]$Gpu,
    [switch]$SerialConsole
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$pathHash = [System.Security.Cryptography.SHA256]::Create()
try { $identity = [BitConverter]::ToString($pathHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot.ToLowerInvariant()))).Replace('-','') }
finally { $pathHash.Dispose() }
$vmMutex = New-Object System.Threading.Mutex($false, "Local\NativeMac-$identity")
$ownsMutex = $false
try {
    try { $ownsMutex = $vmMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (!$ownsMutex) { throw 'This workspace already has a running NativeMac VM.' }
$exe = Join-Path $projectRoot 'backend/openvmm/target/release/openvmm.exe'
if (!(Test-Path -LiteralPath $exe)) { $exe = Join-Path $projectRoot 'backend/openvmm/target/debug/openvmm.exe' }
$firmware = Join-Path $projectRoot 'backend/openvmm/.packages/hyperv.uefi.mscoreuefi.x64.RELEASE/MsvmX64/RELEASE_VS2022/FV/MSVM.fd'
$serial = Join-Path $projectRoot 'artifacts/guest-serial.log'
$workerLog = Join-Path $projectRoot 'artifacts/guest-worker.log'
$serialBackend = "file=$serial"
$vmgs = Join-Path $projectRoot 'backend/media/tahoe-nvram.raw'
if (!(Test-Path -LiteralPath $vmgs)) {
    $stateFile = [System.IO.File]::Create($vmgs)
    try { $stateFile.SetLength(4MB) } finally { $stateFile.Dispose() }
}
if ($SerialConsole) { $serialBackend = 'listen=tcp:127.0.0.1:5906' }
$options = @('--hypervisor','whp','--processors',"$Processors",'--vps-per-socket',"$Processors",'--memory',"${MemoryGiB}G",'--smt','off',
    '--uefi',"firmware=$firmware,console=com1,diagnostics=full",'--com1',$serialBackend,
    '--vnc-listen','127.0.0.1','--vnc-port','5905','--log-file',$workerLog,'--vmgs',"file:$vmgs")
if (!$Gpu) { $options += '--gfx' }
if (!$FirmwareOnly) {
    $prepareOptions = @('--processors',"$Processors")
    if ($Gpu) { $prepareOptions += '--gpu' }
    & python (Join-Path $PSScriptRoot 'Prepare-Boot.py') @prepareOptions
    if ($LASTEXITCODE -ne 0) { throw 'Boot media preparation failed' }
    & (Join-Path $projectRoot 'backend/firmware/opencore-1.0.8-debug/Utilities/ocvalidate/ocvalidate.exe') (Join-Path $projectRoot 'backend/boot/config.plist')
    if ($LASTEXITCODE -ne 0) { throw 'OpenCore configuration validation failed' }
    $manifest = Join-Path $projectRoot 'backend/boot/recovery.nmfat'
    $options += @('--vmbus-scsi','id=boot','--disk',"file:$manifest,ro,on=boot")
    $guestDisk = Join-Path $projectRoot 'backend/media/tahoe.raw'
    if (!(Test-Path -LiteralPath $guestDisk)) {
        $created = [System.IO.File]::Create($guestDisk)
        $created.Dispose()
        & fsutil sparse setflag $guestDisk | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not mark VM disk sparse' }
        $created = [System.IO.File]::OpenWrite($guestDisk)
        try { $created.SetLength(128GB) } finally { $created.Dispose() }
    }
    $options += @('--disk',"file:$guestDisk,on=boot")

}
if ($Gpu) {
    $library = Join-Path $projectRoot 'artifacts/vgpu/reims_vgpu_c.dll'
    $options += @('--pcie-root-complex','rc0,low_mmio=256M,high_mmio=4K',
        '--pcie-root-port','rc0:gpu0,addr=1','--pcie-ecam-below-4gb','--reims-gpu',$library,'--vnc','--net','consomme')
}
Write-Host "Starting WHP VM: RAM ${MemoryGiB} GiB, ${Processors} cores; limits 24 GiB / 8 cores."
& $exe @options
if ($LASTEXITCODE -ne 0) { throw "VM exited with code $LASTEXITCODE" }
} finally {
    if ($ownsMutex) { $vmMutex.ReleaseMutex() }
    $vmMutex.Dispose()
}
