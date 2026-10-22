# Optional object/mesh binding adapter

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

From Windows, build the two authored sources on an accessible Mac with Xcode:

```powershell
./scripts/Build-GuestMetalCompat.ps1 -MacHost account@mac-host
```

Copy `deferred-stage-bindings.dylib`, `deferred-bindings-probe-x64` and
`Run-With-DeferredBindings.sh` from `artifacts/metal-probe` to the same folder in
the development guest. The script is opt-in for one executable and its children:

```bash
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64 --cpu-indirect
/bin/bash Run-With-DeferredBindings.sh ./deferred-bindings-probe-x64 --gpu-indirect
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

The adapter gets GravityMark past the setter exceptions and through a complete
run without a mesh draw request. **The guest scene is black and reports zero
visible objects, so its apparent score is rejected.** The same x86_64 benchmark
and parameters render a populated scene on M4. Hiding Apple GPU families did not
fix this: the guest aborted a cube-array feature check, so that diagnostic is
not part of this adapter. The next investigation is scene visibility/output;
the current tests do not identify its cause.

The explicit `--shared-cpu-readback` regression checks both paths: guest CPU
`getBytes` matches 0/16 pixels while GPU blit-to-buffer matches 16/16; the same
M4 probe matches both. This known failing mode exits 4. Its cause is unproven;
there is no texture-coherence fix or qualification here.

Only authored source and aggregate test results belong in Git. Keep application
logs, captures, shader inputs, binary outputs and channel credentials private.
