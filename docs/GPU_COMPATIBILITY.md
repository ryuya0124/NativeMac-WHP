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
| LLVM `bitreverse` | Authored overload checks, lowering-selection check, 10 integer differential tests, AIR suite (434 tests) | CPU validation passed; guest reached a later Access refusal; bitreverse GPU result is not independently verified |
| GravityMark 1.89, FHD rasterization | First run aborted on `llvm.bitreverse.i32` during pipeline creation | Failed twice: the repaired decoder reaches a later `Lowering(Access)` refusal at compute_main block 1 / instruction 43. No score or completed 3D pass |
| Multiple restored desktop apps | A later FHD trial had three empty-resource faults, three GPU hang reports, then a `pmap_recycle_page` kernel panic | Failed; the panic stack includes pageout and storage completion; causality is unresolved |

Each newly reached refusal needs an authored regression and a guest retest. A benchmark finishing, a reported Metal family, and source-level API inventory do not establish support for every shader or application. Shader bodies and logs derived from guest applications remain private artifacts.

The pinned translator has an upstream API inventory in `docs/METAL-COVERAGE.md` and typed refusal catalogue in `docs/REFUSALS.md`. Its inventory covers the macOS 27 SDK's API items, including metadata and platform-owned services; it is not a percentage of GPU instructions supported by this macOS 26 VM. Use it to select tests, then record actual guest execution here.

Broader CPU validation: 3,204 translator unit tests passed, 10 soak tests were ignored, and one test failed because LLVM fixture assembly tools were absent. This is not a green complete suite; missing tools are being supplied. Translator and AIR Clippy checks passed for all targets/all features with warnings denied after two test-only lint fixes. No real-GPU execution is implied by these CPU checks.
