# Metal benchmark reproduction

These are scoped development checks for the Intel macOS guest. Keep 12 GiB,
8 CPUs and the FHD desktop. Results and limits are in
[metal-benchmarks.json](verification/metal-benchmarks.json). Do not upload private
guest captures, shader inputs, app binaries or logs to this repository.

## GravityMark 1.89

Build the opt-in adapter with `scripts/Build-GuestMetalCompat.ps1`, copy its
dylib and wrapper into a guest probe folder, and run from the benchmark's
`Contents/MacOS` directory:

```bash
/bin/bash "$HOME/NativeMacLab/probes/readback-candidate/Run-With-DeferredBindings.sh" \
  ./GravityMark -width 1920 -height 1080 -fullscreen 0 -vsync 0 \
  -temporal 1 -fps 1 -info 1 -sensors 0 -benchmark 1 -asteroids 20000 \
  -raster 0 -meshlet 0 -raytracing 0 -close 1 -count 1
```

`-raster 0` selects ordinary rasterization, not compute rasterization. Close
the app's crash-restoration question before timing; do not mistake this modal
for a GPU hang. Use a separate bounded process group to clean up a failed run.
Require normal exit, actual populated scenes and a recovered desktop; a score
on a black scene is rejected. Heap creation still returns nil and the benchmark
falls back. Neither a mesh shader nor CPU rendering is substituted.

On the earlier kernel bridge, combined-adapter runs could show populated output
or a black scene. The benchmark never invoked the CPU readback replacement;
foreground activation alone did not remove the failure. A later diagnostic
isolated a synchronous kernel submission refusal, described below. The candidate
has completed three consecutive populated FHD runs at 23.7–24.0 fps
(scores 4012, 3957 and 4018), all exit 0. These benchmark results do not qualify general Metal support.

## Large encoder submission regression

The kernel bridge previously assumed every serializer command occupied 20 bytes
and named a single command buffer. Larger encoders name multiple buffer/used-length
pairs in a variable-length record. The old check rejected them synchronously with
`kIOReturnUnsupported`, so a Metal command buffer finished with Internal Error
before reaching the host GPU. The segmented-submissions patch validates the
count, size, opcode and containing range, while preserving every pair verbatim.
Resource-list validation and actual completion delivery remain in place.

`native/MetalProbe/SegmentedBlitProbe.m` grows one encoder with 16384 real fill
commands and checks all 4096 destination bytes. It fails with Internal Error and
4096 mismatches on the earlier bridge; the candidate completes with zero
mismatches. Its x64 M4 reference also passes. Run this probe without a shim:

```bash
./segmented-blit-probe-x64
```

The affected CPU-only ABI tests cover one, two and three segments, mixed records,
byte preservation, truncation, count/size overflow, unknown opcodes and record
boundaries. Both native and x64 builds pass on the development Mac. The signed
candidate is built from source snapshot `8a079b086b8b3990c1ad60a56e924a9028c9bb4c`;
its source manifest is kept with the source-only verification records.
GravityMark now passes three consecutive populated runs; the second and third
omit submission tracing, and the third omits extra foreground activation. Both
triangle modes then complete again without an injected adapter (159.9 and
160.0 fps). These results do not qualify general Metal support or long-duration
stability on this new kernel snapshot.

## Independent triangle benchmark

Download [ctsilva/triangle-rendering-benchmarks](https://github.com/ctsilva/triangle-rendering-benchmarks)
into a new scratch directory and check out
`37a702cf264bbd6764dfc5f717a5bd5bfeff4921`. Apply this repository's
`patches/triangle-benchmark-projection.patch` there with `git apply`.
The two changed entries repair a column-major projection matrix that otherwise
clips all triangles. This is a source-corrected benchmark, not an untouched
upstream score.

Build on a Mac with Xcode:

```bash
xcrun clang -O3 -arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc \
  benchmark.m -framework Cocoa -framework Metal -framework MetalKit \
  -framework QuartzCore -framework Foundation -o metal-benchmark-projection-x64
```

Copy only that executable and `Shaders.metal` into the guest's temporary
benchmark directory. Run each mode from that directory, without the GPU adapter:

```bash
env SECONDS=30 TRIANGLES=100000 NOVSYNC=1 MODE=triangles ./metal-benchmark-projection-x64
env SECONDS=30 TRIANGLES=100000 NOVSYNC=1 MODE=strips ./metal-benchmark-projection-x64
```

The tool self-terminates and prints `RESULT`. Observe actual moving geometry
in both modes and require exit 0. Its 800x600 drawable differs from GravityMark's
FHD workload. `TRIANGLES` is an input geometry parameter; the tool's generated
counts here are 200978 triangles per frame and 400961 for strips. Around
160 fps is the observed scheduling rate, not evidence of GPU saturation.
