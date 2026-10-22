# Optional Metal compatibility adapter

`DeferredStageBindings.m` is an authored, process-local adapter for the measured
`AppleParavirtRenderCommandEncoder` implementation. Its public object/mesh
sampler entry points claim availability but throw `unrecognized selector`.
GravityMark 1.89 calls these setters, and texture setters, in its ordinary
rasterization path even with mesh rendering disabled.

The adapter retains separate object/mesh sampler, texture and buffer tables,
LOD clamps, buffer offsets, copied inline bytes and object threadgroup lengths
for each encoder. Traditional vertex/fragment commands are unchanged. Every
mesh draw entry point throws an explicit unsupported exception; none is dropped
or reported as successful. This does **not** implement mesh shader execution,
GPU heaps or general Metal compatibility. Family and availability queries are
unchanged. It activates only on the named paravirtual encoder and after both
measured sampler calls reject legal nil bindings. It stays inactive on M4.

`SharedTextureReadback.m` additionally checks the guest's shared-texture CPU
readback against a real GPU clear. Only after native `getBytes` fails and a GPU
blit succeeds does it install raw GPU-to-buffer readback for measured 2D/array
formats. It waits for the copy and preserves destination padding. Compressed,
depth/stencil, unknown formats and other texture kinds keep their native path.
Allocation or command failure throws explicitly. It does not generate pixels.
The wrapper stamps its PID so GPU preflight runs only in the selected process,
not inherited compiler helpers. The native M4 texture path is unchanged.

From Windows, build the authored adapter and probes on a Mac with Xcode:

```powershell
./scripts/Build-GuestMetalCompat.ps1 -MacHost account@mac-host
```

Copy `deferred-stage-bindings.dylib`, the probe executables and
`Run-With-DeferredBindings.sh` from `artifacts/metal-probe` to the same folder in
the development guest. The script is opt-in for one executable and its children:

```bash
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64 --cpu-indirect
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64 --gpu-indirect
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64 --shared-cpu-readback
/bin/bash Run-With-DeferredBindings.sh ./texture-readback-regions-x64
```

The probe checks independent state, nil clearing, copied bytes and buffer
offsets, invalid ranges, all three explicit mesh draw refusals, and 16 exact
GPU-readback pixels. Nearest sampling in the fragment stage must stay red while
the deferred stages hold blue textures and linear samplers. It covers direct
drawing, CPU-written indirect arguments and GPU-written indirect arguments
consumed by a draw in the same command buffer. All three pass in the FHD Windows
guest. Native M4 reference runs also pass. Build warnings are errors.

To launch an installed benchmark, pass its executable and ordinary arguments to
the same wrapper from the benchmark's expected working directory. Do not export
`DYLD_INSERT_LIBRARIES` into login sessions or install it globally. Nothing in the
VM launcher enables it automatically.

With both modules active, GravityMark renders the Earth and asteroids and
completes its FHD/20,000-object run: 167.1 seconds, 22.7 fps, score 3792,
exit 0, 371504 deferred bindings and no mesh requests. Heap allocation remains
unsupported and the app falls back. A binding-only confirmation reproduces
the black scene and zero visible objects; its apparent score is rejected.
The identical combined adapter also reproduced black output on its next run;
that run's score is rejected. This is **one populated-scene completion, not a
repeatable qualification**. **The black-scene cause is still unproven:** the successful run reports only
one readback copy, the constructor's preflight. The benchmark itself never
calls the replacement, so its changed output cannot be attributed to intercepting
`getBytes`. Initialization effects need further investigation. Do not claim
pixel equivalence or general Metal support. Hiding Apple families still triggers
a cube-array assertion and is not installed.

The explicit `--shared-cpu-readback` regression checks both paths: guest CPU
`getBytes` originally matched 0/16 pixels while GPU blit matched 16/16. With the
adapter both match 16/16. `TextureReadbackProbe.m` passes 84 raw-copy/readback
cases (23500 bytes, no mismatches) across seven formats, mips, slices,
subregions and padded rows; its x64 M4 reference also passes. This repairs
the measured CPU readback path, not the underlying driver coherency mechanism.

`ArgumentBufferProbe.m` is a separate diagnostic, not a compatibility claim.
Enabling isolated GPU tasks to expose addresses currently fails cold boot on
the service's unsupported backing lookup. Isolation stays off in the launcher.
See [benchmark results and limits](../../docs/verification/metal-benchmarks.json).

Only authored source and aggregate test results belong in Git. Keep application
logs, captures, shader inputs, binary outputs and channel credentials private.
