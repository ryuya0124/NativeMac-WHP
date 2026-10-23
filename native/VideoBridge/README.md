# Host hardware video transport

`host.py` exposes bounded NVENC/NVDEC batch processing on a Windows loopback
listener. `roundtrip.py` creates NV12 frames in the Intel VM, sends them for
hardware encoding and decoding, and checks returned luma and chroma pixels.
FFmpeg's explicit `*_nvenc` and `*_cuvid` paths have no software fallback.

The batch transport does **not** register a VideoToolbox codec, accelerate
ordinary macOS applications or repair Safari. Hardware labels in its responses
describe the host codec worker. The explicit VideoToolbox streaming experiment
below is separate and remains incomplete.

Start on Windows with an installed FFmpeg containing NVENC and CUVID:

```powershell
python native/VideoBridge/host.py --port 54880
```

Expose that loopback port through an authenticated SSH forward. For a relay
Mac, the Windows connection can use
`-R 127.0.0.1:54881:127.0.0.1:54880`; the guest connection uses
`-L 127.0.0.1:54882:127.0.0.1:54881` to the same relay. Both listeners stay on
loopback. Use existing authorized SSH identities; never commit their keys.
The test harness should terminate only the tunnel process it starts.

Run in the guest:

```bash
python3 roundtrip.py --base http://127.0.0.1:54882
python3 roundtrip.py --width 854 --height 480 --frames 12
python3 roundtrip.py --width 1920 --height 1080 --frames 3
python3 roundtrip.py --width 3840 --height 2160 --frames 2
```

The measured RTX 5080 path passes H.264 and HEVC for these small batches.
See [aggregate evidence](../../docs/verification/video-hardware-transport.json).
These checks do not measure sustained throughput, rate control, arbitrary
input streams, reordering, HDR or browser integration.

Requests are serialized, limited to 64 MiB, even NV12 dimensions up to
3840×2160 and 120 frames. Each FFmpeg worker runs in its own kill-on-close
Windows job with a 20-second / 1-GiB bound. That video-worker bound is separate
from the shader translator's unchanged 20-second / 500-MiB boundary. CUDA
initialization and FHD/4K decode surfaces can exceed 512 MiB. Temporary files
are owned by one request and removed on completion. The remote caller supplies
no executable, filesystem path or command options.

## Experimental VideoToolbox streaming

`stream.py`, `matroska.py` and `server.py` keep one Windows NVDEC worker alive
across compressed packets. `VTDecoder.mm` implements an authored decoder for
an Intel guest test process; `VTStreamProbe.mm` registers it explicitly and
uses ordinary H.264 VideoToolbox session/decode/finish APIs with hardware
required and temporal processing enabled. These are private component
interfaces, with BSD-licensed WebKit declarations under `spi/`.

The checked 320×180 / 90-frame B-frame test completes: all 7,776,000 NV12 bytes
match an independent CUDA/CUVID decode, original sample timestamps match,
callbacks report zero errors and the hardware decoder property is true.
The Windows worker also separately produces frames before EOF, preserving
reordering within CUVID's 100 ns timestamp clock. This checks decoded bytes
and timing; it does not qualify RGB color conversion, HDR or playback speed.
See [streaming evidence](../../docs/verification/video-vt-stream.json).

This is **not ready for ordinary applications**:

- Automatic component selection rejects the ad-hoc probe's signature
  (`SecStaticCodeCheckValidity = -67050`), even though the registry scans its
  metadata and a standalone authored program can load its factory. Signature
  enforcement was not changed. The temporary installed probe bundles were
  removed; normal VM startup does not select this decoder.
- Low-delay calls and early session invalidation still fail the bounded
  regression tests. Only finishing the complete temporal stream is qualified.
  Midstream drain/reset, seeking, preroll and format changes remain unsupported.
- The VideoToolbox encoder side is absent. NVENC is tested through the separate
  Windows worker, not ordinary VM recording/encoding applications.
- Only H.264 is qualified for the streaming VT component. HEVC/4K batch results
  do not qualify HEVC streaming or sustained 4K playback. Frames currently pass
  through CPU-addressable NV12 copies and SSH forwards; this is not zero copy.

Create a synthetic fixture on Windows, using installed FFmpeg/ffprobe paths:

```powershell
python native/VideoBridge/make_fixture.py --ffmpeg C:/path/ffmpeg.exe `
  --ffprobe C:/path/ffprobe.exe --out artifacts/my-video-fixture
python native/VideoBridge/server.py --ffmpeg C:/path/ffmpeg.exe --port 54883
```

The fixture uses NVENC GPU 0, two B frames and a 30-frame GOP; its independent
byte baseline uses CUVID GPU 0. This was tested on the RTX 5080 at that index;
automatic CUDA-device matching to the VM's selected renderer is not implemented.
The destination directory must be new. Do not commit generated movies, packets
or raw pixels.

For the streaming service, forward Windows loopback 54883 to relay loopback
54884, then guest loopback 54885 to relay loopback 54884. Keep all listeners
on loopback and use authenticated SSH identities, as with the batch service.
Copy the source directory, `input.json` and `baseline.nv12` into an Intel guest
test folder, then run:

```bash
bash build_probe.sh
./VTStreamProbe input.json baseline.nv12
```

The build prints the SDK ABI measurement first. The qualified x86-64 layout
has a four-byte class-version field; the implementation pads its class tables
accordingly. It deliberately rejects other target architectures at compile time.
`build_probe.sh` does not install any component. `ProbeCodec-Info.plist` uses
only an authored test codec tag for the failed automatic-discovery experiment.
`--low-delay` and `--cancel` reproduce the known failures, with an eight-second
self-deadline; their timeout is a failure, not a successful cancellation test.
The full probe has a 45-second self-deadline.

The streaming listener permits two codec sessions. Compressed packets are at
most 8 MiB, configuration at most 64 KiB, and dimensions even up to 3840×2160.
Host and guest queues are bounded. Each FFmpeg worker retains the separate
1-GiB job limit, a 20-second pending-work watchdog, 300-second idle deadline
and one-hour lifetime limit. These video limits do not change shader translation
limits. A protocol, codec or hardware failure never enables a software decoder.
