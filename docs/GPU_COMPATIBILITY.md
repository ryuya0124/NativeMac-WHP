# FHD GPU compatibility checks

Tests use macOS 26.6.2 x86_64, WHP, 12 GiB / 8 virtual processors, and RTX 5080 through Reims/Vulkan. CPU execution uses no instruction translation. The active investigation stays at 1920x1080; 4K qualification is deferred until the FHD gaps are addressed.

Latest benchmark checks: the opt-in binding/readback adapter renders a populated
GravityMark 1.89 scene and completes FHD/20,000 asteroids in 167.1 seconds,
22.7 fps, score 3792, exit 0. Binding-only still reproduces zero visible objects.
The identical combined adapter also reproduced black output on its next run,
so this is one successful observation, not repeatable qualification. Its only
readback copy belongs to preflight; the underlying cause is unproven. Heap creation still returns
nil. No pixel-equivalence or general Metal claim follows.

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
