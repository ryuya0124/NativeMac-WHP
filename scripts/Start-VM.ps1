param(
    [ValidateRange(1,256)][int]$MemoryGiB = 12,
    [ValidateRange(1,64)][int]$Processors = 8,
    [switch]$FirmwareOnly,
    [switch]$Gpu,
    [switch]$SerialConsole,
    [switch]$EphemeralDisk,
    [switch]$DevelopmentSigning,
    [switch]$HostMetalEntry,
    [switch]$HostMemoryArchitecture,
    [switch]$SharedGpuVideo,
    [switch]$ExactHalfBlend,
    [ValidateSet('legacy','compat')][string]$MetalTransport,
    [ValidateSet('1920x1080','2560x1440','3840x2160')][string]$DisplayResolution,
    [ValidateRange(30,240)][int]$DisplayRefreshHz
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$defaults = Get-Content (Join-Path $projectRoot 'vm/defaults.json') -Raw | ConvertFrom-Json
if (!$PSBoundParameters.ContainsKey('DevelopmentSigning') -and $defaults.developmentSigning) { $DevelopmentSigning = $true }
if ($Gpu -and !$FirmwareOnly) {
    if (!$PSBoundParameters.ContainsKey('SharedGpuVideo') -and $defaults.sharedGpuVideo) { $SharedGpuVideo = $true }
    if (!$PSBoundParameters.ContainsKey('ExactHalfBlend') -and $defaults.gpuExactHalfBlend) { $ExactHalfBlend = $true }
}
if ($SharedGpuVideo -and (!$Gpu -or $FirmwareOnly -or !$defaults.systemVideoBridge)) { throw '-SharedGpuVideo requires -Gpu, a full guest and the system video service.' }
if ($HostMetalEntry -and (!$DevelopmentSigning -or !$Gpu)) { throw '-HostMetalEntry requires development signing and -Gpu.' }
if ($HostMemoryArchitecture -and !$HostMetalEntry) { throw '-HostMemoryArchitecture requires -HostMetalEntry.' }
if (!$DisplayRefreshHz) {
    $DisplayRefreshHz = if ($defaults.displayRefreshHz) { [int]$defaults.displayRefreshHz } else { 60 }
}
if ($DisplayRefreshHz -lt 30 -or $DisplayRefreshHz -gt 240) { throw 'Display refresh rate must be 30..240 Hz.' }
if (!$DisplayResolution) {
    $DisplayResolution = if ($defaults.displayResolution) { [string]$defaults.displayResolution } else { '1920x1080' }
}
if ($DisplayResolution -notin @('1920x1080','2560x1440','3840x2160')) { throw 'Unsupported display resolution.' }
if (!$MetalTransport) {
    $MetalTransport = if ($defaults.gpuTransport) { [string]$defaults.gpuTransport } else { 'legacy' }
}
if ($MetalTransport -notin @('legacy','compat')) { throw 'Unknown GPU transport in VM defaults.' }
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
$vmgsSpec = if ($EphemeralDisk) { "memdiff:file:$vmgs" } else { "file:$vmgs" }
$options = @('--hypervisor','whp','--processors',"$Processors",'--vps-per-socket',"$Processors",'--memory',"${MemoryGiB}G",'--smt','off',
    '--uefi',"firmware=$firmware,console=com1,diagnostics=full",'--com1',$serialBackend,
    '--vnc-listen','127.0.0.1','--vnc-port','5905','--log-file',$workerLog,'--vmgs',$vmgsSpec)
if (!$Gpu) { $options += '--gfx' }
if (!$FirmwareOnly) {
    $prepareOptions = @('--processors',"$Processors",'--resolution',$DisplayResolution)
    if ($DevelopmentSigning) { $prepareOptions += '--development-signing' }
    if ($HostMetalEntry) { $prepareOptions += '--host-metal-entry' }
    if ($HostMemoryArchitecture) { $prepareOptions += '--host-memory-architecture' }
    if ($Gpu) { $prepareOptions += '--gpu' }
    if ($Gpu) {
        # Ask the same Windows Vulkan DLL and default-device selection used by
        # the VM. Never pick the first Win32_VideoController (often an iGPU),
        # reuse a previous launch's name, or fall back to a configured label.
        $identityLibrary = Join-Path $projectRoot 'artifacts/vgpu/reims_vgpu_c.dll'
        $identityReport = Join-Path $projectRoot 'artifacts/host-renderer-identity.json'
        $identityOutput = & python (Join-Path $PSScriptRoot 'Probe-VGpu.py') $identityLibrary --identity-only --report $identityReport
        if ($LASTEXITCODE -ne 0) { throw 'Could not identify the actual Windows Vulkan renderer.' }
        $hostIdentity = ($identityOutput -join "`n") | ConvertFrom-Json
        if (!$hostIdentity.hostGPUName) { throw 'The selected Windows renderer has no usable name.' }
        if ($hostIdentity.vulkanDeviceType -eq 4) { throw 'The selected Vulkan renderer is a CPU device; a hardware GPU is required.' }
        $prepareOptions += @('--gpu-name', [string]$hostIdentity.hostGPUName)
        if ($null -ne $hostIdentity.hostHasUnifiedMemory) {
            $prepareOptions += @('--gpu-unified-memory', ([string][bool]$hostIdentity.hostHasUnifiedMemory).ToLowerInvariant())
        }
        Write-Host "Windows GPU renderer: $($hostIdentity.hostGPUName)"
    }
    if ($Gpu -and $MetalTransport -eq 'compat') {
        $prepareOptions += '--metal-compat'
        if ($defaults.rejectAstcTextures) { $prepareOptions += '--reject-astc' }
    }
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
    $guestDiskSpec = if ($EphemeralDisk) { "memdiff:file:$guestDisk,on=boot" } else { "file:$guestDisk,on=boot" }
    $options += @('--disk',$guestDiskSpec)

}
if ($Gpu) {
    $library = Join-Path $projectRoot 'artifacts/vgpu/reims_vgpu_c.dll'
    $options += @('--pcie-root-complex','rc0,low_mmio=256M,high_mmio=4K',
        '--pcie-root-port','rc0:gpu0,addr=1','--pcie-ecam-below-4gb','--reims-gpu',$library,'--vnc','--net','consomme')
}
Write-Host "Starting WHP VM: RAM ${MemoryGiB} GiB, ${Processors} cores, $DisplayResolution at $DisplayRefreshHz Hz; limits 256 GiB / 64 cores."
# The OpenVMM worker inherits this per-launch setting. No machine environment is changed.
$previousResolution = $env:NATIVEMAC_DISPLAY_RESOLUTION
$previousRefresh = $env:REIMS_VGPU_WINDOW_REFRESH
$previousGpuControl = $env:NATIVEMAC_VIDEO_CONTROL_FILE
$previousExact = $env:REIMS_VGPU_EXACT
$ownedGpuControl = $null
$videoSession = $null
try {
    $env:NATIVEMAC_DISPLAY_RESOLUTION = $DisplayResolution
    $env:REIMS_VGPU_WINDOW_REFRESH = [string]$DisplayRefreshHz
    if ($ExactHalfBlend) {
        $forms = @($env:REIMS_VGPU_EXACT -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ('half_blend' -notin $forms -and 'all' -notin $forms) { $forms += 'half_blend' }
        $env:REIMS_VGPU_EXACT = $forms -join ','
        Write-Host 'GPU compatibility: exact half blending enabled for this launch.'
    }
    if ($SharedGpuVideo -and !$env:NATIVEMAC_VIDEO_CONTROL_FILE) {
        $controlDirectory = Join-Path $projectRoot 'artifacts/video-service'
        New-Item -ItemType Directory -Path $controlDirectory -Force | Out-Null
        $ownedGpuControl = Join-Path $controlDirectory ("gpu-control-" + [guid]::NewGuid().ToString('N') + '.bin')
        $bytes = New-Object byte[] 36
        [BitConverter]::GetBytes([uint32]54888).CopyTo($bytes, 0)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $secret = New-Object byte[] 32; $random.GetBytes($secret); $secret.CopyTo($bytes, 4) } finally { $random.Dispose() }
        [IO.File]::WriteAllBytes($ownedGpuControl, $bytes)
        $env:NATIVEMAC_VIDEO_CONTROL_FILE = $ownedGpuControl
    }
    if ($Gpu -and $defaults.systemVideoBridge) {
        Write-Host 'Preparing the VM-owned hardware video service before GPU startup.'
        $videoSession = & (Join-Path $PSScriptRoot 'Start-VideoBridge.ps1') -LauncherPid $PID
    }
    & $exe @options
} finally {
    if ($videoSession -and !$videoSession.Process.HasExited) {
        [System.IO.File]::WriteAllText($videoSession.StopFile, 'stop')
        if (!$videoSession.Process.WaitForExit(5000)) { $videoSession.Process.Kill() }
    }
    if ($videoSession) {
        foreach ($path in @($videoSession.StopFile, $videoSession.ReadyFile)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    }
    $env:NATIVEMAC_DISPLAY_RESOLUTION = $previousResolution
    $env:REIMS_VGPU_WINDOW_REFRESH = $previousRefresh
    $env:NATIVEMAC_VIDEO_CONTROL_FILE = $previousGpuControl
    $env:REIMS_VGPU_EXACT = $previousExact
    if ($ownedGpuControl -and (Test-Path -LiteralPath $ownedGpuControl)) { Remove-Item -LiteralPath $ownedGpuControl }
}
if ($LASTEXITCODE -ne 0) { throw "VM exited with code $LASTEXITCODE" }
} finally {
    if ($ownsMutex) { $vmMutex.ReleaseMutex() }
    $vmMutex.Dispose()
}
