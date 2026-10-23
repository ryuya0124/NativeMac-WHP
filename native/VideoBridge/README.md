# Standard-app hardware video bridge

The Intel development guest can use the Windows renderer's NVDEC/NVENC through
ordinary VideoToolbox, AVFoundation and Safari APIs. Apps need no custom launch
wrapper after the explicit system profile is enabled. This is an authored
paravirtual codec component, not an NVIDIA macOS kernel driver.

The qualified path is 8-bit progressive 4:2:0 H.264 / HEVC, even dimensions up to
3840×2160. VP9 profile 0 decoding also covers reference-surface redisplay and an
authored invisible-keyframe/redisplay superframe. H.264 Main / Constrained
Baseline / High and HEVC Main encoding map to actual NVENC profiles. AV1,
VP9 encoding, 10-bit/HDR, alpha, midstream coded-size
changes and arbitrary application-specific codecs are not implemented. Apps
that explicitly disable hardware or select a different encoder retain that
choice. This is not a claim that every application or media format works.

## How it works

- `NvdecWorker.cpp` calls NVIDIA's NVDEC API directly. `CodecWorker.cpp` uses
  matching FFmpeg API headers/DLLs and the hardware-only NVENC encoders.
- `server.py` owns bounded workers on Windows loopback. The selected Vulkan
  renderer is read afresh with the same probe used by the VM launcher; CUDA
  matching must identify one unique adapter. No model name or ordinal is fixed.
- `Run-VideoBridge.py` owns the codec, optional audio and direct pinned TLS
  services. There is no SSH media route or SSH fallback. Kill-on-close Windows
  jobs and a handle to the VM launcher prevent
  orphan processes; guest startup/reconnection has a bounded retry window.
- The root guest `GuestBroker.cpp` exposes a fixed Mach service and anonymous
  codec pipes. Sandboxed Safari/WebKit processes use pipes; they do not acquire
  general networking or a relaxed sandbox. Readiness uses libdispatch because
  direct poll/kevent calls are rejected by WebKit's syscall filter.
- `VideoBridgeEntry.m` registers factories lazily when video APIs are called.
  Catalog-loaded components borrow its pre-sandbox Mach capability. The
  low-latency selection maps to NVENC ULL / zero delay / no B frames, rather
  than Apple's exclusive conferencing selector. Unsupported properties still
  fail. avc1/hvc1 parameter sets remain out of band; sync samples omit NotSync.
- Root-owned system, background and GUI launch jobs set the same helper for
  future standard launches and XPC children. A one-shot GUI initializer checks
  restored Safari's image metadata. If the helper is missing, it requests a
  graceful Safari relaunch through NSWorkspace; restarting only WebKit's GPU
  service does not refresh the parent's cached XPC environment. Already
  configured Safari is left running. Unknown metadata and a refused quit are
  reported, never force-quit. Session/window restoration remains Safari's
  normal behavior. No app/benchmark binary or sealed system volume is
  patched. The scoped development registry check still verifies the exact
  authored component's ad-hoc seal.

The deployed route still copies NV12 through CPU-addressable buffers, optional
lossless LZ4 and direct TLS. Hardware codec work runs on the GPU, but media
transport is not zero copy. Audio uses the separate virtual-output relay in
[`../AudioBridge`](../AudioBridge/README.md). Short 4K checks do not establish
sustained 4K playback/encoding frame rates. Actual YouTube playback remains
slow; a progressing media clock alone is not evidence of rendered frame rate.

## Build and opt in

This component ABI is restricted to the measured Darwin 25.6 x86-64 guest.
Do not install this profile on a physical Mac. The VM must boot with the
explicit `developmentSigning` setting (`amfi=0x80`). Windows signing policy,
macOS SSV and shader translator limits are unchanged.

Build Windows workers with Visual Studio C++ / Windows SDK 10.0.26100:

```powershell
scripts/Build-VideoWorker.ps1 -FfmpegHeaders C:/local/exact-ffmpeg-headers `
  -NvdecHeaders C:/local/nv-codec-headers/include/ffnvcodec
```

The measured FFmpeg headers are revision `199c479b9a`: avcodec 61.4.100 and
avutil 59.10.100, exactly checked against the locally installed DLLs.
NVDEC declarations were built from NVIDIA nv-codec-headers revision
`71acc268a541f7d7f33cf0387229e3015cfb4977`. Vendor headers, DLLs and executables
are local dependencies and are not distributed here.

Copy this source directory to an owned guest working folder, then:

```bash
bash build_video_bridge.sh
sudo bash enable_system_video.sh
```

This installs only the NativeMac component/support directory, its Mach broker,
and its named launch jobs. The GUI initializer may gracefully relaunch an
existing Safari missing the helper. Restart other existing consumers once.
Subsequent standard launches need no per-app environment or wrapper.
The legacy explicit `run_with_video.sh` remains useful for CLI diagnostics.
`disable_system_video.sh` removes the common opt-in, matching environment
values and owned launch jobs; reboot the guest afterwards to clear environment
values already inherited by long-lived GUI parents.

Create the ignored local `artifacts/video-service-config.json` on Windows:

```json
{
  "ffmpeg": "C:/local/ffmpeg/bin/ffmpeg.exe",
  "audio": true,
  "transportConfig": "artifacts/direct-media/host.json"
}
```

Install host Python's pinned dependency first:

```powershell
python -m pip install --only-binary=:all: -r native/VideoBridge/requirements-host.txt
```

Prepare and deploy the direct channel as documented in
[`../MediaTransport`](../MediaTransport/README.md). Its private keys, client
secret and guest configuration stay in ignored artifacts. With
`systemVideoBridge: true`, `Start-VM.ps1` starts/stops the service for both
WinUI and CLI VM launches. For an existing running VM, start it manually:

```powershell
python scripts/Run-VideoBridge.py --config artifacts/video-service-config.json
```

## Verification

Generate owned fixtures with `make_fixture.py` using installed FFmpeg/ffprobe;
`--gpu-name` must match the selected renderer if multiple CUDA adapters exist.
Generated movies, compressed packets, raw frames and guest logs stay local.

`VTStreamProbe` checks every returned NV12 byte and original presentation time
against an independent baseline. Normal fixtures use separate FFmpeg NVDEC;
the authored VP9 redisplay/superframe regressions use FFmpeg's software VP9
reference because its CUVID wrapper omits redisplay outputs. This reference is
test-only, never a live decoder fallback. The probe covers full/low-delay streams,
nonterminal drain, early cancellation and cancellation with output in flight.
`VTEncodeProbe` checks public VT compression, hardware selection, timestamps,
forced keyframes and sync attachment conventions. `--output-handler` covers
modern per-frame blocks, and `--profile baseline|main|high` selects real profiles.
`AVPlayerProbe` and `AVAssetWriterProbe` use public AVFoundation APIs without
manual component registration. Encoded output also needs independent decoding
and container timestamp checks; byte counts alone are not qualification.

Open `BrowserVideoProbe.html` in an ordinarily launched Safari and run its
checks. It records only an authored canvas, plays that MP4 while checking
changing pixels, and verifies WebCodecs output and two forced keyframes. A
passing page alone does not prove hardware use: correlate it with native
NVDEC/NVENC worker sessions. No camera, microphone, account or remote media is
needed. The optional download contains only the authored recording.

Aggregate measured results, including normal Dock launch and GUI-login
restoration, are in `../../docs/verification/video-standard-apps.json`.

The older `host.py` / `roundtrip.py` batch transport is retained for diagnostics.
Its standalone results are not evidence of ordinary-app acceleration.

## GPU sharing qualification

The experimental service path now connects the exported GPU buffer to the
Intel guest's NV12 IOSurfaces and ordinarily launched Safari. It uses a
separate `NativeMacNvdecGpuWorker.exe`, built with `-GpuExportOnly` instead
of `-InteropProbeOnly`, and the additive Reims integration in
`patches/reims-shared-gpu-video.patch`. The copy stays on the selected
CUDA/Vulkan UUID. GPU DMA also updates coherent guest RAM for CPU readers
and later paging; this is not VRAM-exclusive playback.

`Start-VM.ps1 -SharedGpuVideo -ExactHalfBlend` creates a private, per-launch
host control configuration and starts/stops the codec service with the VM.
The development defaults enable these switches. Explicit
`-SharedGpuVideo:$false` selects the older CPU-frame route. The guest and
host negotiate `shared-gpu-v1`; logs record the actual selected route. Missing
GPU dependencies fail startup, rather than claiming GPU transfer. TLS carries
compressed samples and small frame messages, never decoded pixels on this
path. The GPU control port is host loopback only, separately authenticated;
OS handles and the host key are never sent to the guest.

Each frame gets a fresh capability, a twenty-second target deadline and
strong resource holds through GPU completion. Disconnects disarm reservations.
The CoreVideo pool has at most 24 buffers, reused only after consumers release
them. Metadata occupies 64 bytes at offset 1024 of the alignment page,
preserving CoreVideo's planar header. Each acquisition prepares the current
backing after guest discard/rebind. Completion publishes an IOSurface seed
change, without CPU frame reads or writes. A VP9 stream starting without its
references explicitly drops samples until its first real keyframe; drops
retain the original timestamps and are terminal callbacks.

The current VM uses `defaults write com.apple.universalaccess reduceTransparency -bool true`
before ordinary apps start. This avoids an
observed unsupported blended framebuffer-fetch path during desktop login;
`half_blend` alone does not fix that path. This is a visual-setting workaround,
not general shader support. Guest preparation/synchronization still limits
playback: the observed YouTube display notifications were about 19/s at FHD
and 13/s at 4K, with adaptive counter resets. No 4K60 qualification or new
Geekbench gain is claimed. NVENC input and PCM audio still use CPU buffers.

The five byte/PTS checks, 3,060 retained-frame checks, thirteen drain/cancel
cases, two missing-reference VP9 cases and Safari recording/WebCodecs results
are in `docs/verification/video-shared-gpu-guest.json` (relative to repository
root). Reims core's 2,304 tests and strict clippy pass, but its full Windows
gate has unresolved toolchain/runtime failures. The Reims candidate remains
on its isolated branch, not merged into the owner's checkout.

`GpuFrameInterop.cpp` and the separate `NativeMacNvdecInteropProbe.exe` execute
NVDEC -> CUDA device copy -> exported device-local Vulkan buffer -> optimal
R8/RG8 plane images. CUDA/Vulkan UUIDs must match, and two imported binary
semaphores transfer GPU ownership in both directions. NVDEC post-processing
and the CUDA copy share one stream. A nonblocking consumer on another stream
can race post-processing and return stale pixels.

This executable reads the plane images back **after** Vulkan consumes them,
solely to validate every byte and PTS. It is not the production worker, a
guest IOSurface bridge, a playback benchmark or proof of CPU-free Safari.
The normal service never starts it. Build with locally obtained Khronos
Vulkan-Headers (tested tag `v1.4.341`, commit
`b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2`):

```powershell
scripts/Build-VideoWorker.ps1 -FfmpegHeaders C:/local/ffmpeg-headers `
  -NvdecHeaders C:/local/nv-codec-headers/include/ffnvcodec `
  -VulkanHeaders C:/local/Vulkan-Headers/include -InteropProbeOnly
python native/VideoBridge/verify_gpu_interop.py --fixture C:/local/authored/input.json `
  --baseline C:/local/authored/baseline.nv12 `
  --worker artifacts/video-worker/NativeMacNvdecInteropProbe.exe `
  --gpu-name "name of the actual selected Windows renderer"
```

The verifier retains the normal worker's 1-GiB job, watchdog and queue bounds.
The checked fixture/baseline are limited to 16/64 MiB and 120 frames. Results
and precise limits are in `../../docs/verification/video-direct-gpu-sharing.json`.

## Bounds

Two concurrent codec sessions; compressed packets at most 8 MiB; configuration
at most 64 KiB; bounded host/guest queues. Each native Windows worker is in a
separate 1-GiB kill-on-close job with a 20-second pending-work watchdog,
300-second idle timeout and one-hour lifetime. The guest broker bounds relay
writes/idle/lifetime too. No guest caller supplies executable paths, GPU
indices, filesystem paths or FFmpeg arguments. A hardware/protocol failure
never selects a software codec in this bridge.
