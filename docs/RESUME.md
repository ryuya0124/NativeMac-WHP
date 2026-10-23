# Current checkpoint (2026-10-23)

Stock Geekbench 7.1.0 Metal completes all 11 workloads, exit 0, validation
errors 0, score 3238: https://browser.geekbench.com/v7/gpu/317315.
Bridge 42e21ba and translator code 66092df / semantics 1698 qualify that
result. No other benchmark or stress suite overlapped it; light readouts and
two brief probe builds did. No app patch, DYLD adapter, CPU renderer or
GPU-family spoof was used.

The 41-case native Metal comparison completes: VM 37 pass / 4 fail. ICB
allocation, mixed argument buffer binding and two heap cases remain failures.
The M4 reference runs OS 27.2 versus guest 26.6.2; retain its original random
FP16 sum tolerance failure and its Managed-storage not-applicable result.
JSON source hashes and selected counters are in docs/verification.

VM H.264/HEVC software codec round trips and an authored local WebKit movie
pass. YouTube still has a fmt.decode error. Host RTX 5080 NVENC and NVDEC
complete a separate 90-frame H.264 round trip. The guest-to-Windows bounded
loopback transport in native/VideoBridge also passes checked H.264/HEVC
batches at 320×180, 854×480, FHD and 4K. VideoToolbox registration, sustained
playback and Safari hardware codec integration remain required.

GPU naming source 1b9a256 is integrated into backend/reims-stability and is
the current guest kext. ABI and snapshot tests, signed build and cold boot
pass. Start-VM.ps1 now obtains the selected Windows renderer name from a
successful same-DLL probe's startup callback; no fixed model configuration,
first-adapter lookup or cached-name fallback. The dynamic-path cold boot
agrees across probe, actual worker, guest IORegistry and System Information;
4096 GPU values pass. Normal Metal name remains Apple Paravirtual device.
native/MetalIdentity's explicit-process prototype reads the host property
and passes the same GPU calculation, preserving registry ID and compiler
class. It is not installed or selected system-wide. Do not call the complete
Metal-name task finished or substitute a label for a capability.

Monitoring remains deleted. Keep 12 GiB / 8 CPUs, 4K output with readable
1920x1080 HiDPI. Do not publish guest captures, private logs, keys, credentials,
Apple/consumer shader binaries or result claim links.

## Previous checkpoint (2026-10-22 19:07 JST)

Monitoring automation was deleted at the user's request. Do not recreate it.
User prefers Apple sign-in directly inside the Intel VM and handles that
authentication. Xcode 26.5 (17F42) is now installed in the VM with iOS/watchOS
Simulator SDKs 26.5; no external Xcode download is needed.

Kernel snapshot `0471bc25dffab380631e8cb888784ebbd233fff2` is built and
cold-booted, following the qualified segmented-submission repair. PCI display
`model` now preserves its exact name as NUL-terminated OSData. This fixes the
stock Geekbench 7.1.0 pre-workload system-information crash. CPU completes
and uploads (explicitly user-authorized): single 2287, multi 10415,
https://browser.geekbench.com/v7/cpu/692080. Never publish result-claim keys.
Stock Metal still exits 255 at Background Blur with an MPSNDArray nil-device
assertion; no GPU score. Authored ordinary compute then verifies 4096 values.
MPSDeviceProbe initializes the matching Graph device and scalar NDArray, so
do not call all MPS unsupported or its workload failure fixed.

Current session: 12 GiB / 8 CPUs, maximum 4K, refresh budget 60 Hz. macOS
Settings → Displays was tested through 1920×1080 HiDPI / 3840×2160 1× /
2560×1440 1× / back to 1920×1080 HiDPI; probe and host confirm output.
The final physical output is 3840×2160 with readable 1920×1080 scaling.
RAM/CPU defaults are unchanged. Reboot persistence of UI mode choice is not
qualified. Private channel and persistent guest agent remain temporary;
read fresh session PIDs and do not print its tokens/full result log.

MochiLog unchanged pinned `eb1503924d9e9b8ae874010c96443cdf78823682`
builds inside this x86-64 VM: `BUILD SUCCEEDED`, exit 0, phone/watch
simulator apps each x86-64+arm64, signing disabled, no app/simulator launch.
One Sendable source warning plus optional App Intents metadata warnings.
See the aggregate JSON evidence for CPU, display, source provenance and
MochiLog. Only authored patches/source and aggregate evidence may go public;
guest screens/logs, third-party binaries and credentials stay ignored.

# Earlier segmented-submission checkpoint (2026-10-22)

The user authorized public GitHub and unattended work. Keep FHD / 12 GiB / 8 CPUs,
WHP, nonisolated GPU tasks, and the scoped sampler/readback adapter only.

Kernel source snapshot `8a079b086b8b3990c1ad60a56e924a9028c9bb4c` is built and
currently booted. It fixes a fixed-20-byte command assumption that refused
multi-segment serializer submissions before reaching the host GPU. The authored
16384-command blit failed before the change (Internal Error, 4096 mismatches) and
passes after (4096 bytes checked, zero mismatches, completed). Native/x64 ABI
tests and source snapshot tests pass. The unchanged host DLL and translator
remain the earlier baseline. The rejected isolation cache experiment is not
merged into the active library.

Three consecutive repaired GravityMark FHD runs draw real populated scenes and
complete normally: 24.0 / 23.7 / 24.0 fps, scores 4012 / 3957 / 4018, each about
167 seconds. The second and third omit submission tracing; the third omits extra
foreground activation. The corrected independent triangle benchmark then passes
both modes again without a GPU adapter (159.9 / 160.0 fps, 800x600). A direct
unshimmed 16384-command blit passes after the sequence. Four adapter modes pass,
plus 84 readback cases / 23500 bytes and 4096-value GPU compute. Three
post-benchmark lock/unlock cycles return to the desktop, a title-bar drag
responds, and GPU compute after the last unlock verifies 4096 values. No host
fatal, exec fault, GPU hang or kernel panic appears in this cold-boot session.
A new 30-minute continuous observation is not qualified by this session.
Preserve private
trace captures in ignored artifacts; publish only authored sources, patches,
manifest hashes and aggregate verification. General Metal support remains
unqualified; heaps, mesh execution and argument buffers have unresolved limits.

# Earlier benchmark checkpoint (2026-10-22 afternoon)

Public repository remains user-authorized. Never commit private logs, images, shader inputs, credentials or downloaded app binaries. Keep 12 GiB / 8 CPUs / FHD and nonisolated GPU tasks.

Authored `SharedTextureReadback.m` is linked into the opt-in binding adapter. Its main-PID-gated GPU preflight measures stale shared texture CPU getBytes, then installs actual GPU blit/readback for supported raw 2D/array formats. Four direct/indirect/shared-readback probes pass; CPU and GPU readback both match 16 pixels. The new region probe passes 84 cases / 23500 bytes including mips, slices, padded subregions and guards; its x64 M4 reference passes too. Build-GuestMetalCompat builds all three authored probes warning-free.

With both modules, GravityMark 1.89 renders populated Earth/asteroid scenes and completes FHD/20000: 167.1 seconds, 22.7 fps, score 3792, exit 0; 371504 bindings and no mesh draws. Readback copies=1 is solely constructor preflight, so do not claim that intercepting benchmark getBytes fixed the black scene. A binding-only confirmation reproduces black/visible=0. The combined adapter repeat also reproduces black/visible=0 (exit0, 101.9fps /17017 rejected). This is one successful observation and not repeatable qualification; initialization effects are unproven. This is an experimental successful run, not general qualification or pixel equivalence. Heap failures/fallback remain. Do not silently enable this adapter globally or in the VM launcher.

Independent ctsilva/triangle-rendering-benchmarks pinned 37a702cf264bbd6764dfc5f717a5bd5bfeff4921 completes both 30-second modes with actual visible geometry after fixing its perspective matrix columns (patches/triangle-benchmark-projection.patch). Unmodified and shimmed-unmodified scenes were blank, so reject those numbers. Corrected 800x600 runs: triangles 159.8 fps / 200978 triangles per frame, strips 159.6 / 400961; visible triangles repeat 160.0. Requested TRIANGLES=100000 generates those actual counts. No GPU shim injected. M4 GUI reference timed out without frames; no reference score claimed. Native M4 headless probe tests pass. See docs/verification/metal-benchmarks.json.

The isolation experiment is rejected and runtime binaries restored. Enabling isolation exposed argument buffers but MTLCopyAllDevices failed Vulkan -13. A cache lookup for the already-opened registry ID passes its RTX test in backend/reims-stability, but the next cold boot dies at gpu_task.unsupported.backing_for_id. Do not enable isolation or claim argument-buffer support. Its unmerged source change stays in that worktree; candidate binaries and failed logs are ignored artifacts. Main OpenVMM source is restored to isolation:false. Known-good runtime is artifacts/openvmm.pre-isolation.exe and artifacts/vgpu/reims_vgpu_c.pre-isolation.dll; restored into active paths. No upstream merge/full-check claim.

Maintenance is active during benchmark work; restore monitor baselines and clear maintenance only after the current run and recovery checks finish. Guest agent was re-bootstrapped in Terminal from the private channel; it expires after one hour. Current VM session PIDs must be read afresh. Additional probes and benchmark executables are in guest $HOME/NativeMacLab. Never print the full guest-task-results log (private binary payloads).

# Latest optional API checkpoint (2026-10-22)

Repository visibility: **Public**, explicitly approved by the user after this checkpoint. Keep private screens, logs, shader inputs and credentials outside Git regardless of repository visibility.

Authored process-local adapter `native/MetalCompat/DeferredStageBindings.m` retains separate object/mesh resource tables (samplers/LOD, textures, buffers/offsets, copied bytes, object threadgroup lengths). It preserves traditional draws and feature queries; all three mesh draw forms explicitly refuse. It activates only on the measured AppleParavirt encoder after two legal nil sampler bindings throw, and remains inactive on M4. No global/desktop injection or VM restart was performed. Build with `scripts/Build-GuestMetalCompat.ps1`; launch selected executables with `Run-With-DeferredBindings.sh`. Guest copies are in `$HOME/NativeMacLab/probes`. Keep 12 GiB / 8 CPUs / FHD.

Direct, CPU-indirect and GPU-indirect authored tests all match 16 exact GPU-readback pixels, independent binding state, copied bytes and explicit negative cases. Native M4 reference tests pass. GravityMark now completes (exit 0, 1150268 deferred bindings, zero mesh requests), but its scene is black with zero visible objects: reject its apparent score. The identical x64 benchmark/parameters render a populated scene on M4; that is reference evidence only. Hiding Apple families aborted a cube-array feature assertion and is rejected, not installed. The black scene's cause remains unproven. The dedicated `--shared-cpu-readback` mode exits 4 in the guest: CPU getBytes matches 0/16 pixels while GPU blit matches 16/16. M4 matches both. The cause and any relationship to GravityMark are unproven. Do not call either issue fixed.

Post-trial selected-process wrapper and a 25.002-second FHD scene pass (2565 completed frames, 102.59 diagnostic completed fps, zero errors, GPU readback), followed by 29360128 checked GPU values / three releases / zero mapping errors and a final 4096-value compute pass. Desktop reappears after leaving its animated screensaver; a title-bar drag responds and native input capture is released. At the user's earlier request, guest currentHost screensaver idleTime is now 0, verified via CLI. No lock/authentication policy changed. See `docs/verification/deferred-stage-bindings.json`. Private logs/images, the failed family guard and temporary channel stay under ignored artifacts.

# Earlier desktop checkpoint (2026-10-22)

Current runtime: OpenVMM pinned base plus openvmm-nativemac and banked-gpu-ram patches; Reims 18fca9c / translator 4518f02. Keep 12 GiB / 8 CPUs / FHD. The banked RAM fix completed a 1800.004-second real hardware-render observation: 184144 frames, zero render errors, 338.56-ms maximum frame gap, and 29 checked no-copy memory rounds totaling 851443712 GPU values / 87 releases. No GPU hang, exec fault or kernel panic occurred. Calculator, System Settings, Books and Music were opened and followed by checked GPU compute. Native-window drag and wheel worked. Three explicit lock/unlock cycles pass, including one after the full stress observation; initial cold login is a fourth observed unlock. Final GPU compute verified 4096 values and a desktop title-bar drag responded.

GravityMark remains unqualified: it reaches its benchmark in about 4.4 seconds, then exits 134 on unimplemented object sampler binding. Availability-query correction and a process-local Mac2-family restriction did not help. Those private diagnostic libraries are not installed globally and are not active in the desktop. No GPU draws were dropped or fabricated. The broad translator golden-fixture failure and full upstream merge gates remain unresolved. Preserve the working desktop baseline while addressing further compatibility.

RFB diagnostic input can drop initial characters after focus/connection changes. Observe guest focus before entering anything; never echo or persist credentials. Private screen/log/shader artifacts must stay outside Git.

# Earlier investigation and operating details

Intel macOS 26.6.2 (25G83) runs on Windows using the existing WinUI 3 frontend, OpenVMM WHP and RTX 5080/Reims Vulkan. QEMU, CPU instruction translation and OS-media conversion remain unused. Keep the current allocation at 12 GiB / 8 CPUs / FHD. Configurable limits are 256 GiB / 64 CPUs; 4K qualification remains deferred until FHD GPU compatibility is stable.

The user's current request is to fix GPU compatibility after the screen-freeze repair. Unattended repair, guest interaction and source-only updates to https://github.com/ryuya0124/NativeMac-WHP are authorized. The latest user instruction explicitly permits Public visibility. Never store or echo credentials, and observe a guest password field before entering a login secret. No persistent root command channel is installed.

Translator source is backend/metal2-stability at 4518f02, semantics 1696. Its bounded private-cell tests, Clippy and Rustdoc passed. The earlier broad range refinement produced a black display. A complete CPU suite still has one generated LLVM 21/22 fixture comparison failure (3242 pass / 1 fail / 10 ignored); this is not a green merge gate. Private consumer shader inputs, translations and derived censuses must not be committed.

Reims worktree backend/reims-stability is on steelbrain/alias-release-order. Its owner checkout is untouched. Source 0226631 fixes alias release ordering; the no-copy file-backed probe passed 192 releases and 18087936 actual GPU outputs in the Windows guest. Source 81cc109 adds explicitly armed, same-task resource diagnostics. ABI/source-snapshot checks and the x86_64 kext build pass. HeapProbe confirmed automatic/placement and tracked/untracked private heaps return nil before a resource-allocation request reaches the bridge. Do not infer a heap record ABI from an unrelated failed texture/resource request.

At 07:58 and subsequent samples, the frozen FHD GravityMark session's host FIFO was repeatedly inside Windows MapViewOfFile3 through MemoryMap::new_range_mapping. Samples changed between resources: a permanent deadlock was not proven. Another FIFO waited for a TaskCore reader; several others were idle waiting for commands. Preserve the symbolized private stack captures in artifacts. A separate metadata query previously misidentified selector-2 compiler/object-table words as device capabilities; this output was removed from the authored probe and is not evidence about heap support.

A 64-KiB view-bound experiment was rejected because boot was slower and GravityMark still timed out. The restored/coalesced candidate passed 2304 serial debug core tests. Fresh-alias candidate 1c805df passed 54 focused mapping tests, 5 native Windows alias tests, 2142 FHD scene frames in 15.001 seconds with actual GPU pixel readback, and 29360128 checked large-buffer GPU values with three releases. A new Terminal window opened afterward. Nevertheless GravityMark 1.89 at FHD/20000 asteroids timed out after 300 seconds; no score exists.

Diagnostic runtime 18fca9c times large Windows view batches. The actual VM's 12-GiB section takes increasingly long to map: one 42.67-MiB / 10923-view batch took 60.61 seconds. FIFO CPU time was only 1.9 seconds in a 61.65-second sample, indicating a host wait. A read-free, write-free external alias probe duplicated the actual section handle and also took 22.62352 seconds for 4096 views. In contrast, an independent native WHP partition with 12 GiB of resident/touched RAM, NVIDIA host-memory import, the real Reims display and injected overlays maps 16384 aliases in about 0.1 seconds. This narrows the issue to the actual shared-section state; it does not prove the underlying kernel/driver cause.

The next OpenVMM trial splits newly allocated shared RAM into independent sections of at most 64 MiB, only for the NativeMac Reims PCI device on Windows. GPA layout, 12 GiB / 8 CPUs and FHD are preserved. Private, hugepage and restored existing-section requests are unchanged. Four new tests cover layout/policy preservation, exclusions, limits, cross-bank reads/writes and actual shared aliases. All 55 membacking library tests pass serially. Multi-backing RAM-handle restart/snapshot reconstruction is unavailable; ordinary cold startup uses fresh sections. Cold boot and initial unlock pass. A checked FHD scene completes 2273 frames / 15.007 seconds / 151.46 completed fps with zero errors. GravityMark now reaches its Metal benchmark in 4.362 seconds. Its 15 large mapping batches complete in at most 0.1658868 seconds; the prior 42.67-MiB/10923-view batch now takes 0.051694 seconds versus 60.61 seconds previously. It then aborts with an Objective-C unimplemented setObjectSamplerState:atIndex: exception (exit 134), and the desktop recovers. No score exists. Optional API support remains unresolved; the bounded desktop observation now passes as summarized above. The patch and automatic build application are recorded in vm/dependencies.json.

The runtime disk backend/media/tahoe.raw is the trial copy. Preserve artifacts/alias-release-trial/tahoe.original.raw, tahoe-nvram.original.raw and ReimsMetalCompat.original.kext. VM session PIDs change on every boot; read artifacts/vm-session.json and verify real processes. Keep artifacts/vm-maintenance.json active throughout planned repair/restarts. The existing monitor is read-only and must not interfere.

The token-scoped HTTP lab server listens on LAN port 5907. Its base is in ignored artifacts/guest-channel.json. The guest agent expires after one hour and does not survive reboots; bootstrap from an observed, focused Terminal. Each queued foreground task has an authored native process-group timeout. Never consume GET next from the host. Queue shell files as LF with an atomic rename. Task files prove dispatch only; actual outputs are in ignored guest-task-results.log. That log now also contains a private base64 diagnostic binary; do not print its whole tail or add it to Git.

The VM RFB input API is loopback port 5905. Prefer GPU API captures for the actual guest display. Native Windows capture can show an occluder or the Windows lock screen; refresh and select exactly one returned Reims vGPU window before native input. No Windows authentication or security settings should be changed. AC monitor/sleep/hibernate timeouts were disabled by CLI at the user's request; battery settings and lock policy remain unchanged.

No completed commercial 3D benchmark score exists. Source-only updates through root commit 300632e were pushed to the existing private repository; this checkpoint adds the completed desktop observation and reusable guest stability script. Verify remote state before claiming a later push.

The user also requests a 3DMark-like benchmark. Official UL requirements limit 3DMark for macOS to Apple Silicon; the Intel guest is unsupported. Use its installed x86_64 GravityMark Metal benchmark, plus authored SceneProbe, and verify desktop recovery afterward. Do not report a Windows or M4 host score as a guest result.


ApiProbe.m demonstrates that the guest encoder reports respondsToSelector=true
for object/mesh sampler bindings, but actual legal nil bindings throw
NSInvalidArgumentException/unrecognized selector. The same x86_64 probe on M4
accepts both. Guest families Apple1..5 and Mac1/2 are true; Apple6..10 and
Metal3/4 are false. Querying respondsToSelector alone is insufficient. Do not
turn missing bindings/draws into successful no-ops. GravityMark -help is invalid
and opens an error UI; the bounded task runner terminated that diagnostic at
60 seconds. No successful command-line help output exists.


## Current 4K and refresh checkpoint (2026-10-22)

The repository is public at https://github.com/ryuya0124/NativeMac-WHP.
Commit `4ddf137` qualifies a bounded 4K desktop and a populated 4K GravityMark
run: 17.3 fps, score 2895, 167.2 s, exit 0. A 30-second authored 4K scene
passes with checked GPU pixel readback. The session-only display configuration
helper fixes the earlier temporary-mode rollback; a fresh login can still
choose a smaller mode until the helper selects 3840×2160. Defaults remain
FHD / 12 GiB / 8 processors. A per-launch refresh budget is being recorded in
`docs/verification/fourk-display.json`; no instruction translation is used.

SuperTuxKart 1.5 is not playable: its software fallback is rejected; disabling
MoltenVK heaps and argument buffers permits a Vulkan profile to finish but
produces black output, and uncompressed textures show sky with malformed
geometry. No game score is accepted. The GPU is not fully compatible.

The user explicitly stopped the recurring `macos-vm` monitor; it was deleted.
Do not recreate it unless requested. Private lab transport and snapshots remain
under ignored artifacts. Never add those or third-party game assets to Git.
