# FHD GPU compatibility checks

Tests use macOS 26.6.2 x86_64, WHP, 12 GiB / 8 virtual processors, and RTX 5080 through Reims/Vulkan. CPU execution uses no instruction translation. The active investigation stays at 1920x1080; 4K qualification is deferred until the FHD gaps are addressed.

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

Each newly reached refusal needs an authored regression and a guest retest. A benchmark finishing, a reported Metal family, and source-level API inventory do not establish support for every shader or application. Shader bodies and logs derived from guest applications remain private artifacts.

The pinned translator has an upstream API inventory in `docs/METAL-COVERAGE.md` and typed refusal catalogue in `docs/REFUSALS.md`. Its inventory covers the macOS 27 SDK's API items, including metadata and platform-owned services; it is not a percentage of GPU instructions supported by this macOS 26 VM. Use it to select tests, then record actual guest execution here.

Broader CPU validation: 3,204 translator unit tests passed, 10 soak tests were ignored, and one test failed because LLVM fixture assembly tools were absent. This is not a green complete suite; missing tools are being supplied. Translator and AIR Clippy checks passed for all targets/all features with warnings denied after two test-only lint fixes. No real-GPU execution is implied by these CPU checks.

A fixture rerun with LLVM and SPIR-V tools executed 1,309 engine tests: 1,308 passed and one found mutually exclusive primitive-skip flags retained in an unreachable ray-query branch. A structural repair preserves the existing all-culled miss path and supplies valid flags to that branch. Its full ray-tracing engine suite and exhaustive settings interpreter check passed after repair. These are CPU/validation results, not proof of guest ray-tracing support. The Access failure was captured locally and reproduced offline under a 20-second / 500-MiB job boundary (0.015 seconds, 4.004 MiB peak job memory). Analysis found that a bounded dynamic handle-array index loses its bounds and opens a mixed sampler/texture/data private cell. A structural repair passed the authored mixed-cell positive/negative test across four profiles, alongside 33 existing pointer-cell tests. The same authored input refuses before the repair and passes afterward. The captured failing input now translates and passes SPIR-V validation in 0.047 seconds at 7.691 MiB peak job memory under the same boundary. These offline checks use a committed reference RTX profile; actual guest GPU execution is still pending.

The bounded-cell candidate passed 35 authored pointer-cell engine tests and the finite-slot boundary test. The initial broad refinement produced a black display. Restricting the new range refinement to private allocation roots preserves the existing treatment of other memory families; source revision `4518f02`, semantics version 1696, then reached the lock screen and desktop. Translator/AIR all-target/all-feature Clippy and Rustdoc pass with warnings denied. The captured failing input translates and validates offline within the 20-second / 500-MiB boundary (0.235 seconds, 6.762 MiB peak job memory). This does not qualify its guest execution.

The restored pre-bounded library passed the authored uint4 bit-reversal probe: all 16,384 guest GPU outputs matched an independent CPU reference. The same probe passed on the M4 reference Mac. The private-cell candidate also passed the original 4,096-value GPU compute probe at the lock screen, but after unlock the guest panicked in `pmap_recycle_page` during pageout/storage completion. No host GPU fatal, exec fault or hang report preceded this panic. Its cause is unresolved, the VM is stopped, and no completed 3D score or continuous stability pass exists.

A full translator CPU suite at revision `0e83a42` passed 3,242 tests, failed one, and ignored ten. The remaining failure is the generated fixture golden comparison: LLVM 21/22 lifetime-marker signatures give different type numbering in 14 fixtures. This is an unresolved gate failure; focused checks and offline translation passes do not make the full suite green.
