param([Parameter(Mandatory=$true)][string]$Command)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$session = Get-Content (Join-Path $projectRoot 'artifacts/vm-session.json') -Raw | ConvertFrom-Json
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $session.controlPipe, [System.IO.Pipes.PipeDirection]::Out)
try {
    $pipe.Connect(3000)
    $writer = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)))
    try { $writer.WriteLine($Command); $writer.Flush() } finally { $writer.Dispose() }
} finally { $pipe.Dispose() }
