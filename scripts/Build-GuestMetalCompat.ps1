param([Parameter(Mandatory=$true)][string]$MacHost)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'artifacts/metal-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
# This fresh directory contains only our authored source files and outputs.
$remote = '/tmp/nativemac-metal-' + [guid]::NewGuid().ToString('N')
$probes = @(
    @{ Source = 'DeferredBindingsProbe.m'; Output = 'deferred-bindings-probe-x64' },
    @{ Source = 'ArgumentBufferProbe.m'; Output = 'argument-buffer-probe-x64' },
    @{ Source = 'TextureReadbackProbe.m'; Output = 'texture-readback-regions-x64' },
    @{ Source = 'SegmentedBlitProbe.m'; Output = 'segmented-blit-probe-x64' }
)
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)" }
}
Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"mkdir $remote")
try {
    Invoke-Checked 'scp' @((Join-Path $root 'native/MetalCompat/DeferredStageBindings.m'),"${MacHost}:$remote/DeferredStageBindings.m")
    Invoke-Checked 'scp' @((Join-Path $root 'native/MetalCompat/SharedTextureReadback.m'),"${MacHost}:$remote/SharedTextureReadback.m")
    $flags = '-arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Metal'
    Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"xcrun clang $flags -dynamiclib $remote/DeferredStageBindings.m $remote/SharedTextureReadback.m -o $remote/deferred-stage-bindings.dylib")
    Invoke-Checked 'scp' @("${MacHost}:$remote/deferred-stage-bindings.dylib",(Join-Path $output 'deferred-stage-bindings.dylib'))
    foreach ($probe in $probes) {
        Invoke-Checked 'scp' @((Join-Path $root "native/MetalProbe/$($probe.Source)"),"${MacHost}:$remote/$($probe.Source)")
        Invoke-Checked 'ssh' @('-o','BatchMode=yes',$MacHost,"xcrun clang $flags $remote/$($probe.Source) -o $remote/$($probe.Output)")
        Invoke-Checked 'scp' @("${MacHost}:$remote/$($probe.Output)",(Join-Path $output $probe.Output))
    }
    Copy-Item -LiteralPath (Join-Path $root 'native/MetalCompat/Run-With-DeferredBindings.sh') -Destination $output
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output 'deferred-stage-bindings.dylib'),(Join-Path $output 'deferred-bindings-probe-x64') | Select-Object Path,Hash
} finally {
    # No recursive deletion or wildcard: all names belong to this invocation.
    foreach ($probe in $probes) {
        & ssh -o BatchMode=yes $MacHost "rm -f $remote/$($probe.Source) $remote/$($probe.Output)"
    }
    & ssh -o BatchMode=yes $MacHost "rm -f $remote/DeferredStageBindings.m $remote/SharedTextureReadback.m $remote/deferred-stage-bindings.dylib"
    & ssh -o BatchMode=yes $MacHost "rmdir $remote"
}
