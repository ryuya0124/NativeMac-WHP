# Resident-pointer search measurement

`ResidentSearch.metal` follows pointers stored in a buffer. For each of six
resident-set sizes (1, 4, 16, 64, 256 and 4096 buffers), 65536 GPU threads
perform sixteen exact integer reads. The host checks every result against a
separate CPU calculation, in every round. The first round is discarded from
timings; seven subsequent rounds are reported.

Compile the authored shader on a Mac with the Metal command-line tools:

```bash
xcrun -sdk macosx metal -std=macos-metal2.4 -c ResidentSearch.metal -o ResidentSearch.air
xcrun -sdk macosx metallib ResidentSearch.air -o ResidentSearch.metallib
clang -O2 -fobjc-arc -Wall -Wextra -Werror ResidentSearchReference.m \
  -framework Foundation -framework Metal -o ResidentSearchReference
./ResidentSearchReference ResidentSearch.metallib
```

The reference also accepts the `.metal` source directly and compiles it with
Metal language version 2.4. This avoids loading a newer Mac's AIR deployment
version on an older guest. It exits 77 before dispatch if a virtual driver
exposes no public buffer GPU addresses; that is unavailable, not a pass.

On Windows, obtain the pinned translator sources under
`backend/metal2-stability`, then build this manifest in release mode and pass
the authored metallib to the executable. Rust must satisfy that source's MSRV.
Use a separate target directory for a comparison build. The runtime uses the
real selected Vulkan GPU. Its GPU timestamp duration is distinct from the
wall time for command encoding, submission and completion.

Compare the unmodified e839093/semantics-1698 source with the resident-search
patch/semantics-1699 source. Run A/B/A/B with the VM paused and no other GPU
test. The recorded result is a shader-path measurement; it is not a claim of
equivalent gains in applications, games or Geekbench.

`SubmissionProbe.m` is a separate test of CPU-visible encode/commit/wait
costs, batch sizes and shared/private memory placement. Its final private
buffer readback is checked outside its timed interval.
