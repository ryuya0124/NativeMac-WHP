# Standard-app hardware video bridge

The Intel development guest can use the Windows renderer's NVDEC/NVENC through
ordinary VideoToolbox, AVFoundation and Safari APIs. Apps need no custom launch
wrapper after the explicit system profile is enabled. This is an authored
paravirtual codec component, not an NVIDIA macOS kernel driver.

The qualified path is 8-bit progressive 4:2:0 H.264 / HEVC, even dimensions up to
3840×2160. H.264 Main / Constrained Baseline / High and HEVC Main encoding are
mapped to actual NVENC profiles. AV1, VP9, 10-bit/HDR, alpha, midstream coded-size
changes and arbitrary application-specific codecs are not implemented. Apps
that explicitly disable hardware or select a different encoder retain that
choice. This is not a claim that every application or media format works.

## How it works

- `NvdecWorker.cpp` calls NVIDIA's NVDEC API directly. `CodecWorker.cpp` uses
  matching FFmpeg API headers/DLLs and the hardware-only NVENC encoders.
- `server.py` owns bounded workers on Windows loopback. The selected Vulkan
  renderer is read afresh with the same probe used by the VM launcher; CUDA
  matching must identify one unique adapter. No model name or ordinal is fixed.
- `Run-VideoBridge.py` owns the service and one authenticated SSH reverse
  forward. Kill-on-close Windows jobs and a handle to the VM launcher prevent
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

NV12 currently crosses CPU-addressable buffers and SSH. Hardware codec work is
on the GPU, but transport is not zero copy. A relay can limit throughput;
short 4K checks do not establish sustained 4K playback/encoding frame rates.

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
  "guestUser": "your-guest-account",
  "knownHosts": "artifacts/guest-ssh-known_hosts",
  "sshPort": 59220,
  "jump": "your-account@your-authorized-relay"
}
```

The SSH port must already reach the guest's loopback SSH endpoint, directly or
through the optional jump. Use an already trusted host key and authorized SSH
identity. Do not put passwords or keys in the configuration. With
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
against an independent NVDEC baseline. It covers full/low-delay streams,
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

## Bounds

Two concurrent codec sessions; compressed packets at most 8 MiB; configuration
at most 64 KiB; bounded host/guest queues. Each native Windows worker is in a
separate 1-GiB kill-on-close job with a 20-second pending-work watchdog,
300-second idle timeout and one-hour lifetime. The guest broker bounds relay
writes/idle/lifetime too. No guest caller supplies executable paths, GPU
indices, filesystem paths or FFmpeg arguments. A hardware/protocol failure
never selects a software codec in this bridge.
