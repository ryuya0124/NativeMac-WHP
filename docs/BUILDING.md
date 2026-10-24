# Build prerequisites and local assets

This repository contains source and patches. Apple installation media, guest disks, firmware binaries, compiled DLLs and dependency checkouts are excluded. The current checkout is a working development environment; cloning this repository alone does not download every prerequisite.

- Windows x64 with hardware virtualization and Windows Hypervisor Platform.
- .NET 10, Windows SDK 10.0.26100.0, Visual Studio C++ x64 build tools, Rust MSVC and Python 3.
- Exact upstream revisions are in `vm/dependencies.json`.

## Backend and firmware

1. `scripts/Build-VMBackend.ps1 -RestorePackages` clones the pinned OpenVMM, applies the patch and builds the WHP backend. The custom PCI crate reads `native/VGpuPci/device.rs` from this repository.
2. Clone Reims at its pinned revision into a separate worktree, apply `patches/reims-msvc.patch`, then run `cargo +1.98.1 build -p reims-vgpu-c --no-default-features --features vulkan --release --locked` with MSVC lib.exe and Ninja on PATH. Copy `reims_vgpu_c.dll` into `artifacts/vgpu/`. No QEMU submodule or frontend is required.
3. Put clang.exe and lld-link.exe from LLVM 22.1.8 in `backend/llvm-22.1.8/bin/`. Run `scripts/Build-VGpuFirmware.ps1 -Source <Reims-worktree>`.
4. Extract OpenCore 1.0.8 DEBUG into `backend/firmware/opencore-1.0.8-debug/`, and Hyper-V EFI 0.4.0 into `backend/firmware/hyperv-0.4.0/`. Clone AMD_Vanilla into `backend/amd-vanilla/`. Obtain the cpu_syscall_init MSR patch from Qonfused's Hyper-V patch source and place its patch.plist in `backend/firmware/hyperv-msr-patch/`.
5. Build the patched MacHyperVSupportMonterey target for x86_64 on a Mac using Xcode, MacKernelSDK and Lilu SDK. Put the bundle in `artifacts/machyperv/MacHyperVSupportMonterey.kext`.
6. Compile `native/Acpi/SSDT-NM-VMBUS.dsl` using iasl 20250807 and place `SSDT-NM-VMBUS.aml` in `artifacts/`.

The shared-GPU video candidate uses the Reims snapshot
`1b9a256573aa84b3aaaac5935dcdf0289e8256da`, followed by
`patches/reims-msvc.patch` and `patches/reims-shared-gpu-video.patch`.
Its Metal2Vulkan dependency follows the resident-search and fetch-product
patches, then `patches/metal2vulkan-completion-wakes.patch` on base
`79aafca3482a54429bab8e09b62ef558baf4cff1` (resulting source
`2b5f37cbb8c1299336f87fd15be669536ba65064`, runtime version 1185).
Use a local Cargo dependency override for both `metal2vulkan` and
`metal2vulkan-runtime` to that checkout, rather than the older manifest's Git pin.
Build the Vulkan C library and the current OpenVMM PCI source together.
The additive import API must exist before enabling `sharedGpuVideo`.
Build the dedicated NVDEC export worker with `-GpuExportOnly`, Vulkan and
NVDEC headers, and rebuild/install the guest VideoBridge with Metal and
IOSurface frameworks. See `native/VideoBridge/README.md`. This is a candidate
patch: full Windows regression and the Mac behaviour-lock suite are not green
qualifications. The public report records the outstanding failures.

The active completion-wakes patch targets ordinary queue and completion wakeups.
Global stop/failure still wakes all waiters. An experimental follow-up,
`patches/metal2vulkan-completion-transfer.patch`, applies on 2b5f37c and reuses
tracked private copy scratch within each blit encoder. It removes the scratch's redundant
initial zero fill and synchronous initialization wait, while retaining buffers
through GPU completion and preserving transfer barriers. Ordinary buffer
initialization is unchanged. It also skips unused depth-twin copy vectors.
The parked image-memory allocation cache is excluded from both patches.
The transfer follow-up is parked: one 4K GravityMark run scored 2978 / 17.8 fps,
below the earlier wake-only 3381 / 20.2 fps observation. No performance benefit
is qualified; the active VM was restored to wake-only. See
[verification](verification/runtime-overhead.json) for the exact test scope.

An authored guest/API correctness check is available independently of the
performance diagnostic:

```sh
xcrun clang -O2 -fobjc-arc -Wall -Wextra -Werror TransferScratchProbe.m \
  -framework Foundation -framework Metal -o transfer-scratch
./transfer-scratch
```

It compares seven intermediate buffer-copy snapshots (458752 bytes) and three
overlapping texture-copy snapshots (192 bytes) against CPU-computed expected
bytes, plus three buffer-backed texture copies and their surrounding row padding
(3072 bytes at the tested 256-byte pitch). The GPU performs all Metal copies.
Run under an external process timeout
when checking an unqualified driver. It is a correctness check, not a benchmark.

## Apple media and installation

Obtain the original Intel macOS 26.6.2 recovery BaseSystem.dmg and its verified chunklist from Apple. Place BaseSystem.dmg in `backend/media/`. The tested original is 960530321 bytes. Boot preparation exposes the original file through a synthetic read-only FAT filesystem; it does not convert the DMG.

The tested full installer is Apple's original 18384624402-byte InstallAssistant package. `scripts/Prepare-Installer.py --help` describes extracting its app payload. The original package itself must be the installed app's `Contents/SharedSupport/SharedSupport.dmg`: Apple uses an extra pkgdmg footer outside the inner XAR member. Do not use only the inner SharedSupport DMG. Installation creates the guest's own APFS volumes on `backend/media/tahoe.raw` (128 GiB sparse RAW); no host physical disks are used.

The token-scoped `scripts/Guest-LabServer.py --bind <Windows-LAN-IP>` can serve the original package and payload to Recovery. `native/MetalProbe/Install-Probe.sh` installs a one-time guest verification daemon from Recovery; set NM_URL to that temporary server's URL. It removes its own launch daemon after a successful test and report upload. Stop the development server after use.

## App

Run `scripts/Build.ps1 -Publish`, then `artifacts/app/TahoeVm.exe --start-vm --memory 12 --processors 8`. Choose NativeMac in OpenCore. RAM and CPU are configurable before startup up to 256 GiB and 64 virtual processors; the default and tested allocation remains 12 GiB / 8 processors. Allocations beyond available host resources are not qualified. Guest display and input use the independent GPU window. The WinUI app manages resources and power.

The recorded Metal result is a validation of one compute workload, alongside the setup UI. See `vm/progress.json` for known limitations. Additional applications and long-running workloads need separate validation.

The experimental default Metal transport also needs the guest bridge described in [GPU_STABILITY.md](GPU_STABILITY.md). Apply `patches/reims-metal-compat-astc.patch` to the pinned Reims sources and commit the guest directory before exporting its build snapshot. `rejectAstcTextures` in vm/defaults.json enables allocation rejection for the current host, whose Vulkan runtime rejects ASTC. This is not an ASTC decoder or a long-term compatibility guarantee.

Display modes: select FHD/WQHD/4K before startup, or pass `--resolution 3840x2160` to TahoeVm / `-DisplayResolution 3840x2160` to Start-VM.ps1. OpenCore and the GPU mode cap receive the same resolution. Defaults remain 1920x1080, 12 GiB, 8 processors. Build `DisplayModeProbe.m` and `SceneProbe.m` with `Build-GuestMetalCompat.ps1`. Within the configured maximum, use macOS System Settings → Displays to change resolution live. A 4K output can use readable 1920×1080 HiDPI scaling; the probe reports logical and pixel dimensions separately. In the logged-in guest, run `display-mode-probe-x64 3840 2160` to commit 4K for this session. Run `scene-probe-x64 30 3840 2160` for the authored 4K GPU diagnostic; its default remains FHD. The launcher defaults to 60 Hz (`displayRefreshHz` in `vm/defaults.json`) and offers a process-local `-DisplayRefreshHz` override (30–240 Hz) so a high-refresh host need not make the guest compositor run at its maximum refresh rate. It restores the inherited environment after exit.

## Presentation-path diagnostic

`SceneProbe.m` accepts an optional fourth argument: `drawable` (default),
`drawable-no-present`, `offscreen` (Private), `offscreen-shared`, or
`offscreen-managed`. Append `-pipelined` to any mode to bound in-flight commands
at three instead of waiting for each command individually. No-present acquires
and renders a drawable but omits `presentDrawable`; use it only to diagnose the
drawable lifecycle. Offscreen modes reuse one persistent texture and create no
window. All modes use the same authored geometry, shaders and target dimensions.

For the measured optimized build, run in the Intel guest:

```sh
xcrun clang -O2 -fobjc-arc -Wall -Wextra -Werror SceneProbe.m \
  -framework AppKit -framework Metal -framework QuartzCore -o scene-probe-x64
codesign -s - -f scene-probe-x64
./scene-probe-x64 10 3840 2160 offscreen-pipelined
./scene-probe-x64 10 3840 2160 drawable-pipelined
./scene-probe-x64 10 3840 2160 drawable-no-present-pipelined
```

Repeat in reverse order to expose drift. Final rates count GPU-completed
commands, include startup and pipeline drain, and are **not physical display
fps**. The first command checks one GPU-readback pixel; this is not per-frame
image equivalence. Phase means exclude two seconds of warmup; p95 uses at most
the first 8192 measured frames. Pipeline GPU timestamps are not sampled.
The layer uses `framebufferOnly=false`, `displaySyncEnabled=false`, a 4K target
and a 960×540-point window; this does not represent a fullscreen 4K game.

[Presentation evidence](verification/presentation-path.json) records 24 accepted
runs on the restored runtime. Matching three in-flight commands still leaves
Private offscreen at 1307–1415 versus presented drawable at 107–121 completed
commands/s. No-present drawables also reach only 114–121, mostly waiting for
`nextDrawable`; persistent Managed offscreen reaches 1349–1462. This narrows the
next investigation to drawable/IOSurface recycling and synchronization, rather
than establishing that the final host present or Managed storage alone is the
cause. This diagnostic change does not accelerate the product or other games.

## Experimental LLVM bitreverse repair

`patches/metal2vulkan-llvm-bitreverse.patch` applies to the translator revision in `vm/dependencies.json` under `metal2vulkanRepair`. Apply it in a separate translator checkout. To build Reims against it, pass a local Cargo configuration with the following three overrides, replacing the example absolute path with that checkout:

```toml
[patch."https://github.com/tqmane/metal2vulkan"]
metal2vulkan = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan" }
metal2vulkan-air = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan-air" }
metal2vulkan-runtime = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan-runtime" }
```

Use `cargo +1.98.1 --config <local-config.toml> build -p reims-vgpu-c --no-default-features --features vulkan --release`. The first resolution updates the local Reims lockfile to these path dependencies. Keep this build separate from the unmodified pinned build. This repair is experimental: see [the FHD compatibility checks](GPU_COMPATIBILITY.md) for executed tests and remaining runtime failures.

The optional `patches/metal2vulkan-ray-cull-flags.patch` applies after the bitreverse patch and corrects the invalid primitive-cull flag combination found by the authored CPU/validation suite. It does not enable guest ray-tracing capabilities.

The experimental bounded private-cell repair is `patches/metal2vulkan-bounded-pointer-cells.patch`, applied after the ray-cull repair. It preserves unsigned-min index bounds and keeps small separated slot sets apart from neighboring handles/data. Use its authored regression and a guest retest; an offline SPIR-V validation pass does not qualify the VM.
