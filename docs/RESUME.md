# Current checkpoint (2026-10-25, VM power lifecycle)

Runtime1190 remains adopted and unchanged (DLL SHA256
0ff8c44e7bdfdcaaf92db4e2da61c541b125bd3902d9df8b0c943ed4c44dfd78).
Preserve 12 GiB, eight CPUs and 3840x2160 at configured 60 Hz. The current
WinUI app has been republished. Start-VM now exits cleanly on a guest power-off
and starts a fresh VMM/GPU/video-service process after a guest reset, preserving
the persistent disk, NVRAM and options. One real guest restart and shutdown
passed, and GPU compute verifies all 4096 values after reboot and host pause/
resume. The final frontend records running/paused/stopped states from actual
launcher and VMM acknowledgements. See docs/verification/power-lifecycle.json.

Guest S3/hibernation resume remains unsupported. Do not remove the Hyper-V
driver's sleep prevention or mistake pmset returning success for a completed
sleep/wake cycle. Use the added host WinUI pause/resume buttons for volatile
RAM retention. This is not S3 or a disk snapshot. Host force-stop/frontend close
still sends quit; normal shutdown is requested within macOS. Ephemeral memdiff
reset remains in-process and is unqualified with the GPU. No monitoring
automation was enabled. SSH remains maintenance/test-only.

# Earlier checkpoint (2026-10-24, runtime overhead and single benchmark)

The user first prioritized removing suspected overhead, then requested one
benchmark run. Transfer-scratch candidate 1188 completed GravityMark 1.89:
2978 points / 17.8 fps / 167.1 s at 3840x2160, Temporal AA, 20000 asteroids,
Metal, fullscreen, VSync off, with the unchanged deferred-binding/shared-readback
process adapter. The earlier wake-only observation was 3381 / 20.2 fps / 167.1 s.
This single comparison is about 12% lower, with cache/background/host drift not
controlled as a new A/B pair. It establishes no performance gain or causal
regression proof. Existing unsupported-heap warnings persist.

The transfer candidate is parked; no second benchmark was run. The live VM is
restored to wake-only runtime 1185, DLL SHA256
f8780bf294dd9097066d49001ac799605bf66666c8a1d288f54294c8e186f856,
built from d0ee60f. Source 2b5f37c moves only a cfg(test) body out of production
files; its pre-cfg(test) production prefix is byte-identical to d0ee60f.
Preserve 12 GiB, 8 CPUs, 3840x2160 and configured 60 Hz. No monitor automation
is enabled; SSH remains maintenance/test-only. Post-restore boot/unlock, the
authored buffer/image/linear-row copy checks, and 4096 GPU values pass.

The active source patch is patches/metal2vulkan-completion-wakes.patch on
fetch-product 79aafca. It separates per-queue and completion condition variables,
targeting normal progress wakes while stop/failure still wakes every waiter.
The test-layout follow-up is included. No guest callback, resource release,
visibility or failure ordering is weakened.

Experimental patches/metal2vulkan-completion-transfer.patch applies AFTER the
wake-only patch, from 2b5f37c to c37d756/runtime 1188. It reuses tracked private
scratch in four blit paths, removes redundant initialization fills/waits, and
omits unused depth-twin copy vectors. All allocations stay retained to GPU
completion, including buffers replaced during growth, and barriers stay.
Ordinary caller-visible buffer initialization is unchanged. The code remains
in owner development dbd143c and the release branch; no history was rewritten.
The parked image-memory allocation cache is excluded from both release patches.

Candidate correctness: Windows GPU/copy/completion regression 64/64 passes.
Seven intermediate buffer snapshots (458752 bytes), scratch reuse/growth and
4096 guard bytes pass. A latency test had one 63-ms sample with competing GPU
tests; it passes 600 isolated rounds (max 18.7 ms). Its final nextest override
pauses sibling tests, with queue concurrency and the 50-ms threshold unchanged.
This is test isolation, not a runtime latency guarantee.

Authored TransferScratchProbe.m passes on M4 and in the candidate Intel VM:
seven buffer snapshots, three image-copy snapshots (192 bytes), and three
buffer-backed texture-row snapshots including padding (3072 bytes) match the
same CPU oracle. Candidate post-boot GPU compute (4096 values), HEVC (90 frames),
4K HEVC decode (four frames, 49766400 bytes) and hardware H.264 encode (four 4K
frames) pass. These are short correctness checks, not sustained video, game,
frame-pacing or flicker-free coverage. Earlier transient whole-screen green
flicker stopped before this batch; its cause remains unresolved.

Metal2 checks on f9e0874: all 4570 core/AIR/runtime/devtools tests (22 skipped),
1303 validation tests (four skipped), doctests, fmt, warnings-denied Rustdoc,
workspace/GPU-cfg clippy and every translator feature configuration pass.
Final notice/catalogue/version-guard follow-up on dbd143c passes fmt, clippy,
GPU-cfg clippy, Rustdoc, 11 notice/wake checks and the runtime-source guard.
Owner development retains the parked image cache; the release branches do not.
Stock MoltenVK 1.4.2 GPU checks pass 62/64, including both scratch tests; two
teardown tests reject its primitive-restart warning. Do not claim a green full
Mac GPU gate. Unchanged Reims retains its previously recorded 14 gate failures.
See docs/verification/runtime-overhead.json for exact revision-specific evidence.

# Earlier checkpoint (2026-10-24, presentation investigation)

The user prioritized investigating the offscreen-versus-presented 4K gap before
further cache/game work. The active runtime DLL is restored to SHA256
5470f35138a2b313c8146785db7bfebc9f96227ef65220ce665c6d53a36ab6f7
(Reims 84fb809 / Metal2 product 59d9ef3 and guard 79aafca). Preserve 12 GiB,
8 CPUs and the configured 4K60 display. Actual guest pixels are 3840×2160 with
1920×1080 logical scaling. CoreGraphics refresh reports zero; AppKit maximum
fps reports 58, so configured refresh is not a physical-cadence measurement.
No monitor automation is enabled. SSH remains maintenance/test-only.

SceneProbe now separates Private/Shared/Managed offscreen, real drawables
without presentation, and presented drawables. Each mode can use one or three
in-flight commands. Pipeline final counts come from completion callbacks after
draining, with error checks; the first frame has a real GPU pixel witness.
The layer remains framebufferOnly=false, displaySyncEnabled=false, target 4K
in a 960×540-point window. These are diagnostic completed-command rates, not
physical display fps or game scores. Phase means exclude two seconds of warmup.

Twenty-four bounded runs pass, with zero command errors. Serial presented
A/B/B/A: 59.83, 108.66, 105.04, 59.29 commands/s (B uses three in-flight frames).
The harness's per-frame completion wait amplifies the initial gap. Matching
three slots on both sides still gives Private offscreen 1306.58–1414.73,
Shared offscreen 479.05–565.49 and presented drawable 107.38–120.65.
No-present drawables reach 114.26–120.85 and spend about 7–8 ms in nextDrawable.
Managed persistent offscreen reaches 1349.46–1461.77; Managed alone is not the
cause. Drawable usage 23 versus offscreen usage 4 and IOSurface backing are
not isolated. Next investigate drawable pool/recycling and resource paging/
synchronization across the guest compositor and Reims. Do not assert that a
single final display copy or shader execution alone causes the whole gap.

PCIe remains Gen5 ×16. Short GPU-wide samples show large transfer traffic with
presentation but cannot attribute all bytes to the VM. MAILBOX runs without
present fences; no queue-idle fallback occurs during captured steady trials.
Its source callsites are retired-swapchain overflow and window end, so the
startup warning is not evidence of per-frame queue idle. Preserve completion,
resource visibility and release ordering in any future optimization.
Two rejected harness development runs had pending-status/semaphore-disposal
bugs, fixed before the accepted trials; they were not GPU driver faults.
Evidence and caveats: docs/verification/presentation-path.json. Reproduction:
docs/BUILDING.md. No runtime performance fix or all-game improvement is claimed.

The bounded image-memory cache candidate is parked under ignored
artifacts/image-cache-pending and artifacts/vgpu-image-spares-backup. It is
not active or integrated into root manifests. Its native allocation guard also
passes against the attempted baseline and does not establish a cache hit;
do not publish that as cache-effect proof. Keep its owner Metal2 development
history intact and correct forward if that work resumes. Earlier full gates
and their unresolved Reims failures below are unchanged by this diagnostic.

# Previous checkpoint (2026-10-24, general UI input latency)

The Windows frontend now sends the first motion after idle immediately, keeps
only the latest continuous position at the existing approximate 8-ms cadence,
and waits on a condition variable without a periodic idle timer. Button edges,
the final held-button position and wheel ordering remain serialized under the
same mutex. Stop publishes under that mutex before notifying, avoiding lost wakes.
Only native/VGpuPci/device.rs changes product behavior; the Reims/Metal2 binaries
and their outstanding qualification limits below stay as previously recorded.

The same release test against root 38c9e19 and the candidate measured 100 sparse
callbacks: handoff-counter median 5254 -> 1 us, p95 6099 -> 3 us. This excludes
guest HID processing, WindowServer, GPU execution and presentation. Continuous
pending drag cadence is median 8.321 ms, p95 8.989 ms over 50 samples. Nine unit
tests pass, including pending delivery and idle shutdown. Optimized OpenVMM
build passes. Cold boot at 12 GiB / 8 CPUs / 3840x2160 reaches desktop and an
actual host-window drag moves Terminal. Scrolling cadence is not yet qualified.

An authored 4K scene completes with correct readback and no errors before and
after (66.71 and 57.70 mean fps). Different boots/backgrounds, and a debugger
snapshot in the reference, prevent interpreting that as a controlled comparison.
No GPU throughput improvement or app-launch/build-speed improvement is claimed.
GPU submission/compositing overhead remains an open performance work item.
The guest's reduceMotion preference is now true (was absent/false), verified
through fresh NSWorkspace accessibility display queries; reduceTransparency
was already true. Restore with `defaults delete com.apple.universalaccess
reduceMotion`. This suppresses zoom/parallax effects and is not a measured GPU
throughput improvement. A branch-local display-gamma sampling experiment matched
pixels but showed no reliable timing gain; it was not adopted into product code.
See docs/verification/ui-input-latency.json. No monitor automation is enabled.

# Previous checkpoint (2026-10-24, video target reuse and lost-wake repair)

The standard VideoToolbox/Safari decoder now negotiates shared-gpu-v2.
NVDEC -> CUDA -> shared device-local Vulkan buffer -> guest plane images and
GPU DMA into coherent guest RAM avoids host CPU full-frame readback, LZ4
and decoded-pixel network transfer. This is not VRAM-exclusive playback.
NVENC raw input and PCM audio still use CPU buffers and direct pinned TLS.
No live media or GPU workload travels through SSH or the M4. Maintenance and
authored test media remain allowed. Do not recreate the deleted monitor.

Keep the actual 12-GiB / 8-CPU / 4K60 allocation. Development defaults enable
sharedGpuVideo and gpuExactHalfBlend. A structural fast-math product-blend
framebuffer-fetch implementation replaces the earlier setting workaround.
Float-output authored comparisons are 8/8 exact; half-output comparisons
are 8/8 non-exact and retain explicit precision notes. Do not waive them.
The private control file is per-launch and host-only; do not print its key.
Fresh frame capabilities hold current GPU backing through copy completion.
Parked targets can be reused only with validated fresh metadata, exact shape,
current backing and their twenty-second deadline. Core discard/destruction
invalidates targets before releasing pages. Expiry/discard falls back to
materialization (a 22-second pause test takes that fallback and passes).
CoreVideo alone owns buffer recycling (24 slots); no extra pixel-buffer holds.
Metadata remains at offset 1024, beyond CoreVideo's own header.

Five end-to-end cases (147 frames) match CPU and Metal-plane readbacks in the
actual Intel VM. A 3,060-frame retained-buffer check and thirteen lifecycle
cases pass. Barrier/end/cancel notifications now publish their predicate under
the waiting mutex, fixing a lost wake that stalled successful calls for twenty
seconds. A deterministic regression passes on Windows/MSVC and Intel/libc++.
Twenty serial 120-frame runs (2,400 exact frames) each finish within 1.81 s.
Interleaved v1/v2 trials with the wake repair in both reduce FHD elapsed time
by 34% and short 4K elapsed time by 14% (overlapping ranges at 4K). This is
serial decode plus CPU byte verification, not display fps. Ordinary Safari
recording/WebCodecs and post-cold-boot decode checks pass. No new Geekbench,
sustained 4K60 or all-application compatibility is claimed.

Reims candidate 84fb809 is isolated at
C:/Users/ryuya/.codex/build-cache/nativemac-reims-video-worktree; target is
C:/Users/ryuya/.codex/build-cache/nativemac-reims-video-disk-target.
Root patches/reims-shared-gpu-video.patch records its authored changes on
1b9a256; existing patches/reims-msvc.patch is also required. Metal2Vulkan is
79aafca on base 90004070, recorded by metal2vulkan-fetch-product.patch.
SEMANTICS_VERSION is 1700. RUNTIME_VERSION remains 1183: the source-guard
follow-up only corrects an inherited stale hash; all 383 runtime inputs are
unchanged from base. Product commit 59d9ef3 and follow-up 79aafca are merged
into owner development, never master. Local dependency overrides stay private.
Owner backend checkouts and their earlier dirty changes are preserved.
Reims strict clippy passes. Full Windows xtask is NOT green: 2916 pass,
14 fail, 4 skip. Nine shader-death failures reproduce in isolation; PE/nm,
C harness linking and Vulkan enumeration also remain. Mac-only behaviour-lock
suite not run. Reims candidate is not merged into its owner checkout.
Metal2 macOS checks cover all 4567 core/AIR/runtime/devtools cases, all 1303
validation cases (four ignored), doctests, docs with warnings denied, fmt,
workspace/feature-matrix clippy and GPU-cfg clippy. The four resource-heavy
compile census cases were resumed with two test threads; the sole initial
validation failure was the audited inherited source-guard hash, now passing.
Aggregate evidence: docs/verification/video-target-reuse.json and fetch-product.json.

# Historical checkpoint (2026-10-24, direct transport and GPU sharing foundation)

The production codec/audio service now uses direct certificate-pinned TLS,
never SSH media or an SSH fallback. SSH is authorized only for maintenance
commands/deployment and authored test media. The M4 is not a media/GPU server.
Do not recreate the deleted monitor. Keep 12 GiB, 8 CPUs and the 4K60 display.

VP9 profile-0 decoding now preserves redisplay timestamps and covers an
authored invisible-keyframe/redisplay superframe. Three codec families use
NVDEC; encoding remains H.264/HEVC NVENC. Host Python needs the pinned binary
LZ4 dependency. The live route still reads pixels into CPU memory, compresses
losslessly, sends direct TLS, then fills guest pixel buffers. It is not zero
copy. YouTube remains low fps. An adaptive VP9 start with coded/display sizes
both 0x0 is still refused; do not call adaptive playback fixed.

The separate Windows-only GPU interop worker performs NVDEC -> CUDA device
copy -> exported device-local Vulkan buffer -> optimal R8/RG8 images, matching
all 147 frames / 98,409,600 bytes and original PTS in five authored cases,
including short FHD/4K. CUDA/Vulkan UUID equality and binary semaphores are
required. NVDEC output processing and CUDA consumption must use the same
stream; an earlier nonblocking stream race failed byte comparison. Its final
readback is only for verification. The service does not launch this worker.
No guest integration, sustained 4K frame rate or new Geekbench gain is claimed.

The guest accepts a separate metadata page before NV12 planes through public
IOSurface/CVPixelBuffer/Metal creation. Its public plane texture resource IDs
are both 0, so they cannot identify a host copy destination. A capability-based
backing observer is being developed in an isolated Reims worktree; it is not
merged or deployed. Existing backend dirty checkouts remain preserved. Finish
the host/guest binding, lifetime, GPU copy and coherence checks before enabling
the direct-GPU path for Safari. Do not silently label the CPU/TLS path as GPU
sharing. Source/build details and honest limits are in native/VideoBridge and
docs/verification/video-direct-gpu-sharing.json.

The separate virtual audio relay selects only BlackHole2ch_UID, sends PCM via
direct TLS and plays it through Windows WinMM. The user confirmed audible
output. The exact official BlackHole driver and the narrowly scoped
development-VM TCC entitlement are documented in native/AudioBridge. No
physical microphone or TCC database change was made. Full cold-boot/long-term
A/V synchronization remains unqualified. The latest successful Geekbench
Metal score remains 2931; the failed discrete-memory trial was not installed.

# Historical checkpoint (2026-10-23, standard-application hardware video)

The common VideoToolbox / AVFoundation / Safari route now uses the actual
Windows-selected renderer's NVDEC and NVENC, without a per-app launcher.
The host selection is a fresh Vulkan name matched to a unique CUDA adapter;
identical-name ambiguity is rejected. This remains an authored paravirtual
codec, not an NVIDIA macOS kernel driver or a universal compatibility claim.

The root guest profile installs the bounded native Mach broker, root-owned
codec bundle / entry and system, background and GUI environment jobs. Safari's
sandbox uses anonymous pipes and pre-sandbox Mach capabilities; no general
networking permission is added. Ad-hoc component seals are still checked.
Default VM settings now explicitly enable development signing and the video
service. SSV and Windows signing policy remain unchanged. The stock Metal entry
is retained. Keep the actual current 12-GiB / 8-CPU / 4K60 physical allocation.

Normal Dock-launched Safari passes authored canvas recording -> MP4 playback
with changing pixels, and WebCodecs 30 frames / two forced keyframes. Native
worker sessions prove NVENC / NVDEC use. A GUI LaunchServices AVAssetWriter app
writes 30 frames without registering factories or supplying a dyld wrapper;
independent NVDEC checks its exact MP4 timestamps and pixels. AVPlayer's
90-frame public API playback also passes. Direct H.264 / HEVC VT tests cover
small, FHD and short 4K frames, real encoding profiles, modern output handlers,
nonterminal drain and 13 lifecycle / cancellation cases. Cancellation deliberately
drops frames: do not claim whole-input PTS equality for those cancellation cases.

A restored Safari can retain an old per-process XPC bootstrap environment even
when the GUI domain has the new environment. Restarting only WebKit's GPU does
not repair it. The one-shot GUI initializer now inspects trusted same-UID Safari
image metadata (bounded platform vmmap fallback, no memory contents or URLs).
Only a Safari missing the helper is asked to quit normally and reopen through
NSWorkspace. Unknown metadata / refused quit is reported; no forced app exit.
Cold guest reboot + GUI login + browser hardware checks pass. Already configured
Safari is left running. Other consumers running before initial installation
need an initial restart. Unrelated apps are not automatically terminated.

The system profile's disable operation was checked against all three launchd
domains, then enabled again. Reboot after disable is required to clear old
GUI-parent environment snapshots. Do not boot out an identical Mach broker on
re-enable: that destroys the sandbox clients' acquired capabilities. The
installer now preserves an identical live broker and uses the existing launchd
service instance on an upgrade. No loginwindow restart, LoginHook, authentication
plugin, system-volume patch or permanent process monitor is installed.

Windows Start-VM uses the shared Start-VideoBridge readiness helper before VMM
GPU startup, then owns its cleanup. The Python service owns all children in
kill-on-close Windows jobs and watches an actual VM-launcher process handle.
Guest reset/reconnect and the shared startup helper are tested. A complete
second WinUI launch with the final readiness ordering was not repeated; do not
claim otherwise. Required connection/dependency configuration stays in ignored
artifacts/video-service-config.json. No passwords or private evidence are public.

Limits: 8-bit progressive 4:2:0 H.264 / HEVC only; no AV1, VP9, 10-bit/HDR, alpha
or midstream coded-size changes. Four no-B-frame 4K frames pass; sustained 4K60
and long reordered 4K are not qualified. A larger B-frame setup hit the existing
1-GiB worker limit and was rejected, not counted as a pass. NV12 copies still
cross CPU-addressable buffers and authenticated SSH; no zero-copy claim.
A custom media stack, explicit software selection or an unqualified protected
launch path can bypass the bridge. Do not describe this as all apps/formats.

Source and sanitized aggregate/source hashes are in
`docs/verification/video-standard-apps.json`; setup/disable is documented in
`native/VideoBridge/README.md`. No new Geekbench run was done for this video
change. The latest prior Metal score remains 2931 / GPU result 317819; its
conditions are in resident-search-signing.json. The same video profile retains
4096-value Metal compute and Windows-derived name/registry/superclass identity.
Prior same-profile FP32/FP16 matmul and convolution checks pass.

Monitoring remains deleted. VM/private process identities are in ignored
artifacts/vm-session.json. Preserve all pre-existing backend dirty trees; this
video change did not reset or rebuild them. The earlier checkpoint below is
historical, including its now-superseded claims that common video was absent
and that the default signing boot was off.

# Previous checkpoint (2026-10-23 17:05 JST)

The resident-pointer search now performs four fixed binary-search steps rather
than sixteen, then retains the original bounded residual loop. No shader/app
identity checks, precision relaxation or feature claims were added. Translator
code 0d91a54 and golden source 9000407 are merged on backend/metal2-stability
development; semantics is 1699. The distributable patch includes the 51 updated
output hashes. Preserve the pre-existing four Metal2 and six Reims dirty paths.

On the real RTX 5080, an authored integer-pointer shader was run A/B/A/B with
the VM paused. Every value in all rounds matches a separate CPU calculation.
GPU timestamp medians for 1..256 resident buffers are about 21-32% shorter;
4096-buffer timing varies. This is a specific shader path gain, not evidence
of a corresponding game/application speedup. The final M4 reference source
also verifies all 42 rounds. The guest public buffer GPU address is zero, so
that reference exits 77 before dispatch in the VM: unavailable, not a pass.

Pinned LLVM 21.1.8 on M4: fmt, all-target/all-feature clippy and all 3264
translator nextest cases pass (19 skipped). Windows clippy passes; two
scratch-path races in a multi-threaded cargo-test run pass under isolated
nextest. Windows LLVM 22 AIR numbering/golden differences remain; do not
claim the original Windows full cargo-test run passed. Authored translation
passes the unchanged 20-second / 500-MiB bound and SPIR-V 1.2/1.4 validation.

The rebuilt Vulkan DLL (66e95a8ebe8551b7321beb8af24e4773567168227c0525b599ab03b84bc075ac)
is deployed. Stock signed Geekbench 7.1.0 completes all eleven Metal workloads,
exit 0, reported validation errors 0, score 2931:
https://browser.geekbench.com/v7/gpu/317819. It identifies the Windows-selected
NVIDIA GeForce RTX 5080. This run used a memory-backed disk diff and an explicit
development-signing boot with the stock Metal entry. No other GPU benchmark
overlapped. It remains below the earlier best 3238; do not attribute an overall
benchmark gain to the optimization. Guest 4096-value compute, FP32/FP16
899-value matmul and 144-value convolution checks also pass.

The user explicitly authorized VM signing bypass and sudo. New opt-in
Start-VM switches DevelopmentSigning / HostMetalEntry / HostMemoryArchitecture
stage development trials separately. Only DevelopmentSigning adds amfi=0x80
to that VM boot. Default launch, Windows policy and sealed system volume are
unchanged. NVRAM boot-args are replaced by each prepared boot. The authored
Metal entry now loads in WindowServer and presents at 4K after linking IOGPU.
It is NOT qualified: host-discrete memory reporting fails Background Blur/
Face Tracking validation, and retaining the parent memory contract still
fails Super Resolution. Both trials were stopped; keep the stock entry.
The separately staged candidate bridge is 631546f, while the normal staged
bridge is restored to source 1b9a256 / binary SHA256
4745852df065cfc9d85a9ca11dc2b8be60317e1ccf788e87952fd421f96d688e.

The explicit-process CoreMedia registry interposer now permits automatic
discovery of the exact root-owned authored nmq3 decoder while still checking
its ad-hoc seal: 90 frames, 7,776,000 matching NV12 bytes, original PTS and
zero callback errors. Unrelated code retains the Apple-anchor rejection;
a tampered probe executable is rejected and the original was restored.
This does not provide ordinary H.264/Safari selection. Low-delay and early
invalidation remain failing, and VideoToolbox NVENC encoding is absent.
No global internal-OS cache, SSV or persistent injection was changed.

Source patches and aggregate evidence are in
docs/verification/resident-search-signing.json. Do not publish raw guest logs,
screens, result claim links, Apple/consumer binaries or private shader inputs.
Monitoring remains deleted. The normal persistent WinUI-controlled VM is now
restored: actual boot args have no amfi=0x80, dynamic host names agree,
4096 GPU values and all three MPS smoke cases pass. Its real session PID/pipe
is refreshed in artifacts/vm-session.json. Own experimental system bundles
were removed and the idle streaming test server/tunnel stopped. Keep 12 GiB,
8 CPUs, 4K60 physical / 1080p HiDPI. A separate older batch-video tunnel is
pre-existing and was left alone.

## Previous checkpoint (2026-10-23)

The previous best stock Geekbench 7.1.0 Metal run completes all 11 workloads,
exit 0, validation errors 0, score 3238:
https://browser.geekbench.com/v7/gpu/317315. The newer named-device run is 2378
(details and conditions below); do not describe the name update as a speedup.
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
batches at 320×180, 854×480, FHD and 4K. Automatic VideoToolbox selection,
sustained playback and Safari hardware codec integration remain required.

The experimental persistent NVDEC worker (native/VideoBridge/stream.py) has
now decoded the authored 90-frame H.264 fixture with reordered input PTS:
72 frames arrive before EOF; all 7,776,000 NV12 bytes match an independent
NVDEC batch, PTS maximum error 33 ns (CUVID clock quantization). The Matroska
mux separately preserves all compressed packets/configuration and exact input
timestamps under ffprobe. The explicit-process VT decoder now completes an
authored 90-frame B-frame H.264 fixture: 7,776,000 NV12 bytes match an independent
CUVID baseline, source sample PTS match, hardware required/property true,
zero callback errors. The public make_fixture.py and build_probe.sh reproduce
this on the Intel VM. SDK ABI is version 4 bytes, base 76, storage offset 4,
decoder class 84, start offset 4; class version 2 is needed for drain dispatch.
Low-delay and early invalidation remain failures under a bounded self-deadline;
do not select the component for ordinary use. NVENC VT integration is absent.

Automatic component selection is specifically blocked by a signature gate in
CoreMedia's registry after its item predicate accepts the metadata. Public
SecRequirementCopyString and SecStaticCodeCheckValidity in an authored process
confirm the ad-hoc component does not satisfy the registry's Apple-anchor
requirement (-67050). Direct CFBundle load/factory lookup in an authored process
passes. No signing policy was weakened. Both temporary /Library/Video/Plug-Ins
probe components were removed. Investigate a supported trusted video-driver
route rather than installing this unfinished component or changing policy.

GPU naming source 1b9a256 is integrated into backend/reims-stability and is
the current guest kext. ABI and snapshot tests, signed build and cold boot
pass. Start-VM.ps1 now obtains the selected Windows renderer name from a
successful same-DLL probe's startup callback; no fixed model configuration,
first-adapter lookup or cached-name fallback. The dynamic-path cold boot
agrees across probe, actual worker, guest IORegistry and System Information;
4096 GPU values pass. The new native/GpuIdentityAgent is installed in the
base guest: it reads the host property and publishes Metal's existing
all-user forceDeviceName. The stock Apple Metal entry stays selected.
A cold boot with a memory-backed disk diff starts WindowServer and the
launch daemon exits 0 (runs=1). Ordinary and base-class Metal name getters
return the Windows name; 4096 GPU values, FP32/FP16 899-value matmul and
9216-value four-layer convolution pass. Stock Geekbench completes all 11
workloads with the name NVIDIA GeForce RTX 5080, score 2378,
https://browser.geekbench.com/v7/gpu/317477. This is lower than 3238;
ephemeral disk and light CPU-only diagnostics overlapped, and the cause is
not isolated. The name helper source/evidence are published in 736bd35.

The separate native/MetalIdentity entry had a missing IOGPU link dependency;
IOGPU.tbd fixes it for ordinary processes. A cold-boot trial on source
631546f then confirms WindowServer rejects its non-platform signature.
The trial was reverted; no signing enforcement was disabled. Do not select
that entry for normal use or merge its experimental backend branch.

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
