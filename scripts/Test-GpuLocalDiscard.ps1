param(
    [Parameter(Mandatory=$true)][string]$RuntimeSource,
    [string]$LlvmAs,
    [string]$SpirvVal
)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$source=(Resolve-Path -LiteralPath $RuntimeSource).Path.Replace('\','/')
if (!$LlvmAs) { $LlvmAs=Join-Path $project 'artifacts/tools/llvm-22.1.8/llvm-as.exe' }
if (!$SpirvVal) { $SpirvVal=Join-Path $project 'artifacts/tools/spirv-tools/spirv-val.exe' }
$fixture=Join-Path $source 'crates/metal2vulkan-validation/fixtures/public/engine/tob_renders.ll'
foreach ($inputPath in @($LlvmAs,$SpirvVal,$fixture)) {
    if (!(Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "Missing prerequisite: $inputPath" }
}
$output=Join-Path $project 'artifacts/discard-clear-gpu'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$runtimePath=ConvertTo-Json "$source/crates/metal2vulkan-runtime" -Compress
$translatorPath=ConvertTo-Json "$source/crates/metal2vulkan" -Compress
$probePath=ConvertTo-Json ((Join-Path $project 'native/MetalProbe/DiscardClearGpu.rs').Replace('\','/')) -Compress
$manifest=@"
[package]
name="nativemac-discard-clear-gpu"
version="0.1.0"
edition="2024"
[[bin]]
name="discard-clear-gpu"
path=$probePath
[dependencies]
metal2vulkan-runtime={path=$runtimePath}
metal2vulkan={path=$translatorPath}
serde_json="1"
"@
$manifestPath=Join-Path $output 'Cargo.toml'
[IO.File]::WriteAllText($manifestPath,$manifest,[Text.UTF8Encoding]::new($false))
$air=Join-Path $output 'tob_renders.bc'
& $LlvmAs $fixture -o $air
if ($LASTEXITCODE) { throw 'Assembling the authored public fixture failed' }
$hasher=[Security.Cryptography.SHA256]::Create()
try { $pathHash=([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($source)))).Replace('-','').Substring(0,12).ToLowerInvariant() }
finally { $hasher.Dispose() }
$savedTarget=$env:CARGO_TARGET_DIR
$savedLlvm=$env:METAL2VULKAN_LLVM_AS
$savedValidator=$env:METAL2VULKAN_SPIRV_VAL
try {
    $env:CARGO_TARGET_DIR=Join-Path $env:USERPROFILE ".cache/nativemac-discard-clear-gpu-$pathHash"
    $env:METAL2VULKAN_LLVM_AS=$LlvmAs
    $env:METAL2VULKAN_SPIRV_VAL=$SpirvVal
    cargo build --manifest-path $manifestPath --release
    if ($LASTEXITCODE) { throw 'GPU probe build failed' }
    & (Join-Path $env:CARGO_TARGET_DIR 'release/discard-clear-gpu.exe') $air
    if ($LASTEXITCODE) { throw "GPU path/byte check failed ($LASTEXITCODE)" }
} finally {
    $env:CARGO_TARGET_DIR=$savedTarget
    $env:METAL2VULKAN_LLVM_AS=$savedLlvm
    $env:METAL2VULKAN_SPIRV_VAL=$savedValidator
}
