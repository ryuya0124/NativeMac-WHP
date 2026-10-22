param([Parameter(Mandatory=$true)][string]$MacHost)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'artifacts/metal-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
# This fresh directory contains only our two authored source files and outputs.
$remote = '/tmp/nativemac-metal-' + [guid]::NewGuid().ToString('N')
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)" }
}
Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"mkdir $remote")
try {
    Invoke-Checked 'scp' @((Join-Path $root 'native/MetalCompat/DeferredStageBindings.m'),"${MacHost}:$remote/DeferredStageBindings.m")
    Invoke-Checked 'scp' @((Join-Path $root 'native/MetalProbe/DeferredBindingsProbe.m'),"${MacHost}:$remote/DeferredBindingsProbe.m")
    $flags = '-arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Metal'
    Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"xcrun clang $flags -dynamiclib $remote/DeferredStageBindings.m -o $remote/deferred-stage-bindings.dylib")
    Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"xcrun clang $flags $remote/DeferredBindingsProbe.m -o $remote/deferred-bindings-probe-x64")
    Invoke-Checked 'scp' @("${MacHost}:$remote/deferred-stage-bindings.dylib",(Join-Path $output 'deferred-stage-bindings.dylib'))
    Invoke-Checked 'scp' @("${MacHost}:$remote/deferred-bindings-probe-x64",(Join-Path $output 'deferred-bindings-probe-x64'))
    Copy-Item -LiteralPath (Join-Path $root 'native/MetalCompat/Run-With-DeferredBindings.sh') -Destination $output
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output 'deferred-stage-bindings.dylib'),(Join-Path $output 'deferred-bindings-probe-x64') | Select-Object Path,Hash
} finally {
    # No recursive deletion or wildcard: all names belong to this invocation.
    & ssh -o BatchMode=yes $MacHost "rm -f $remote/DeferredStageBindings.m $remote/DeferredBindingsProbe.m $remote/deferred-stage-bindings.dylib $remote/deferred-bindings-probe-x64"
    & ssh -o BatchMode=yes $MacHost "rmdir $remote"
}
