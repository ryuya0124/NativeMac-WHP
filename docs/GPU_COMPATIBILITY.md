# GPU compatibility checks

Stock signed Geekbench 7.1.0 Metal completes all 11 workloads with zero
validation errors: [3238](https://browser.geekbench.com/v7/gpu/317315).
The guest uses kernel bridge `42e21ba` and translator code `66092df`
(semantics 1698), without benchmark patches, injected adapters or changed
GPU-family claims. No other benchmark or stress suite ran concurrently;
light SSH readouts and two brief identity-probe compilations occurred during
the run, so laboratory-isolated performance is not claimed.

The later host-name regression also completes all 11 workloads, exit 0,
displaying `NVIDIA GeForce RTX 5080`: [2378](https://browser.geekbench.com/v7/gpu/317477).
That run used an ephemeral disk and overlapped light CPU-only development
diagnostics. Its score is lower; the cause has not been isolated and no
performance improvement is claimed for the name update.

The bridge preserves subpage NoCopy aliases and publishes completed Shared
texture GPU writes to their CPU backing, including mipmapped records. The
translator respects final descriptor-relative vector offsets of 4, 8 and
12 bytes while retaining aligned vector accesses. Authored GPU checks cover
512 vector values plus guard bytes and 84 texture readback cases / 23500 bytes.
FP32 matrix multiplication checks 899 values with zero mismatches, maximum
error 3.5108e-6; the transposed case has maximum error 5.6965e-7.

The [automatically generated feature matrix](verification/feature-matrix-comparison-v2.json)
executes identical probe sources on the M4 reference and Intel VM. The VM
passes 37 of 41 cases. Remaining failures are indirect command buffer
allocation, mixed argument buffer bindings, private heap buffers and private
heap textures. The reference runs macOS 27.2 while the VM runs 26.6.2, so the
comparison includes OS, SDK and architecture differences. The original FP16
random sum check fails its unchanged tolerance on the reference; a separately
authored exactly representable sum passes on both. See
[counts and limitations](verification/metal-feature-matrix.json).

VM VideoToolbox software H.264 and HEVC round trips each return 12 verified
frames. An authored local H.264 movie plays through WKWebView with 38 frame
callbacks and 5 observed pixel changes. These are software codec results;
Automatic VideoToolbox hardware encoder/decoder selection is not implemented. The
Windows RTX 5080 separately passes a 90-frame NVENC H.264 encode and NVDEC
decode. The guest-to-Windows transport also passes checked H.264/HEVC encode
and decode batches from 320×180 through 3840×2160, with explicit NVENC/CUVID
and no software fallback. See [transport evidence](verification/video-hardware-transport.json).
An explicit-process H.264 VideoToolbox/NVDEC streaming prototype now completes
90 B-frame samples: 7,776,000 NV12 bytes match the independent hardware baseline,
timestamps match and the hardware property is true. Automatic selection rejects
the ad-hoc component at the codec registry's signature check (-67050).
Low-delay and early invalidation still fail bounded tests; the temporary
components were removed. This does not qualify ordinary Safari/QuickTime,
VideoToolbox encoding or sustained playback. See
[streaming evidence](verification/video-vt-stream.json) and
[scope/reproduction](../native/VideoBridge/README.md).
YouTube still fails with a player `fmt.decode` error. Neither host codec
success nor local movie playback qualifies Safari hardware video.

## GPU model discovery

Every GPU-enabled launch creates a short-lived probe using the same Reims
DLL and default device selection as the VM. Its selected Windows Vulkan
renderer name is read from the pinned backend's startup callback, validated
and passed through OpenCore `reims-gpu-model` to the guest bridge. No fixed
GPU model, first-Windows-adapter assumption or cached-name fallback is used.
Failure to obtain one valid name stops launch.

The dynamic path cold boots with the probe, actual VM renderer log,
IORegistry model and System Information model all agreeing; the subsequent
4096-value GPU compute check passes. See [identity evidence](verification/gpu-host-identity.json).
Install the [GPU identity boot helper](../native/GpuIdentityAgent/README.md)
inside the guest to publish that metadata through Metal's existing all-user
display-name preference. The standard Apple Metal entry stays selected.
The cold boot starts WindowServer, ordinary Metal and base-class name getters
agree with Windows, and GPU compute plus FP32/FP16 MPS checks pass. See
[standard-driver name evidence](verification/gpu-metal-identity.json).
No signing policy is changed. App-specific user preferences or cached strings
can override or retain a previous label.

The separate [Metal entry prototype](../native/MetalIdentity/README.md) works
in ordinary authored test processes but WindowServer rejects its non-platform
signature. That trial was reverted; it is not the deployed naming path.
OpenCL device support and Geekbench's malformed OpenCL API-menu label remain
separate gaps.

## Earlier FHD and 4K checks

Tests use macOS 26.6.2 x86_64, WHP, 12 GiB / 8 virtual processors, and RTX 5080 through Reims/Vulkan. CPU execution uses no instruction translation. FHD remains the default. A bounded 4K desktop and populated GravityMark run now pass; general Metal and game compatibility remain incomplete.

The kernel bridge's fixed-size serializer check rejected large encoders before
submission to the host GPU. Snapshot `8a079b0` validates variable-length segment
lists and preserves every command buffer. The authored 16384-command GPU blit
now completes with all 4096 bytes correct; before the repair it was refused with
Internal Error and all 4096 bytes wrong. Native/x64 ABI checks pass, and the
candidate cold boots to the FHD desktop.

Three consecutive repaired GravityMark runs show populated scenes and finish
FHD/20,000 asteroids normally (24.0 fps / score 4012, 23.7 fps / score 3957,
and 24.0 fps / score 4018). The second and third runs have no submission tracing;
the third also has no extra foreground activation. Earlier black/zero-visible scores remain rejected.
Three post-benchmark lock/unlock cycles, a desktop title-bar drag and checked
4096-value GPU compute also pass. No new host fatal, exec fault, GPU hang or
kernel panic appears in this session. A new 30-minute continuous observation
has not been qualified. Heap creation still returns nil; pixel equivalence and general Metal support
are not qualified.

The independent `ctsilva/triangle-rendering-benchmarks` completes both modes
with visible geometry at 800x600 and approximately 160 fps after correcting
the benchmark's transposed perspective entries; its untouched blank scores
are rejected. No GPU adapter is injected into this benchmark. Shared-texture
readback separately passes 84 cases / 23500 checked bytes, including padded
subregions, array slices and mips. Isolation remains disabled: its cold boot
reaches `gpu_task.unsupported.backing_for_id`. See
[current aggregate evidence](verification/metal-benchmarks.json) and
[adapter scope](../native/MetalCompat/README.md).

The table and investigation entries below record earlier checkpoints, including
failures superseded by the current scoped checks above.

| Path | Evidence | Status / limits |
| --- | --- | --- |
| Metal compute, shared-buffer readback | 4,096 values compared in the guest, repeated runs | Passed for this probe |
| Queue bursts | Three runs, 64 completed command buffers each | Passed for this probe |
| Texture allocation/reuse | Three runs, 100 checked reuse rounds each | Passed for this probe |
| CAMetalLayer presentation | 2,875 completed frames in 20.006 s with the ASTC rejection candidate | Passed short run; this is a clear test, not 3D geometry |
| ASTC texture allocation | ASTC 8x8 allocation returned nil; subsequent compute and presentation succeeded | Explicitly unsupported; no ASTC decoder is implemented |
| Desktop lock/unlock | User confirmed three fast unlocks in the ASTC rejection session | Passed these transitions; subsequent trials still have resource faults |
| LLVM `bitreverse` | Authored overload checks, lowering-selection check, 10 integer differential tests, AIR suite (434 tests); authored Metal uint4 reverse-bits probe checked 16,384 guest GPU outputs | Passed these checks; the Metal probe alone does not establish which decoder intrinsic was exercised |
| GravityMark 1.89, FHD rasterization | First run aborted on `llvm.bitreverse.i32` during pipeline creation | Failed twice: the repaired decoder reaches a later `Lowering(Access)` refusal at compute_main block 1 / instruction 43. No score or completed 3D pass |
| Multiple restored desktop apps | A later FHD trial had three empty-resource faults, three GPU hang reports, then a `pmap_recycle_page` kernel panic | Failed; the panic stack includes pageout and storage completion; causality is unresolved |
| File-backed no-copy buffers | 192 GPU buffer lifetimes; 18,087,936 output values compared; all 192 deallocators completed with successful flush/unmap | Passed on M4 reference and Windows guest with bridge revision `0226631`; no long-term stability claim |

Each newly reached refusal needs an authored regression and a guest retest. A benchmark finishing, a reported Metal family, and source-level API inventory do not establish support for every shader or application. Shader bodies and logs derived from guest applications remain private artifacts.

The pinned translator has an upstream API inventory in `docs/METAL-COVERAGE.md` and typed refusal catalogue in `docs/REFUSALS.md`. Its inventory covers the macOS 27 SDK's API items, including metadata and platform-owned services; it is not a percentage of GPU instructions supported by this macOS 26 VM. Use it to select tests, then record actual guest execution here.

Earlier optional API checkpoint: the authored, opt-in binding adapter retains
object/mesh resource settings used by GravityMark's traditional draw path. It
does not change feature queries or implement mesh execution; mesh draws throw
explicitly. Direct, CPU-indirect and GPU-indirect authored render tests all pass
16 exact GPU-readback pixels, including independence of fragment state from
deferred object/mesh state. GravityMark now completes without the setter
exception, but shows a black scene and zero visible objects. Its apparent score
is rejected. The identical x64 benchmark/parameters show a populated scene on
M4. The general scene-output cause remains unproven, and hiding Apple families
only triggers a guest cube-array feature assertion. These process-local tests
do not qualify the benchmark, heap creation, mesh rendering or general Metal.
See [adapter scope](../native/MetalCompat/README.md) and
[aggregate checks](verification/deferred-stage-bindings.json).

Broader CPU validation: 3,204 translator unit tests passed, 10 soak tests were ignored, and one test failed because LLVM fixture assembly tools were absent. This is not a green complete suite; missing tools are being supplied. Translator and AIR Clippy checks passed for all targets/all features with warnings denied after two test-only lint fixes. No real-GPU execution is implied by these CPU checks.

A fixture rerun with LLVM and SPIR-V tools executed 1,309 engine tests: 1,308 passed and one found mutually exclusive primitive-skip flags retained in an unreachable ray-query branch. A structural repair preserves the existing all-culled miss path and supplies valid flags to that branch. Its full ray-tracing engine suite and exhaustive settings interpreter check passed after repair. These are CPU/validation results, not proof of guest ray-tracing support. The Access failure was captured locally and reproduced offline under a 20-second / 500-MiB job boundary (0.015 seconds, 4.004 MiB peak job memory). Analysis found that a bounded dynamic handle-array index loses its bounds and opens a mixed sampler/texture/data private cell. A structural repair passed the authored mixed-cell positive/negative test across four profiles, alongside 33 existing pointer-cell tests. The same authored input refuses before the repair and passes afterward. The captured failing input now translates and passes SPIR-V validation in 0.047 seconds at 7.691 MiB peak job memory under the same boundary. These offline checks use a committed reference RTX profile; actual guest GPU execution is still pending.

The bounded-cell candidate passed 35 authored pointer-cell engine tests and the finite-slot boundary test. The initial broad refinement produced a black display. Restricting the new range refinement to private allocation roots preserves the existing treatment of other memory families; source revision `4518f02`, semantics version 1696, then reached the lock screen and desktop. Translator/AIR all-target/all-feature Clippy and Rustdoc pass with warnings denied. The captured failing input translates and validates offline within the 20-second / 500-MiB boundary (0.235 seconds, 6.762 MiB peak job memory). This does not qualify its guest execution.

The restored pre-bounded library passed the authored uint4 bit-reversal probe: all 16,384 guest GPU outputs matched an independent CPU reference. The same probe passed on the M4 reference Mac. The private-cell candidate also passed the original 4,096-value GPU compute probe at the lock screen, but after unlock the guest panicked in `pmap_recycle_page` during pageout/storage completion. No host GPU fatal, exec fault or hang report preceded this panic. Its cause is unresolved, the VM is stopped, and no completed 3D score or continuous stability pass exists.

A full translator CPU suite at revision `0e83a42` passed 3,242 tests, failed one, and ignored ten. The remaining failure is the generated fixture golden comparison: LLVM 21/22 lifetime-marker signatures give different type numbering in 14 fixtures. This is an unresolved gate failure; focused checks and offline translation passes do not make the full suite green.

The bridge candidate now withdraws its CPU alias before asking the backend to release the backing allocation. Refused releases restore the alias, and failed restoration closes the connection to further commands. Native ownership-order tests cover success, refusal, retry and failed restoration. The x86_64 kext built without warnings; its loaded UUID matches the candidate binary and committed source manifest. The one-time root boot diagnostic's LaunchDaemon and script were confirmed removed.

With this bridge and translator revision `4518f02`, GravityMark passed the prior shader-creation refusal and displayed its initialization window. It then repeatedly failed to allocate 16-MiB GPU heaps. The 180-second bound terminated the benchmark (exit 143); no score was produced. Guest display presents stopped and did not recover after termination. No kernel panic or host GPU fatal was observed in that trial. The pageout panic's cause therefore remains unproven, and desktop stability is still failed. The next test isolates heap creation using the authored `HeapProbe.m`; its ordinary and placement private-heap allocations pass on the M4 reference Mac.

## Fresh-alias investigation (2026-10-22)

The frozen worker was repeatedly sampled inside Windows `MapViewOfFile3` while
assembling fragmented shared-buffer/texture aliases. Samples moved between
resources; this establishes a mapping bottleneck, not a permanent deadlock.
A 64-KiB view-bound trial delayed unlock and still timed out in GravityMark; it
was rejected. Contiguous physical-run grouping (`c812e2c`) passed all 2,304 core
unit tests in a serial debug run and booted to Terminal, but did not qualify:
the 64-MiB no-copy GPU round exceeded its completion bound, and GravityMark
again timed out after 180 seconds (exit 143, no score).

The next candidate (`1c805df`) installs a fully validated fresh alias directly
into placeholders. It keeps real shared file backing, source protections,
source-page identity and runtime remap/lifetime reporting. Invalid core plans
keep their original partial-operation and refusal ordering. Five native Windows
VM tests pass, including a fragmented 64-MiB / 16,384-page alias checked in both
write directions and after releasing the source. The same guest then passed all three 16/32/64-MiB no-copy rounds: 29,360,128 checked GPU values and three completed deallocators in 8.520331 seconds. A new Terminal window opened after the probes. The subsequent GravityMark run timed out at 300 seconds, leaving the display stalled; continuous stability was not qualified.

[3DMark for macOS requires Apple Silicon](https://support.benchmarks.ul.com/support/solutions/articles/44002642889-3dmark-for-macos-system-requirements),
so it cannot measure this Intel guest. The installed x86_64 GravityMark Metal
workload remains the commercial benchmark trial. `SceneProbe.m` adds an authored
FHD diagnostic with 441 indexed, instanced, textured cubes, depth testing and a
GPU pixel readback. Its frame-completion rate is a diagnostic measurement, not a
3DMark score or a count of frames physically shown by the monitor. The M4
reference build passes. The Windows guest at `1c805df` completed 2,142 frames in
15.001 seconds (142.79 completed frames/s), with zero errors and a checked GPU
pixel readback. This small scene does not qualify GravityMark or general desktop
stability.


## Shared-section banking trial (2026-10-22)

An external process duplicated the actual VM's anonymous 12-GiB RAM section
and mapped aliases without reading or writing guest bytes. It also stalled:
4096 views took 22.62352 seconds. Independent native-WHP/NVIDIA-import/Reims-window
controls did not reproduce the delay. This associates the slowdown with the
actual section state; it does not establish its underlying kernel/driver cause.

The OpenVMM trial uses separate shared sections of at most 64 MiB for the
Windows NativeMac Reims PCI device. It preserves GPAs, RAM capacity, CPU count
and FHD. Existing restored handles, private memory and hugepages are excluded.
All 55 memory-manager unit tests pass, including cross-bank read/write and
actual alias checks. Cold boot and initial unlock pass. RAM-handle restart
reconstruction is unavailable for multi-backing RAM; cold startup is supported.

The guest completed 2273 authored FHD scene frames in 15.007 seconds (151.46
completed frames/s), with zero errors and checked pixel readback. GravityMark's
15 timed large alias batches all completed; the slowest, 268472320 bytes across
65545 views, took 0.1658868 seconds. A 44740608-byte/10923-view batch took
0.051694 seconds, versus 60.61 seconds in the previous monolithic trial. These
are corresponding sizes and counts, not proven identical physical page sequences.

GravityMark reached its Metal benchmark in 4.362 seconds, then exited 134:
`AppleParavirtRenderCommandEncoder` does not implement
`setObjectSamplerState:atIndex:`. There is still no commercial benchmark score.
The desktop recovered visibly after this application failure. Optional Metal
entry points and feature claims are under investigation; no draws are skipped
or reported as successful. Three explicit lock/unlock cycles now pass, including one after the full
30-minute observation. It completed 184144 real FHD render frames and 29
checked no-copy memory rounds (851443712 GPU values, 87 releases), with zero
render/mapping errors, GPU hangs or kernel panics. The maximum observed frame
gap was 338.56 ms during app/input interactions. A final post-unlock GPU
check verified 4096 values and the desktop title-bar drag responded. These
results qualify this bounded desktop observation, not general Metal compatibility. See `docs/verification/banked-gpu-ram.json`.


## 4K display qualification (2026-10-22)

The 3840×2160 maximum-mode launch cold-boots and unlocks. macOS initially
chooses 2560×1600. A temporary `CGDisplaySetDisplayMode` selection reverts after
about one second; `DisplayModeProbe.m` now commits an explicit session display
configuration instead. Both CoreGraphics and the host GPU callback then retain
3840×2160. This changes the current login session only. It does not change the
default launch resolution or promise a persisted mode after the next login.

The same authored 441-cube workload renders actual 3840×2160 drawables, checks
a GPU pixel and completes 30 seconds with zero command errors. With a
2560×1600 desktop it reports 103.30 completed fps; with a 3840×2160 desktop
it reports 59.55. These are different desktop workloads, not a measured
optimization gain, a commercial score, or physical monitor delivery rates.

GravityMark 1.89 at 3840×2160 fullscreen, 20,000 asteroids, temporal=1,
raster=0, meshlet=0 and raytracing=0 completes in 167.2 seconds: 17.3 fps,
score 2895, exit 0. Changing populated scenes are observed, with visible-object
samples 18,202 and 9,497. The process-scoped binding/readback adapter remains
required. Heap allocation is still refused and the application falls back;
full pixel equivalence, general Metal compatibility and long 4K stability
remain unqualified. See [aggregate evidence](verification/fourk-display.json).


SuperTuxKart 1.5 is not qualified. Its signed x86_64 application initially
falls back silently to Apple's software OpenGL renderer after Vulkan
attachment allocation fails; that trial is rejected. MoltenVK's official
`MVK_CONFIG_USE_MTLHEAP=0` and `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`
settings allow Vulkan initialization and a timed profile to finish, but the
observed output is black. Disabling texture compression produces visible sky
with malformed/incomplete geometry. No game performance number from these
trials is accepted. This is an application compatibility failure, even though
the profile exits normally and the desktop recovers.


### Compositor refresh budget

The launcher now sets the guest's refresh rate explicitly (60 Hz by default,
configurable with `-DisplayRefreshHz 30..240` or `displayRefreshHz` in
`vm/defaults.json`). This avoids inheriting a high-refresh host's maximum
without changing the guest's RAM, CPU count, render dimensions or scene.
The environment override is local to that launch and restored on exit.

At a 3840×2160 desktop and drawable, the same 30-second authored scene
completed 59.55 fps at the previous 160-Hz mode and 74.17 fps at the new
60-Hz mode, both with zero errors and checked GPU pixel readback. AppKit
reports a maximum of 60 fps for the new guest screen; CoreGraphics reports
a zero nominal refresh rate for its modes. The 24.55% throughput difference
is one run per setting across cold boots, not a universal GPU speedup or
physical monitor delivery above 60 Hz.


The matching 4K GravityMark workload also completes at 60 Hz: 18.3 fps,
score 3058, 167.2 seconds, exit 0, with changing populated scenes observed
(visible-object sample 34,490). Relative to the 160-Hz run's 17.3 fps / 2895,
this single-run comparison gains 5.78% in reported fps. The same heap
fallback and adapter limitations apply. No game compatibility improvement
is established by these measurements.

## PCI display metadata compatibility (2026-10-22)

Stock Geekbench 7.1.0 originally aborted before a CPU workload with an
`NSInvalidArgumentException`: a PCI display `model` property was an OSString
where its consumer requested bytes. The scoped kernel patch preserves the
exact `Apple Paravirtualized Graphics Device` name as NUL-terminated OSData
on PCI 106b:eeee. It leaves existing data values, CPU identity, Metal features
and workloads unchanged. Cold boot exposes the corrected data property and
stock `--sysinfo` now exits 0; CPU benchmark execution reaches its workloads.
Stock CPU workloads complete and upload successfully: single-core 2287,
multi-core 10415. Metal selects the paravirtual device but exits 255 on its
first Background Blur workload with an MPSNDArray nil-device assertion; no
GPU score exists. A separate authored device probe finds a valid Metal
device, MPS support, a matching MPSGraph device, and successful scalar
NDArray initialization, so this does not establish that all MPS is absent.
It does not qualify graph execution or fix the workload failure. Ordinary
Metal compute still checks all 4096 values after the benchmark. See
[`geekbench7.json`](verification/geekbench7.json) for the public CPU result.

Source revision: `0471bc25dffab380631e8cb888784ebbd233fff2`, following the
segmented-submission patch. The source snapshot tests (3), native/x86-64 ABI
checks, warning-free x86-64 kernel build and strict signature/provenance
verification pass. The active kernel binary SHA-256 is
`684999c66e36e303054cbd656f17062886beba8b99c5d3c3ac2b0903a4801684`.
This guest-only metadata change does not reach the Rust library or C API;
their full test suite is not rerun for it. General GPU compatibility remains
incomplete.

The macOS Displays settings list was also exercised directly: 1920×1080
HiDPI (3840×2160 pixels), 3840×2160 at 1×, 2560×1440 at 1×, then back to
1920×1080 HiDPI. CoreGraphics pixel and logical dimensions follow the UI
choices. `DisplayModeProbe.m` now reports both dimensions, avoiding a
misleading assumption that a larger UI necessarily reduced pixel output.
The VM is left at 4K output with readable 1920×1080 HiDPI scaling.

## Intel VM Xcode build (2026-10-22)

MochiLog `eb1503924d9e9b8ae874010c96443cdf78823682` builds inside this
x86-64 VM with Xcode 26.5 (17F42), iOS/watchOS Simulator 26.5 SDKs,
and code signing disabled. The unchanged project produces both phone and
watch simulator apps with x86-64/arm64 slices. `BUILD SUCCEEDED`, exit 0,
in a 68-second observed wall-clock window including dependency resolution.
There is an AppDistributor Sendable warning and skipped optional App Intents
metadata extraction. This verifies compilation only; neither simulator nor
app was launched. See [`mochilog-vm-build.json`](verification/mochilog-vm-build.json).
