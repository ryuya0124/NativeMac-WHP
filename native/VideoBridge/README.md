# Host hardware video transport

`host.py` exposes bounded NVENC/NVDEC batch processing on a Windows loopback
listener. `roundtrip.py` creates NV12 frames in the Intel VM, sends them for
hardware encoding and decoding, and checks returned luma and chroma pixels.
FFmpeg's explicit `*_nvenc` and `*_cuvid` paths have no software fallback.

This is a transport prototype. It does **not** register a VideoToolbox codec,
accelerate ordinary macOS applications or repair Safari. Hardware labels in
its responses describe the host codec worker, not the guest's system APIs.

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
