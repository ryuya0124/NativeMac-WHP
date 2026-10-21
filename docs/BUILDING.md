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

## Apple media and installation

Obtain the original Intel macOS 26.6.2 recovery BaseSystem.dmg and its verified chunklist from Apple. Place BaseSystem.dmg in `backend/media/`. The tested original is 960530321 bytes. Boot preparation exposes the original file through a synthetic read-only FAT filesystem; it does not convert the DMG.

The tested full installer is Apple's original 18384624402-byte InstallAssistant package. `scripts/Prepare-Installer.py --help` describes extracting its app payload. The original package itself must be the installed app's `Contents/SharedSupport/SharedSupport.dmg`: Apple uses an extra pkgdmg footer outside the inner XAR member. Do not use only the inner SharedSupport DMG. Installation creates the guest's own APFS volumes on `backend/media/tahoe.raw` (128 GiB sparse RAW); no host physical disks are used.

The token-scoped `scripts/Guest-LabServer.py --bind <Windows-LAN-IP>` can serve the original package and payload to Recovery. `native/MetalProbe/Install-Probe.sh` installs a one-time guest verification daemon from Recovery; set NM_URL to that temporary server's URL. It removes its own launch daemon after a successful test and report upload. Stop the development server after use.

## App

Run `scripts/Build.ps1 -Publish`, then `artifacts/app/TahoeVm.exe --start-vm --memory 12 --processors 8`. Choose NativeMac in OpenCore. RAM and CPU are configurable before startup up to 256 GiB and 64 virtual processors; the default and tested allocation remains 12 GiB / 8 processors. Allocations beyond available host resources are not qualified. Guest display and input use the independent GPU window. The WinUI app manages resources and power.

The recorded Metal result is a validation of one compute workload, alongside the setup UI. See `vm/progress.json` for known limitations. Additional applications and long-running workloads need separate validation.

The experimental default Metal transport also needs the guest bridge described in [GPU_STABILITY.md](GPU_STABILITY.md). Apply `patches/reims-metal-compat-astc.patch` to the pinned Reims sources and commit the guest directory before exporting its build snapshot. `rejectAstcTextures` in vm/defaults.json enables allocation rejection for the current host, whose Vulkan runtime rejects ASTC. This is not an ASTC decoder or a long-term compatibility guarantee.

Display modes: select FHD/WQHD/4K before startup, or pass `--resolution 3840x2160` to TahoeVm / `-DisplayResolution 3840x2160` to Start-VM.ps1. OpenCore and the GPU mode cap receive the same resolution. Defaults remain 1920x1080, 12 GiB, 8 processors.

## Experimental LLVM bitreverse repair

`patches/metal2vulkan-llvm-bitreverse.patch` applies to the translator revision in `vm/dependencies.json` under `metal2vulkanRepair`. Apply it in a separate translator checkout. To build Reims against it, pass a local Cargo configuration with the following three overrides, replacing the example absolute path with that checkout:

```toml
[patch."https://github.com/tqmane/metal2vulkan"]
metal2vulkan = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan" }
metal2vulkan-air = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan-air" }
metal2vulkan-runtime = { path = "C:/path/to/metal2vulkan/crates/metal2vulkan-runtime" }
```

Use `cargo +1.98.1 --config <local-config.toml> build -p reims-vgpu-c --no-default-features --features vulkan --release`. The first resolution updates the local Reims lockfile to these path dependencies. Keep this build separate from the unmodified pinned build. This repair is experimental: see [the FHD compatibility checks](GPU_COMPATIBILITY.md) for executed tests and remaining runtime failures.
