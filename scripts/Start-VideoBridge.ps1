param([int]$LauncherPid = $PID)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$videoConfig = Join-Path $projectRoot 'artifacts/video-service-config.json'
if (!(Test-Path -LiteralPath $videoConfig)) { throw 'Missing local video-service configuration. See native/VideoBridge/README.md.' }
$logDirectory = Join-Path $projectRoot 'artifacts/video-service'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$nonce = [guid]::NewGuid().ToString('N')
$stopFile = Join-Path $logDirectory "stop-$nonce"
$readyFile = Join-Path $logDirectory "ready-$nonce.json"
$pythonExecutable = (& python -c 'import sys; print(sys.executable)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Python executable lookup failed.' }
$videoScript = Join-Path $PSScriptRoot 'Run-VideoBridge.py'
$process = Start-Process -FilePath $pythonExecutable -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
    -ArgumentList "`"$videoScript`" --config `"$videoConfig`" --vm-launcher-pid $LauncherPid --stop-file `"$stopFile`" --ready-file `"$readyFile`"" `
    -RedirectStandardOutput (Join-Path $logDirectory 'launcher.log') `
    -RedirectStandardError (Join-Path $logDirectory 'launcher-error.log')
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(100)
    while (!(Test-Path -LiteralPath $readyFile)) {
        if ($process.HasExited) { throw 'Hardware video service startup failed; inspect artifacts/video-service/launcher-error.log.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Hardware video service startup deadline exceeded.' }
        Start-Sleep -Milliseconds 200
    }
    $ready = Get-Content -LiteralPath $readyFile -Raw | ConvertFrom-Json
    if ($ready.servicePid -ne $process.Id -or $ready.launcherPid -ne $LauncherPid -or $process.HasExited) { throw 'Unexpected video service readiness owner.' }
    [pscustomobject]@{ Process = $process; StopFile = $stopFile; ReadyFile = $readyFile }
} catch {
    [IO.File]::WriteAllText($stopFile, 'stop')
    if (!$process.HasExited -and !$process.WaitForExit(5000)) { $process.Kill() }
    foreach ($path in @($stopFile, $readyFile)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    throw
}
