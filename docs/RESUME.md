# Current checkpoint

The most recent FHD VM ran with 12 GiB RAM and 8 virtual processors, with the current allocation unchanged. The configurable limits are now 256 GiB / 64 virtual processors at the user’s request; these larger allocations are not qualified.

Confirmed: Intel macOS 26.6.2 build 25G83 boots using OpenVMM WHP. Guest Metal compute verified all 4096 values on the RTX 5080, and the GPU displayed Setup Assistant. No QEMU or CPU instruction translation is used. Original recovery media is read without disk-image conversion.

The mouse-wheel fix is verified: all three mouse protocol tests passed, the release backend built, and the guest logged the 73-byte HID descriptor with signed 8-bit wheel packets. The user confirmed scrolling works after this boot. Initial setup and guest-account preferences are managed by the user; do not request/store the password.

The private GitHub repository is https://github.com/ryuya0124/NativeMac-WHP. Source, patches, build prerequisites and validation evidence are committed. OS media, VM disks and compiled dependency binaries are excluded.

The current stability candidate uses the pinned ReimsMetalCompat guest bridge, coalesced pointer motion and FHD 1920x1080. Six frontend tests pass, including the bounded FHD/WQHD/4K mode selection. The guest display timing probe completed 3043 frames in 20.005 seconds (152.11 FPS), with host presents advancing at approximately 160 per second after warm-up. The user confirms smoother unlock and normal operation, but reported a 10-second backlog after repeated actions. Earlier candidate boots still had GPU faults. Long-term qualification remains in progress; see docs/GPU_STABILITY.md.

A temporary token-scoped lab channel may be active during the repair. Its state and private results are under artifacts; do not publish them. The monitoring automation consults artifacts/vm-maintenance.json to distinguish planned repairs.

Evidence is in docs/verification and vm/progress.json. Detailed local logs are under artifacts and excluded from Git.

Latest checkpoint (2026-10-22): the opt-in ASTC allocation rejection passed a negative allocation probe, followed by compute and 20 seconds of actual Metal presentation. Eight system-app launches plus compute checks passed; the user confirmed three fast unlocks. GravityMark 1.89 then aborted the GPU worker on unsupported `llvm.bitreverse.i32`; the VM is stopped while that translator repair is built. No score or 30-minute stability pass exists. The configurable resource bounds were raised to 256 GiB / 64 processors at the user's request, with current allocation/defaults still 12 / 8. FHD, WQHD and 4K are selectable; the first 4K guest boot is pending.

The active priority is FHD GPU instruction compatibility. See docs/GPU_COMPATIBILITY.md. The LLVM bitreverse patch and a controlled candidate are prepared; the first later FHD trial had empty resource faults and a pageout/storage-stack panic, so causality is unresolved. The prior library restored a responsive FHD session and checked compute. After closing the reproduction apps and synchronizing the guest disk, the controlled bitreverse candidate was started again at 12 GiB / 8 CPUs / FHD. Wait for the user to unlock and foreground Terminal before bootstrapping the temporary agent. Do not assume the old agent survives a guest reboot.

The controlled FHD GravityMark retest ran x64/Metal (Build Info mtl=4) and failed during compute pipeline creation on Lowering(Access), compute_main block 1 / instruction 43. The host worker aborted and the VM is stopped. Bitreverse decoding was passed, but no independent GPU bitreverse result or 3D score was produced. A bounded, default-off local shader capture diagnostic is being built in the Reims worktree for offline analysis. Captured guest shader inputs must remain private and uncommitted.
