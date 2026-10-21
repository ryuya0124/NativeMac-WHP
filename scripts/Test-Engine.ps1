$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$probe = Join-Path $projectRoot 'artifacts\native\native-probe.exe'
if (-not (Test-Path -LiteralPath $probe)) { throw 'Run scripts/Build-Native.ps1 first.' }
$runs = @()
foreach ($index in 1..3) {
    $json = & $probe
    if ($LASTEXITCODE -ne 0) { throw "CPU probe failed: $json" }
    $cpu = $json | ConvertFrom-Json
    if ($cpu.status -ne 'passed' -or $cpu.rax -ne '0x123456789ABCDEF1' -or
        $cpu.storedValue -ne $cpu.rax -or $cpu.guestVendor -ne $cpu.hostVendor -or
        $cpu.serial -ne 'WHP x64 OK' -or $cpu.ioExits -lt 1 -or $cpu.macOsBooted) {
        throw "CPU result verification failed: $json"
    }
    $runs += $cpu
}
$json = & $probe --gpu
if ($LASTEXITCODE -ne 0) { throw "GPU probe failed: $json" }
$gpu = $json | ConvertFrom-Json
if ($gpu.status -ne 'passed' -or -not $gpu.hardware -or $gpu.cpuFallback -or
    $gpu.stage -ne 'GpuPixelsVerified' -or $gpu.guestGpuAccelerated) {
    throw "Hardware GPU verification failed: $json"
}
$report = [ordered]@{ cpuRuns = $runs; gpu = $gpu; macOsBooted = $false }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $projectRoot 'artifacts\engine-tests.json') -Encoding utf8
Write-Output "PASS: 3 hardware x64 guests; guest registers, RAM and I/O verified."
Write-Output "PASS: GPU shader pixels verified on $($gpu.adapter); no CPU fallback."
