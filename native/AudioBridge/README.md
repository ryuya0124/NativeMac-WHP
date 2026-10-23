# Virtual VM output to Windows playback

`AudioRelay.mm` captures only the fixed `BlackHole2ch_UID` virtual device and
sends 48-kHz stereo float32 PCM to the guest's local direct-media endpoint.
`server.py` submits it through Windows WinMM. No physical microphone is selected;
audio is handled by the CPU. No PCM is saved. The relay does not use SSH.

Install the separate, official signed/notarized
[BlackHole 2ch](https://existential.audio/blackhole/) driver in the development
guest and select it as the system output. The tested 0.7.1 installer SHA-256 is
`57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf`.
The vendor installer/binary is not distributed here. An absent CoreAudio output
can make AVFoundation/YouTube fail even when hardware video decoding succeeds.

After deploying the source to an owned Intel guest directory:

```bash
bash build.sh --development-vm
sudo bash install.sh
```

This installation is restricted to the measured x86-64 Darwin 25.6 development
VM with `amfi=0x80`. The opt-in development build adds the microphone TCC allow
entitlement solely to this virtual-output relay. In this guest boot mode macOS
labels ad-hoc executables platform binaries and refuses the normal TCC prompt.
No TCC database, global permission, sealed system volume or physical input is
modified. `build.sh` without the switch uses only the public audio-input
entitlement; it does not bypass a permission prompt.

The root-owned app is installed under `/Library/Application Support/NativeMac/AudioBridge`;
LaunchAgent `io.nativemac.audio.relay` starts it at GUI login. Configure the
[`direct media channel`](../MediaTransport/README.md) and set `audio: true` in
the host video service configuration. The callback uses a fixed 64-KiB ring and
drops new blocks on backpressure; it never blocks or allocates. Reconnects drop
stale ring contents. Windows uses four reusable output buffers with a bounded
wait. No unbounded audio latency queue is allowed.

`sudo bash disable.sh` stops/removes the owned launch job. It retains the
third-party audio driver and installed app. Switch the output device separately
if desired. Live audible output was confirmed by the user; source builds,
service restarts and nonzero Windows audio submissions were also checked.
This is not a complete cold-boot or long-term A/V synchronization qualification.
